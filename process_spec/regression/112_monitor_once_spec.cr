require "../../src/gcry"
require "spec"

# The execution-context Monitor starts in the prelude (`kernel.cr`), before
# `__crystal_main` reaches gcry's class variables, and from 0.40 runs gcry
# code at the top of its loop, around its sleeps and around its gated work. A
# class variable or constant with a call initializer is Crystal's `once`; a
# Monitor that read one while the main thread was running its initializer
# waited in `once`, and on Crystal 1.21 its fiber has no execution context, so
# the main thread's `resume_all` raised `Fiber#execution_context cannot be nil`
# at startup: regression 107's unplanted child on macos-latest, PR #57
# (`bench/log/macos/2026-11-11-monitor-once-race/`). The Monitor's state is
# now literal-initialized (`MonitorGate`, `StaticAtomic`).
#
# The race is a window of nanoseconds, so the regression holds it open:
# `MonitorOnceTest` holds the main thread inside a class variable's
# initializer, before gcry's own are initialized, until the Monitor has
# finished three gated calls. The fixed arm finishes them; the control arm
# reads the held variable from the Monitor, the old `Atomic(Int32).new` shape,
# and either dies as above (1.21) or stalls for the whole hold (1.22).
#
# The second half is static: no class variable or constant of a module whose
# code the Monitor, the idle thread or the watchdog runs may have a lazy
# initializer, which shows in the binary as an `:init`/`:const_init` flag.

private MONITOR112_SKIP_MARK = "monitor112: skipped"
# Crystal 1.21's two ways of dying in it: the main thread's `resume_all`
# enqueuing the Monitor's fiber, or the Monitor's own `Fiber.suspend`, whose
# `every` rescues it and leaves its waiter on the list for `resume_all`.
private MONITOR112_CRASHES = ["Fiber#execution_context cannot be nil", "in 'wait_initializer'"]

private MONITOR112_ARMS = {
  "fixed"   => "1",
  "control" => "2",
}

# Modules whose class variables and constants a bare thread reads.
private MONITOR112_GUARDED = %w[MonitorGate IdleRelease StwWatchdog StaticAtomic Clock]

private def monitor112_child(arm : String) : Nil
  {% if @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
    Gcry::MonitorOnceTest.arm.should eq(MONITOR112_ARMS[arm].to_i)
    STDERR.puts "monitor112: #{arm}: #{Gcry::MonitorOnceTest.held_passes} gated call(s) finished while main was held"
  {% else %}
    STDERR.puts MONITOR112_SKIP_MARK
  {% end %}
end

private def monitor112_run(arm : String) : Nil
  captured = IO::Memory.new
  status = Process.run(Process.executable_path.not_nil!, ["-e", "monitor112 child #{arm}"],
    env: {"GCRY_MONITOR_ONCE_TEST" => MONITOR112_ARMS[arm]}, output: captured, error: captured)
  text = captured.to_s
  text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("monitor112:") || MONITOR112_CRASHES.any? { |c| l.includes?(c) } }
  return if status.success? && text.includes?(MONITOR112_SKIP_MARK)
  held = text.match(/monitor112: \w+: (\d+) gated call/).try(&.[1].to_i)
  if arm == "fixed"
    fail "fixed child #{status.inspect}:\n#{text}" unless status.success?
    text.should contain("1 examples, 0 failures")
    fail "fixed child: the Monitor stalled while main was held:\n#{text}" unless held && held >= Gcry::MonitorOnceTest::HOLD_PASSES
  else
    crashed = !status.success? && MONITOR112_CRASHES.any? { |c| text.includes?(c) }
    stalled = status.success? && held && held < Gcry::MonitorOnceTest::HOLD_PASSES
    fail "control child neither crashed in once nor stalled (#{status.inspect}):\n#{text}" unless crashed || stalled
  end
end

describe "Regression: the Monitor never waits in a class variable's once" do
  it "fixed arm in a process of its own" do
    monitor112_run("fixed")
  end

  it "control arm in a process of its own" do
    monitor112_run("control")
  end

  it "no lazily initialized state in a module a bare thread runs" do
    {% if flag?(:win32) %}
      STDERR.puts MONITOR112_SKIP_MARK
    {% else %}
      nm = Process.find_executable("nm")
      fail "nm not found: the static half of regression 112 needs it" unless nm
      captured = IO::Memory.new
      status = Process.run(nm, [Process.executable_path.not_nil!], output: captured, error: Process::Redirect::Inherit)
      fail "nm #{status.inspect}" unless status.success?
      pattern = /Gcry::(?:#{MONITOR112_GUARDED.join('|')})::\w+:(?:const_)?init\b/
      lazy = captured.to_s.scan(pattern).map(&.[0]).uniq!
      # Sanity: the scan sees flags at all — the control arm's own one.
      captured.to_s.should contain("Gcry::MonitorOnceTest::held:init")
      lazy.should be_empty
    {% end %}
  end

  MONITOR112_ARMS.each do |arm, digit|
    it "monitor112 child #{arm}" do
      next unless ENV["GCRY_MONITOR_ONCE_TEST"]? == digit
      monitor112_child(arm)
    end
  end
end
