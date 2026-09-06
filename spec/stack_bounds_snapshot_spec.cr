require "./spec_helper"

# The bounds snapshot is a *correctness*-critical substitution, not an
# optimisation. `scan_other_thread_stacks` used to ask `pthread_getattr_np` for
# each thread's stack bounds while the world was stopped, which deadlocks against
# a thread frozen holding its own descriptor lock
# (bench/log/linux/2026-08-10-stw-startup-hang/FINDINGS.md). The fix takes those
# bounds before suspending and reads a table instead.
#
# Nothing else in the suite can see that table go wrong. If it answered `nil`, or
# answered the wrong range, the hang gate would stay green — there is no hang —
# and thread-stack root coverage would quietly shrink or point somewhere else.
# `pthread_bounds_misses` counts an *absent* entry; it cannot count a wrong one.
#
# So these pin the claim the substitution rests on: the table answers what the
# live call would have answered, for every thread, and refuses to answer for a
# thread it did not record.
{% if flag?(:linux) %}
  describe "Gcry::Platform stack bounds snapshot" do
    it "answers what pthread_getattr_np would, for the calling thread" do
      self_id = LibC.pthread_self
      live = Gcry::Platform.pthread_stack_bounds(self_id)
      live.should_not be_nil
      live = live.not_nil!

      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshot_pthread_stack_bounds(self_id)

      snapped = Gcry::Platform.snapshotted_stack_bounds(self_id)
      snapped.should_not be_nil
      snapped = snapped.not_nil!

      snapped[0].address.should eq(live[0].address)
      snapped[1].address.should eq(live[1].address)
    end

    it "answers the initial thread from its cached bounds after the first read" do
      # `GC.init` records the initial thread; in the library the spec does.
      # The process running this spec is that thread.
      self_id = LibC.pthread_self
      Gcry::Platform.note_main_thread
      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
      first = Gcry::Platform.snapshotted_stack_bounds(self_id).not_nil!
      cached = Gcry::Platform.stack_bounds_main_cached

      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
      second = Gcry::Platform.snapshotted_stack_bounds(self_id).not_nil!

      Gcry::Platform.stack_bounds_main_cached.should eq(cached + 1)
      second[0].address.should eq(first[0].address)
      second[1].address.should eq(first[1].address)
      live = Gcry::Platform.pthread_stack_bounds(self_id).not_nil!
      second[1].address.should eq(live[1].address)
    end

    it "re-derives the initial thread's cached low when the soft RLIMIT_STACK changes" do
      # glibc derives the main thread's low as `high - min(RLIMIT_STACK, gap)`,
      # so raising the soft limit lowers it. A cache that never looked again
      # would scan `[stale low, high)` from another thread and miss the frames
      # a deeper main stack had grown into.
      #
      # Only the initial thread's low follows the limit; a pool thread's is its
      # mmap. CI run 34051069821 had this example on a pool thread — the
      # execution context's monitor had moved the main fiber after an earlier
      # `open(2)` — and the low read `0x7fbb38e49000`, 275 GiB below the top of
      # user space, unchanged by the halving. That is not the cache failing to
      # refresh (it refreshed, and matched the live answer); it is a premise
      # this example cannot make hold, so it says so instead.
      pending!("the main fiber is not on the initial thread (the execution context's monitor moved it), " \
               "and only the initial thread's low follows RLIMIT_STACK") unless SpecInitialThread.current?
      self_id = LibC.pthread_self
      Gcry::Platform.note_main_thread
      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
      before = Gcry::Platform.snapshotted_stack_bounds(self_id).not_nil!
      refreshed = Gcry::Platform.stack_bounds_main_refreshed

      rl = uninitialized LibC::Rlimit
      LibC.getrlimit(LibC::RLIMIT_STACK, pointerof(rl)).should eq(0)
      saved = rl
      # Halve the soft limit rather than raise it: lowering never needs the
      # hard limit's permission, so the spec runs on any box. The gap below
      # the main stack is far larger than 4 MiB, so `min` picks the limit and
      # the low bound must move *up* by the same amount.
      pending!("RLIMIT_STACK is unlimited here; nothing to halve") if rl.rlim_cur == LibC::RlimT::MAX
      rl.rlim_cur = rl.rlim_cur // 2
      LibC.setrlimit(LibC::RLIMIT_STACK, pointerof(rl)).should eq(0)
      begin
        Gcry::Platform.begin_stack_bounds_snapshot
        Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
        after = Gcry::Platform.snapshotted_stack_bounds(self_id).not_nil!
        live = Gcry::Platform.pthread_stack_bounds(self_id).not_nil!

        Gcry::Platform.stack_bounds_main_refreshed.should eq(refreshed + 1)
        after[0].address.should eq(live[0].address)
        after[1].address.should eq(before[1].address)
        after[0].address.should be > before[0].address
      ensure
        LibC.setrlimit(LibC::RLIMIT_STACK, pointerof(saved))
        # Leave the cache matching the restored limit for the specs after this.
        Gcry::Platform.begin_stack_bounds_snapshot
        Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
      end
    end

    it "brackets an address that is actually on this thread's stack" do
      # Tying the table to a real address, not just to the other API: if both
      # ever agreed on a wrong range, the comparison above would still pass.
      probe = uninitialized UInt8[64]
      here = probe.to_unsafe.address

      self_id = LibC.pthread_self
      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
      bounds = Gcry::Platform.snapshotted_stack_bounds(self_id).not_nil!

      bounds[0].address.should be < bounds[1].address
      # Only meaningful while this spec runs on the thread's own stack rather
      # than a fiber stack, which is where Crystal starts it.
      if here >= bounds[0].address && here < bounds[1].address
        (here >= bounds[0].address).should be_true
        (here < bounds[1].address).should be_true
      end
    end

    it "covers every thread in the list, which is what the scan iterates" do
      Gcry::Platform.begin_stack_bounds_snapshot
      Thread.unsafe_each { |t| Gcry::Platform.snapshot_pthread_stack_bounds(t.to_unsafe) }

      Thread.unsafe_each do |t|
        id = t.to_unsafe
        live = Gcry::Platform.pthread_stack_bounds(id)
        next if live.nil? # a thread that has gone away between the two calls
        snapped = Gcry::Platform.snapshotted_stack_bounds(id)
        snapped.should_not be_nil
        snapped.not_nil![0].address.should eq(live[0].address)
        snapped.not_nil![1].address.should eq(live[1].address)
      end
    end

    it "refuses to answer for a thread it did not record, and counts it" do
      Gcry::Platform.begin_stack_bounds_snapshot
      before = Gcry::Platform.stack_bounds_snapshot_misses

      Gcry::Platform.snapshotted_stack_bounds(LibC.pthread_self).should be_nil

      Gcry::Platform.stack_bounds_snapshot_misses.should be > before
    end

    it "drops the previous collection's entries" do
      # A pthread_t is reusable once its thread exits, so an entry carried across
      # a collection could hand the scan another thread's address range. The
      # snapshot must start empty every time.
      self_id = LibC.pthread_self
      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshot_pthread_stack_bounds(self_id)
      Gcry::Platform.snapshotted_stack_bounds(self_id).should_not be_nil

      Gcry::Platform.begin_stack_bounds_snapshot
      Gcry::Platform.snapshotted_stack_bounds(self_id).should be_nil
    end
  end
{% end %}
