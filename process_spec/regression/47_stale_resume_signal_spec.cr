require "../../src/gcry"
require "spec"

# A resume signal left over from an earlier stop (PR #44 review, round 2).
#
# On Linux a thread is stopped by `SIG_SUSPEND`, whose handler waits in
# `sigsuspend` for `SIG_RESUME`. `start_world` resends the resume to a thread
# slow to acknowledge, so a thread can be handed one it never takes. A thread
# that keeps `SIG_RESUME` unblocked loses it to the empty resume handler; one
# that blocks it — a C thread registered with `GC_register_my_thread`, from a
# pool that blocks every signal — keeps it pending, and it arrives the moment
# the next stop's `sigsuspend` unblocks it. Until 2026-10-08 the handler took
# that as the end of the stop: the thread ran through a stopped world, and an
# 8-thread register/allocate loop next to `GC.collect` wedged on a lock such a
# thread took (2 of 2 runs with SIGXCPU blocked, 3 of 3 with every signal).
# Boehm waits in a loop until its stop count moves; so does gcry now, on the
# stop epoch (src/gcry/platform/linux_stw.cr).
#
# The stale resume is sent here by hand, which is what the resend amounts to,
# and the thread is caught moving from inside the stopped world rather than by
# a hang, so the old handler fails this file instead of wedging it.

{% if flag?(:linux) && (flag?(:x86_64) || flag?(:aarch64)) %}
  lib LibStaleResume
    fun pthread_kill(thread : LibC::PthreadT, sig : LibC::Int) : LibC::Int
  end

  # Words shared with the C thread and the hook, in libc memory: the thread
  # has no `Thread`, and the hook runs world stopped, so neither may touch
  # anything that initialises lazily.
  private enum Slot
    Phase
    Register
    Counter
    ThreadId
    Unregister
    Watch
    Moved
    HookRuns
    Count
  end

  private def slot_ptr(shared : Int64*, slot : Slot) : Int64*
    shared + slot.value
  end

  private def load(shared : Int64*, slot : Slot) : Int64
    Atomic::Ops.load(slot_ptr(shared, slot), :sequentially_consistent, true)
  end

  private def store(shared : Int64*, slot : Slot, value : Int64) : Nil
    Atomic::Ops.store(slot_ptr(shared, slot), value, :sequentially_consistent, true)
  end

  private def now_ns : Int64
    ts = uninitialized LibC::Timespec
    LibC.clock_gettime(LibC::CLOCK_MONOTONIC, pointerof(ts))
    ts.tv_sec.to_i64 &* 1_000_000_000 &+ ts.tv_nsec.to_i64
  end

  # The C thread: every signal blocked, as a library's pool has it, then
  # registered — which unblocks the suspend signal and nothing else — and then
  # busy until told to stop, counting in libc memory. It allocates nothing, so
  # nothing it does while running through a stop can take a lock the collector
  # waits on; the counter is the only witness.
  private def foreign_body(shared : Int64*) : Nil
    all = uninitialized LibC::SigsetT
    LibC.sigfillset(pointerof(all))
    LibC.pthread_sigmask(LibC::SIG_SETMASK, pointerof(all), nil)
    store(shared, Slot::ThreadId, LibC.pthread_self.unsafe_as(Int64))
    sb = LibGC::StackBase.new
    LibGC.get_stack_base(pointerof(sb))
    store(shared, Slot::Register, LibGC.register_my_thread(pointerof(sb)).to_i64)
    store(shared, Slot::Phase, 1)
    n = 0_i64
    until load(shared, Slot::Phase) >= 2
      n &+= 1
      store(shared, Slot::Counter, n)
    end
    store(shared, Slot::Unregister, LibGC.unregister_my_thread.to_i64)
    store(shared, Slot::Phase, 3)
  end

  describe "Regression: a stale resume signal does not end the next stop" do
    it "keeps a registered C thread that blocks SIG_RESUME stopped for the whole stop" do
      LibGC.allow_register_threads
      shared = LibC.malloc(Slot::Count.value * sizeof(Int64)).as(Int64*)
      shared.clear(Slot::Count.value)
      store(shared, Slot::Register, -1)
      store(shared, Slot::Unregister, -1)

      # Runs world stopped in every collection's root phase, and allocates
      # nothing. While watching, it waits 20 ms — far longer than a running
      # thread takes to bump the counter, far shorter than a stop tolerates —
      # and adds up how far the counter moved meanwhile.
      GC.before_collect do
        if load(shared, Slot::Watch) != 0
          store(shared, Slot::HookRuns, load(shared, Slot::HookRuns) &+ 1)
          before = load(shared, Slot::Counter)
          deadline = now_ns &+ 20_000_000
          while now_ns < deadline
            Intrinsics.pause
          end
          store(shared, Slot::Moved, load(shared, Slot::Moved) &+ (load(shared, Slot::Counter) &- before))
        end
      end

      body = ->(arg : Void*) { foreign_body(arg.as(Int64*)); Pointer(Void).null }
      # Plain `LibC.pthread_create`: a thread gcry is told about only by the
      # thread itself, as a C library's would be.
      LibC.pthread_create(out tid, nil, body, shared.as(Void*)).should eq(0)
      deadline = Time.instant + 30.seconds
      until load(shared, Slot::Phase) >= 1
        raise "the C thread never registered" if Time.instant > deadline
        Thread.sleep(1.millisecond)
      end
      load(shared, Slot::Register).should eq(0) # GC_SUCCESS

      # A clean stop first: the thread is stopped and resumed as any other.
      store(shared, Slot::Watch, 1)
      LibGC.collect
      load(shared, Slot::HookRuns).should eq(1)
      load(shared, Slot::Moved).should eq(0)

      # The leftover resume. Blocked in the thread's mask, so it stays pending
      # until the next stop's `sigsuspend` unblocks it.
      3.times do |round|
        LibStaleResume.pthread_kill(load(shared, Slot::ThreadId).unsafe_as(LibC::PthreadT),
          Gcry::Platform::STW_SIG_RESUME).should eq(0)
        LibGC.collect
        load(shared, Slot::HookRuns).should eq(2 + round)
        load(shared, Slot::Moved).should eq(0)
      end

      store(shared, Slot::Watch, 0)
      store(shared, Slot::Phase, 2)
      LibC.pthread_join(tid, nil).should eq(0)
      load(shared, Slot::Unregister).should eq(0)
      # `shared` stays allocated: the hook outlives this example.
    end
  end
{% end %}
