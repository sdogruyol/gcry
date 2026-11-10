require "../../src/gcry"
require "spec"

# The execution-context Monitor's sleep kept half of whatever word the call
# before it left at that depth. Crystal's `Monitor#every` ends each pass in
# `Thread.sleep(remaining)`, and `Crystal::System::Thread.sleep` copies the
# `Time::Span` into its frame, storing 4 bytes of the word that holds its
# nanoseconds. On Crystal 1.21.0 the other 4 were the high half of
# `Comparable#clamp`'s `self` (`every`'s `remaining = (…).clamp(…)`, at the
# same depth just before), an address in the Monitor's stack, which shares
# its high half with the heap: a count under 10^7 beneath it named an
# address in the heap's 4 GiB, read at every stop. It held `make
# parallel-dormant`'s burst in 13 of 8 000 local runs, 3 of them to the end
# ("seeded by … parked 3812 KiB";
# `bench/log/linux/2026-11-10-parked-seed-2/`). Regression 107's scrub runs
# once, before the loop, and the half is rewritten every pass. The Monitor
# now zeroes the stack under `Thread.sleep` before Crystal's sleep builds its
# frames there.
#
# Which bytes a build leaves unwritten, and what the call before left in
# them, is the compiler's, so the regression plants it. With
# `GCRY_MONITOR_SLEEP_TEST` set (read in `GC.init`: the Monitor starts before
# any spec), the Monitor writes `MonitorGate::LOOP_MARKER`, whose high half
# no address has, over 8 KiB below `Thread.sleep`'s frame before each sleep,
# and the child counts the words below that frame that keep the marker's
# high half over another low half. The fixed arm must have none. The control
# arm (`MonitorGate.sleep_residue_kept?`, the code before) must have some, or
# the fixed arm could pass on a layout that writes every word whole; a build
# that keeps no half-written word there prints `MONITOR111_SKIP_MARK`.
#
# Each arm in a process of its own. Linux only, as regressions 104, 105 and
# 107: elsewhere, and in a build with no Monitor, the child prints the skip
# mark.

private MONITOR111_SKIP_MARK   = "monitor111: skipped"
private MONITOR111_HALVES      = "monitor111: planted high halves kept"
private MONITOR111_HALVES_NONE = "monitor111: no planted high half"

private MONITOR111_ARMS = {
  "fixed"   => "1",
  "control" => "2",
}

# The marker's high half over another low half, in the 8 KiB the plant
# covered and a margin, below the SP it was taken under.
private def monitor111_halves_left(sp : UInt64) : Int32
  marker = Gcry::MonitorGate::LOOP_MARKER
  n = 0
  a = sp - (Gcry::MonitorGate::PLANT_WORDS.to_u64 + 64_u64) * 8_u64
  while a < sp
    v = Pointer(UInt64).new(a).value
    n += 1 if v >> 32 == marker >> 32 && v != marker
    a += 8
  end
  n
end

private def monitor111_child(arm : String) : Nil
  {% if flag?(:linux) && @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
    Gcry::MonitorGate.sleep_test.should eq(MONITOR111_ARMS[arm].to_i)
    deadline = Time.instant + 10.seconds
    until Gcry::MonitorGate.sleep_test_ready?
      fail "the Monitor did not reach its sleep" if Time.instant > deadline
      sleep 1.millisecond
    end
    # Some passes, so the sleep has built its frames over the plant.
    sleep 50.milliseconds
    halves = monitor111_halves_left(Gcry::MonitorGate.sleep_test_sp)
    STDERR.puts "monitor111: #{arm}: #{halves} word(s) below the sleep's frame keep the planted high half"
    if arm == "control" && halves == 0
      STDERR.puts MONITOR111_SKIP_MARK
    else
      STDERR.puts(halves > 0 ? MONITOR111_HALVES : MONITOR111_HALVES_NONE)
    end
  {% else %}
    STDERR.puts MONITOR111_SKIP_MARK
  {% end %}
end

private def monitor111_run(arm : String, want : String) : Nil
  captured = IO::Memory.new
  status = Process.run(Process.executable_path.not_nil!, ["-e", "monitor111 child #{arm}"],
    env: {"GCRY_MONITOR_SLEEP_TEST" => MONITOR111_ARMS[arm]}, output: captured, error: captured)
  text = captured.to_s
  text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("monitor111:") }
  fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  unless text.includes?(MONITOR111_SKIP_MARK)
    fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
  end
end

describe "Regression: the Monitor's sleep keeps no half of the word before it" do
  it "fixed arm in a process of its own" do
    monitor111_run("fixed", MONITOR111_HALVES_NONE)
  end

  it "control arm in a process of its own" do
    monitor111_run("control", MONITOR111_HALVES)
  end

  MONITOR111_ARMS.each do |arm, digit|
    it "monitor111 child #{arm}" do
      next unless ENV["GCRY_MONITOR_SLEEP_TEST"]? == digit
      monitor111_child(arm)
    end
  end
end
