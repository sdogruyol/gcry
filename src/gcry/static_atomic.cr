module Gcry
  # Sequentially consistent operations, as `Atomic(T)`'s defaults, on class
  # variables with literal initializers. For state a thread of gcry's or the
  # Monitor reads: an `Atomic(T).new` class variable is initialized through
  # Crystal's `once`, and a bare thread that reads it while `__crystal_main`
  # is running its initializer waits in `once`, which on Crystal 1.21 kills
  # the program when the initializer ends (`MonitorGate`, regression 112).
  # Only on literal-initialized class variables: `pointerof` on one with a
  # call initializer runs the initializer.
  module StaticAtomic
    @[AlwaysInline]
    def self.load(ptr : T*) : T forall T
      Atomic::Ops.load(ptr, :sequentially_consistent, true)
    end

    @[AlwaysInline]
    def self.store(ptr : T*, value : T) : Nil forall T
      Atomic::Ops.store(ptr, value, :sequentially_consistent, true)
    end

    @[AlwaysInline]
    def self.add(ptr : T*, value : T) : T forall T
      Atomic::Ops.atomicrmw(:add, ptr, value, :sequentially_consistent, false)
    end

    @[AlwaysInline]
    def self.swap(ptr : T*, value : T) : T forall T
      Atomic::Ops.atomicrmw(:xchg, ptr, value, :sequentially_consistent, false)
    end
  end
end
