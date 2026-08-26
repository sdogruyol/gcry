# Does the default page-release walk zero live objects?
#
# `flush_pending_page_release_chunks` runs after `start_world` — mutators live —
# and on Linux walks every HOLED chunk. For each it calls
# `release_free_pages_in_chunk(..., preserve_content: false)`, which builds a
# live-page mask by reading every `BlockHeader.free?` in the chunk **holding no
# lock**, and then `madvise(MADV_DONTNEED)`s the page runs the mask calls free.
#
# A block that reads free during the mask walk can be handed to a mutator and
# written before the syscall lands. DONTNEED does not wait for memory pressure
# the way MADV_FREE does: the page is zeroed there and then, and the object in
# it reads back as zeros.
#
# `heap.release_empty_chunks` is `true` in `GC.init` and the call site is
# unconditional, so this is the default configuration on Linux. No knob.
#
# This gate does not wait for a crash. Every live object carries a checksum
# derived from its own identity; the workers verify what they hold on every
# round. Zeroed memory fails the check whether or not it ever gets dereferenced
# as a pointer, which is the only way to see a defect whose whole nature is that
# it leaves no trace.
#
#   holes    allocate many, keep one in eight — the survivors leave whole pages
#            free inside an otherwise-live chunk, which is what HOLED means
#   verify   re-check every survivor each round
#
#   default                      must be clean
#   GCRY_DISABLE_PAGE_RELEASE=1  must also be clean — if it is not, the walk is
#                                not what is doing the damage and this harness
#                                is measuring something else
#
# The verifier itself was checked by zeroing a held object on purpose: it
# reported 40 corrupt, 40 of them entirely zero. A checksum gate that cannot be
# shown to fail is not a gate.
#
# As of 2026-08-23 the HOLED arm does not pass. It faults about one run in six,
# and not on a checksum — on an address the report places inside the heap span
# and in no live chunk, reached through the worker's own live array. That is a
# released chunk holding a live object, not a zeroed page. 7 of 40 with the walk
# on, 0 of 40 with it off.
# See `bench/log/linux/2026-08-23-holed-release-uaf/`.
#
# Raise `PAGE_RELEASE_ATTEMPTS` when hunting rather than guarding — four per arm
# is a smoke test, and four cannot separate 0 % from 10 %.
#
#   crystal build -Dgc_none bench/page_release_corruption.cr -o bin/page_release_corruption
#   bin/page_release_corruption

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "page_release_corruption requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS =    4
ROUNDS  =  120
BATCH   = 8192
KEEP    =    8 # keep one in KEEP, so 7 of 8 blocks become holes
PAYLOAD =  112

# A checksum the object can be verified against without storing anything else:
# every byte is a function of the object's first two bytes.
def fill(b : Bytes, seed : UInt16) : Nil
  b[0] = (seed & 0xff).to_u8
  b[1] = (seed >> 8).to_u8
  i = 2
  while i < b.size
    b[i] = ((seed &* 31_u16 &+ i) & 0xff).to_u8
    i += 1
  end
end

def check(b : Bytes) : Bool
  seed = b[0].to_u16 | (b[1].to_u16 << 8)
  i = 2
  while i < b.size
    return false if b[i] != ((seed &* 31_u16 &+ i) & 0xff).to_u8
    i += 1
  end
  true
end

class Verdict
  @@bad = Atomic(Int32).new(0)
  @@zeroed = Atomic(Int32).new(0)

  def self.corrupt!(zeroed : Bool)
    @@bad.add(1)
    @@zeroed.add(1) if zeroed
  end

  def self.bad
    @@bad.get
  end

  def self.zeroed
    @@zeroed.get
  end
end

