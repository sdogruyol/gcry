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
      # The Monitor is never signal-suspended, so it is shut out by handshake
      # instead — before anything it could be mutating is touched.
      MonitorGate.close
      @stw_owner = current_thread
      {% if flag?(:darwin) %}
        Platform.stop_world_threads(current_thread)
        @world_stopped = true
      {% else %}
        # `GCRY_STAGED_WAIT=1`: give a thread that exists but has not published
        # itself a moment to do so, before the world is stopped around it.
        #
        # gcry records such threads (`Platform.stage_thread`), so it can *see*
        # the window the census measures — but seeing it changes nothing on its
        # own. Waiting is the least invasive way to act on the record: it does
        # not touch what is suspended or scanned, it only declines to start
        # stopping while a thread is known to be invisible.
        #
        # **Before `Thread.lock`, and that is not a detail.** A starting thread
        # publishes itself from `Thread#start`, which takes the very mutex
        # `Thread.lock` holds. Waiting while holding it would deadlock by
        # construction — the thread cannot do the thing being waited for.
        #
        # Hard-bounded. A staged entry that never clears — a thread that died
        # before publishing, or a record lost to table overflow — must cost a
        # bounded delay and not a hung collector, so the wait gives up and says
        # so in `stw_staged_wait_timeouts`.
        wait_for_staged_threads if @staged_wait

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
          listed = 0
          Thread.unsafe_each do |thread|
            listed += 1
            Platform.unstage_thread(thread.to_unsafe.unsafe_as(UInt64))
            # On the list, so the list is its root from here on: drop the one
            # taken at `pthread_create` (src/gcry/thread_birth_root.cr).
            # `@roots` directly — `@roots_lock` is already held by
            # `stop_world_quiescing_roots` and it is not reentrant.
            if rooted = ThreadBirthRoot.release(thread.to_unsafe.unsafe_as(UInt64))
              @roots.delete(rooted)
            end
            Platform.snapshot_pthread_stack_bounds(thread.to_unsafe)
          end
          # Does the set about to be stopped account for every thread the
          # process has? gcry learns about threads from Crystal's list, so a
          # thread that exists but has not pushed itself yet is neither
          # suspended nor scanned (src/gcry/platform/linux_thread_census.cr).
          # Off by default: it reads /proc inside the pause.
          census_threads(listed) if @thread_census
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
        MonitorGate.open
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
          MonitorGate.open
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
