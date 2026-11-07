require "spec"
describe "mover" do
  it "moves the main fiber off the initial thread" do
    if ENV["MOVE"]? == "1"
      ts = LibC::Timespec.new(tv_sec: 0, tv_nsec: 60_000_000)
      Fiber.syscall { LibC.nanosleep(pointerof(ts), nil) }
      Fiber.yield
    end
    if ENV["MOVE"]? == "par"
      # Pending fibers for long enough that the monitor grows the default
      # context's parallelism; they spin and yield so every scheduler stays busy.
      done = Channel(Nil).new
      8.times do
        spawn do
          t = Time.instant
          while Time.instant - t < 400.milliseconds
            x = 0
            100_000.times { |i| x &+= i }
            Fiber.yield
          end
          done.send(nil)
        end
      end
      8.times { done.receive }
      STDERR.puts "MOVER ctx size #{Fiber::ExecutionContext.default.size rescue -1}"
    end
  end
end