if ARGV.includes?("--child")
  threads = [] of Thread
  WORKERS.times do |w|
    threads << Thread.new do
      kept = Array(Bytes).new(ROUNDS * (BATCH // KEEP))
      seed = (w.to_u16 &+ 1) &* 977_u16
      ROUNDS.times do
        BATCH.times do |i|
          b = Bytes.new(PAYLOAD)
          seed &+= 1
          fill(b, seed)
          # Survivors have to be *clustered*, not sampled. One in eight spread
          # evenly leaves a live block on every page — 4 KiB holds 32 blocks of
          # this class — so no page is ever fully free and the chunk is never
          # HOLED. Keeping the head of each batch and dropping the tail leaves
          # whole free page runs behind, which is the shape the walk looks for.
          kept << b if i < KEEP
        end
        # Verify everything still held. A page zeroed under us shows up here.
        kept.each do |b|
          unless check(b)
            all_zero = true
            b.each { |x| (all_zero = false) if x != 0 }
            Verdict.corrupt!(all_zero)
          end
        end
      end
    end
  end
  threads.each(&.join)

  # Silence only counts if the walk ran. `dontneed_bytes` is what
  # `release_free_pages_in_chunk` bumps on every successful release, so a zero
  # here means this harness never reached the path and proves nothing.
  heap = Gcry.default_heap
  puts "child: #{Verdict.bad} corrupt (#{Verdict.zeroed} entirely zero), " \
       "dontneed #{heap.dontneed_bytes} B, unlinked #{heap.page_release_unlinked_chunks}, " \
       "collections #{heap.collections}"
  exit(Verdict.bad > 0 ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["PAGE_RELEASE_ATTEMPTS"]?.try(&.to_i?) || 4)

puts "=== page-release walk vs. a live object ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds × #{BATCH} of #{PAYLOAD} B, keeping the first #{KEEP} of each batch"
puts "#{attempts} attempts per arm"
puts ""

# Bounded, and hangs counted apart from faults.
#
# This ran children through a bare `Process.run` with no deadline, so a child
# that stopped making progress hung the gate instead of failing it — and a
# hung gate reads as a slow one. That is not hypothetical: the stop-the-world
# hang fixed in 0.21.1 lived here for a day looking like a slow machine, and
# two measurements were thrown away as noise before anyone looked at a process
# and found four threads parked in `rt_sigsuspend` with two spinning
# (`bench/log/linux/2026-08-26-stw-sweep-hang/FINDINGS.md`).
#
# It also means every rate this gate has ever printed counted **crashes only**:
# a child that hung never returned, so it never entered the denominator either.
def run(exe : String, env, attempts : Int32) : {Int32, Int32, String?, UInt64, UInt64}
  bad = 0
  hung = 0
  first = nil
  dontneed = 0_u64
  unlinked = 0_u64
  attempts.times do
    result = BoundedChild.run(exe, ["--child"], env)
    text = result.output
    if m = text.match(/dontneed (\d+) B/)
      dontneed += m[1].to_u64
    end
    if m = text.match(/unlinked (\d+)/)
      unlinked += m[1].to_u64
    end
    unless result.ok
      bad += 1
      hung += 1 if result.timed_out
      first ||= text.lines.find { |l| l.includes?("corrupt") || l.includes?("Invalid memory") }
    end
  end
  {bad, hung, first, dontneed, unlinked}
end

def arm_line(label : String, bad : Int32, hung : Int32, attempts : Int32,
             dn : UInt64, ul : UInt64, note : String?) : String
  "  #{label} #{bad} of #{attempts}#{hung > 0 ? " (#{hung} timed out)" : ""}, " \
  "released #{dn} B, unlinked #{ul}#{note ? "\n     #{note.strip}" : ""}"
end

# Linux keeps the HOLED walk opt-in, so the arm that exercises it has to ask
# for it. Darwin turns it on in `GC.init` and walks every chunk, not just the
# HOLED ones — the same code, reached without a knob.
holed_bad, holed_hung, holed_note, holed_dn, holed_ul = run(exe, {"GCRY_PAGE_DONTNEED" => "1"}, attempts)
puts arm_line("GCRY_PAGE_DONTNEED=1:    ", holed_bad, holed_hung, attempts, holed_dn, holed_ul, holed_note)

# `GCRY_MOSTLY_EMPTY` is ignored while `madvise_free_pages` is on, and Darwin
# turns that on in `GC.init`. Without disabling it here the arm would quietly
# measure the HOLED walk a second time and still report bytes released, which
# is the shape of a gate that says "both walks ran" when only one did.
empty_bad, empty_hung, empty_note, empty_dn, empty_ul = run(exe,
  {"GCRY_MOSTLY_EMPTY" => "1", "GCRY_DISABLE_PAGE_RELEASE" => "1"}, attempts)
puts arm_line("GCRY_MOSTLY_EMPTY=1:     ", empty_bad, empty_hung, attempts, empty_dn, empty_ul, empty_note)

off_bad, off_hung, off_note, off_dn, off_ul = run(exe, {"GCRY_DISABLE_MADVISE" => "1"}, attempts)
puts arm_line("GCRY_DISABLE_MADVISE=1:  ", off_bad, off_hung, attempts, off_dn, off_ul, off_note)
puts ""

failures = [] of String

# A hang and a corrupted object are different defects with different owners,
# and folding them into one count is how the 0.21.1 stop-the-world hang hid
# here. Say which happened.
hung_total = holed_hung + empty_hung + off_hung
if hung_total > 0
  failures << "#{hung_total} child(ren) were killed on the deadline — a killed " \
              "child says nothing about page release. Re-run with " \
              "GCRY_STW_WATCHDOG_MS set: the last one of these was the collector " \
              "spinning in phase=sweep on a lock a suspended mutator held"
end

failures << "the HOLED walk faulted #{holed_bad - holed_hung} of #{attempts}" if holed_bad - holed_hung > 0
failures << "the mostly-empty walk faulted #{empty_bad - empty_hung} of #{attempts}" if empty_bad - empty_hung > 0
failures << "the control arm faulted #{off_bad - off_hung} of #{attempts} — nothing was " \
            "released, so this harness is measuring something other than page release" if off_bad - off_hung > 0

# Silence only counts if the walks ran. Without this the whole gate passes on a
# workload whose survivors are spread one per page, where no chunk is ever
# HOLED and no page is ever released — which is exactly how it was first
# written, and it looked clean.
#
# The floor is the control arm rather than zero: `dontneed_bytes` is shared with
# `flush_pending_dormant_chunks`, which answers to the empty-chunk machinery and
# not to `madvise_free_pages`, so the control releases a little no matter what.
# An engaged walk releases two orders of magnitude more than that.
# An absolute floor as well as a relative one: `dontneed_bytes` is shared with
# the dormant flush, whose output varies run to run and came back as 0 B once —
# which made a purely relative floor of `off_dn * 4` equal to zero, and the
# engagement check vacuous.
floor = {off_dn * 4, 8_u64 * 1024 * 1024}.max
failures << "GCRY_PAGE_DONTNEED released #{holed_dn} B against a #{off_dn} B control — " \
            "no chunk went HOLED, so a clean result says nothing about that walk" if holed_dn <= floor
failures << "GCRY_MOSTLY_EMPTY released #{empty_dn} B against a #{off_dn} B control — " \
            "no chunk was sparse enough, so a clean result says nothing about that " \
            "walk" if empty_dn <= floor

if failures.empty?
  puts "ok — both release walks ran and no live object was corrupted"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
