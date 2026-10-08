# Parallel mark.
#
# Library heaps (`stop_the_world == false`): Crystal::Thread helpers steal grey
# work under `@mark_lock`.
#
# Process GC (`stop_the_world`): Crystal::Thread would freeze in `stop_world`, so
# helpers are raw `Gcry::OS.pthread_create` threads (not registered with Crystal).
# They only touch mark state / heap headers — no Fiber, no managed alloc.
#
# Fields (@parallel_mark_workers, …) are declared/initialized in heap.cr.

require "./platform/os"

{% unless flag?(:win32) %}
  lib LibC
    fun pthread_create(thread : PthreadT*, attr : PthreadAttrT*, start : Void* -> Void*, arg : Void*) : Int
    fun pthread_join(thread : PthreadT, retval : Void**) : Int
  end
{% end %}

# The compare-and-wait primitives idle markers sleep on (`mark_wait`,
# `mark_wake`). Linux has `futex` through `syscall`. libSystem exports
# `__ulock_wait`/`__ulock_wake`, the pair libc++ waits `std::atomic` with on
# Apple targets; the timeout is in microseconds and 0 means none. Windows has
# `WaitOnAddress` (Windows 8+), which lives in the `Synchronization` import
# library, not kernel32.
{% if flag?(:darwin) %}
  lib LibC
    fun gcry_ulock_wait = __ulock_wait(operation : UInt32, addr : Void*, value : UInt64, timeout_us : UInt32) : Int
    fun gcry_ulock_wake = __ulock_wake(operation : UInt32, addr : Void*, wake_value : UInt64) : Int
  end
{% elsif flag?(:win32) %}
  @[Link("synchronization")]
  lib LibGcryWindowsSync
    fun WaitOnAddress(address : Void*, compare_address : Void*, address_size : LibC::SizeT, milliseconds : UInt32) : Int32
    fun WakeByAddressSingle(address : Void*) : Nil
    fun WakeByAddressAll(address : Void*) : Nil
  end
{% end %}

# C ABI entry — must not be a Crystal::Thread so STW will not suspend it.
fun gcry_mark_worker_main(arg : Void*) : Void*
  Gcry::Heap.run_mark_worker(arg)
  Pointer(Void).null
end

