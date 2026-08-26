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

# `pthread_kill(id, 0)` asks whether a handle still names a live thread without
# sending anything. Crystal does not bind it.
lib LibStwProbe
  fun pthread_kill(thread : LibC::PthreadT, sig : LibC::Int) : LibC::Int
end

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
      if (prestall = @stw_test_presuspend_stall_ms) > 0
        deadline = Gcry::Clock.monotonic_ns &+ prestall &* 1_000_000_u64
        while Gcry::Clock.monotonic_ns < deadline
          Intrinsics.pause
        end
      end
      # The Monitor is never signal-suspended, so it is shut out by handshake
      # instead — before anything it could be mutating is touched.
      # Second close, kept deliberately: `GC.stop_world` calls `stop_world`
      # directly, so removing this would leave that entry point with the
      # Monitor still running. On the normal path the gate is already shut and
      # this costs two atomic reads.
      MonitorGate.close
      StwWatchdog.note_suspend_step(StwWatchdog::STEP_GATE_CLOSED)
      @stw_owner = current_thread
      @stw_owner_pthread = LibC.pthread_self.unsafe_as(UInt64)
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
        StwWatchdog.note_suspend_step(StwWatchdog::STEP_STAGED_DONE)

        Thread.lock
        StwWatchdog.note_suspend_step(StwWatchdog::STEP_THREAD_LOCK)
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
          StwWatchdog.note_suspend_step(StwWatchdog::STEP_BOUNDS_DONE)
          census_threads(listed) if @thread_census
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            thread.suspend
          end
          # The breadcrumbs the first legible sighting of the aarch64 hang asked
          # for. It said `STALLED … in phase=suspend` and could go no further:
          # the collector was spinning here for a thread that never
          # acknowledged, and nothing recorded which. Two plain stores per
          # thread, on a path that runs once per collection.
          expected = 0
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            expected += 1
          end
          # Positive control for the report below: hold this phase open long
          # enough for the watchdog to fire, with the breadcrumbs already set.
          if (sstall = @stw_test_suspend_stall_ms) > 0
            StwWatchdog.note_suspend(expected, 0, 0xdead_0000_0000_0001_u64)
            deadline = Gcry::Clock.monotonic_ns &+ sstall &* 1_000_000_u64
            while Gcry::Clock.monotonic_ns < deadline
              Intrinsics.pause
            end
          end
          # Is anyone mid-`realloc` copy as the world stops? See
          # `note_realloc_overlap`.
          note_realloc_overlap
          StwWatchdog.note_suspend_step(StwWatchdog::STEP_SIGNALS_SENT)
          acked = 0
          @suspend_stall_reported = false
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            id = thread.to_unsafe.unsafe_as(UInt64)
            StwWatchdog.note_suspend(expected, acked, id)
            spins = 0_u64
            until thread.@suspended.get
              Intrinsics.pause
              spins &+= 1
              if spins == @suspend_stall_spins
                report_stuck_suspend(thread, id, expected, acked)
              end
            end
            acked += 1
          end
          StwWatchdog.note_suspend(expected, acked, 0_u64)
          # Positive control for the other half of the report: the loop is
          # done, the breadcrumb is cleared, and the phase is still suspend.
          if (pstall = @stw_test_postsuspend_stall_ms) > 0
            deadline = Gcry::Clock.monotonic_ns &+ pstall &* 1_000_000_u64
            while Gcry::Clock.monotonic_ns < deadline
              Intrinsics.pause
            end
          end
          @world_stopped = true
          # Past the wait loop and past every ack. Anything that hangs from here
          # to PHASE_FLUSH is not the suspension.
          StwWatchdog.enter(StwWatchdog::PHASE_STOPPED)
          if (tstall = @stw_test_stopped_stall_ms) > 0
            deadline = Gcry::Clock.monotonic_ns &+ tstall &* 1_000_000_u64
            while Gcry::Clock.monotonic_ns < deadline
              Intrinsics.pause
            end
          end
        rescue ex
          @world_stopped = false
          @stw_owner = nil
          @stw_owner_pthread = 0_u64
          Thread.unlock
          raise ex
        end
      {% end %}
    end

    # Roughly a second of `pause` on either arch. The watchdog reports the stall
    # from outside at 10 s; this one runs *inside* the spin, which is the only
    # place that can ask the question the watchdog cannot: is the thread we are
    # waiting for still there?
    # Roughly a second of `pause` on either arch, and a **property** rather than
    # a constant with an `ENV` lookup in it. That first version cost a 120%
    # heap-growth regression on `make rss-leak`: a Crystal constant with a
    # runtime initializer is evaluated lazily at first use, and the first use of
    # this one is inside `stop_world` — so `ENV[]?` allocated a `String` with
    # the world stopped, which is the one thing this collector must never do.
    # `GCRY_SUSPEND_STALL_SPINS` is read at init like every other knob.
    property suspend_stall_spins : UInt64 = 200_000_000_u64

    @suspend_stall_reported = false

    # Called once per stop, from inside the suspend wait, and only when the
    # watchdog is armed — this asks libc about a `pthread_t` the collector has
    # been unable to get an answer from, and if that handle came out of a freed
    # `Thread` (the open use-after-free on this same runner) the question can
    # fault. A fault here names the defect; a hang names nothing, and a hang is
    # what six aarch64 jobs have produced.
    private def report_stuck_suspend(thread : Thread, id : UInt64, expected : Int32, acked : Int32) : Nil
      return unless StwWatchdog.armed?
      return if @suspend_stall_reported
      @suspend_stall_reported = true

      buf = uninitialized UInt8[RawOut::LIMIT]
      p = buf.to_unsafe
      len = RawOut.append(p, 0, "gcry: SUSPEND STALLED on thread 0x")
      len = RawOut.append_hex(p, len, id)
      len = RawOut.append(p, len, " — ")
      len = RawOut.append_u64(p, len, acked.to_u64)
      len = RawOut.append(p, len, " of ")
      len = RawOut.append_u64(p, len, expected.to_u64)
      len = RawOut.append(p, len, " acknowledged. ")
      # ESRCH means the handle names no live thread, which is what a `Thread`
      # object that was swept and reissued would look like from here.
      rc = LibStwProbe.pthread_kill(id.unsafe_as(LibC::PthreadT), 0)
      len = RawOut.append(p, len, rc == 0 ? "the handle is live (pthread_kill 0 → 0)" : "pthread_kill(0) → ")
      len = RawOut.append_u64(p, len, rc.to_u64) unless rc == 0
      len = RawOut.append(p, len, rc == 3 ? " ESRCH: the handle names no live thread" : "")
      len = RawOut.append(p, len, "\n")
      RawOut.flush(p, len)
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
      # Shut the Monitor out **before** taking `@roots_lock`, and that is not a
      # detail either.
      #
      # `MonitorGate.close` spins until the Monitor's current call finishes.
      # One of those calls is `transfer_schedulers_blocked_on_syscall`, which
      # reaches `ExecutionContext.thread_pool.checkout` and, with no parked
      # thread to hand out, `Thread.new` — `pthread_create`, which gcry wraps
      # to root the new `Thread` object (`ThreadBirthRoot.arm` ->
      # `heap.add_root` -> `@roots_lock`).
      #
      # Holding `@roots_lock` across that handshake closes a cycle the
      # collector cannot break: it waits for the Monitor to finish, the Monitor
      # waits for the lock the collector holds, and the Monitor is the one
      # thread the suspend signals deliberately never touch.
      #
      # That is the aarch64 hang — `ec-queue-audit`, ten seconds in
      # phase=suspend at step "entered, monitor gate not yet closed"
      # (run 32725238411). Closing first costs a slightly longer exclusion
      # window and nothing else: once `stopped` is set the Monitor declines to
      # start new work, and the call it is already in can finish.
      #
      # `GCRY_MONITOR_GATE_LATE_CLOSE=1` restores the old ordering for the gate.
      MonitorGate.close unless @monitor_gate_late_close
      @roots_lock.lock
      @finalizers.lock_for_stw
      begin
        stop_world
        # The locks below are released with the world already stopped. If that
        # is where a stop wedges, the report should say so rather than blaming
        # the suspension it has already finished.
        StwWatchdog.enter(StwWatchdog::PHASE_QUIESCE)
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
        @stw_owner_pthread = 0_u64
        MonitorGate.open
        StwWatchdog.leave
      {% else %}
        begin
          # **Before** the first `resume`, not after them.
          #
          # `chunk_containing` skips `@index_lock` while this flag is set, on
          # the grounds that only the collector can be reading the chunk index
          # then. Clearing it after the resume loop breaks that: every thread is
          # running again while the flag still says stopped, so each of them
          # takes the unlocked path — against an `index_insert` / `index_remove`
          # from any peer that maps or unmaps a chunk, and a binary search over
          # a shifting array yields a garbage `ChunkHeader*`.
          #
          # Measured with `GCRY_INDEX_AUDIT=1` on `stw_mt_property_test`: 5–6
          # unlocked index reads per run by a thread that is not the collector,
          # and the readers are named worker threads — `stw-mt-4-1` and
          # friends — not the signal-exempt Monitor and not an unpublished one.
          # Zero on the arm without TLAB, because `tlab_alloc_small` is what
          # puts `find_block` on the allocation fast path.
          #
          # `GCRY_STW_LATE_CLEAR=1` restores the old order, which is how the
          # gate shows the reads coming back.
          @world_stopped = false unless @stw_late_clear
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
          @stw_owner_pthread = 0_u64
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
      @stw_owner_pthread = 0_u64
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
      @chunk_list_lock = Crystal::SpinLock.new
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
