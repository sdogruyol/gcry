module Gcry
  # Research only, regression 112 (`GCRY_MONITOR_ONCE_TEST`, read in
  # `GC.init`, before the Monitor starts): the main thread is held inside a
  # class variable's initializer in `__crystal_main` — this file is required
  # before every other one that declares class variables, so none of gcry's
  # own is initialized yet — until the Monitor has finished `HOLD_PASSES`
  # gated calls (`MonitorGate.leave`), or `HOLD_LIMIT_NS` has passed. 1 is
  # the fixed arm: the Monitor runs its loop prologue, its sleeps and its
  # gated work meanwhile, every one of them on literal-initialized storage.
  # 2 is the control arm, the code before: once the main thread is in the
  # initializer, the Monitor reads the variable it initializes, an
  # `Atomic(Int32).new` as `MonitorGate`'s flags were, and waits in `once`.
  # On Crystal 1.21 the main thread's `resume_all` then raises
  # `Fiber#execution_context cannot be nil`; on 1.22 the Monitor's thread
  # waits out the hold, and `held_passes` stays under `HOLD_PASSES`.
  # `held_passes` is how many gated calls the Monitor finished while the main
  # thread was held.
  module MonitorOnceTest
    HOLD_PASSES   =                 3
    HOLD_LIMIT_NS = 3_000_000_000_u64

    class_property arm : Int32 = 0
    class_getter held_passes : Int32 = 0
    @@passes : Int32 = 0
    @@holding : Int32 = 0
    # The one call initializer the Monitor may read, and only in arm 2.
    @@held : Atomic(Int32) = hold

    def self.hold : Atomic(Int32)
      if @@arm != 0
        StaticAtomic.store(pointerof(@@holding), 1)
        t0 = Clock.monotonic_ns
        while StaticAtomic.load(pointerof(@@passes)) < HOLD_PASSES && Clock.monotonic_ns &- t0 < HOLD_LIMIT_NS
          Intrinsics.pause
        end
        @@held_passes = StaticAtomic.load(pointerof(@@passes))
        StaticAtomic.store(pointerof(@@holding), 0)
      end
      Atomic(Int32).new(0)
    end

    # On the Monitor, at the end of each gated call.
    def self.pass : Nil
      StaticAtomic.add(pointerof(@@passes), 1)
      return unless @@arm == 2 && StaticAtomic.load(pointerof(@@holding)) != 0
      @@held.get
    end
  end
end
