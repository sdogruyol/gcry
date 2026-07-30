# Stop-the-world: GC lock, thread suspend/resume, fork child reinit.
#
# RWLock notes for Darwin:
#   `Crystal::RWLock` is a pure userspace spinlock with no `try_write_lock`.
#   If thread A holds `lock_read` and then calls `lock_write` (via allocation →
#   `maybe_collect`), it spins forever because it can't release its own read lock.
#   On Linux, signal-based thread_suspend interrupts the reader; on Darwin, Mach
#   `thread_suspend` freezes the thread in place — the lock stays held.
#
#   Fortunately, Mach STW already provides mutual exclusion: the collector stops
#   **all** other threads before touching the heap, so there is no concurrent
#   mutation during GC.  The RWLock is thus redundant on Darwin — make it a no-op.

module Gcry
  class Heap
    def lock_read : Nil
      {% unless flag?(:darwin) %}
        return unless @stop_the_world
        @gc_lock.read_lock
      {% end %}
    end

    def unlock_read : Nil
      {% unless flag?(:darwin) %}
        return unless @stop_the_world
        @gc_lock.read_unlock
      {% end %}
    end

    def lock_write : Nil
      {% unless flag?(:darwin) %}
        return unless @stop_the_world
        @gc_lock.write_lock
      {% end %}
    end

    def unlock_write : Nil
      {% unless flag?(:darwin) %}
        return unless @stop_the_world
        @gc_lock.write_unlock
      {% end %}
    end

    # Match Crystal `gc/none` STW on Linux (signal-suspend). Darwin uses Mach
    # thread_suspend instead — SIGXFSZ never interrupts kevent waits under HTTP.
    #
    # Hold `Thread.lock` for the whole stop→start window (same as Crystal
    # `gc/none`). Parallel ExecutionContext starts worker threads lazily under
    # load; without the list mutex a new thread can `threads.push` + allocate
    # during mark/sweep (Kemal EC>1: realloc "not a gcry allocation" / SEGV).
    # Do not allocate while this lock is held.
    def stop_world : Nil
      return unless @stop_the_world
      return if @world_stopped

      current_thread = Thread.current
      Thread.lock
      begin
        {% if flag?(:darwin) %}
          Platform.stop_world_threads(current_thread)
        {% else %}
          Thread.unsafe_each do |thread|
            thread.suspend unless thread == current_thread
          end
          Thread.unsafe_each do |thread|
            thread.wait_suspended unless thread == current_thread
          end
        {% end %}
        @world_stopped = true
      rescue ex
        # If suspend fails mid-way, unlock so the process can still unwind.
        Thread.unlock
        raise ex
      end
    end

    # stop_world only after root-list mutators finish add/delete (see @roots_lock).
    private def stop_world_quiescing_roots : Nil
      @roots_lock.lock
      begin
        stop_world
      ensure
        # If stop_world raised before setting @world_stopped, unlock roots only;
        # Thread.lock is released in the rescue above. On success Thread.lock
        # stays held until start_world.
        @roots_lock.unlock
      end
    end

    def start_world : Nil
      return unless @world_stopped

      current_thread = Thread.current
      begin
        {% if flag?(:darwin) %}
          Platform.start_world_threads(current_thread)
        {% else %}
          Thread.unsafe_each do |thread|
            thread.resume unless thread == current_thread
          end
        {% end %}
        Platform.clear_thread_sps
        @world_stopped = false
      ensure
        Thread.unlock
      end
    end

    # Child after fork: only this OS thread survives. Reset locks / STW / caches
    # so GC can run again (heap mappings are inherited).
    def after_fork_child_reinit : Nil
      @world_stopped = false
      @collecting = false
      @running_finalizers = false
      @incremental_marking = false
      @inc_active = false
      @gc_lock = Crystal::RWLock.new
      @alloc_lock = Crystal::SpinLock.new
      @roots_lock = Crystal::SpinLock.new
      @index_lock = Crystal::SpinLock.new
      @post_stw_lock = Crystal::SpinLock.new
      @tlabs_booted = false
      @soft_dirty_armed = false
      @soft_dirty_probed = false
      @soft_dirty_works = false
      @soft_dirty_skip_until_major = false
      disarm_mprotect_barrier if @barrier_backend.mprotect?
      @barrier_backend = Platform::BarrierBackend::None
      reset_mark_workers_after_fork
      Platform.reset_stw_after_fork
      Platform.invalidate_static_root_cache
      begin
        set_stackbottom(Fiber.current.@stack.bottom)
      rescue
      end
    end
  end
end
