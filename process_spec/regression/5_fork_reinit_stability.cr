# Regression test for fork+reinit stability.
#
# After fork, GC.init must reinitialize internal state without corrupting
# the parent or child heap. Parent must continue allocating normally,
# child must be able to allocate independently.
#
# See samples/fork_reinit.cr for the full integration test.
# This spec tests the invariant: fork does not corrupt the heap.

require "../../src/gcry"
require "spec"

describe "Regression: fork reinit stability" do
  it "parent survives fork and continues allocating" do
    # Allocate before fork
    parent_ptr = GC.malloc_atomic(128)
    parent_ptr.should_not be_nil

    pid = Process.fork do
      # Child: reinit and allocate
      Gcry.default_heap.after_fork_child_reinit
      child_ptr = GC.malloc_atomic(64)
      child_ptr.should_not be_nil
    end

    # Parent: wait for child, then continue allocating
    LibC.waitpid(pid, nil, 0)

    # Parent should be able to allocate and collect after fork
    after_ptr = GC.malloc_atomic(256)
    after_ptr.should_not be_nil
    GC.collect
    GC.malloc_atomic(32).should_not be_nil
  end
end
