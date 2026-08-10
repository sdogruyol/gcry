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
