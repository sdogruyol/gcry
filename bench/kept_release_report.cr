# Does a fault inside a chunk a flush refused to release say so?
#
# The refusal (2026-09-14) puts an occupied chunk back on the live list instead
# of unmapping it. If a fault later lands in that chunk - because it was
# released for real afterwards, or because keeping it was not enough - every
# other line of the report describes an ordinary release and nothing says the
# chunk went through that window. `kept_release_at` and the report line that
# reads it exist for that, and this is their positive control.
#
# Why a control at all: the real window does not open on this host. Measured
# 2026-09-14, the post-STW flush considered 0 chunks in 120 collections with
# more than one mutator alive, and the CI sighting that motivated the refusal
# has never reproduced locally. `GCRY_REFUSE_EMPTY_RELEASE=<n>` refuses the
# first n empty-chunk releases regardless of occupancy, which reaches the
# ledger without needing the race.
#
# The sequence the child runs:
#
#   1. `GCRY_REFUSE_EMPTY_RELEASE=1` - the first empty chunk is kept, and
#      recorded in the ledger.
#   2. The same chunk becomes empty again and is released for real, under
#      `GCRY_UNMAP_GUARD=1`, so the range stays mapped as PROT_NONE and a read
#      of it faults instead of silently succeeding.
#   3. The child reads a pointer it saved into that chunk. The report must
#      name both the release and the refusal that preceded it.
#
#   crystal build -Dgc_none bench/kept_release_report.cr -o bin/kept_release_report
#   bin/kept_release_report
{% unless flag?(:gc_none) %}
  {% raise "kept_release_report requires -Dgc_none (gcry as process GC)" %}
{% end %}

require "../src/gcry"

CHILD = ARGV.includes?("--child")

heap = Gcry.default_heap.not_nil!

if CHILD
  # Own whole chunks of one size class, then drop them all. Addresses are kept
  # as `UInt64` on purpose - an integer is not a root, so nothing here keeps a
  # chunk alive across the collection that frees it.
  candidates = [] of UInt64
  8.times do
    ptrs = Array(Pointer(Void)).new(40_000) { GC.malloc(64) }
    i = 0
    while i < ptrs.size
      candidates << ptrs[i].address
      i += 4_000
    end
    ptrs.clear
    GC.collect
    GC.collect
  end

  # Which of them is in a chunk the knob kept. The ledger holds sixteen, and
  # which chunks the sweep queued is not something this harness gets to
  # choose, so it asks rather than assumes.
  victim = candidates.find { |a| !heap.kept_release_at(a).nil? }
  unless victim
    STDERR.puts "child: no candidate is in a kept chunk (#{candidates.size} asked)"
    exit 2
  end
  STDERR.puts "child: victim 0x#{victim.to_s(16)} kept=true"

  # Now let it go for real: the budget is spent, so the next flush that finds
  # this chunk empty releases it. Under `GCRY_UNMAP_GUARD=1` the range stays
  # mapped as PROT_NONE, so the read below faults instead of quietly
  # returning recycled memory.
  4.times do
    ptrs = Array(Pointer(Void)).new(40_000) { GC.malloc(64) }
    ptrs.clear
    GC.collect
    GC.collect
  end

  STDERR.puts "child: read 0x#{Pointer(UInt64).new(victim).value.to_s(16)}"
  exit 0
end

exe = Process.executable_path.not_nil!
env = {
  "GCRY_REFUSE_EMPTY_RELEASE" => "64",
  "GCRY_UNMAP_GUARD"          => "1",
  "GCRY_SEGV_REPORT"          => "1",
}
sink = IO::Memory.new
status = Process.run(exe, ["--child"], env: env,
  output: Process::Redirect::Close, error: sink)
text = sink.to_s
puts text

failures = [] of String
unless text.includes?("kept=true")
  failures << "the ledger did not record the refused release - `kept_release_at` " \
              "found nothing for an address inside the chunk the knob kept"
end
if text.includes?("kept=true") && !text.includes?("KEPT by a refused release")
  failures << "the ledger has the chunk but no report line named it; either the " \
              "read did not fault (no crash report at all) or the report skipped " \
              "the branch. exit #{status.exit_code}"
end

# The line is not the whole claim: the report has to *survive* printing it.
# The first version of this gate passed while the child died inside its own
# handler - the kept-release line is 377 bytes and its buffer was 256, so
# writing it ran 121 bytes past the end of the stack frame, clobbered the
# block count it had already printed and then the return address, and the
# report exited at 0x0 with the description of the fault it was called for
# still unflushed. Three checks, because each failed separately there.
if text.includes?("faulted inside itself")
  failures << "the report faulted inside itself after naming the chunk. A line " \
              "longer than its own buffer is the shape of this: `RawOut` " \
              "truncates at `LIMIT`, so anything below that smashes the stack " \
              "instead of losing characters"
end
if text.includes?("KEPT by a refused release") && !text.includes?("SIGSEGV at")
  failures << "the kept-release line printed and the report's own description of " \
              "the faulting address did not, so the report died between them"
end
if text.includes?("KEPT by a refused release") &&
   !text.includes?("forced by GCRY_REFUSE_EMPTY_RELEASE")
  failures << "the report read a non-zero block count for a chunk the knob kept. " \
              "The knob refuses regardless of occupancy and these chunks are " \
              "empty, so a count above zero means the value was corrupted between " \
              "the ledger and the line - which is what an overflowing line buffer " \
              "does to the locals beside it"
end

if failures.empty?
  puts "PASS - a fault inside a chunk a flush refused to release says so"
  exit 0
end
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
