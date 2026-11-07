require "spec"

# Diagnostic only: the mover, placed right after `process_gc_spec`, whose
# "keeps every thread bounded when the list outgrows the table" filled the
# cursor-set table with 80 threads; the pool thread the monitor hands the
# main fiber to now may be born before their sets are freed.
describe "diag late mover" do
  it "moves the main fiber off the initial thread" do
    ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 60_000_000)
    Fiber.syscall { LibC.nanosleep(pointerof(ts), nil) }
  end
end