module Gcry
  class Heap
    MAX_MARK_PTHREADS = 15

    def parallel_mark_workers : Int32
      @parallel_mark_workers
    end

    # Serial under `-Dwithout_mt` off Windows: `Crystal::SpinLock` compiles to
    # nothing there, so `@mark_lock` would not guard the shared mark stack.
    def parallel_mark_workers=(value : Int32) : Int32
      {% if flag?(:without_mt) && !flag?(:win32) %}
        @parallel_mark_workers = 1
      {% else %}
        @parallel_mark_workers = @force_serial_mark ? 1 : value.clamp(1, 16)
      {% end %}
    end

    # The process GC's default worker count for *cpus* CPUs (gc_override.cr
    # has the measurements): two up to 7 CPUs, then one per four CPUs, at most
    # `cpus − 1` and 8, at least 1.
    def self.default_mark_workers(cpus : Int32) : Int32
      small = cpus - 1 < 2 ? cpus - 1 : 2
      wide = cpus // 4 + 1
      wide = cpus - 1 if wide > cpus - 1
      wide = 8 if wide > 8
      n = small > wide ? small : wide
      n < 1 ? 1 : n
    end

    # Below this many live bytes at the last major, mark serially even with
    # helpers configured (`GCRY_PARALLEL_MARK_MIN_LIVE`, default 0: always
    # parallel). A small heap gives four workers nothing to divide and still
    # costs their wake-up and termination: Kemal `/json`, 0.3 ms pauses, ran
    # 4–16 points slower with four than with one, while a 500 MiB heap marks
    # 2× faster with them (`bench/log/linux/2026-10-04-parallel-mark-pushbuf/`).
    property parallel_mark_min_live : UInt64 = 0_u64

    # Research only — `GCRY_DISABLE_PARALLEL_MARK=1`: pin workers at 1 even
    # if a later assignment asks for more. `make parallel-mark-process`
    # `--disabled` is the red arm — stolen stays 0. Never a product setting.
    def force_serial_mark? : Bool
      @force_serial_mark
    end

    def force_serial_mark=(value : Bool) : Bool
      @force_serial_mark = value
      @parallel_mark_workers = 1 if value
      value
    end

    # Research only — `GCRY_MARK_BUSY_UNLOCKED=1`: count a mark worker busy
    # *after* releasing the lock that gave it the batch, as gcry did before
    # 2026-09-04, and widen the window that opens. The master then reads
    # `busy == 0` and an empty stack while a worker holds up to
    # `MARK_POP_BATCH` unscanned objects, ends the cycle, and sweeps their
    # unmarked children. `make parallel-mark-termination` uses it as the red
    # arm. Never ship non-false: this reclaims live objects.
    property mark_busy_unlocked : Bool = false

    # Diagnostic: what `shutdown_mark_workers` will actually try to join.
    # A non-zero count with `parallel_mark_workers == 1` means this bookkeeping
    # has been corrupted, not that workers exist.
    # Diagnostic: the mark stack as a raw pointer, so a test can ask another
    # heap whether it still considers this object live.
    def mark_stack_object : Void*
      @mark_stack.as(Void*)
    end

    def mark_worker_pool_state : {Int32, Int32, Bool}
      {@mark_worker_threads.size, @mark_pthread_count, @mark_pthread_mode}
    end

    def parallel_mark_runs : UInt64
      @parallel_mark_runs
    end

    def parallel_mark_stolen : UInt64
      @parallel_mark_stolen
    end

    # Waits of an idle marker on `@mark_wake` (`mark_wait`) that a wake ended
    # before their timeout. Every collection with parked helpers has some —
    # the cycle's start and end wake all of them — so a parallel mark that
    # leaves it at 0 has markers that only ever time out, which is what every
    # target but Linux had until 2026-10-08.
    def parallel_mark_wakes : UInt64
      @parallel_mark_wakes.get
    end

    # Entry for `gcry_mark_worker_main` (raw pthread).
    def self.run_mark_worker(arg : Void*) : Nil
      arg.as(Heap).mark_worker_loop
    end

    protected def ensure_mark_worker_pool : Nil
      return if @parallel_mark_workers <= 1

      need = @parallel_mark_workers - 1
      if @stop_the_world
        ensure_mark_pthreads(need)
      else
        ensure_mark_crystal_threads(need)
      end
    end

    private def ensure_mark_crystal_threads(need : Int32) : Nil
      while @mark_worker_threads.size < need
        heap = self
        @mark_worker_threads << Thread.new do
          heap.mark_worker_loop
        end
      end
      @mark_pthread_mode = false
    end

    private def ensure_mark_pthreads(need : Int32) : Nil
      return if @mark_pthread_count >= need

      @mark_pthread_mode = true
      while @mark_pthread_count < need && @mark_pthread_count < MAX_MARK_PTHREADS
        tid = uninitialized Gcry::OS::PthreadT
        rc = Gcry::OS.pthread_create(
          pointerof(tid),
          Pointer(Gcry::OS::PthreadAttrT).null,
          ->gcry_mark_worker_main(Void*),
          self.as(Void*),
        )
        break if rc != 0
        # Name it here, on the handle, before this loop hands control back.
        #
        # These helpers are raw `pthread_create` threads on purpose, so they
        # are outside Crystal's list by construction — and
        # `GCRY_THREAD_CENSUS=1` read that as "thread(s) are outside Crystal's
        # list … at least one is unrecorded", i.e. as the open
        # unscanned-mutator defect. Measured 2026-09-19: `GCRY_PARALLEL_MARK=4`
        # with no other thread reports `gap=3`, exactly the three helpers.
        # They touch mark state and block headers only — no Fiber, no managed
        # allocation — so they can hold no mutator reference.
        #
        # From the creating side rather than from the helper itself: a thread
        # that names itself is unnamed for a moment, and the census caught one
        # in that state on aarch64 (run `35448782491`, `2 are gcry's own …
        # leaving 2 unexplained`, then `3 … leaving 1` one collection later).
        # The creator is the collector, so it cannot be here and in a stop at
        # once, which closes the window rather than narrowing it.
        Gcry::Platform.name_own_thread(tid, "gcry-mark")
        @mark_pthreads[@mark_pthread_count] = tid
        @mark_pthread_count += 1
      end
    end

    protected def shutdown_mark_workers : Nil
      @mark_shutdown.set(1)
      @mark_epoch.add(1)
      wake_mark_helpers

      if @mark_pthread_mode || @mark_pthread_count > 0
        @mark_pthread_count.times do |i|
          Gcry::OS.pthread_join(@mark_pthreads[i], Pointer(Void*).null)
        end
        @mark_pthread_count = 0
        @mark_pthread_mode = false
      end

      unless @mark_worker_threads.empty?
        @mark_worker_threads.each &.join
        @mark_worker_threads.clear
      end

      @mark_shutdown.set(0)
      @mark_workers_busy.set(0)
      @mark_parallel = false
    end

    # Abandon helpers after fork (only the forking thread survives).
    protected def reset_mark_workers_after_fork : Nil
      @mark_worker_threads.clear
      @mark_pthread_count = 0
      @mark_pthread_mode = false
      @mark_parallel = false
      @mark_shutdown.set(0)
      @mark_workers_busy.set(0)
      @mark_sleepers.set(0)
      @mark_spinners.set(0)
      @mark_lock = Crystal::SpinLock.new
      @mark_epoch = Atomic(UInt64).new(0_u64)
      # The forking thread keeps its slot (it becomes the sole thread), but the
      # claim counter resets so a rebuilt pool re-numbers from 1. Shard buffers
      # survive — they are mmap, inherited across fork, and reused.
      @mark_slot_claim = Atomic(Int32).new(1)
      Heap.mark_worker = 0
    end

    # Helper loop (Crystal::Thread or raw pthread). No managed-heap alloc.
    # Per-worker shard: how much a worker accumulates before publishing to the
    # shared stack, and how much it takes back per lock. Both amortise the lock
    # to once per few hundred objects instead of once per object, which is what
    # made parallel mark 60x slower than serial.
    MARK_PUSHBUF_CAP = 512

    # Idle helper backoff: this many `pause` polls (~tens of µs) before it
    # starts sleeping, then sleeps of this many ns. See `mark_worker_loop`.
    MARK_IDLE_SPINS    =  20_000
    MARK_IDLE_SLEEP_NS = 200_000
    # The sleep doubles while nothing comes, up to this. At a flat 200 µs three
    # idle helpers woke ~15 000 times a second, and on a 4-vCPU runner serving
    # Kemal that cost `/` 10–14 points of throughput even with every mark
    # serial (`GCRY_PARALLEL_MARK_MIN_LIVE` above the live set).
    MARK_IDLE_SLEEP_MAX_NS = 5_000_000
    # In a cycle: how long a marker polls an empty shared stack before it
    # parks (`park_idle_marker`), and the park's timeout, doubling from the
    # first value to the second while nothing comes.
    MARK_STEAL_SPIN_NS    =    50_000
    MARK_STEAL_NAP_NS     =   100_000
    MARK_STEAL_NAP_MAX_NS = 1_000_000

    # How long a marker has found the shared stack empty in a row. Timed, not
    # counted: one `Intrinsics.pause` poll is 20 ns on this x86-64 host, and
    # on aarch64 the pause is a YIELD, a cycle or so, so a count that spins
    # 40 µs here would spin a few there. The clock is read when the drought
    # starts and every 128 polls after.
    #
    # While it spins the marker is counted in `spinners` (the heap's
    # `@mark_spinners`): an awake marker that will take whatever is
    # published next, so a publisher need not wake a parked one.
    struct MarkDrought
      def initialize(@spinners : Int32*)
        @polls = 0
        @from = 0_u64
        @over = false
      end

      # Work came, or the cycle ended.
      def reset : Nil
        spinner(-1) if @polls > 0 && !@over
        @polls = 0
        @over = false
      end

      # One more empty poll. True once the stack has been empty for
      # `MARK_STEAL_SPIN_NS`, and from then until `reset`.
      def over? : Bool
        return true if @over
        @polls &+= 1
        if @polls == 1
          spinner(1)
          @from = Clock.monotonic_ns
        elsif @polls & 127 == 0 && Clock.monotonic_ns &- @from >= MARK_STEAL_SPIN_NS
          # Uncounted before the park's check of the stack, which is under
          # the lock a publisher pushes under before it reads the count.
          spinner(-1)
          @over = true
        end
        @over
      end

      # The count is the heap's `Atomic(Int32)`, changed in place.
      private def spinner(by : Int32) : Nil
        Atomic::Ops.atomicrmw(LLVM::AtomicRMWBinOp::Add, @spinners, by, LLVM::AtomicOrdering::SequentiallyConsistent, false)
      end
    end

    MARK_POP_BATCH = 256
    # Entries are {header, chunk} pairs, so the flat buffer is twice the count.
    # Literal, not `MARK_POP_BATCH * 2`: a computed constant initializer runs
    # before Fiber is up during GC.init (see size_classes.cr).
    MARK_POP_BATCH_WORDS = 512

    # Which shard the current OS thread owns. -1 until claimed; the master sets
    # 0 explicitly. Survives across collections, so a pthread keeps its slot.
    @[ThreadLocal]
    @@mark_worker : Int32 = -1

    protected def self.mark_worker : Int32
      @@mark_worker
    end

    protected def self.mark_worker=(v : Int32) : Int32
      @@mark_worker = v
    end

    # Each worker's shard is its own 128-byte stride of `@mark_pushbuf_slots`:
    # the push buffer, as base, top and limit addresses, and the bytes the
    # worker scanned this cycle. No two workers' words share a cache line.
    # They were two `StaticArray`s indexed by slot — all sixteen counts in one
    # 64-byte line, written by every worker on every push. Sampled with four
    # workers on Primes, the count's read was 18.8% of all CPU and the
    # buffer's 18.5% (`bench/log/linux/2026-10-04-parallel-mark-pushbuf/`).
    MARK_PUSHBUF_STRIDE = 16
    # Slot 0 the master, 1..15 the helpers (`mark_worker_loop` caps a claim).
    MARK_SHARDS = 16
    # Words of a shard. Base is 0 until the buffer is mapped, and top and
    # limit with it, so an unmapped shard reads as full.
    SHARD_BASE    = 0
    SHARD_TOP     = 1
    SHARD_LIMIT   = 2
    SHARD_SCANNED = 3

    # A batch scan hands its shard down the scan path (`scan_object` →
    # `scan_payload` → `scan_edges_inline` → `mark_stack_push`); nil means
    # the caller has none — the serial drains, the finalizer pass — and the
    # push and the scanned-bytes count find it from `@@mark_worker`. Crystal
    # compiles a method once per argument type, so the scan path exists twice,
    # and the copy the serial drain runs reaches a shard only behind
    # `@mark_parallel`, the push through an out-of-line `push_to_own_shard`.
    #
    # That lookup used to be the only way. A `@[ThreadLocal]` read is an
    # out-of-line call — Crystal emits a `NoInline` accessor for every
    # thread-local class variable — and the scan made two per object, one for
    # the push and one for the byte count. On one long linked list, where a
    # single worker marks every node, the parallel path took 54 instructions
    # per object more than the serial drain: those two calls, a `memcpy` call
    # in the local drain (`scan_batch_local_first`), and the push's index
    # arithmetic. It takes 1 more now (callgrind, 300 000 nodes, two workers;
    # `bench/mark_list_heap.cr`, `bench/log/linux/2026-10-06-mark-idle/`).
    #
    # A struct around the pointer rather than the pointer: a struct is never
    # falsey, so a scan that was handed one tests nothing before it pushes or
    # counts, where a pointer is tested for null each time.
    struct MarkShard
      def initialize(@words : UInt64*)
      end

      @[AlwaysInline]
      def [](i : Int32) : UInt64
        @words[i]
      end

      @[AlwaysInline]
      def []=(i : Int32, value : UInt64) : UInt64
        @words[i] = value
      end
    end

    @[AlwaysInline]
    protected def mark_shard(slot : Int32) : MarkShard
      MarkShard.new(@mark_pushbuf_slots.to_unsafe + slot &* MARK_PUSHBUF_STRIDE)
    end

    # Lazily mmap a shard's push buffer. Called by a worker before it drains, and
    # by the master; mmap during a collection is fine (it is what MarkStack#grow
    # does), a managed allocation would not be.
    protected def ensure_pushbuf(shard : MarkShard) : Nil
      return if shard[SHARD_BASE] != 0_u64
      bytes = MARK_PUSHBUF_CAP.to_u64 * sizeof(Void*).to_u64
      ptr = Gcry.os_map(bytes)
      return if Gcry.mmap_failed?(ptr)
      shard[SHARD_BASE] = ptr.address
      shard[SHARD_TOP] = ptr.address
      shard[SHARD_LIMIT] = ptr.address &+ bytes
    end

    @[AlwaysInline]
    private def pushbuf_n(shard : MarkShard) : Int32
      ((shard[SHARD_TOP] &- shard[SHARD_BASE]) // sizeof(Void*).to_u64).to_i32!
    end

    # Publish one shard's accumulated children to the shared stack under one
    # lock. Single-writer per slot, so the buffer itself needs no lock.
    #
    # Parked markers (`park_idle_marker`) are woken only when the stack now
    # holds more than one pop takes: up to `MARK_POP_BATCH` entries is what
    # the publisher, awake and about to pop, takes back by itself, so a
    # sleeper woken for it would find nothing and park again. One sleeper is
    # woken per `MARK_POP_BATCH` held.
    protected def flush_pushbuf(shard : MarkShard) : Nil
      n = pushbuf_n(shard)
      return if n == 0
      buf = Pointer(Void*).new(shard[SHARD_BASE])
      @mark_lock.lock
      i = 0
      while i < n
        @mark_stack.push(buf[i].as(BlockHeader*))
        i += 1
      end
      depth = @mark_stack.size
      @mark_lock.unlock
      shard[SHARD_TOP] = shard[SHARD_BASE]
      wake_parked_markers(depth // MARK_POP_BATCH) if depth > MARK_POP_BATCH
    end

    # One entry onto the shared stack, outside a shard buffer: the rest of a
    # large payload being scanned in pieces, or a push with no buffer. A rest
    # entry is up to the whole payload's work in one entry, so a parked
    # marker is woken for it whatever the depth — unless one is awake and
    # spinning (`MarkDrought`), which will take it. Waking one per 64 KiB
    # piece regardless cost a syscall per piece: JsonGenerate +4.6% and
    # Revcomp +7.8% wall against spinning helpers (`ab-cm-1.txt` in
    # `bench/log/linux/2026-10-06-mark-idle/`).
    protected def publish_mark_entry(entry : BlockHeader*) : Nil
      @mark_lock.lock
      @mark_stack.push(entry)
      @mark_lock.unlock
      wake_parked_markers(1) if @mark_spinners.get == 0
    end

    # A parallel-mark push into `shard`'s buffer, unlocked (single writer),
    # flushed to the shared stack when full.
    @[AlwaysInline]
    protected def push_to_shard(header : BlockHeader*, shard : MarkShard) : Nil
      top = shard[SHARD_TOP]
      if top == shard[SHARD_LIMIT]
        # Full, or never mapped (all three words still 0).
        if shard[SHARD_BASE] == 0_u64
          publish_mark_entry(header)
          return
        end
        flush_pushbuf(shard)
        top = shard[SHARD_TOP]
      end
      Pointer(Void*).new(top).value = header.as(Void*)
      shard[SHARD_TOP] = top &+ sizeof(Void*).to_u64
    end

    # A parallel-mark push from a caller with no shard in hand: the thread's
    # own, found from `@@mark_worker`. Out of line, so the scan loop that
    # inlines `mark_stack_push` for the serial drain carries one call here
    # rather than this body. Inlined, it cost that loop six instructions per
    # object of register shuffling on a linked list, serial mark included
    # (callgrind, `bench/log/linux/2026-10-06-mark-idle/`).
    @[NoInline]
    protected def push_to_own_shard(header : BlockHeader*) : Nil
      slot = Heap.mark_worker
      # A thread with no claimed slot (should not happen on a mark worker)
      # falls back to the locked shared push rather than corrupting slot -1.
      if slot < 0
        publish_mark_entry(header)
        return
      end
      push_to_shard(header, mark_shard(slot))
    end

    # Scan a batch with the serial drain's prefetch (`prefetch_mark_entry`)
    # of the object `MARK_PREFETCH_DEPTH` ahead, while this one
    # scans. The batch scan had none, and mark is latency-bound — on 64-byte
    # objects the serial drain is **27.6% slower** without its ring
    # (`GCRY_PREFETCH=0`, t=+12.9), which is about the whole gap between two
    # parallel workers and one serial one at that size
    # (`bench/log/linux/2026-09-23-parallel-mark-scaling/`). `GCRY_PREFETCH=0`
    # turns this off too, so the A/B is one knob.
    @[AlwaysInline]
    private def scan_batch_prefetched(batch : Pointer(Void*), m : Int32, shard : MarkShard) : Nil
      unless @mark_prefetch
        i = 0
        while i < m
          scan_object(batch[i].as(BlockHeader*), shard)
          i += 1
        end
        return
      end
      ahead = m < MARK_PREFETCH_DEPTH ? m : MARK_PREFETCH_DEPTH
      j = 0
      while j < ahead
        prefetch_mark_entry(batch[j].as(BlockHeader*))
        j += 1
      end
      i = 0
      while i < m
        k = i + MARK_PREFETCH_DEPTH
        if k < m
          prefetch_mark_entry(batch[k].as(BlockHeader*))
        end
        scan_object(batch[i].as(BlockHeader*), shard)
        i += 1
      end
    end

    # A worker keeps scanning its own new children while there are few of
    # them, and publishes only when its push buffer has more than
    # `MARK_LOCAL_DRAIN_MAX`.
    #
    # Publishing every batch's children made a narrow graph pay two
    # `@mark_lock` round trips per object: this worker's flush, then some
    # worker's pop. Four threads contending for that lock on a linked list
    # cost far more than they gained. A 200 000-node chain took 834 ms per
    # collection with 4 workers against 4.7 ms serial on Linux x86_64, and on
    # Windows arm64 2 workers took 576 ms, 3 took 3 823 ms and 4 did not finish
    # in 120 s (2026-10-01). With this, 4 workers take 21 ms on that chain.
    #
    # The threshold is small on purpose. At 64, a fanout-6 graph grew two
    # levels locally before anyone could share it, and 4 workers were 5–8%
    # slower than with the old protocol (t≈3). At 4, a chain (one or two
    # children per node) stays local and a wider node is shared at once. On
    # `gc_phases --fanout=6 --shuffle` the difference from the old protocol
    # was −0.4% to +3.9%, within what the untouched serial path moved between
    # the two builds (+4.7%) (`bench/log/linux/2026-10-01-parallel-mark-local-first/`).
    # The 2026-09-23 local drain, rejected there, published only to an idle
    # peer and was measured on wide graphs alone.
    #
    # The termination check still holds. This worker has been counted busy
    # since the pop that gave it the batch, and stays busy until the caller's
    # `add(-1)` after the final flush, so every object it holds, scanned or
    # not, is covered by that count.
    private def scan_batch_local_first(batch : Pointer(Void*), m : Int32, shard : MarkShard) : Nil
      scan_batch_prefetched(batch, m, shard)
      base = shard[SHARD_BASE]
      if base != 0_u64
        buf = Pointer(Void*).new(base)
        loop do
          n = pushbuf_n(shard)
          break if n == 0 || n > MARK_LOCAL_DRAIN_MAX
          # At most `MARK_LOCAL_DRAIN_MAX` words: a loop, not `copy_from`,
          # whose variable length is a `memcpy` call — per node on a list.
          i = 0
          while i < n
            batch[i] = buf[i]
            i += 1
          end
          shard[SHARD_TOP] = base
          scan_batch_prefetched(batch, n, shard)
        end
      end
      flush_pushbuf(shard)
    end

    # Must not exceed `MARK_POP_BATCH`: the local drain reuses the pop buffer.
    MARK_LOCAL_DRAIN_MAX = 4

    # Take up to `cap` headers from the shared stack under one lock, and count
    # the taker busy **inside that same critical section**.
    #
    # The two have to be one step. The master stops when it sees
    # `busy == 0 && stack empty`, and the argument for that being stable is
    # that a worker can only become busy by popping a non-empty batch. With
    # the increment outside the lock the argument does not hold: a worker
    # pops the last batch, is preempted before `add(1)`, and the master reads
    # `busy == 0` and an empty stack in that window, ends the cycle and
    # sweeps — while the worker still holds up to `MARK_POP_BATCH` unscanned
    # objects whose children are unmarked and now unreachable from the mark.
    # Live objects are reclaimed. Counting under the lock closes it: an
    # observer holding the lock cannot see the stack lose entries without
    # seeing the taker become busy.
    #
    # An idle worker used to take the lock on every poll to find the stack
    # empty, and every take is a write to the lock's line, so pollers slowed
    # whoever had work to push. On native Windows arm64 a 256-chain mark still
    # took 33–44 s against 1 s serial after the local drain above, and
    # `parallel-mark-termination` did not finish in 600 s (2026-10-01). The
    # unlocked peek is safe: a worker that sees an empty stack takes nothing,
    # is not counted busy, and polls again.
    protected def pop_mark_batch(into : Pointer(Void*), cap : Int32) : Int32
      return 0 if @mark_stack.empty_unlocked?
      @mark_lock.lock
      # The cycle can end between a worker's `while @mark_parallel` and this
      # lock. After it ends, the master pushes onto `@mark_stack` and drains it
      # with no lock: the finalizer pass between two `mark_loop`s, for one.
      # A late worker that popped there raced those unlocked pushes and pops.
      # It then pushed its own children unlocked, since `mark_stack_push` reads
      # `@mark_parallel` false, and live objects went unmarked: `stw_mt` with
      # `GCRY_PARALLEL_MARK=4` lost explicitly rooted blocks or crashed in
      # about 1% of runs (2026-10-01). Both transitions happen under this lock,
      # so a pop here sees the cycle it belongs to or none.
      unless @mark_parallel
        @mark_lock.unlock
        return 0
      end
      n = 0
      while n < cap && !@mark_stack.empty?
        into[n] = @mark_stack.pop.as(Void*)
        n += 1
      end
      # Paired with the `add(-1)` every caller owes after its scan and flush.
      @mark_workers_busy.add(1) if n > 0 && !@mark_busy_unlocked
      @mark_lock.unlock
      if n > 0 && @mark_busy_unlocked
        # Research only: the protocol as it was before 2026-09-04 — the
        # increment outside the lock — with the window it left open widened
        # so the gate does not depend on losing a scheduling coin toss.
        i = 0
        while i < MARK_BUSY_DELAY_SPINS
          Intrinsics.pause
          i += 1
        end
        @mark_workers_busy.add(1)
      end
      n
    end

    MARK_BUSY_DELAY_SPINS = 4096

    # Both halves of the termination condition, from one critical section.
    # Read separately, an emptiness observed after a `busy` read describes two
    # different instants and neither is the one being decided about — which is
    # what the research arm restores.
    private def mark_drain_finished? : Bool
      if @mark_busy_unlocked
        return @mark_workers_busy.get == 0 && mark_stack_empty_locked?
      end
      # The idle workers' peek in `pop_mark_batch`, on the master's side. The
      # master asks this on every empty poll, and while workers still hold
      # batches the answer is no: taking the lock to hear it was a write to the
      # lock's line per poll, against the workers flushing children through
      # the same lock. Unlocked, a "no" is final for this poll; only a "maybe"
      # is decided below, under the lock, from one critical section. Measured
      # on native aarch64 once the Monitor stopped occupying a core during
      # the stop: `parallel-mark-termination` 140–412 s per run against 25–75 s
      # (`bench/log/linux/2026-10-03-monitor-wait-spin/`).
      return false if @mark_workers_busy.get != 0 || !@mark_stack.empty_unlocked?
      @mark_lock.lock
      done = @mark_workers_busy.get == 0 && @mark_stack.empty?
      @mark_lock.unlock
      done
    end

    private def mark_stack_empty_locked? : Bool
      @mark_lock.lock
      e = @mark_stack.empty?
      @mark_lock.unlock
      e
    end

    protected def mark_worker_loop : Nil
      # Claim a shard slot once, on first wake, and keep it.
      if Heap.mark_worker < 0
        slot = @mark_slot_claim.add(1)
        slot = 15 if slot > 15
        Heap.mark_worker = slot
        ensure_pushbuf(mark_shard(slot))
      end
      shard = mark_shard(Heap.mark_worker)

      local_epoch = 0_u64
      batch = uninitialized StaticArray(Void*, MARK_POP_BATCH)
      # Between collections a helper has nothing to do, and it used to spin on
      # `@mark_epoch` with `Intrinsics.pause` for as long as the program ran:
      # **a full core per helper, forever** — measured on an idle process,
      # `GCRY_PARALLEL_MARK=2/4/8` burned 100% / 301% / 703% of one core
      # while the mutator slept (2026-09-23). So it spins for
      # `MARK_IDLE_SPINS` polls — long enough to catch the back-to-back
      # epoch bumps of one collection without a syscall — and then sleeps in
      # `MARK_IDLE_SLEEP_NS` steps. The cost is at most one sleep of lateness
      # joining a collection that starts after an idle stretch; the master
      # starts marking alone and a late helper picks up from the shared stack,
      # so lateness costs parallelism, never correctness. Polling rather than a
      # condition variable because there is no lost wake-up to reason about,
      # and Windows maps this layer's mutex to an SRWLOCK with no condvar.
      #
      # The sleep is a wait on `@mark_wake` with the same timeout (`mark_wait`:
      # `futex`, `__ulock_wait` or `WaitOnAddress`), which the master cuts
      # short when a cycle starts (`wake_mark_helpers`). Between
      # two collections of an allocation storm the helpers are asleep, and a
      # sleep that only timed out joined each mark up to 5 ms late: with the
      # helpers spinning instead, Σ mark fell 10–15% on JsonParsePure and
      # Primes at four workers, and by 15–50% on JsonParseSerializable.
      idle = 0
      nap = MARK_IDLE_SLEEP_NS
      while @mark_shutdown.get == 0
        epoch = @mark_epoch.get
        if epoch == local_epoch
          if idle < MARK_IDLE_SPINS
            idle += 1
            Intrinsics.pause
          else
            wait_for_mark_epoch(local_epoch, nap)
            nap = nap * 2 > MARK_IDLE_SLEEP_MAX_NS ? MARK_IDLE_SLEEP_MAX_NS : nap * 2
          end
          next
        end
        idle = 0
        nap = MARK_IDLE_SLEEP_NS
        local_epoch = epoch
        next if @mark_shutdown.get != 0
        ensure_pushbuf(shard)

        # Stay in the cycle as long as the master says marking is live. A
        # transient empty is a pause, not an exit — the earlier bug was a worker
        # dropping out on the first empty and never re-entering while other
        # workers still had work. The master ends the cycle by clearing
        # `@mark_parallel`.
        #
        # A long empty is a park, though, not a spin (`park_idle_marker`).
        # One long linked list gives the extra workers nothing to take — the
        # worker holding it keeps each node's one child to itself — and they
        # polled the empty stack for the whole mark: with four workers on a
        # 3 M-node list, 4.0 cores of CPU per second of collecting against
        # 1.05 serial, and a pause of 40.1 ms against 31.6; 1.11 cores and
        # 31.1 ms now (`bench/mark_list_heap.cr`,
        # `bench/log/linux/2026-10-06-mark-idle/`).
        drought = MarkDrought.new(pointerof(@mark_spinners).as(Int32*))
        nap = MARK_STEAL_NAP_NS
        while @mark_parallel && @mark_shutdown.get == 0
          m = pop_mark_batch(batch.to_unsafe, MARK_POP_BATCH)
          if m == 0
            # The drought stays over until a pop succeeds: a wake that finds
            # the stack already taken parks again without another spin.
            if drought.over?
              park_idle_marker(nap, master: false)
              nap = nap * 2 > MARK_STEAL_NAP_MAX_NS ? MARK_STEAL_NAP_MAX_NS : nap * 2
            else
              Intrinsics.pause
            end
            next
          end
          drought.reset
          nap = MARK_STEAL_NAP_NS
          # `pop_mark_batch` already counted this worker busy, under the lock
          # that took the batch. Busy therefore spans the batch AND its
          # unflushed children — a worker is never counted idle while it might
          # still push — which is the invariant the master's check rests on.
          begin
            @parallel_mark_stolen &+= m.to_u64
            scan_batch_local_first(batch.to_unsafe, m, shard)
          ensure
            end_helper_batch
          end
        end
        drought.reset
      end
    end

    # Every idle mark thread waits on `@mark_wake`: helpers between cycles
    # (`wait_for_mark_epoch`) and any marker parked inside one
    # (`park_idle_marker`). Both follow one protocol on every platform: count
    # yourself a sleeper, read the word, check the condition you would sleep
    # on, then `mark_wait` on the value read. A waker changes the condition,
    # reads the sleeper count, bumps the word and then wakes
    # (`wake_parked_markers`), so a waiter that read the word before the bump
    # returns at once, and one that read it after sees the condition changed.
    #
    # Until 2026-10-08 only Linux waited here; elsewhere both functions were a
    # `nanosleep` of the timeout with no wake, and Windows rounds that up to
    # whole milliseconds of `Sleep`, about 15.6 ms at the default timer
    # resolution. A helper parked in a cycle then took published work only
    # after its sleep, and the marks were over by then: the steals per run of
    # `make parallel-mark-process` fell from 380 k to 1–5 k on darwin x86_64,
    # from 330 k to 0.7–5.6 k on Windows x86_64 and to 0 on darwin arm64,
    # against 165–369 k on Linux (CI, 2026-10-06).
    {% if flag?(:linux) %}
      FUTEX_WAIT_PRIVATE = 128
      FUTEX_WAKE_PRIVATE = 129
      SYS_FUTEX          = {{ flag?(:aarch64) ? 98 : 202 }}
    {% elsif flag?(:darwin) %}
      # <sys/ulock.h>: compare a 32-bit word, process-private; wake all.
      UL_COMPARE_AND_WAIT =     1_u32
      ULF_WAKE_ALL        = 0x100_u32
    {% end %}

    # Sleep while `@mark_wake` still holds `seq`, for at most `nap_ns`. It
    # returns at once if the word has moved, and early on a wake, a signal or
    # a spurious return; the result is not looked at, because every caller
    # re-checks its own condition afterwards and a wait that ended for nothing
    # costs one more pass of its loop. On Darwin that covers EINTR and
    # ETIMEDOUT from `__ulock_wait`; on Windows FALSE with ERROR_TIMEOUT.
    #
    # The timeout is the safety net for a wake-up the protocol misses, and
    # what finds work published without one. Darwin takes it in whole
    # microseconds, where 0 would mean no timeout at all; Windows in whole
    # milliseconds, rounded up, and then to its timer tick — a 100 µs nap can
    # last 15.6 ms there, which only a missed wake would ever wait out.
    #
    # A return before `nap_ns` with the word moved is a wake, since no
    # timeout here is shorter than that, and `parallel_mark_wakes` counts it.
    # Two clock reads per wait, against the syscall they bracket.
    private def mark_wait(seq : Int32, nap_ns : Int32) : Nil
      word = pointerof(@mark_wake).as(Int32*)
      t0 = Clock.monotonic_ns
      {% if flag?(:linux) %}
        req = uninitialized Gcry::OS::Timespec
        req.tv_sec = typeof(req.tv_sec).new(0)
        req.tv_nsec = typeof(req.tv_nsec).new(nap_ns)
        LibC.syscall(LibC::Long.new(SYS_FUTEX), word, LibC::Long.new(FUTEX_WAIT_PRIVATE),
          LibC::Long.new(seq), pointerof(req), Pointer(Void).null, LibC::Long.new(0))
      {% elsif flag?(:darwin) %}
        us = (nap_ns + 999) // 1000
        LibC.gcry_ulock_wait(UL_COMPARE_AND_WAIT, word.as(Void*), seq.to_u32!.to_u64, (us < 1 ? 1 : us).to_u32)
      {% else %}
        # `platform/os.cr` admits Linux, macOS and Windows only.
        compare = seq
        ms = (nap_ns + 999_999) // 1_000_000
        LibGcryWindowsSync.WaitOnAddress(word.as(Void*), pointerof(compare).as(Void*), LibC::SizeT.new(4), (ms < 1 ? 1 : ms).to_u32)
      {% end %}
      if @mark_wake.get != seq && Clock.monotonic_ns &- t0 < nap_ns.to_u64
        @parallel_mark_wakes.add(1)
      end
    end

    # Wake up to `count` of the `sleepers` waiting in `mark_wait`, after the
    # word's bump. `futex` takes the count. The other two wake one or all, so
    # a count short of the sleepers is that many single wakes, at most
    # `MAX_MARK_PTHREADS` − 1: waking all of them for a flush worth two pops
    # would send the rest back to park through a futile check each.
    private def mark_wake(count : Int32, sleepers : Int32) : Nil
      word = pointerof(@mark_wake).as(Void*)
      {% if flag?(:linux) %}
        LibC.syscall(LibC::Long.new(SYS_FUTEX), word, LibC::Long.new(FUTEX_WAKE_PRIVATE),
          LibC::Long.new(count), Pointer(Void).null, Pointer(Void).null, LibC::Long.new(0))
      {% elsif flag?(:darwin) %}
        # ENOENT, no waiter left, is the normal answer to a late wake.
        if count >= sleepers
          LibC.gcry_ulock_wake(UL_COMPARE_AND_WAIT | ULF_WAKE_ALL, word, 0_u64)
        else
          count.times { LibC.gcry_ulock_wake(UL_COMPARE_AND_WAIT, word, 0_u64) }
        end
      {% else %}
        if count >= sleepers
          LibGcryWindowsSync.WakeByAddressAll(word)
        else
          count.times { LibGcryWindowsSync.WakeByAddressSingle(word) }
        end
      {% end %}
    end

    # One idle helper's sleep of at most `nap_ns`, cut short by the next
    # cycle's `wake_mark_helpers`.
    #
    # The helper counts itself a sleeper before it reads the wake word and
    # then the epoch; the master bumps the epoch before it reads the sleeper
    # count. Both sides are sequentially consistent RMWs followed by loads, so
    # either the helper sees the new epoch and does not sleep, or the master
    # sees the sleeper and bumps the word, which makes the wait return at
    # once or wakes it. The timeout stays as before, so a lost wake-up could
    # only cost what the plain sleep always did.
    private def wait_for_mark_epoch(local_epoch : UInt64, nap_ns : Int32) : Nil
      @mark_sleepers.add(1)
      seq = @mark_wake.get
      if @mark_epoch.get == local_epoch && @mark_shutdown.get == 0
        mark_wait(seq, nap_ns)
      end
      @mark_sleepers.add(-1)
    end

    # Inside a cycle, a marker that has found the shared stack empty for
    # `MARK_STEAL_SPIN_NS` sleeps here for at most `nap_ns`.
    #
    # The wait is entered only if, under `@mark_lock`, the cycle is live and
    # the shared stack empty — for the master, also with a batch still held
    # somewhere, since `busy == 0` there is the end of the mark. Everything
    # that ends such a state announces itself, after the same lock where it
    # has one, and reads the sleeper count after it:
    #
    # - work published to the shared stack (`flush_pushbuf`,
    #   `publish_mark_entry`) wakes sleepers when it is worth a pop;
    # - the end of the cycle (`@mark_parallel` cleared) wakes all;
    # - the batch end that leaves nothing held and nothing shared
    #   (`end_helper_batch`) wakes all, for the master.
    #
    # The marker counts itself a sleeper and reads the wake word before its
    # check. For the first two that makes the lost wake-up impossible by the
    # lock: a publisher whose push this check missed took the lock after it,
    # so it sees the sleeper and bumps the word, and the wait returns at once
    # or is woken. The third is not under the lock; it is a sequentially
    # consistent RMW followed by a load against this one, as in
    # `wait_for_mark_epoch`. The timeout bounds any wake-up this misses, and
    # it is what finds work that was published without a wake — which is
    # only ever work its awake publisher takes back itself.
    private def park_idle_marker(nap_ns : Int32, master : Bool) : Nil
      @mark_sleepers.add(1)
      seq = @mark_wake.get
      @mark_lock.lock
      idle = @mark_parallel && @mark_stack.empty? && (!master || @mark_workers_busy.get != 0)
      @mark_lock.unlock
      mark_wait(seq, nap_ns) if idle && @mark_shutdown.get == 0
      @mark_sleepers.add(-1)
    end

    # Wake up to `count` sleepers on `@mark_wake`. No syscall while none is.
    @[AlwaysInline]
    private def wake_parked_markers(count : Int32) : Nil
      sleepers = @mark_sleepers.get
      return if sleepers == 0
      @mark_wake.add(1)
      mark_wake(count, sleepers)
    end

    # After an epoch bump or the end of a cycle: wake every helper that is in
    # `wait_for_mark_epoch` or `park_idle_marker`.
    private def wake_mark_helpers : Nil
      wake_parked_markers(Int32::MAX)
    end

    # A helper's batch end, the `add(-1)` its pop owes. The decrement that
    # leaves no batch held while the shared stack is empty is the end of the
    # cycle's work, which a master parked in `park_idle_marker` waits for.
    # That state is final — only a worker holding a batch publishes — so this
    # wakes once per cycle. The master's own decrement wakes nobody: it is
    # the one awake to see it.
    @[AlwaysInline]
    private def end_helper_batch : Nil
      last = @mark_workers_busy.add(-1) == 1
      wake_mark_helpers if last && @mark_stack.empty_unlocked?
    end

    # The drain, with `scan_edges_inline` allowed for its length. Set before
    # the helpers are woken and cleared after the last of them has finished
    # its batch, so every scan of this cycle sees one value; any other scan
    # (the finalizer pass, a library heap's unstopped collect) takes the
    # `mark_impl` path, which needs no precondition.
    private def mark_loop : Nil
      @mark_edges_inline = mark_edges_inline_allowed?
      begin
        mark_loop_drain
      ensure
        @mark_edges_inline = false
      end
    end

    private def mark_loop_drain : Nil
      # The live bytes the last major's sweep measured; this cycle's sweep has
      # not run yet.
      if @parallel_mark_workers <= 1 || live_bytes_after_sweep < @parallel_mark_min_live
        serial_mark_drain
        return
      end
      @parallel_mark_runs += 1

      ensure_mark_worker_pool
      # No helpers available (pthread_create failed) → serial.
      helpers = @mark_pthread_mode ? @mark_pthread_count : @mark_worker_threads.size
      if helpers == 0
        serial_mark_drain
        return
      end

      Heap.mark_worker = 0
      shard = mark_shard(0)
      ensure_pushbuf(shard)
      # Under the lock, which also publishes the master's unlocked pushes
      # above to a worker that sees `true` under it (see `pop_mark_batch`).
      @mark_lock.lock
      @mark_parallel = true
      @mark_lock.unlock
      @mark_epoch.add(1)
      wake_mark_helpers
      batch = uninitialized StaticArray(Void*, MARK_POP_BATCH)
      drought = MarkDrought.new(pointerof(@mark_spinners).as(Int32*))
      nap = MARK_STEAL_NAP_NS
      begin
        loop do
          m = pop_mark_batch(batch.to_unsafe, MARK_POP_BATCH)
          if m > 0
            drought.reset
            nap = MARK_STEAL_NAP_NS
            # The master takes a batch through the same door, so it owes the
            # same decrement. It is never mid-batch at the termination check
            # below — that branch is only reached when the pop came back
            # empty and nothing was counted.
            begin
              scan_batch_local_first(batch.to_unsafe, m, shard)
            ensure
              @mark_workers_busy.add(-1)
            end
            next
          end
          # Master found nothing. Safe to stop only when no worker holds a
          # batch and the stack is empty, both read in one critical section:
          # a worker becomes busy only by popping under that lock, so with the
          # stack empty it cannot, and the pair is stable once observed.
          break if mark_drain_finished?
          # A helper holds the rest of the mark — one long chain, say — and
          # the master waits for it parked, as an idle helper does, rather
          # than polling for the whole of it. The batch end that finishes the
          # work wakes it (`end_helper_batch`), so only a missed wake-up
          # would add the wait's timeout to the pause. Until 2026-10-08 this
          # was Linux only, because elsewhere the park was a plain sleep that
          # nothing could cut short; every platform waits on `@mark_wake` now.
          if drought.over?
            park_idle_marker(nap, master: true)
            nap = nap * 2 > MARK_STEAL_NAP_MAX_NS ? MARK_STEAL_NAP_MAX_NS : nap * 2
            next
          end
          Intrinsics.pause
        end
      ensure
        drought.reset
        @mark_lock.lock
        @mark_parallel = false
        @mark_lock.unlock
        @mark_epoch.add(1)
        # Helpers parked in the cycle are told it is over under the same
        # lock-then-count order they sleep by (`park_idle_marker`).
        wake_mark_helpers
        until @mark_workers_busy.get == 0
          Intrinsics.pause
        end
        # Every helper is past its last scan: no batch can be popped with
        # `@mark_parallel` false, and busy counts the ones in flight.
        @mark_scanned_bytes &+= take_parallel_scanned_bytes
      end
    end
  end
end
