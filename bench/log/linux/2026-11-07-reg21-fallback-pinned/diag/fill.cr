require "spec"

# Forced reproduction only: park more threads than the cursor-set table holds
# (`Heap::MAX_CURSOR_SETS`), each after one allocation, so the next thread to
# allocate — the pool thread the monitor hands the main fiber to — is given
# the shared fallback set. The threads stay parked for the whole run.
module D21Fill
  class_getter threads = [] of Thread
end

describe "diag fill" do
  it "fills the cursor-set table with parked threads" do
    fds = uninitialized Int32[2]
    LibC.pipe(fds).should eq(0)
    ready = Atomic(Int32).new(0)
    70.times do
      D21Fill.threads << Thread.new do
        LibGC.malloc_atomic(16)
        ready.add(1)
        buf = uninitialized UInt8[1]
        LibC.read(fds[0], buf.to_unsafe, 1)
      end
    end
    until ready.get == 70
      Thread.yield
    end
  end
end
