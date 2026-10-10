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
    # The unlisted `Thread` objects stay where their birth roots hold them
    # (`ThreadBirthRoot`): none of the dead threads will ever say it is
    # done with its object, and one whose handle the child's libc hands to
    # a new thread is reclaimed by `ThreadBirthRoot.arm`, as in the parent.
    def self.unlist_threads_after_fork : Nil
      ::Thread.gcry_unlist_all_but(LibC.pthread_self)
    end
  end
end

class Thread
  # :nodoc:
  def self.gcry_unlist_all_but(survivor_handle : LibC::PthreadT) : Nil
    list = @@threads
    # `uninitialized` until `Thread.init`, and a null reference until then.
    return if list.object_id == 0
    survivor = nil
    list.unsafe_each do |thread|
      survivor = thread if thread.to_unsafe == survivor_handle
    end
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
