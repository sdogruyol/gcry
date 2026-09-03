# Parallel mark.
#
# Library heaps (`stop_the_world == false`): Crystal::Thread helpers steal grey
# work under `@mark_lock`.
#
# Process GC (`stop_the_world`): Crystal::Thread would freeze in `stop_world`, so
# helpers are raw `LibC.pthread_create` threads (not registered with Crystal).
# They only touch mark state / heap headers — no Fiber, no managed alloc.
#
# Fields (@parallel_mark_workers, …) are declared/initialized in heap.cr.

require "c/pthread"

lib LibC
  fun pthread_create(thread : PthreadT*, attr : PthreadAttrT*, start : Void* -> Void*, arg : Void*) : Int
  fun pthread_join(thread : PthreadT, retval : Void**) : Int
end

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

    def parallel_mark_workers=(value : Int32) : Int32
      @parallel_mark_workers = value.clamp(1, 16)
    end

    def parallel_mark_runs : UInt64
      @parallel_mark_runs
    end

    def parallel_mark_stolen : UInt64
      @parallel_mark_stolen
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
        tid = uninitialized LibC::PthreadT
        rc = LibC.pthread_create(
          pointerof(tid),
          Pointer(LibC::PthreadAttrT).null,
          ->gcry_mark_worker_main(Void*),
          self.as(Void*),
        )
        break if rc != 0
        @mark_pthreads[@mark_pthread_count] = tid
        @mark_pthread_count += 1
      end
    end

    protected def shutdown_mark_workers : Nil
      @mark_shutdown.set(1)
      @mark_epoch.add(1)

      if @mark_pthread_mode || @mark_pthread_count > 0
        @mark_pthread_count.times do |i|
          LibC.pthread_join(@mark_pthreads[i], Pointer(Void*).null)
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
    MARK_POP_BATCH   = 256
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

    # Lazily mmap a shard's push buffer. Called by a worker before it drains, and
    # by the master; mmap during a collection is fine (it is what MarkStack#grow
    # does), a managed allocation would not be.
    protected def ensure_pushbuf(slot : Int32) : Nil
      return if @mark_pushbuf[slot] != 0_u64
      bytes = MARK_PUSHBUF_CAP.to_u64 * sizeof(Void*).to_u64
      ptr = LibC.mmap(Pointer(Void).null, LibC::SizeT.new(bytes),
        LibC::PROT_READ | LibC::PROT_WRITE,
        LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, 0)
      return if Gcry.mmap_failed?(ptr)
      @mark_pushbuf[slot] = ptr.address
      @mark_pushbuf_n[slot] = 0
    end

    # Publish one shard's accumulated children to the shared stack under one
    # lock. Single-writer per slot, so the buffer itself needs no lock.
    protected def flush_pushbuf(slot : Int32) : Nil
      n = @mark_pushbuf_n[slot]
      return if n == 0
      buf = Pointer(Void*).new(@mark_pushbuf[slot])
      @mark_lock.lock
      i = 0
      while i < n
        @mark_stack.push(buf[i].as(BlockHeader*))
        i += 1
      end
      @mark_lock.unlock
      @mark_pushbuf_n[slot] = 0
    end

    # Take up to `cap` headers from the shared stack under one lock.
    protected def pop_mark_batch(into : Pointer(Void*), cap : Int32) : Int32
      @mark_lock.lock
      n = 0
      while n < cap && !@mark_stack.empty?
        into[n] = @mark_stack.pop.as(Void*)
        n += 1
      end
      @mark_lock.unlock
      n
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
        ensure_pushbuf(slot)
      end
      slot = Heap.mark_worker

      local_epoch = 0_u64
      batch = uninitialized StaticArray(Void*, MARK_POP_BATCH)
      while @mark_shutdown.get == 0
        epoch = @mark_epoch.get
        if epoch == local_epoch
          Intrinsics.pause
          next
        end
        local_epoch = epoch
        next if @mark_shutdown.get != 0
        ensure_pushbuf(slot)

        # Stay in the cycle as long as the master says marking is live. A
        # transient empty is a pause, not an exit — the earlier bug was a worker
        # dropping out on the first empty and never re-entering while other
        # workers still had work. The master ends the cycle by clearing
        # `@mark_parallel`.
        while @mark_parallel && @mark_shutdown.get == 0
          m = pop_mark_batch(batch.to_unsafe, MARK_POP_BATCH)
          if m == 0
            Intrinsics.pause
            next
          end
          # Busy spans holding a batch AND its unflushed children, so a worker
          # is never counted idle while it might still push. That is the
          # invariant the master's termination check rests on.
          @mark_workers_busy.add(1)
          begin
            @parallel_mark_stolen &+= m.to_u64
            i = 0
            while i < m
              scan_object(batch.to_unsafe[i].as(BlockHeader*))
              i += 1
            end
            flush_pushbuf(slot)
          ensure
            @mark_workers_busy.add(-1)
          end
        end
      end
    end

    private def mark_loop : Nil
      if @parallel_mark_workers > 1
        @parallel_mark_runs += 1
      end

      if @parallel_mark_workers <= 1
        serial_mark_drain
        return
      end

      ensure_mark_worker_pool
      # No helpers available (pthread_create failed) → serial.
      helpers = @mark_pthread_mode ? @mark_pthread_count : @mark_worker_threads.size
      if helpers == 0
        serial_mark_drain
        return
      end

      Heap.mark_worker = 0
      ensure_pushbuf(0)
      @mark_parallel = true
      @mark_epoch.add(1)
      batch = uninitialized StaticArray(Void*, MARK_POP_BATCH)
      begin
        loop do
          m = pop_mark_batch(batch.to_unsafe, MARK_POP_BATCH)
          if m > 0
            i = 0
            while i < m
              scan_object(batch.to_unsafe[i].as(BlockHeader*))
              i += 1
            end
            flush_pushbuf(0)
            next
          end
          # Master found nothing. Safe to stop only when no worker is mid-scan
          # (so none can push) AND the stack is freshly observed empty. A worker
          # can only become busy by popping a non-empty batch, so it cannot
          # transition to busy while the stack is empty — busy==0 && empty is
          # therefore stable. `mark_stack_empty_locked?` re-reads under the lock
          # in case a worker flushed after this master pop.
          break if @mark_workers_busy.get == 0 && mark_stack_empty_locked?
          Intrinsics.pause
        end
      ensure
        @mark_parallel = false
        @mark_epoch.add(1)
        until @mark_workers_busy.get == 0
          Intrinsics.pause
        end
      end
    end
  end
end
