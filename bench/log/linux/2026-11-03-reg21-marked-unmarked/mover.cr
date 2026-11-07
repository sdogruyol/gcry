require "spec"

# Diagnostic only: the execution context's monitor hands a scheduler it finds
# inside a syscall to a pool thread, and the main fiber carries on there.
describe "diag mover" do
  it "moves the main fiber off the initial thread" do
    ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 60_000_000)
    Fiber.syscall { LibC.nanosleep(pointerof(ts), nil) }
  end
end
