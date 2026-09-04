# What is Darwin's free-page walk standing down from on a bitmap chunk?
#
# `flush_pending_page_release_chunks` has a Darwin arm that visits **every**
# kept size-class chunk, not only the ones the sweep flagged HOLED, and hands
# each to `release_free_pages_in_chunk`. That function builds its free-page
# mask from `BlockHeader.free?` (collect_sweep.cr, `live_mask`) — and on a
# bitmap-allocated chunk the FREE flag is not maintained: occupancy lives in
# `occ`, and the streaming sweep never writes the header. So the mask on such
# a chunk is not "the free pages"; it is whatever the carve left behind.
#
# The stand-down (`next if bitmap_alloc_chunk?(chunk)`) was written blind, on
# Linux, from that reading of the code and never run on Darwin. This is the
# run. It measures which of the two possible stories is true, because they
# call for different confidence:
#
#   * if the stale flag reads *not free*, the mask is all-ones, no run is ever
#     selected, and the stand-down only saves a pointless walk;
#   * if it reads *free* for live blocks, runs covering live objects are
#     selected, and the only thing between that and a live object being
#     `madvise`d away is the `occ`-based re-read in `audit_page_run_live`.
#
# Arms:
#
#   default    `GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1`, stand-down in
#              place. A checksummed live graph must survive, and the walk must
#              not have touched a bitmap chunk: `page_release_live_blocks` and
#              `page_release_skipped_runs` both zero. **The gate.**
#
#   --walk     the same, plus `GCRY_PAGE_RELEASE_BITMAP_WALK=1`, which lets
#              the walk into bitmap chunks. Reports what it finds. **This is
#              the red arm**: if it comes back identical to the default arm,
#              the stand-down is guarding nothing and this file should say so
#              rather than imply otherwise.
#
#   --unchecked  `--walk` plus `GCRY_PAGE_RELEASE_UNCHECKED=1`, i.e. both nets
#              removed: the mask is stale *and* the re-read that would have
#              caught it is gone. Run as a child, because a process that has
#              had a live page dropped underneath it may not survive to
#              report. Either a broken checksum or a death is the answer;
#              surviving intact would mean the run selection never covered a
#              live object after all.
#
#   --headers  bitmap allocation off, so the FREE flag *is* the authority and
#              the walk is operating as designed. This one is the control for
#              the default arm: it shows the walk releases bytes at all on
#              this host, so "no bytes released on a bitmap chunk" is a fact
#              about the stand-down and not about a walk that never works.
#
#   crystal build -Dgc_none bench/darwin_bitmap_page_release.cr -o bin/darwin_bitmap_page_release
#   GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1 bin/darwin_bitmap_page_release
#   GCRY_BITMAP_ALLOC=1 GCRY_PAGE_DONTNEED=1 GCRY_PAGE_RELEASE_BITMAP_WALK=1 \
#     bin/darwin_bitmap_page_release --walk
#   GCRY_PAGE_DONTNEED=1 bin/darwin_bitmap_page_release --headers

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "darwin_bitmap_page_release requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% if flag?(:darwin) %}
  lib LibC
    MADV_FREE_REUSABLE = 7
    fun madvise(addr : Void*, len : SizeT, advice : Int) : Int
  end
{% end %}

# Payload that spans several pages worth of blocks per chunk, so a chunk has
# both live and dead blocks and the free-page mask has something to say.
PAYLOAD  =                       192
KEEP     =                     6_000
CHURN    =                    60_000
ROUNDS   =                        12
FILL_KEY = 0x9E37_79B9_7F4A_7C15_u64

