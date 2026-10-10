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
    # them as `scan_thread_roots` marks a listed thread and scans their
    # running fibers' stacks whole: there is no SP for a thread that does
    # not exist. Boehm drops a dead thread's stack in the child; nothing the
    # child runs can reach what is on it, so keeping it costs memory only,
    # and freeing it runs finalizers against state no thread will release.
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
    survivor = nil
    orphans = @@gcry_fork_orphans
    node = list.@head
    while node
      following = node.next
      if node.to_unsafe == survivor_handle
        survivor = node
      else
        node.previous = nil
        node.next = orphans
        orphans = node
      end
      node = following
    end
    @@gcry_fork_orphans = orphans
    list.gcry_reset_after_fork(survivor)
  end

  class LinkedList(T)
    # :nodoc:
    def gcry_reset_after_fork(survivor : T?) : Nil
      @mutex.gcry_reinit_after_fork
      if survivor
        survivor.previous = nil
        survivor.next = nil
      end
      @head = @tail = survivor
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
