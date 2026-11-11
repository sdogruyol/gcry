# Keep the EC Monitor out of the stopped world.
#
# `Heap#stop_world` does not signal-suspend the Monitor (SYSMON) once it is in
# its loop (`MonitorGate.settle`; its birth is suspended like any thread's) —
# the recorded reason is that resume races left it in `sigsuspend` forever — and
# instead assumed it would cooperate by blocking in `allocate` / `lock_read`. Measured,
# it does not: through a 4 s stop the Monitor woke ~100 times a second, and it ran
# `StackPool#collect` — `Crystal::System::Fiber.free_stack`, i.e. munmap — *inside*
# the stop, while the collector was in its thread-stacks phase.
# `bench/log/linux/2026-08-11-sysmon-runs-during-stw/FINDINGS.md`.
#
# An entry check alone is not enough: it stops the Monitor *starting* work during
# a stop, but work already in flight when the world stops keeps running (the
# observed `collect_stacks` took 250 µs). So this is a handshake, and both halves
# are needed:
#
#   Monitor:  busy = 1 ; if stopped { busy = 0 ; wait until !stopped ; retry }
#   stop_world: stopped = 1 ; wait until busy == 0
#
# Both sides store before they load, which is the one shape where a relaxed
# ordering would let both proceed, so every access here is sequentially
# consistent. Liveness comes from the Monitor backing off — it clears `busy`
# before waiting, so it can never hold the collector while waiting for it.
#
# `GCRY_MONITOR_GATE=0` turns it off for A/B. Off is the old behaviour, i.e. the
# Monitor runs inside the stopped world.