class Cell
  property nxt : Cell?
  property tag : UInt64
  property fill : Slice(UInt64)

  def initialize(@tag : UInt64)
    @nxt = nil
    @fill = Slice(UInt64).new(PAYLOAD // 8) { |i| @tag &* (i.to_u64 &+ 1) }
  end

  def sum : UInt64
    s = @tag
    @fill.each { |w| s = (s &* 31) &+ w }
    s
  end

  def intact? : Bool
    ok = true
    @fill.each_with_index do |w, i|
      ok = false if w != @tag &* (i.to_u64 &+ 1)
    end
    ok
  end
end

# The survivors, rooted through a class variable so they are reachable but
# scattered across chunks that also hold garbage.
class Live
  @@cells = [] of Cell

  def self.build(n : Int32) : Nil
    @@cells = Array(Cell).new(n) { |i| Cell.new(FILL_KEY &* (i.to_u64 &+ 1)) }
  end

  def self.checksum : UInt64
    total = 1_u64
    @@cells.each { |c| total = (total &* 131) &+ c.sum }
    total
  end

  def self.damaged : Int32
    @@cells.count { |c| !c.intact? }
  end

  def self.size : Int32
    @@cells.size
  end

  def self.cells : Array(Cell)
    @@cells
  end
end

def churn(n : Int32) : UInt64
  acc = 0_u64
  n.times do |i|
    c = Cell.new(FILL_KEY &* (i.to_u64 &+ 7))
    acc = acc &+ (c.tag & 0xff)
  end
  acc
end

record Counters,
  live_blocks : UInt64,
  skipped_runs : UInt64,
  release_bytes : UInt64,
  dontneed_bytes : UInt64,
  unlinked_chunks : UInt64

def counters(heap : Gcry::Heap) : Counters
  Counters.new(
    live_blocks: heap.page_release_live_blocks,
    skipped_runs: heap.page_release_skipped_runs,
    release_bytes: heap.page_release_bytes,
    dontneed_bytes: heap.dontneed_bytes,
    unlinked_chunks: heap.page_release_unlinked_chunks,
  )
end

arm = if ARGV.includes?("--selfcheck")
        "selfcheck"
      elsif ARGV.includes?("--unchecked")
        "unchecked"
      elsif ARGV.includes?("--walk")
        "walk"
      elsif ARGV.includes?("--headers")
        "headers"
      else
        "default"
      end

# Two questions, and they have to be asked separately on Darwin.
#
# 1. Can this file see a lost payload at all? A checksum gate that cannot be
#    shown to fail is not a gate, so one held cell's payload is zeroed on
#    purpose — the same thing `bench/page_release_corruption.cr` does to its
#    verifier. `damaged` must come back non-zero.
#
# 2. Would the *real* release have shown up? On Linux the walk issues
#    `MADV_DONTNEED`, which zeroes the page there and then, so a checksum
#    catches a mis-released page immediately. Darwin's
#    `Platform.release_physical_pages` issues `madvise(..., MADV_FREE)`
#    (`platform/darwin_stubs.cr`, advice 5), which only marks the page
#    reclaimable. Measured on Apple M2 Pro / Darwin 25.6.0: both `MADV_FREE`
#    and `MADV_FREE_REUSABLE` return 0 on a still-referenced range and leave
#    every word intact, through 2 GiB of allocation pressure. So on this
#    platform a released live page is *latent* — and every `intact=true` in
#    the arms above is therefore non-discriminating, which is why the gate
#    reads `page_release_live_blocks` and not the checksum. This arm exists to
#    keep that stated rather than assumed: if a future macOS starts losing the
#    contents, the reading here changes and the arms above become evidence.
record SelfCheck, zeroed : Int32, advised : Int32, advise_lost : Int32

def selfcheck(cells : Array(Cell)) : SelfCheck
  return SelfCheck.new(zeroed: 0, advised: 0, advise_lost: 0) if cells.empty?

  # (2) first, on cells the checksum will *not* be asked about afterwards is
  # impossible — every cell is in the checksum — so measure the advice on a
  # separate mapping-free way: advise the payload pages, count how many lost
  # their first word, then restore them before (1) runs.
  advised = 0
  advise_lost = 0
  {% if flag?(:darwin) %}
    page = Gcry::Platform.host_page_size
    sample = cells.first(256)
    saved = sample.map { |c| c.fill.to_unsafe.value }
    sample.each do |c|
      base = c.fill.to_unsafe.address & ~(page - 1)
      next if base == 0
      advised += 1 if Gcry::Platform.release_physical_pages(base, page)
    end
    sample.each_with_index do |c, i|
      advise_lost += 1 if c.fill.to_unsafe.value != saved[i]
    end
    # Put back whatever the advice took, so (1) and the checksum below are
    # measuring the deliberate zeroing and nothing else.
    sample.each_with_index { |c, i| c.fill.to_unsafe.value = saved[i] }
  {% end %}

  # (1) the verifier's own power: one cell, zeroed on purpose.
  victim = cells[cells.size // 2]
  victim.fill.size.times { |i| victim.fill.to_unsafe[i] = 0_u64 }
  SelfCheck.new(zeroed: 1, advised: advised, advise_lost: advise_lost)
end

heap = Gcry.default_heap.not_nil!
failures = [] of String

bitmap_alloc = heap.bitmap_alloc?
madvise = heap.madvise_free_pages
walk_knob = ENV["GCRY_PAGE_RELEASE_BITMAP_WALK"]? == "1"
unchecked = ENV["GCRY_PAGE_RELEASE_UNCHECKED"]? == "1"

puts "=== darwin bitmap free-page release: arm=#{arm} ==="
puts "  bitmap_alloc=#{bitmap_alloc} madvise_free_pages=#{madvise} " \
     "bitmap_walk=#{walk_knob} unchecked=#{unchecked} page_size=#{Gcry::Platform.host_page_size}"

# Harness preconditions. Every arm below is a statement about a specific
# configuration, and reading them off the heap rather than off the command
# line is what stops the arm from measuring something else.
unless madvise
  failures << "harness: madvise_free_pages is off — set GCRY_PAGE_DONTNEED=1; " \
              "with the walk disabled every arm here is vacuous"
end
case arm
when "default", "walk", "unchecked"
  unless bitmap_alloc
    failures << "harness: arm #{arm} needs GCRY_BITMAP_ALLOC=1; without it there is " \
                "no bitmap chunk to stand down from"
  end
when "headers"
  if bitmap_alloc
    failures << "harness: --headers must run without GCRY_BITMAP_ALLOC=1"
  end
end
if (arm == "walk" || arm == "unchecked") && !walk_knob
  failures << "harness: arm #{arm} needs GCRY_PAGE_RELEASE_BITMAP_WALK=1"
end
if arm == "unchecked" && !unchecked
  failures << "harness: --unchecked needs GCRY_PAGE_RELEASE_UNCHECKED=1"
end
if arm != "unchecked" && unchecked
  failures << "harness: GCRY_PAGE_RELEASE_UNCHECKED=1 set outside the --unchecked arm"
end

Live.build(KEEP)
expected = Live.checksum
before = counters(heap)

acc = 0_u64
ROUNDS.times do
  acc = acc &+ churn(CHURN // ROUNDS)
  heap.collect
end
heap.collect

sc = arm == "selfcheck" ? selfcheck(Live.cells) : SelfCheck.new(zeroed: 0, advised: 0, advise_lost: 0)

after = counters(heap)
got = Live.checksum
damaged = Live.damaged

d_live = after.live_blocks - before.live_blocks
d_skip = after.skipped_runs - before.skipped_runs
d_bytes = after.release_bytes - before.release_bytes
d_dontneed = after.dontneed_bytes - before.dontneed_bytes
d_unlinked = after.unlinked_chunks - before.unlinked_chunks

puts "  churn acc=#{acc & 0xffff} (kept so the loop is not dead code)"
puts "  page_release: live_blocks=#{d_live} skipped_runs=#{d_skip} " \
     "release_bytes=#{d_bytes} dontneed_bytes=#{d_dontneed} unlinked_chunks=#{d_unlinked}"
puts "  live graph: cells=#{Live.size} damaged=#{damaged} checksum_match=#{got == expected}"
# Machine-readable, and printed before anything else can go wrong: the
# unchecked arm may not reach the end.
puts "result: arm=#{arm} live_blocks=#{d_live} skipped_runs=#{d_skip} " \
     "release_bytes=#{d_bytes} damaged=#{damaged} intact=#{got == expected}"
STDOUT.flush

case arm
when "default"
  # The stand-down means the walk never looked at a bitmap chunk. Both
  # counters are only ever written from inside `release_free_pages_in_chunk`,
  # so a zero is the walk not having run there.
  if d_live != 0 || d_skip != 0
    failures << "default: the walk reached a bitmap chunk anyway " \
                "(live_blocks=#{d_live} skipped_runs=#{d_skip}) — the stand-down in " \
                "flush_pending_page_release_chunks is not holding"
  end
  if damaged != 0 || got != expected
    failures << "default: #{damaged} of #{Live.size} live cells damaged " \
                "(checksum_match=#{got == expected}) — a live object lost content " \
                "with the stand-down in place"
  end
when "headers"
  # The control. If this releases nothing, the default arm's zeros are a
  # statement about the walk rather than about the stand-down.
  if d_bytes == 0 && d_dontneed == 0
    failures << "headers: the walk released no bytes on a header-managed heap, so " \
                "it is not working on this host at all and the default arm's zeros " \
                "mean nothing"
  end
  if damaged != 0 || got != expected
    failures << "headers: #{damaged} live cells damaged on the header path — that is " \
                "a defect in the walk itself, not in the bitmap stand-down"
  end
when "walk"
  # What the stand-down is standing down from. The walk must actually engage
  # here, or the arm is measuring the stand-down twice.
  if d_bytes == 0
    failures << "walk: GCRY_PAGE_RELEASE_BITMAP_WALK=1 released no bytes from a " \
                "bitmap chunk, so it is not reaching the walk and the default arm " \
                "is being compared against itself"
  end
  # The measured shape of the staleness, and the reason the stand-down is a
  # cost decision rather than a soundness one: on a bitmap chunk
  # `BlockHeader.free?` is false for *every* block — `set_used` clears FREE on
  # allocation and `bitmap_free_block` only clears `occ`/`mark`, never the
  # header — so the mask over-reports liveness and can only fail to release.
  # A change that makes it `occ`-derived without porting the cursor exclusion
  # (`unlink_free_only_page_runs`, collect_sweep.cr) breaks this.
  if d_live != 0
    failures << "walk: audit_page_run_live found #{d_live} live blocks inside runs the " \
                "header-built mask had selected. That mask is supposed to be " \
                "one-directionally stale — FREE is never set on a bitmap chunk, so it " \
                "over-reports liveness — and this says it no longer is. The " \
                "stand-down is now load-bearing for soundness, not just for cost"
  end
  if damaged != 0 || got != expected
    failures << "walk: #{damaged} live cells damaged with the occ-based re-read still " \
                "on — `audit_page_run_live` did not hold, which is a second defect " \
                "and not the one this gate is about"
  end
when "unchecked"
  # Both nets off: the header mask is used as-is and nothing re-reads `occ`.
  # This must still be intact, and that is the whole finding — the staleness
  # is conservative. If this ever goes red, the stand-down stopped being an
  # RSS/CPU trade and became the only thing between the walk and a live
  # object.
  if damaged != 0 || got != expected
    failures << "unchecked: #{damaged} live cells damaged with the mask stale and the " \
                "re-read off. The header FREE flag is no longer one-directional on a " \
                "bitmap chunk, so `flush_pending_page_release_chunks`' stand-down is " \
                "load-bearing for correctness and must be documented as such"
  end
when "selfcheck"
  puts "  selfcheck: zeroed=#{sc.zeroed} cell payload(s) on purpose; " \
       "release_physical_pages accepted #{sc.advised} live payload pages and " \
       "#{sc.advise_lost} of them lost their first word"
  if sc.zeroed == 0
    failures << "selfcheck: nothing was zeroed, so this arm did not run"
  elsif damaged == 0 || got == expected
    failures << "selfcheck: a held cell's payload was zeroed and the verifier reported " \
                "damaged=#{damaged} checksum_match=#{got == expected} — this file " \
                "cannot see a lost payload, so every `intact=` above is vacuous"
  else
    puts "  selfcheck: the verifier reports damaged=#{damaged}, so it can see a lost payload"
  end
  if sc.advised > 0 && sc.advise_lost == 0
    puts "  selfcheck: MADV_FREE left all #{sc.advised} advised live pages intact, so on " \
         "this host a mis-released page is latent and the checksum arms above are " \
         "NOT the evidence — page_release_live_blocks is."
  elsif sc.advise_lost > 0
    puts "  selfcheck: MADV_FREE lost #{sc.advise_lost} of #{sc.advised} advised live " \
         "pages, so on this host the checksum arms above do discriminate."
  end
end

puts
if failures.empty?
  puts "ok — arm #{arm}"
  exit 0
end
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
