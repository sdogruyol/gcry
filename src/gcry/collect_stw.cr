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
        wait_if_world_stopped_other_thread
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

    # Non-collector threads must not mutate the heap or take GC.lock_read while
    # STW is active (SYSMON is signal-exempt — see stop_world), or during EC1
    # post-STW `@chunks` rebuild / pending munmap (`@block_other_heap`).
    private def wait_if_world_stopped_other_thread : Nil
      return unless @world_stopped || @block_other_heap
      owner = @stw_owner
      return if owner && Thread.current == owner
      until !@world_stopped && !@block_other_heap
        Intrinsics.pause
      end
    end

    # Match Crystal `gc/none` STW on Linux (signal-suspend). Darwin uses Mach
    # thread_suspend instead — SIGXFSZ never interrupts kevent waits under HTTP.
    #
    # Linux ExecutionContext (`GCRY_STRESS` hang: main=`futex_do_wait`,
    # SYSMON=`sigsuspend`):
    # - Never call `Thread#wait_suspended` (`yield_current` parks on SYSMON).
    # - Do not SIGPWR-suspend the Monitor (`SYSMON`): resume races leave it in
    #   `sigsuspend` forever. Instead mark `@world_stopped` and make
    #   allocate/lock_read spin until start_world (cooperative STW).
    # - Still signal-suspend other mutator threads; busy-wait `@suspended`.
    # - Hold `Thread.lock` for stop→start (Crystal list-mutex protocol).
    def stop_world : Nil
      return unless @stop_the_world
      return if @world_stopped

      current_thread = Thread.current
      StwWatchdog.enter(StwWatchdog::PHASE_SUSPEND)
      @stw_owner = current_thread
      {% if flag?(:darwin) %}
        Platform.stop_world_threads(current_thread)
        @world_stopped = true
      {% else %}
        Thread.lock
        begin
          # Take every thread's stack bounds while they are all still running.
          # `pthread_getattr_np` locks the *target's* descriptor, so asking it
          # about a thread the suspend signals have already frozen deadlocks the
          # collector. It did: 18 of 150 starts, wedged in that call
          # (`bench/stw_startup_hang.cr`; isolated to non-main threads, 9 of 100,
          # against 0 of 100 for the main thread). Same call count as before,
          # moved out of the suspension window; `Thread.lock` is already held, so
          # the set snapshotted here is exactly the set scanned below.
          Platform.begin_stack_bounds_snapshot
          Thread.unsafe_each do |thread|
            Platform.snapshot_pthread_stack_bounds(thread.to_unsafe)
          end
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            thread.suspend
          end
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            until thread.@suspended.get
              Intrinsics.pause
            end
          end
          @world_stopped = true
        rescue ex
          @world_stopped = false
          @stw_owner = nil
          Thread.unlock
          raise ex
        end
      {% end %}
    end

    # ExecutionContext Monitor — signal-exempt; cooperates via @world_stopped.
    # Use `@name` (not `#name`) to avoid getter side effects under `-Dgc_none`.
    private def stw_signal_exempt?(thread : Thread) : Bool
      name = thread.@name
      !name.nil? && name == "SYSMON"
    end

    # stop_world only after root-list / finalizer-table mutators finish
    # (see @roots_lock, Finalizers::Registry#lock_for_stw).
    private def stop_world_quiescing_roots : Nil
      @roots_lock.lock
      @finalizers.lock_for_stw
      begin
        stop_world
      ensure
        @finalizers.unlock_for_stw
        @roots_lock.unlock
      end
    end

    def start_world : Nil
      return unless @world_stopped

      # Drop last-chunk cache before mutators resume — index_remove already
      # invalidates, but a mark-time cache entry must not outlive STW.
      invalidate_chunk_cache

      current_thread = Thread.current
      {% if flag?(:darwin) %}
        Platform.start_world_threads(current_thread)
        Platform.clear_thread_sps
        @world_stopped = false
        @stw_owner = nil
        StwWatchdog.leave
      {% else %}
        begin
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            thread.resume
            spins = 0
            until !thread.@suspended.get
              Intrinsics.pause
              spins += 1
              if spins == 10_000
                thread.resume
                spins = 0
              end
            end
          end
          Platform.clear_thread_sps
          @world_stopped = false
          @stw_owner = nil
          StwWatchdog.leave
        ensure
          Thread.unlock
        end
      {% end %}
    end

    # Child after fork: only this OS thread survives. Reset locks / STW / caches
    # so GC can run again (heap mappings are inherited).
    def after_fork_child_reinit : Nil
      @world_stopped = false
      @stw_owner = nil
      @block_other_heap = false
      @collecting = false
      @running_finalizers = false
      @incremental_marking = false
      @inc_active = false
      @gc_lock = Crystal::RWLock.new
      @alloc_lock = Crystal::SpinLock.new
      init_freelist_locks
      @roots_lock = Crystal::SpinLock.new
      @index_lock = Crystal::SpinLock.new
      init_post_stw_mutex
      @tlabs_booted = false
      @alloc_batches_booted = false
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
