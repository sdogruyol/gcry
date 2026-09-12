# Stop-the-world: GC lock, thread suspend/resume, fork child reinit.
#
# RWLock notes for Darwin and Windows:
#   `Crystal::RWLock` is a pure userspace spinlock with no `try_write_lock`.
#   If thread A holds `lock_read` and then calls `lock_write` (via allocation →
#   `maybe_collect`), it spins forever because it can't release its own read lock.
#   On Linux, signal-based thread_suspend interrupts the reader; on Darwin, Mach
#   `thread_suspend` freezes the thread in place — the lock stays held.
#
#   Fortunately, Mach STW already provides mutual exclusion: the collector stops
#   **all** other threads before touching the heap, so there is no concurrent
#   mutation during GC.  Windows SuspendThread has the same lock hazard and mutual exclusion.
#   The RWLock is a no-op on both platforms.

# `pthread_kill(id, 0)` asks whether a handle still names a live thread without
# sending anything. Crystal does not bind it.
{% unless flag?(:win32) %}
  lib LibStwProbe
    fun pthread_kill(thread : Gcry::OS::PthreadT, sig : LibC::Int) : LibC::Int
  end
{% end %}

module Gcry
  class Heap
    def lock_read : Nil
      {% unless (flag?(:darwin) || flag?(:win32)) %}
        return unless @stop_the_world
        wait_if_world_stopped_other_thread
        @gc_lock.read_lock
      {% end %}
    end

    def unlock_read : Nil
      {% unless (flag?(:darwin) || flag?(:win32)) %}
        return unless @stop_the_world
        @gc_lock.read_unlock
      {% end %}
    end

    def lock_write : Nil
      {% unless (flag?(:darwin) || flag?(:win32)) %}
        return unless @stop_the_world
        @gc_lock.write_lock
      {% end %}
    end

    def unlock_write : Nil
      {% unless (flag?(:darwin) || flag?(:win32)) %}
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
    def stop_world(*, raise_on_error : Bool = true) : Nil
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
      @stw_owner_pthread = Gcry::Platform.current_thread_id
      {% if (flag?(:darwin) || flag?(:win32)) %}
        begin
          {% if flag?(:win32) %}
            unless Platform.try_stop_world_threads(current_thread)
              @stw_owner = nil
              @stw_owner_pthread = 0_u64
              MonitorGate.open
              StwWatchdog.leave
              Platform.raise_thread_suspension_error if raise_on_error
              return
            end
          {% else %}
            Platform.stop_world_threads(current_thread)
          {% end %}
        rescue ex
          @stw_owner = nil
          @stw_owner_pthread = 0_u64
          MonitorGate.open
          StwWatchdog.leave
          raise ex
        end
        @world_stopped = true
        {% if flag?(:win32) %}
          Thread.unsafe_each do |thread|
            id = thread.to_unsafe.address
            Platform.unstage_thread(id)
            if rooted = ThreadBirthRoot.release(id)
              @roots.delete(rooted)
            end
          end
        {% end %}
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

        # One walk of the list before locking it. The `0x18` fault below is
        # `Thread.lock` reading a null out of the list object, so the last
        # moment it can be reported as damage rather than as a signal is here.
        # See src/gcry/thread_list_tripwire.cr.
        check_thread_list_before_lock

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
            Platform.snapshot_pthread_stack_bounds(thread.to_unsafe)
          end
          # The birth root is **not** released here any more.
          #
          # It was, on the reasoning that a thread on Crystal's list is rooted
          # by the list. It is — until `Thread#start`'s `ensure` takes it off
          # the list, which happens while the thread is still running and
          # still dereferencing itself, on a stack gcry does not scan because
          # a thread off the list is one it cannot see. The object was swept
          # in that gap: `bench/log/linux/2026-09-12-thread-life-root/`.
          #
          # So the root spans the whole life now, and only death ends it —
          # observed through the `pthread_detach` / `pthread_join` hooks, with
          # one collection of grace so a thread still finishing keeps it, or
          # at once when glibc hands the handle to a new thread
          # (src/gcry/thread_birth_root.cr). `@roots` directly: `@roots_lock`
          # is already held by `stop_world_quiescing_roots` and it is not
          # reentrant.
          ThreadBirthRoot.release_dead(@collections) { |rooted| @roots.delete(rooted) }
          # Does the set about to be stopped account for every thread the
          # process has? gcry learns about threads from Crystal's list, so a
          # thread that exists but has not pushed itself yet is neither
          # suspended nor scanned (src/gcry/platform/linux_thread_census.cr).
          # Off by default: it reads /proc inside the pause.
          StwWatchdog.note_suspend_step(StwWatchdog::STEP_BOUNDS_DONE)
          census_threads(listed) if @thread_census
          # The stop id every suspend signal below is tagged with, set before
          # the first `pthread_kill`: a delivery that arrives while the epoch
          # is 0 is declined by its own handler, so sending first and stamping
          # after would drop the signal it was meant to authorise
          # (src/gcry/platform/linux_stw.cr).
          Platform.begin_stop_epoch
          # Research, two different failures with the same symptom.
          #
          #   drop — swallow the first N suspend signals of every stop: a
          #     delivery that was lost. The resend is exactly the repair for
          #     it, so this is the arm that must go green.
          #   mute — swallow every signal to the first N threads, resends
          #     included: a thread that cannot take the signal at all, which
          #     is the other candidate for the aarch64 hang. No number of
          #     resends fixes that one, and saying so is the point.
          #
          # Per stop rather than a one-shot budget, so the arm does not depend
          # on which collection happens to run first.
          drop_budget = @stw_test_drop_suspends
          mute_budget = @stw_test_mute_threads
          ack_via_thread = Platform.stw_ack_via_thread?
          @stw_muted_count = 0
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            # Reserve this thread's acknowledgement slot **before** its signal
            # goes out. Two reasons, both load-bearing: the handler must not
            # have to claim one (claiming is a CAS loop, and the handler is
            # the one place that cannot afford to contend), and the wait below
            # spins on a slot index rather than scanning the table.
            # `reserve_suspend_slot` also clears the slot's stale SP and
            # acknowledgement, which is what `Thread#suspend` used to do for
            # the flag it no longer writes.
            Platform.reserve_suspend_slot(thread.to_unsafe)
            if mute_budget > 0 || drop_budget > 0
              if mute_budget > 0
                mute_budget -= 1
                note_muted_suspend(thread.to_unsafe.unsafe_as(UInt64))
              else
                drop_budget -= 1
                @stw_suspend_dropped_for_test &+= 1
              end
              # Both arms are the absence of `thread.suspend`, which is what
              # normally clears the flag side of the acknowledgement. The slot
              # side was cleared by the reservation above.
              thread.@suspended.set(false)
              next
            end
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
          @stw_abandoned_count = 0
          # Zero disables the resend, which is the control arm: the wait then
          # spins forever on a dropped signal exactly as it did before the
          # epoch existed. Hoisted out of the spin — the loop below runs
          # hundreds of millions of iterations and must stay three
          # instructions wide.
          resend_spins = @suspend_resend ? @suspend_resend_spins : 0_u64
          resend_limit = @suspend_resend_limit
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            id = thread.to_unsafe.unsafe_as(UInt64)
            # Resolved once, never from inside the spin: the slot lookup walks
            # the table and the loop below runs hundreds of millions of
            # iterations. -1 means the table was full when the slot was
            # reserved, and the handler falls back to `Thread#@suspended`.
            slot = suspend_ack_slot(thread, ack_via_thread)
            StwWatchdog.note_suspend(expected, acked, id)
            spins = 0_u64
            since_resend = 0_u64
            resends = 0_u32
            abandoned = false
            until suspend_acknowledged?(thread, slot)
              Intrinsics.pause
              spins &+= 1
              if spins == @suspend_stall_spins
                report_stuck_suspend(thread, id, expected, acked, resends)
              end
              next if resend_spins == 0
              since_resend &+= 1
              next if since_resend < resend_spins
              since_resend = 0_u64
              if resends < resend_limit
                # Safe only because of the epoch: a duplicate that lands after
                # this thread has already served the stop is declined instead
                # of suspending it again with nobody left to resume it. That
                # hazard is why the symmetry with `start_world`'s resume retry
                # was refused twice before.
                resends &+= 1
                @stw_suspend_resends &+= 1
                resend_suspend_signal(id)
              elsif suspend_handle_dead?(id)
                # The handle names no live thread, so there is nothing left to
                # suspend and nothing left that can mutate the heap through it.
                # Waiting on it is the 20-minute job timeout that has been
                # reading as `cancelled` since 2026-08-20.
                report_abandoned_suspend(id, expected, acked, resends)
                note_abandoned_suspend(id)
                abandoned = true
                break
              end
            end
            acked += 1 unless abandoned
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
          # The epoch is cleared on every path that leaves without a stopped
          # world. A stop that raises here has signals outstanding, and a
          # thread that serves one after this point must keep running.
          Platform.end_stop_epoch
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

    # Re-sending a suspend signal is safe **only** with the stop epoch: see
    # `Platform.admit_suspend_signal?`. Default on; `GCRY_STW_RESEND=0` is the
    # control arm that restores the wait that hung six aarch64 jobs.
    property suspend_resend : Bool = true

    # Spins between resends — roughly a tenth of the stall report's threshold,
    # so a stop that is merely slow resends a few times in silence and one
    # that is stuck still reaches the loud report. A property for the same
    # reason `suspend_stall_spins` is one: a constant with a runtime
    # initializer would evaluate `ENV[]?` with the world stopped.
    property suspend_resend_spins : UInt64 = 20_000_000_u64

    # After this many unanswered resends the collector stops asking and starts
    # asking *about* the thread instead. Bounded because a live thread that
    # ignored sixteen signals will not answer the seventeenth, and an unbounded
    # retry is a signal storm aimed at a thread that may be mid-teardown.
    property suspend_resend_limit : UInt32 = 16_u32

    # The spin predicate for both the suspend wait and the resume wait.
    #
    # A slot is the shipped path: one plain array load, and the handler that
    # writes it touches no Crystal object, so a thread signalled before it has
    # set its own TLS can still answer. `Thread#@suspended` is the fallback
    # for a table that was full when the slot was reserved.
    @[AlwaysInline]
    private def suspend_acknowledged?(thread : Thread, slot : Int32) : Bool
      slot >= 0 ? Platform.suspend_acked?(slot) : thread.@suspended.get
    end

    # Which side of the acknowledgement this stop is using for *thread*: the
    # reserved slot, or -1 for `Thread#@suspended`.
    #
    # The reader and the writer **must** agree, and getting that wrong is not
    # theoretical: the first version let the collector read the slot while
    # `GCRY_STW_ACK_VIA_THREAD=1` had the handler writing the `Thread` flag,
    # and the control arm hung 3 of 3 on a harness artefact that read exactly
    # like the defect it was built to look for.
    private def suspend_ack_slot(thread : Thread, via_thread : Bool) : Int32
      return -1 if via_thread
      Platform.suspend_slot_of(thread.to_unsafe)
    end

    # Suspend deliveries that arrived on a thread with no `Thread.current`,
    # and those that could not answer at all. The first is the birth window
    # `Thread#start` opens by publishing before it sets its TLS — non-zero
    # means the pre-table handler would have allocated a `Thread` and taken
    # `Thread.lock` from inside a signal handler with the world stopping.
    def stw_suspend_no_tls : UInt64
      {% if flag?(:linux) %}
        Platform.stw_no_tls_entries
      {% else %}
        0_u64
      {% end %}
    end

    def stw_suspend_ack_unavailable : UInt64
      {% if flag?(:linux) %}
        Platform.stw_ack_unavailable
      {% else %}
        0_u64
      {% end %}
    end

    # Research: drop this many suspend signals before sending any, to stand in
    # for the delivery the aarch64 hang has never let anyone observe.
    property stw_test_drop_suspends : UInt32 = 0_u32

    # Research: swallow every suspend signal to this many threads, resends
    # included — a thread that never answers rather than a delivery that went
    # missing. The resend cannot repair this one; only the abandonment can,
    # and only when the handle is dead.
    property stw_test_mute_threads : UInt32 = 0_u32

    # Research: answer every `pthread_kill(id, 0)` with ESRCH, so the
    # abandonment path can be walked without arranging a dead handle on
    # Crystal's list — which is the open use-after-free itself. Unsound on
    # purpose: with it the stop proceeds around a thread that is very much
    # alive.
    property stw_test_esrch : Bool = false

    # Research: after the world has restarted, send one more `SIG_SUSPEND` to
    # every thread it just resumed. That is exactly the delivery the epoch
    # exists to decline — the redundant signal that stays pending inside the
    # handler and lands after the resume — and arranging it here is what turns
    # "resending would be unsafe" from an argument into an arm.
    property stw_test_double_suspend : Bool = false

    getter stw_suspend_resends : UInt64 = 0_u64
    getter stw_suspend_abandoned : UInt64 = 0_u64
    getter stw_suspend_dropped_for_test : UInt64 = 0_u64

    # Deliveries the epoch declined. Kept on the heap rather than read from
    # `Platform` at the call site so `/gc-stats` stays one shape on every
    # platform: a Mach or Windows stop suspends by API and has no signal that
    # could arrive twice, which is a real zero rather than a missing field.
    def stw_suspend_stale_signals : UInt64
      {% if flag?(:linux) %}
        Platform.stw_stale_signals
      {% else %}
        0_u64
      {% end %}
    end

    def stw_suspend_redundant_signals : UInt64
      {% if flag?(:linux) %}
        Platform.stw_redundant_signals
      {% else %}
        0_u64
      {% end %}
    end

    # `ESRCH`. Spelled out rather than reached through `Errno`, which is an
    # enum lookup on a path that runs with the world stopped.
    SUSPEND_ESRCH = 3

    # Threads abandoned during this stop, so `start_world` does not resume a
    # handle libc has already told us names nothing: Crystal's `Thread#resume`
    # panics the process when `pthread_kill` fails, which would turn a handled
    # defect into an abort.
    STW_ABANDON_SLOTS = 8
    @stw_abandoned = uninitialized StaticArray(UInt64, STW_ABANDON_SLOTS)
    @stw_abandoned_count = 0

    private def note_abandoned_suspend(id : UInt64) : Nil
      @stw_suspend_abandoned &+= 1
      return if @stw_abandoned_count >= STW_ABANDON_SLOTS
      @stw_abandoned[@stw_abandoned_count] = id
      @stw_abandoned_count += 1
    end

    private def suspend_abandoned?(id : UInt64) : Bool
      i = 0
      while i < @stw_abandoned_count
        return true if @stw_abandoned[i] == id
        i += 1
      end
      false
    end

    # Research only, and the same shape: threads whose signals this stop is
    # deliberately swallowing.
    @stw_muted = uninitialized StaticArray(UInt64, STW_ABANDON_SLOTS)
    @stw_muted_count = 0

    private def note_muted_suspend(id : UInt64) : Nil
      @stw_suspend_dropped_for_test &+= 1
      return if @stw_muted_count >= STW_ABANDON_SLOTS
      @stw_muted[@stw_muted_count] = id
      @stw_muted_count += 1
    end

    private def suspend_muted?(id : UInt64) : Bool
      i = 0
      while i < @stw_muted_count
        return true if @stw_muted[i] == id
        i += 1
      end
      false
    end

    private def resend_suspend_signal(id : UInt64) : Nil
      return if @stw_muted_count > 0 && suspend_muted?(id)
      LibStwProbe.pthread_kill(id.unsafe_as(Gcry::OS::PthreadT), Platform::STW_SIG_SUSPEND)
    end

    # Does this handle still name a live thread? `pthread_kill(id, 0)` sends
    # nothing and answers exactly that.
    private def suspend_handle_dead?(id : UInt64) : Bool
      return true if @stw_test_esrch
      LibStwProbe.pthread_kill(id.unsafe_as(Gcry::OS::PthreadT), 0) == SUSPEND_ESRCH
    end

    # Unconditional, unlike `report_stuck_suspend`: this one is not asking a
    # question that can fault — it has already been answered — and a stop that
    # proceeds without one of its threads must say so whether or not a
    # watchdog happens to be armed.
    private def report_abandoned_suspend(id : UInt64, expected : Int32, acked : Int32, resends : UInt32) : Nil
      buf = uninitialized UInt8[RawOut::LIMIT]
      p = buf.to_unsafe
      len = RawOut.append(p, 0, "gcry: SUSPEND ABANDONED thread 0x")
      len = RawOut.append_hex(p, len, id)
      len = RawOut.append(p, len, " — no acknowledgement after ")
      len = RawOut.append_u64(p, len, resends.to_u64)
      len = RawOut.append(p, len, " resends and pthread_kill(0) says ESRCH, so the handle names no live thread. ")
      len = RawOut.append_u64(p, len, acked.to_u64)
      len = RawOut.append(p, len, " of ")
      len = RawOut.append_u64(p, len, expected.to_u64)
      len = RawOut.append(p, len, " acknowledged; stopping without it. A `Thread` still on Crystal's list whose handle is dead is the shape of the open use-after-free\n")
      RawOut.flush(p, len)
    end

    # Called once per stop, from inside the suspend wait, and only when the
    # watchdog is armed — this asks libc about a `pthread_t` the collector has
    # been unable to get an answer from, and if that handle came out of a freed
    # `Thread` (the open use-after-free on this same runner) the question can
    # fault. A fault here names the defect; a hang names nothing, and a hang is
    # what six aarch64 jobs have produced.
    private def report_stuck_suspend(thread : Thread, id : UInt64, expected : Int32, acked : Int32, resends : UInt32) : Nil
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
      len = RawOut.append(p, len, " acknowledged, ")
      len = RawOut.append_u64(p, len, resends.to_u64)
      # Three numbers that separate the readings of a missing acknowledgement:
      # a signal that was never delivered (handler calls flat across the
      # resends), one delivered and declined (stale/redundant climbing), and a
      # thread that cannot run its handler at all (calls flat, handle live).
      # Without them the report says only that nobody answered.
      len = RawOut.append(p, len, " resends unanswered; handler entries so far ")
      len = RawOut.append_u64(p, len, Platform.stw_handler_calls)
      len = RawOut.append(p, len, ", declined stale ")
      len = RawOut.append_u64(p, len, Platform.stw_stale_signals)
      len = RawOut.append(p, len, " / redundant ")
      len = RawOut.append_u64(p, len, Platform.stw_redundant_signals)
      len = RawOut.append(p, len, ". ")
      # ESRCH means the handle names no live thread, which is what a `Thread`
      # object that was swept and reissued would look like from here.
      rc = LibStwProbe.pthread_kill(id.unsafe_as(Gcry::OS::PthreadT), 0)
      len = RawOut.append(p, len, rc == 0 ? "the handle is live (pthread_kill 0 → 0)" : "pthread_kill(0) → ")
      len = RawOut.append_u64(p, len, rc.to_u64) unless rc == 0
      len = RawOut.append(p, len, rc == SUSPEND_ESRCH ? " ESRCH: the handle names no live thread" : "")
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
        {% if flag?(:win32) %}
          stop_world(raise_on_error: false)
        {% else %}
          stop_world
        {% end %}
        # The locks below are released with the world already stopped. If that
        # is where a stop wedges, the report should say so rather than blaming
        # the suspension it has already finished.
        {% if flag?(:win32) %}
          StwWatchdog.enter(StwWatchdog::PHASE_QUIESCE) if @world_stopped
        {% else %}
          StwWatchdog.enter(StwWatchdog::PHASE_QUIESCE)
        {% end %}
      ensure
        @finalizers.unlock_for_stw
        @roots_lock.unlock
      end
      {% if flag?(:win32) %}
        # Exception::CallStack grows an Array via realloc, which pins the old
        # buffer under @roots_lock. Raise only after BOTH locks are released.
        Platform.raise_thread_suspension_error if @stop_the_world && !@world_stopped
      {% end %}
    end

    def start_world : Nil
      return unless @world_stopped

      # Drop last-chunk cache before mutators resume — index_remove already
      # invalidates, but a mark-time cache entry must not outlive STW.
      invalidate_chunk_cache

      current_thread = Thread.current
      {% if (flag?(:darwin) || flag?(:win32)) %}
        {% if flag?(:win32) %} @world_stopped = false {% end %}
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
          # **Before** the first resume as well, and for a different reason:
          # a duplicate suspend signal still in flight must find no stop in
          # progress by the time its thread runs again, or it re-suspends a
          # thread this loop has already woken. Closing the epoch here is what
          # makes the resend above a repair rather than a new hang
          # (src/gcry/platform/linux_stw.cr).
          Platform.end_stop_epoch
          ack_via_thread = Platform.stw_ack_via_thread?
          Thread.unsafe_each do |thread|
            next if thread == current_thread
            next if stw_signal_exempt?(thread)
            # A thread the stop gave up on: libc said its handle names nothing,
            # and Crystal's `Thread#resume` panics the process when
            # `pthread_kill` fails.
            next if suspend_abandoned?(thread.to_unsafe.unsafe_as(UInt64))
            slot = suspend_ack_slot(thread, ack_via_thread)
            thread.resume
            spins = 0
            while suspend_acknowledged?(thread, slot)
              Intrinsics.pause
              spins += 1
              if spins == 10_000
                thread.resume
                spins = 0
              end
            end
          end
          # Research: the redundant delivery, arranged. With the epoch it is
          # declined and counted in `stw_suspend_stale_signals`; without it,
          # each of these suspends a running thread that nothing will ever
          # resume, and the next stop waits on it forever. That is the hazard
          # that made the resend above unshippable twice.
          if @stw_test_double_suspend
            Thread.unsafe_each do |thread|
              next if thread == current_thread
              next if stw_signal_exempt?(thread)
              id = thread.to_unsafe.unsafe_as(UInt64)
              next if suspend_abandoned?(id)
              resend_suspend_signal(id)
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
      # Only the forking thread survives: its in-flight publications, its
      # cursor lock and the other threads' sets - see the method.
      reset_cursor_sets_after_fork
      @soft_dirty_armed = false
      @soft_dirty_probed = false
      @soft_dirty_works = false
      @soft_dirty_skip_until_major = false
      disarm_mprotect_barrier if @barrier_backend.mprotect?
      @barrier_backend = Platform::BarrierBackend::None
      reset_mark_workers_after_fork
      Platform.reset_stw_after_fork
      Platform.reset_main_thread_after_fork
      Platform.invalidate_static_root_cache
      begin
        set_stackbottom(Fiber.current.@stack.bottom)
      rescue
      end
    end
  end
end
