require "../../src/gcry"
require "spec"

# The execution-context Monitor's loop frame kept what the thread's birth left
# under it. `Monitor#run_loop` never returns, and every stop reads its frame;
# bytes of it the loop never writes keep whatever was at that depth before.
# Crystal's `every` keeps its `Time::Instant`s there, an `Int64` and an
# `Int32` in 16 bytes, and stores 4 bytes of the second word every pass, so
# that word was a nanosecond count under the high half of an address the
# birth left: a new address in the heap's 4 GiB every 10 ms, which kept
# whatever block it named until the next pass. In regression 1's full suite
# order on Crystal 1.22.2 it was the one root word that held a block at the
# baseline and something else after the check
# (`bench/log/linux/2026-11-04-reg1-drift/`). The Monitor now zeroes its
# stack below the loop's entry before the loop's frame is built
# (`MonitorGate.scrub_loop_stack`), as the idle thread does at its birth
# (regression 104).
#
# Which bytes a build leaves unwritten, and what the birth left in them, is
# the compiler's and the runtime's, so the regression plants it. With
# `GCRY_MONITOR_LOOP_TEST` set, read in `GC.init` because the Monitor starts
# before any spec, the Monitor makes a block at the top of its loop and
# writes over 8 KiB below the loop's entry before the scrub.
#
# The block arms plant the block's address, then three collections. The
# fixed arm must free the block; the control arm
# (`MonitorGate.loop_residue_kept?`, the code before) must keep it, or the
# fixed arm could pass on a layout the scan does not read; and an arm with no
# plant must free it, or the control arm could be kept by something other
# than the plant. Only a word the loop's frames never write keeps the whole
# address, and how many there are varies with the build and the pass the
# Monitor is in: the control child counts them and prints
# `MONITOR107_SKIP_MARK` when there are none.
#
# The halves arms plant `MonitorGate::LOOP_MARKER`, whose high half no
# address has, and count the words in the Monitor's frames that keep it over
# a low half the loop wrote: the `Time::Instant` words themselves. The fixed
# arm must have none and the control arm some (a build that keeps no such
# value in memory has none to show, and prints the skip mark).
#
# Each arm in a process of its own. Linux only, as regressions 104 and 105:
# elsewhere, and in a build with no Monitor, the child prints the skip mark.

private MONITOR107_SKIP_MARK   = "monitor107: skipped"
private MONITOR107_KEPT        = "monitor107: planted block kept"
private MONITOR107_FREED       = "monitor107: planted block freed"
private MONITOR107_HALVES      = "monitor107: planted high halves kept"
private MONITOR107_HALVES_NONE = "monitor107: no planted high half"

private MONITOR107_ARMS = {
  "fixed"          => "1",
  "control"        => "2",
  "unplanted"      => "3",
  "halves fixed"   => "4",
  "halves control" => "5",
}

# The Monitor's stack from the plant's frame up to the loop's entry, i.e. the
# frames the loop and its calls built over it.
private def monitor107_each_word(entry_sp : UInt64, & : UInt64 ->) : Nil
  a = entry_sp - (Gcry::MonitorGate::PLANT_WORDS.to_u64 + 64_u64) * 8_u64
  while a < entry_sp
    yield Pointer(UInt64).new(a).value
    a += 8
  end
end

# Planted addresses left whole. Compared masked, so this frame holds no copy
# of the address.
private def monitor107_words_left(entry_sp : UInt64, masked : UInt64) : Int32
  n = 0
  monitor107_each_word(entry_sp) do |v|
    n += 1 if v ^ Gcry::MonitorGate::PLANT_KEY == masked
  end
  n
end

# The marker's high half over another low half.
private def monitor107_halves_left(entry_sp : UInt64) : Int32
  marker = Gcry::MonitorGate::LOOP_MARKER
  n = 0
  monitor107_each_word(entry_sp) do |v|
    n += 1 if v >> 32 == marker >> 32 && v != marker
  end
  n
end

private def monitor107_wait_for_loop : Nil
  deadline = Time.instant + 10.seconds
  until Gcry::MonitorGate.loop_test_ready?
    fail "the Monitor did not reach its loop" if Time.instant > deadline
    sleep 1.millisecond
  end
  # Some passes, so the loop and its calls have built their frames and
  # `MonitorGate.leave` has zeroed the dead stack below them.
  sleep 50.milliseconds
end

private def monitor107_child(arm : String) : Nil
  {% if flag?(:linux) && @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
    Gcry::MonitorGate.loop_test.should eq(MONITOR107_ARMS[arm].to_i)
    monitor107_wait_for_loop
    if arm.starts_with?("halves")
      halves = monitor107_halves_left(Gcry::MonitorGate.loop_test_sp)
      STDERR.puts "monitor107: #{arm}: #{halves} word(s) in the loop's frames keep the planted high half"
      if arm == "halves control" && halves == 0
        STDERR.puts MONITOR107_SKIP_MARK
      else
        STDERR.puts(halves > 0 ? MONITOR107_HALVES : MONITOR107_HALVES_NONE)
      end
      return
    end
    heap = Gcry.default_heap
    3.times { GC.collect }
    masked = Gcry::MonitorGate.loop_test_block
    kept = !heap.find_live_object_with_chunk(Pointer(Void).new(masked ^ Gcry::MonitorGate::PLANT_KEY)).nil?
    left = monitor107_words_left(Gcry::MonitorGate.loop_test_sp, masked)
    STDERR.puts "monitor107: #{arm}: block #{kept ? "kept" : "freed"} after three collections, #{left} planted word(s) in the loop's frames"
    if arm == "control" && left == 0
      STDERR.puts MONITOR107_SKIP_MARK
    else
      STDERR.puts(kept ? MONITOR107_KEPT : MONITOR107_FREED)
    end
  {% else %}
    STDERR.puts MONITOR107_SKIP_MARK
  {% end %}
end

private def monitor107_run(arm : String, want : String) : Nil
  captured = IO::Memory.new
  status = Process.run(Process.executable_path.not_nil!, ["-e", "monitor107 child #{arm}"],
    env: {"GCRY_MONITOR_LOOP_TEST" => MONITOR107_ARMS[arm]}, output: captured, error: captured)
  text = captured.to_s
  text.each_line { |l| STDERR.puts "#{arm}: #{l}" if l.starts_with?("monitor107:") }
  fail "#{arm} child #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  unless text.includes?(MONITOR107_SKIP_MARK)
    fail "#{arm} child: expected '#{want}':\n#{text}" unless text.includes?(want)
  end
end

private def monitor107_want(arm : String) : String
  case arm
  when "control"        then MONITOR107_KEPT
  when "halves fixed"   then MONITOR107_HALVES_NONE
  when "halves control" then MONITOR107_HALVES
  else                       MONITOR107_FREED
  end
end

describe "Regression: the Monitor's loop frame keeps nothing from its birth" do
  MONITOR107_ARMS.each_key do |arm|
    it "#{arm} arm in a process of its own" do
      monitor107_run(arm, monitor107_want(arm))
    end
  end

  MONITOR107_ARMS.each do |arm, digit|
    it "monitor107 child #{arm}" do
      next unless ENV["GCRY_MONITOR_LOOP_TEST"]? == digit
      monitor107_child(arm)
    end
  end
end
