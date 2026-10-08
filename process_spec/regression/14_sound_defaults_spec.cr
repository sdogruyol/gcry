require "../../src/gcry"
require "spec"

# The process GC's defaults are the root-complete profile (docs/SOUND-DEFAULTS.md):
# no knob may decline a live pointer unless an env var asks for it. The last
# two that did by default were the multi-mutator STW stack lags (256 KiB until
# 2026-10-05), which left a parked fiber's frames deeper than the lag unseen.
describe "process GC defaults" do
  it "are root-complete and barrier-free" do
    heap = Gcry.default_heap
    heap.stw_multi_stack_lag.should eq(0)
    heap.stw_multi_pthread_lag.should eq(0)
    Gcry.soundness(heap).should eq("sound")
  end
end
