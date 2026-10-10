# pthread_atfork handlers for process GC. Child inherits the heap mapping but
# must reset locks / STW / thread-local tables (dead parent threads vanish).

require "c/pthread"

lib LibC
  fun pthread_atfork(prepare : ->, parent : ->, child : ->) : Int32
end

module Gcry
  module Platform
    @@atfork_installed = false
    @@fork_prepare : Proc(Nil)? = nil
    @@fork_parent : Proc(Nil)? = nil
    @@fork_child : Proc(Nil)? = nil

    def self.atfork_installed? : Bool
      @@atfork_installed
    end

    def self.set_atfork_handlers(prepare : -> Nil, parent : -> Nil, child : -> Nil) : Nil
      @@fork_prepare = prepare
      @@fork_parent = parent
      @@fork_child = child
    end

    # Register once. Call after set_atfork_handlers from GC.init.
    def self.install_atfork : Nil
      {% unless flag?(:unix) %}
        return
      {% end %}
      return if @@atfork_installed
      return unless @@fork_prepare && @@fork_parent && @@fork_child

      rc = LibC.pthread_atfork(
        -> { @@fork_prepare.try(&.call) },
        -> { @@fork_parent.try(&.call) },
        -> { @@fork_child.try(&.call) },
      )
      @@atfork_installed = rc == 0
    end

    # Take every thread but this one off Crystal's thread list, as Boehm's
    # child handler does (`GC_remove_all_threads_but_me`). Only the thread
    # that called `fork` exists in the child; the list still names every
    # thread the parent had, and every stop walks it. Left there, the
    # child's first stop signals a thread nothing can answer for — the
    # idle-release thread is enough, since the parent's first collection
    # starts it — and waits on it for good: the child of a `GC.collect`,
    # 0.3 s of sleep and a `fork` printed `SUSPEND STALLED … pthread_kill(0)
    # → 22` and was still spinning minutes later
    # (`process_spec/regression/57_fork_child_collects_spec.cr`).
    #
    # The survivor is found by `pthread_self`, not `Thread.current`, which
    # creates a `Thread` on a miss: a `fork` from a thread Crystal never
    # listed leaves the list empty, and that thread is listed the first
    # time it asks. No allocation and no lock: the list mutex may have been
    # held by a parent thread at the `fork`, so it is initialised afresh,
    # and a `push` or `delete` it was in the middle of is overwritten.
    #
    # What the dead threads held stays as reachable as it was at the fork.
    # Unlisted and nothing more, their `Thread` objects, their stacks and
    # their running fibers stopped being roots, and whatever only they held
    # was swept in the child — finalizers included: a `Thread::Mutex` a
    # parked parent thread had locked was destroyed by its finalizer, which
    # raised `pthread_mutex_destroy: Device or resource busy` out of the
    # child's `GC.collect` on every CI job of 2026-10-10 (spec 57). So the
    # unlisted threads are chained on `Thread.gcry_fork_orphans` instead,
    # through the same `next` links, and `Heap#scan_fork_orphan_roots` marks
    # them as `scan_thread_roots` marks a listed thread. Their stacks are
    # scanned from a copy taken right after this, in the same handler
    # (`Heap#snapshot_fork_orphan_stacks`): glibc hands a dead thread's
    # stack to the child's next new thread, or unmaps it. Boehm drops a dead
    # thread's stack in the child; nothing the child runs can reach what is
    # on it, so keeping it costs memory only, and freeing it runs finalizers
    # against state no thread will release.
    #
    # What this cannot keep is what a dead thread held only in a register
    # at the moment of the `fork`. The kernel copies the forking thread's
    # registers and nobody else's, so those values exist nowhere in the
    # child. A parent stop reads them from the suspend handler's saved
    # context; the child has no such context to read. Boehm has the same
    # limit and drops the stacks besides.
    def self.unlist_threads_after_fork : Nil
      ::Thread.gcry_unlist_all_but(LibC.pthread_self)
    end
  end
end

class Thread
  # The parent's threads, unlisted in a forked child, chained through
  # `next`; those of every earlier `fork` in this process's ancestry too.
  # No initializer, so no lazy guard: nil until the first `fork`.
  @@gcry_fork_orphans : Thread?

  # :nodoc:
  def self.gcry_fork_orphans : Thread?
    @@gcry_fork_orphans
  end

  # :nodoc:
  def self.gcry_unlist_all_but(survivor_handle : LibC::PthreadT) : Nil
    list = @@threads
    # `uninitialized` until `Thread.init`, and a null reference until then.
    return if list.object_id == 0
    @@gcry_fork_orphans = list.gcry_unlink_after_fork(@@gcry_fork_orphans) do |thread|
      thread.to_unsafe != survivor_handle
    end
  end

  class LinkedList(T)
    # :nodoc:
    # For a fork child: initialises the mutex afresh — a dead thread may
    # have held it, in a `push` or `delete` this overwrites — and moves every
    # node the block selects off the list and onto *chain*, linked through
    # `next`. Returns the chain's new head. No lock and no allocation.
    #
    # Forward links only, and every back link and `@tail` rebuilt from them.
    # A parent thread can have been inside `push` or `delete` at the `fork`,
    # and both write the forward link before the back link and `@tail`:
    # `delete(D)` leaves `X.next == N` with `N.previous` still `D`, and
    # `push` can leave `@tail` on the node before the one it appended.
    # Splicing through `previous` there wrote to `D`, kept `X.next == N`,
    # and, with `N` moved to the chain, cut every node after it off the
    # list: a fiber parked after it went unscanned in the child and lost
    # what its frame held (the torn-list example in spec 57).
    def gcry_unlink_after_fork(chain : T?, & : T -> Bool) : T?
      @mutex.gcry_reinit_after_fork
      kept = nil
      node = @head
      @head = nil
      while node
        following = node.next
        if yield node
          node.previous = nil
          node.next = chain
          chain = node
        else
          if kept
            kept.next = node
          else
            @head = node
          end
          node.previous = kept
          kept = node
        end
        node = following
      end
      kept.next = nil if kept
      @tail = kept
      chain
    end
  end

  class Mutex
    # :nodoc:
    # The same `ERRORCHECK` mutex `#initialize` makes, in place.
    def gcry_reinit_after_fork : Nil
      attributes = uninitialized LibC::PthreadMutexattrT
      LibC.pthread_mutexattr_init(pointerof(attributes))
      LibC.pthread_mutexattr_settype(pointerof(attributes), LibC::PTHREAD_MUTEX_ERRORCHECK)
      LibC.pthread_mutex_init(to_unsafe, pointerof(attributes))
      LibC.pthread_mutexattr_destroy(pointerof(attributes))
    end
  end
end

class Fiber
  # The fibers the parent's threads were on, unlisted in a forked child
  # (`Heap#snapshot_fork_orphan_stacks` says which), chained through `next`.
  # Their stacks were glibc's or are not where the fiber says any more, so a
  # walk of the list must not read them; their objects stay reachable from
  # here. No initializer, so no lazy guard: nil until the first `fork`.
  @@gcry_fork_orphans : Fiber?

  # :nodoc:
  def self.gcry_fork_orphans : Fiber?
    @@gcry_fork_orphans
  end

  # :nodoc:
  def self.gcry_unlist_after_fork(& : Fiber -> Bool) : Nil
    list = @@fibers
    # `uninitialized` until `Fiber.init`, and a null reference until then.
    return if list.object_id == 0
    @@gcry_fork_orphans = list.gcry_unlink_after_fork(@@gcry_fork_orphans) { |fiber| yield fiber }
  end
end