module Gcry
  module MonitorGate
    # Every class variable and constant the Monitor's thread reads — here, in
    # the `Monitor` and `Thread.sleep` wrappers below, and in what they call —
    # has a literal initializer, and the shared flags are plain `Int32`s read
    # and written through `StaticAtomic`, never an `Atomic(Int32).new`. A call
    # initializer is Crystal's `once`: run by `__crystal_main` at the
    # declaration, or by whichever thread reads it first. The Monitor starts
    # in the prelude (`kernel.cr`), before `__crystal_main` reaches gcry's
    # declarations, and its loop prologue runs at once; a Monitor that read
    # a variable while the main thread was running its initializer waited in
    # `once`, and on Crystal 1.21 its fiber has no execution context, so the
    # main thread's `resume_all` raised `Fiber#execution_context cannot be
    # nil` and the program died at startup
    # (`bench/log/macos/2026-11-11-monitor-once-race/`). Regression 112 holds
    # the main thread in an initializer while the Monitor runs, and fails on
    # any lazily initialized symbol in this module.
    @@enabled = true
    @@stopped : Int32 = 0
    @@busy : Int32 = 0

    # Times stop_world had to wait for work the Monitor had already started, and
    # the worst one. This is the pause the handshake *adds*, so it must not be a
    # number anyone has to guess at.
    @@stw_waits = 0_u64
    @@stw_wait_ns = 0_u64
    @@stw_wait_max_ns = 0_u64
    # Times the Monitor was held off at the gate.
    @@monitor_blocks = 0_u64
    @@reg_spills = 0_u64
    @@site : Int32 = 0

    def self.enabled? : Bool
      @@enabled
    end

    def self.enabled=(value : Bool) : Bool
      @@enabled = value
    end

    def self.stw_waits : UInt64
      @@stw_waits
    end

    def self.stw_wait_ns : UInt64
      @@stw_wait_ns
    end

    def self.stw_wait_max_ns : UInt64
      @@stw_wait_max_ns
    end

    def self.monitor_blocks : UInt64
      @@monitor_blocks
    end

    # The Monitor's thread once it is in its loop, stored by the thread itself
    # (`settle`). Until then it is a mutator to every stop.
    @@exempt : Thread? = nil

    # Does a stop leave *thread* unsignalled? `Heap#stw_signal_exempt?`.
    def self.signal_exempt?(thread : Thread) : Bool
      if t = @@exempt
        t.same?(thread)
      else
        false
      end
    end

    # From the top of `Monitor#run_loop`, on the Monitor's thread: exempt from
    # the suspend signal from here on, and not before. Its birth is a
    # mutator's — `Thread#start` allocates the thread's main `Fiber` after
    # pushing it onto Crystal's list — and nothing gates it: an exempt thread
    # allocating runs on through a stop, because `allocate`'s
    # `wait_if_world_stopped_other_thread` is a check and not a handshake.
    # The first collection of a program can land on that birth: in the
    # window-free child of `make chunk-list-drift` the Monitor inserted a
    # chunk into the index during a stop in 3 of 1000 runs, and in 10 of 100
    # with a 200 µs hold between `map_chunk`'s two stores, while the
    # collector read the index unlocked.
    #
    # Under `Thread.lock`, which a stop holds from its first
    # `stw_signal_exempt?` to its last resume, so every test in one stop gets
    # the same answer. Nothing else is held here, and the birth before it
    # holds nothing a stop waits for: the thread-list and fiber-list mutexes
    # its `Thread#start` takes are taken by the stop *before* it signals, so
    # the thread is never suspended inside them.
    def self.settle : Nil
      Thread.lock
      @@exempt = Thread.current
      Thread.unlock
    end

    # Collector side. Call *before* touching anything the Monitor could be
    # mutating, and pair with `open`.
    def self.close : Nil
      return unless @@enabled
      StaticAtomic.store(pointerof(@@stopped), 1)

      return if StaticAtomic.load(pointerof(@@busy)) == 0

      # The Monitor was already inside its work. Wait it out — bounded by that
      # one call, because the handshake keeps it from starting another.
      t0 = now_ns
      while StaticAtomic.load(pointerof(@@busy)) != 0
        Intrinsics.pause
      end
      waited = now_ns - t0
      @@stw_waits += 1
      @@stw_wait_ns += waited
      @@stw_wait_max_ns = waited if waited > @@stw_wait_max_ns
    end

    def self.open : Nil
      StaticAtomic.store(pointerof(@@stopped), 0)
    end

    # Monitor side.
    SITE_NONE     = 0
    SITE_TRANSFER = 1
    SITE_COLLECT  = 2
    SITE_OTHER    = 3

    def self.site : Int32
      StaticAtomic.load(pointerof(@@site))
    end

    def self.site_name(v : Int32) : String
      case v
      when SITE_TRANSFER then "transfer_schedulers_blocked_on_syscall"
      when SITE_COLLECT  then "collect_stacks"
      when SITE_OTHER    then "other monitor work"
      else                    "none"
      end
    end

    # Research only. Makes the real Monitor do, inside its handshake, the one
    # thing `transfer_schedulers_blocked_on_syscall` does that reaches the
    # collector's locks: `thread_pool.checkout` with nothing parked is
    # `Thread.new`, and gcry wraps `pthread_create` to root the new `Thread`
    # through `@roots_lock`.
    #
    # A harness cannot stand in for the Monitor here. `@@busy` is one shared
    # bit, not a count, so a second thread calling `enter` has its hold cleared
    # by the real Monitor's next back-off — measured: `stw_waits=1`,
    # `monitor_blocks=12`, and no deadlock in either arm.
    @@test_spawn = false

    def self.test_spawn=(v : Bool)
      @@test_spawn = v
    end

    def self.test_spawn_hook : Nil
      return unless @@test_spawn
      t = Thread.new { }
      t.join
    end

    # The `setjmp` here is a **root**, and it is the only one the Monitor has
    # for its registers.
    #
    # Every thread the stop suspends by signal gets its GP registers spilled
    # into the `ucontext` and scanned (`Platform.each_thread_greg`), because a
    # reference can live only in a register. The Monitor is deliberately
    # never signalled — a resume race leaves it in `sigsuspend` forever — so
    # it waits out the stop here instead, and this is the one thread whose
    # registers nothing captured. A pointer live only in a Monitor register
    # was invisible, which is what `GCRY_POISON_HOLDERS=1` reports on the
    # thread-death reproducer: *"holders — none … the pointer is in a
    # register, in thread-local storage, or in memory gcry never mapped"*.
    #
    # `spill_registers` + `capture_registers` is the pair the collector
    # already uses on itself: the asm clobber forces live pointers out of
    # registers and `setjmp` writes the callee-saved set into the buffer. The
    # buffer is a **local**, so the Monitor's own stack scan — it is on
    # Crystal's list and its pthread range is walked — picks them up, with no
    # new table and no new ownership question.
    def self.enter(site : Int32 = SITE_OTHER) : Nil
      return unless @@enabled
      StaticAtomic.store(pointerof(@@site), site)
      loop do
        StaticAtomic.store(pointerof(@@busy), 1)
        if StaticAtomic.load(pointerof(@@stopped)) == 0
          plant_for_test if @@test_plant != 0
          return
        end

        # Back off first: holding `busy` while waiting for the world to restart
        # would deadlock against a collector waiting for `busy` to clear.
        StaticAtomic.store(pointerof(@@busy), 0)
        @@monitor_blocks += 1
        Roots.spill_registers
        regs = uninitialized StaticArray(UInt8, Roots::REGISTER_BUFFER_SIZE)
        Roots.capture_registers(regs.to_unsafe)
        @@reg_spills &+= 1
        wait_for_open
        # Without a use after the spin the optimiser may drop the frame slot,
        # and a root the compiler deleted is the defect this exists to close.
        Roots.keep_alive(regs.to_unsafe.as(Void*))
      end
    end

    # Polls before the wait starts sleeping, and the sleep between polls after.
    # The wait lasts a whole stop, which is the collection's pause: hundreds of
    # milliseconds on a large heap. Spinning through all of it kept one core
    # at 100% for every pause — a third of the process's CPU on crystal-metric's
    # Primes — and on a machine with no spare core that core is taken from the
    # collector. The Monitor's own period is ~10 ms, so waking up to 100 µs
    # late after the world restarts costs it nothing. Polling, not a condition
    # variable, for the reason `parallel_mark.cr`'s idle wait gives: Windows
    # maps this layer's mutex to an SRWLOCK with no condvar.
    WAIT_SPINS    =   1_000
    WAIT_SLEEP_NS = 100_000

    private def self.wait_for_open : Nil
      spins = 0
      while StaticAtomic.load(pointerof(@@stopped)) != 0
        if spins < WAIT_SPINS
          spins += 1
          Intrinsics.pause
        else
          req = uninitialized Gcry::OS::Timespec
          req.tv_sec = typeof(req.tv_sec).new(0)
          req.tv_nsec = typeof(req.tv_nsec).new(WAIT_SLEEP_NS)
          rem = uninitialized Gcry::OS::Timespec
          Gcry::OS.nanosleep(pointerof(req), pointerof(rem))
        end
      end
    end

    # Waits that spilled the Monitor's registers. The gate is that this is
    # **non-zero** — 238 of 240 collections on a thread-churn workload — and
    # not a survival A/B, for the same reason `make greg-roots` gives: whether
    # a pointer lives only in a register is a codegen outcome no source-level
    # test can compel. Stated plainly: this did **not** change the rate of the
    # thread-churn reproducer (56 of 258 runs with it, 49 of 252 without), so
    # it closes a hole rather than a known crash.
    def self.reg_spills : UInt64
      @@reg_spills
    end

    def self.leave : Nil
      {% if flag?(:linux) %}
        unless @@residue_kept
          scrub_dead_stack
          # The band under `scrub_dead_stack`'s SP and the frame it ran on,
          # with the allocation slow path's frameless wipe from this one.
          Roots.wipe_below_sp(Roots.wipe_limit(Roots.hardware_stack_pointer.address))
        end
      {% end %}
      StaticAtomic.store(pointerof(@@busy), 0)
      StaticAtomic.store(pointerof(@@site), SITE_NONE)
      MonitorOnceTest.pass if MonitorOnceTest.arm != 0
    end

    # Dead stack zeroed below the Monitor's SP as each piece of gated work
    # ends, before `busy` clears, so a stop never reads it half done. On
    # Linux the Monitor is never signalled and publishes no SP, so a stop
    # reads its stack whole from the low-water mark
    # (`Heap#scan_other_thread_fiber_ec1`, and `scan_all_fiber_roots` with
    # more than one mutator), and every word its earlier, deeper calls left
    # below where it sleeps was a root. The gated calls are the deep ones and
    # the ones that handle schedulers, thread pools and fiber stacks. In
    # regression 1's suite order such a word, about 650 bytes below the
    # Monitor's sleeping SP, named a word inside a large block, and kept the
    # block and the 16–70 thousand objects it reached until a later Monitor
    # pass wrote over it, inside the spec's measured window
    # (`bench/log/linux/2026-11-04-reg1-drift/`). The idle thread does the
    # same before every park (`IdleRelease.scrub_dead_stack`, whose shape
    # this keeps). Measured in that suite order, the Monitor's touched stack
    # ended 1 072 bytes below its sleeping SP. Darwin and Windows suspend the
    # Monitor and scan it from its SP.
    SCRUB_BYTES = 16_384_u64
    # Below the SP captured here, so the `memset` frame the clear itself pushes
    # sits in the gap and is not zeroed under it (as `clear_stack_body`).
    SCRUB_SKIP = 256_u64

    # Research only, the control arm of
    # `process_spec/regression/105_monitor_dead_stack_spec.cr`: `true` leaves
    # the Monitor's dead stack as its calls left it, as before 2026-11-04.
    class_property? residue_kept : Bool = false

    @[NoInline]
    private def self.scrub_dead_stack : Nil
      stack = Fiber.current.@stack
      floor = stack.pointer.address + Roots.runtime_page_size
      sp = Roots.hardware_stack_pointer.address
      return if sp <= floor + SCRUB_SKIP
      high = sp - SCRUB_SKIP
      low = high > floor + SCRUB_BYTES ? high - SCRUB_BYTES : floor
      return if low >= high
      Pointer(UInt8).new(low).clear(high - low)
    end

    # Research only, for regression 105: when not 0, each gated call writes
    # `test_plant ^ PLANT_KEY` over `PLANT_WORDS` words of the Monitor's stack
    # below `enter`, standing in for a deeper call that left a heap address
    # there, and counts it in `test_plants`. Stored masked so the field is no
    # root.
    class_property test_plant : UInt64 = 0_u64
    class_getter test_plants : UInt64 = 0_u64
    PLANT_KEY   = 0x0105_a5a5_5a5a_0105_u64
    PLANT_WORDS =                      1024

    @[NoInline]
    private def self.plant_for_test : Nil
      pad = uninitialized StaticArray(UInt64, PLANT_WORDS)
      word = @@test_plant ^ PLANT_KEY
      PLANT_WORDS.times { |i| pad[i] = word }
      asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
      @@test_plants &+= 1
    end

    private def self.now_ns : UInt64
      Clock.monotonic_ns
    end

    # The Monitor zeroes its stack below its loop's entry before `run_loop`
    # builds its frame there. That frame never returns, and every stop reads
    # it: whole on Linux, where the Monitor publishes no SP, and above the
    # suspend SP elsewhere. Bytes of it the loop never writes keep whatever the
    # thread's birth left at that depth. Crystal's `every` keeps its
    # `Time::Instant`s and `Time::Span`s there, an `Int64` and an `Int32` in
    # 16 bytes, and stores 4 of the second word's 8 every pass: the word was a
    # nanosecond count under the high half of an address the birth left, i.e.
    # a fresh address in the heap's 4 GiB every 10 ms. In regression 1's full
    # suite order on Crystal 1.22.2 it was the one root word that first marked
    # a block before the baseline and held something else after the check, in
    # every run instrumented; a dead graph it named at the baseline is let go
    # inside the window, the shape of the one `drift=-2444` after regression 105
    # (`bench/log/linux/2026-11-04-reg1-drift/`). With the birth's residue
    # zeroed first the high half is 0, and a count under 10^9 names no heap.
    # The shape of `IdleRelease.ensure_started`'s birth scrub: everything the
    # birth touched below this call's SP, less `SCRUB_SKIP` for the `memset`
    # frame, from the lowest faulted page, or `LOOP_SCRUB_BYTES` when the
    # probe cannot say. The caller wipes the skipped band and this call's own
    # frame.
    LOOP_SCRUB_BYTES = 65_536_u64

    @[NoInline]
    def self.scrub_loop_stack : Nil
      stack = Fiber.current.@stack
      floor = stack.pointer.address + Roots.runtime_page_size
      sp = Roots.hardware_stack_pointer.address
      return if sp <= floor + SCRUB_SKIP
      high = sp - SCRUB_SKIP
      low = Platform.stack_low_water(floor, high)
      low = high > floor + LOOP_SCRUB_BYTES ? high - LOOP_SCRUB_BYTES : floor if low <= floor
      return if low >= high
      Pointer(UInt8).new(low).clear(high - low)
    end

    # Research only, regression 107 (`GCRY_MONITOR_LOOP_TEST`, read in
    # `GC.init`, before the Monitor starts): at the top of its loop, while
    # still a mutator, the Monitor makes a block of `LOOP_TEST_BYTES` and
    # keeps its address masked with `PLANT_KEY` in `loop_test_block`. 1 then
    # writes the address over 8 KiB below the loop's entry before the scrub,
    # standing in for a birth that left it there; 2 does the same and leaves
    # the scrub out (`loop_residue_kept?`, the code before, the control arm);
    # 3 makes the block and plants nothing. 4 and 5 are 1 and 2 with
    # `LOOP_MARKER` planted instead, whose high half no address has, so a
    # word the loop wrote only the low half of shows. `loop_test_sp` is the
    # entry's SP and `loop_test_ready?` turns true once the loop is about to
    # start.
    class_property loop_test : Int32 = 0
    class_getter loop_test_block : UInt64 = 0_u64
    class_getter loop_test_sp : UInt64 = 0_u64
    @@loop_test_ready : Int32 = 0
    # Large, so in a chunk of its own: a 24 000-byte block, in a chunk the
    # Monitor's allocation cursor still held, read allocated after the
    # collections in every arm, the unplanted one included, with nothing
    # found pointing at it ([INFERENCE] a cursor's claim, regression 106).
    LOOP_TEST_BYTES =                    40_000
    LOOP_MARKER     = 0x5eed_5eed_5eed_5eed_u64

    def self.loop_residue_kept? : Bool
      @@loop_test == 2 || @@loop_test == 5
    end

    def self.loop_test_ready? : Bool
      StaticAtomic.load(pointerof(@@loop_test_ready)) != 0
    end

    def self.loop_test_ready : Nil
      StaticAtomic.store(pointerof(@@loop_test_ready), 1)
    end

    @[NoInline]
    def self.loop_test_alloc : Nil
      @@loop_test_block = GC.malloc_atomic(LOOP_TEST_BYTES).address ^ PLANT_KEY
    end

    @[NoInline]
    def self.loop_test_plant(entry_sp : UInt64) : Nil
      @@loop_test_sp = entry_sp
      return if @@loop_test == 3
      pad = uninitialized StaticArray(UInt64, PLANT_WORDS)
      word = @@loop_test >= 4 ? LOOP_MARKER : @@loop_test_block ^ PLANT_KEY
      PLANT_WORDS.times { |i| pad[i] = word }
      asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
    end

    # The Monitor zeroes the stack under `Thread.sleep` before Crystal's sleep
    # builds its frames there (`Thread.sleep` below; the Monitor's `every` is
    # the stdlib's one caller; program and spec calls get the same bounded wipe). `Crystal::System::Thread.sleep` copies the `Time::Span`
    # it is given into its frame and stores 4 bytes of the 8 that hold its
    # nanoseconds; the other 4 are whatever the call before it at that depth
    # left, and each pass that is `every`'s own: on Crystal 1.21.0,
    # `Comparable#clamp`'s `self`, an address in the Monitor's stack, whose
    # high half is the heap's. The word was then a count under 10^7 beneath
    # that half, an address in the heap's 4 GiB, rewritten every 10 ms and
    # read at every stop for as long as the Monitor sleeps: the loop-frame
    # scrub above runs once and cannot reach it. It held `make
    # parallel-dormant`'s burst ("seeded by … parked 3812 KiB"): 13 of 8 000
    # local runs seeded a ≥ 1 MiB block from that one slot of SYSMON's stack,
    # 3 kept it to the end, and with the stack zeroed first none did
    # (`bench/log/linux/2026-11-10-parked-seed-2/FINDINGS.md`). 1 KiB below
    # the SP, frameless, as `leave` does; over-retention only.
    #
    # Research only, regression 111 (`GCRY_MONITOR_SLEEP_TEST`, read in
    # `GC.init`): before each sleep the Monitor writes `LOOP_MARKER` over
    # 8 KiB below `Thread.sleep`'s frame, standing in for `clamp`'s residue,
    # then zeroes it (1) or leaves it, the code before (2,
    # `sleep_residue_kept?`, the control arm). `sleep_test_sp` is the SP the
    # plant was taken under, and `sleep_test_ready?` turns true after the
    # first.
    class_property sleep_test : Int32 = 0
    class_getter sleep_test_sp : UInt64 = 0_u64
    @@sleep_test_ready : Int32 = 0

    def self.sleep_residue_kept? : Bool
      @@sleep_test == 2
    end

    def self.sleep_test_ready? : Bool
      StaticAtomic.load(pointerof(@@sleep_test_ready)) != 0
    end

    @[NoInline]
    def self.sleep_test_plant(sp : UInt64) : Nil
      @@sleep_test_sp = sp
      pad = uninitialized StaticArray(UInt64, PLANT_WORDS)
      PLANT_WORDS.times { |i| pad[i] = LOOP_MARKER }
      asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
      StaticAtomic.store(pointerof(@@sleep_test_ready), 1)
    end
  end
