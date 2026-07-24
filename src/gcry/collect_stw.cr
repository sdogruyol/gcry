# Stop-the-world: GC lock, thread suspend/resume, fork child reinit.

module Gcry
  class Heap
    def lock_read : Nil
      return unless @stop_the_world
      @gc_lock.read_lock
    end

    def unlock_read : Nil
      return unless @stop_the_world
      @gc_lock.read_unlock
    end

    def lock_write : Nil
      return unless @stop_the_world
      @gc_lock.write_lock
    end

    def unlock_write : Nil
      return unless @stop_the_world
      @gc_lock.write_unlock
    end

    # Match Crystal `gc/none` STW: signal-suspend every other OS thread.
    # Required for process GC because ExecutionContext's Monitor thread holds
    # live heap pointers that are not on Fiber.current's stack.
    #
    # Do not hold Thread.lock across suspend/mark — another thread may allocate
    # while mutating the thread list and deadlock on @gc_lock.
    def stop_world : Nil
      return unless @stop_the_world
      return if @world_stopped

      current_thread = Thread.current
      Thread.unsafe_each do |thread|
        thread.suspend unless thread == current_thread
      end
      Thread.unsafe_each do |thread|
        thread.wait_suspended unless thread == current_thread
      end
      @world_stopped = true
    end

    def start_world : Nil
      return unless @world_stopped

      current_thread = Thread.current
      Thread.unsafe_each do |thread|
        thread.resume unless thread == current_thread
      end
      Platform.clear_thread_sps
      @world_stopped = false
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
      @tlabs_booted = false
      @soft_dirty_armed = false
      @soft_dirty_probed = false
      @soft_dirty_works = false
      @soft_dirty_skip_until_major = false
      disarm_mprotect_barrier if @barrier_backend.mprotect?
      @barrier_backend = Platform::BarrierBackend::None
      Platform.reset_stw_after_fork
      Platform.invalidate_static_root_cache
      begin
        set_stackbottom(Fiber.current.@stack.bottom)
      rescue
      end
    end
  end
end
