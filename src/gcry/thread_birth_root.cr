# The `Thread` object between `pthread_create` and its own first push.
#
# The second use-after-free, named on 2026-08-20
# (`bench/log/linux/2026-08-20-dying-thread-holder/FINDINGS.md`): gcry read a
# `Thread`'s `@system_handle` out of a block it had already reclaimed. The chain
# is short and every link of it was measured —
#
#   1. `pthread_create` returns. The new thread has not yet pushed itself onto
#      `Thread.threads`, because Crystal publishes a thread only from inside its
#      own `start`.
#   2. A collection begins. `stop_world`'s pre-stop wait spins for the staged
#      thread, it does not publish in time, and the wait **gives up** — it drops
#      the record and stops the world anyway. In the catch: `5 on Crystal's
#      list … the kernel says 6`.
#   3. The `Thread` object is off the list, so the static root that is
#      `Thread.threads` does not cover it. Its only holder is the new thread's
#      own stack, which gcry has no bounds for and never scans. The mark cannot
#      reach it; the sweep frees it.
#   4. The thread publishes. The **next** `stop_world` walks the list, reads
#      `@system_handle` out of the freed block and hands it to
#      `pthread_getattr_np`. That is the SIGSEGV seen since 2026-08-16, and the
#      `+0x418` into `struct pthread` that never varied.
#
# The fix does not touch the stopped world at all, and that is the point: two
# earlier attempts at this defect changed collector behaviour and broke it. It
# needs no wait, no timeout, and no bounds for a stack nobody can safely ask
# about — because **the object is already in gcry's hands**. Crystal calls
# `GC.pthread_create(..., arg: self.as(Void*))`, so the `Thread` is the very
# argument the hook is handed. Root it there, release it when the thread turns
# up on Crystal's list, and step 3 cannot happen.
#
# What it does not close, stated because the census will keep reporting it: the
# interval *inside* `pthread_create`, before it returns. Covering that needs a
# trampoline on the new thread, which was tried for the staging record and
# crashed 8 runs in 10.
#
# `GCRY_THREAD_BIRTH_ROOT=0` turns it off. `GCRY_THREAD_BIRTH_NOROOT=1` is the
# twin: it records exactly the same births and roots nothing, so a run that
# survives cannot be credited to the bookkeeping.

module Gcry
  module ThreadBirthRoot
    # One slot per thread being born. 64 concurrent births is far past anything
    # Crystal's scheduler starts at once; overflow is counted rather than
    # silently dropped, because "no births recorded" and "the table was full"
    # are different facts.
    SLOTS = 64

    # The recorded address is stored **masked**. This table is a class variable,
    # i.e. static memory that the conservative root scan reads, so a plain
    # address in it is a root — which would make the twin arm
    # (`GCRY_THREAD_BIRTH_NOROOT=1`) keep alive exactly what it claims to leave
    # alone, and would leave the shipped arm unable to say whether the survival
    # came from `add_root` or from the bookkeeping. Caught by the twin on
    # aarch64 CI, where it survived; it had passed locally on x86_64.
    TABLE_MASK = 0x5A5A_A5A5_5A5A_A5A5_u64

    @@ids = uninitialized StaticArray(UInt64, SLOTS)
    @@objects = uninitialized StaticArray(UInt64, SLOTS)
    @@used = uninitialized StaticArray(Bool, SLOTS)
    @@enabled = uninitialized Bool
    @@noroot = uninitialized Bool
    @@armed = uninitialized UInt64
    @@released = uninitialized UInt64
    @@overflows = uninitialized UInt64
    @@outstanding = uninitialized Int32

    # Called once from `GC.init`, on the main thread, before any thread exists.
    # `uninitialized` and cleared here for the same reason as the staging table:
    # a class variable with an initializer is set up lazily behind a guard, and
    # an early access from a thread that has not finished starting hung the
    # first process that created one.
    def self.init : Nil
      i = 0
      while i < SLOTS
        @@ids[i] = 0_u64
        @@objects[i] = 0_u64
        @@used[i] = false
        i += 1
      end
      @@enabled = true
      @@noroot = false
      @@armed = 0_u64
      @@released = 0_u64
      @@overflows = 0_u64
      @@outstanding = 0
    end

    def self.enabled=(value : Bool) : Bool
      @@enabled = value
    end

    def self.noroot=(value : Bool) : Bool
      @@noroot = value
    end

    def self.armed : UInt64
      @@armed
    end

    def self.released : UInt64
      @@released
    end

    def self.overflows : UInt64
      @@overflows
    end

    # Births rooted and not yet released. Non-zero at exit is a thread that
    # never published — the root is then held for the life of the process, which
    # is the lesser harm and is countable.
    def self.outstanding : Int32
      n = @@outstanding
      n < 0 ? 0 : n
    end

    # From `GC.pthread_create`, immediately after it returns. *object* is the
    # `arg` Crystal passed, which for a `Thread` is the object itself.
    def self.arm(id : UInt64, object : Void*) : Nil
      return unless @@enabled
      return if id == 0 || object.null?
      heap = Gcry.default_heap?
      return unless heap
      i = 0
      while i < SLOTS
        unless @@used[i]
          @@ids[i] = id
          @@objects[i] = object.address ^ TABLE_MASK
          @@used[i] = true
          @@armed &+= 1
          @@outstanding += 1
          # The twin walks the same table and offers nothing.
          heap.add_root(object) unless @@noroot
          return
        end
        i += 1
      end
      @@overflows &+= 1
    end

    # From `stop_world`'s pre-suspend walk of Crystal's list: this thread has
    # published itself, so the list is its root from here on.
    #
    # Returns the pointer to un-root, and does **not** un-root it here. The
    # caller is inside `stop_world`, which runs under `@roots_lock` — taken by
    # `stop_world_quiescing_roots` and held across the whole stop — and that
    # lock is a non-reentrant spinlock. The first version called
    # `heap.delete_root` from here and deadlocked the collector on the first run
    # of `make thread-birth-root`: `GC.collect` never returned.
    def self.release(id : UInt64) : Void*?
      return nil if id == 0
      i = 0
      while i < SLOTS
        if @@used[i] && @@ids[i] == id
          object = @@objects[i] ^ TABLE_MASK
          @@used[i] = false
          @@ids[i] = 0_u64
          @@objects[i] = 0_u64
          @@released &+= 1
          @@outstanding -= 1
          return nil if @@noroot || object == TABLE_MASK || object == 0
          return Pointer(Void).new(object)
        end
        i += 1
      end
      nil
    end
  end
end