end

# The three things `Monitor#run_loop` calls every ~10 ms are each wrapped in the
# gate: `run_loop` never returns, so a wrapper around the loop has no point at
# which to check anything per pass. The loop itself gets a prologue only, which
# ends the thread's birth as far as a stop is concerned (`MonitorGate.settle`)
# and zeroes the stack the loop's frame is then built on
# (`MonitorGate.scrub_loop_stack`), and the sleep between passes zeroes the
# stack its frames are built on (`Thread.sleep`).
# No compiler fork — reopening the class and calling `previous_def` is ordinary
# Crystal, verified to take effect.
# Only for the process GC: a library heap never stops the world, so there is
# nothing to shut the Monitor out of and no reason to reach into the stdlib.
{% if flag?(:gc_none) && @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
  # Each method wrapped below must exist in this Crystal: a rename would
  # otherwise leave the Monitor ungated, or its loop unscrubbed.
  {% for name in %w[run_loop transfer_schedulers_blocked_on_syscall increase_parallelism collect_stacks] %}
    {% unless Fiber::ExecutionContext::Monitor.has_method?(name) %}
      {% raise "gcry: Fiber::ExecutionContext::Monitor##{name.id} not found; MonitorGate wraps it" %}
    {% end %}
  {% end %}
  {% unless Thread.class.has_method?("sleep") %}
    {% raise "gcry: Thread.sleep not found; MonitorGate wraps it" %}
  {% end %}
  class Fiber::ExecutionContext::Monitor
    # Crystal's loop in a frame of its own, never inlined into the prologue
    # below: the frame must be built after the scrub, not as part of the
    # prologue's.
    @[NoInline]
    private def run_loop : Nil
      previous_def
    end

    # The scrub runs before `settle`, while the Monitor is still a mutator a
    # stop suspends, as `IdleRelease`'s birth scrub runs before its thread is
    # exempt: what it calls (the low-water probe) then never runs alongside a
    # stop. The frameless wipe after `settle` takes the band under this frame,
    # `settle`'s residue included.
    private def run_loop : Nil
      # While still a mutator: a block allocated once settled would run on
      # through a stop.
      if Gcry::MonitorGate.loop_test != 0
        Gcry::MonitorGate.loop_test_alloc
        Gcry::MonitorGate.loop_test_plant(Gcry::Roots.hardware_stack_pointer.address)
      end
      Gcry::MonitorGate.scrub_loop_stack unless Gcry::MonitorGate.loop_residue_kept?
      Gcry::MonitorGate.settle
      unless Gcry::MonitorGate.loop_residue_kept?
        # The band that left under this frame, and the frames it ran on: the
        # allocation slow path's frameless wipe, 1 KiB down from this SP.
        Gcry::Roots.wipe_below_sp(Gcry::Roots.wipe_limit(Gcry::Roots.hardware_stack_pointer.address))
      end
      Gcry::MonitorGate.loop_test_ready if Gcry::MonitorGate.loop_test != 0
      previous_def
    end

    private def transfer_schedulers_blocked_on_syscall
      Gcry::MonitorGate.enter(Gcry::MonitorGate::SITE_TRANSFER)
      begin
        Gcry::MonitorGate.test_spawn_hook
        previous_def
      ensure
        Gcry::MonitorGate.leave
      end
    end

    private def increase_parallelism(now)
      Gcry::MonitorGate.enter(Gcry::MonitorGate::SITE_OTHER)
      begin
        previous_def
      ensure
        Gcry::MonitorGate.leave
      end
    end

    private def collect_stacks(now)
      Gcry::MonitorGate.enter(Gcry::MonitorGate::SITE_COLLECT)
      begin
        previous_def
      ensure
        Gcry::MonitorGate.leave
      end
    end
  end

  # The Monitor's `every` is the stdlib's one caller (Crystal 1.21–1.22); a program calling it gets the same bounded wipe. The stack
  # under this frame is zeroed before Crystal's sleep builds its frames there,
  # so the half of a `Time::Span` word it does not write is 0
  # (`MonitorGate.sleep_test`). Crystal's sleep in a frame of its own, never
  # inlined into this one: its frames must be built after the wipe.
  class Thread
    @[NoInline]
    def self.sleep(time : Time::Span) : Nil
      previous_def
    end

    def self.sleep(time : Time::Span) : Nil
      Gcry::MonitorGate.sleep_test_plant(Gcry::Roots.hardware_stack_pointer.address) if Gcry::MonitorGate.sleep_test != 0
      unless Gcry::MonitorGate.sleep_residue_kept?
        Gcry::Roots.wipe_below_sp(Gcry::Roots.wipe_limit(Gcry::Roots.hardware_stack_pointer.address))
      end
      previous_def
    end
  end
{% end %}
