# Does a freed block read as poison, and does the collector still hand out zeros?
#
# The 2026-08-10 soak died in `Parallel::Scheduler#quick_dequeue?` on
# `0x7f1700000149`. Three sessions have argued about what that value was — a
# partially overwritten pointer, a reissued object's first two Int32s, a valid
# pointer into an unmapped chunk — and the argument is unresolvable because the
# value is *plausible*. `GCRY_POISON_FREED=1` overwrites a freed block's payload
# with `0xdeadf2eedeadf2ee`, which is not plausible: it is not a pointer, it is
# not zero, it is not anyone's data, and dereferencing it faults at an address
# that says use-after-free and nothing else.
#
# The knob is only sound because of a pairing, and both halves are gated here:
#
#   poison    a freed payload must read the pattern. Without this the knob does
#             nothing and every other arm passes vacuously.
#
#   zeroing   a `malloc` that asks to be cleared must still get zeros. This is
#             the half that could break the collector rather than debug it:
#             gcry skips the clearing memset when a size class's freelist is
#             known clean (a freshly carved chunk is zero), so poisoning a block
#             on a "clean" list would hand poison to a caller expecting zeros.
#             Every path into `push_size_class_free` sets that flag false; this
#             arm is what proves it, over the size classes the poison touches.
#             **This is the gate.**
#
#   use-after-free
#             a pointer read out of a block *after* it was freed must read
#             poison rather than what was written there — the property that
#             turns the next soak crash into a sentence.
#
#   --control the same run with the knob off: freed payloads keep their old
#             bytes, so the arms above are attributable to the knob and not to
#             something else zeroing memory.
#
#   crystal build -Dgc_none bench/poison_freed.cr -o bin/poison_freed
#   GCRY_POISON_FREED=1 bin/poison_freed
#   bin/poison_freed --control

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "poison_freed requires -Dgc_none (gcry as process GC)" %}
{% end %}

HEAP   = Gcry.default_heap.not_nil!
POISON = 0xDEADF2EEDEADF2EE_u64
MARKER = 0x0123456789ABCDEF_u64

# Sizes across several size classes. All small (the threshold is 32 KiB): a
# freed *large* block can be munmapped outright, so reading one back is not
# defined and the first version of this harness SEGV'd on its own probe. The
# large path is poisoned too — `poisoned_blocks` counts it — but it cannot be
# read back from here.
SIZES = [32, 64, 200, 1024, 4096]

def run(control : Bool) : Int32
  failures = [] of String
  on = HEAP.poison_freed
  puts "poison_freed: #{on}"

  # ── Arm 1: a freed payload reads the pattern ────────────────────────────────
  poisoned = 0
  intact = 0
  SIZES.each do |size|
    ptr = GC.malloc(size)
    words = ptr.as(UInt64*)
    n = size // 8
    n.times { |i| words[i] = MARKER }
    GC.free(ptr)
    # Reading a freed block is exactly what this knob exists to make legible;
    # the block is still mapped, so the read itself is defined.
    first = words[0]
    last = words[n - 1]
    if first == POISON && last == POISON
      poisoned += 1
    elsif first == MARKER
      intact += 1
    end
  end
  puts "freed payloads: #{poisoned}/#{SIZES.size} poisoned, #{intact} still holding their old bytes"

  before = HEAP.poisoned_blocks
  if on
    failures << "#{SIZES.size - poisoned} of #{SIZES.size} freed payloads did not read as poison" if poisoned != SIZES.size
    failures << "poisoned_blocks is 0 — the counter cannot see the work" if before == 0
  else
    failures << "the knob is off but #{poisoned} payloads read as poison" if poisoned > 0
    failures << "the knob is off but poisoned_blocks is #{before}" if before > 0
  end

  # ── Arm 2: cleared allocations still get zeros ──────────────────────────────
  # The dangerous direction. Free a run of blocks in a class, then allocate the
  # same class back and require every word to be zero.
  dirty = 0
  checked = 0
  [32, 64, 200, 1024].each do |size|
    freed = [] of Void*
    64.times do
      p = GC.malloc(size)
      w = p.as(UInt64*)
      (size // 8).times { |i| w[i] = MARKER }
      freed << p
    end
    freed.each { |p| GC.free(p) }

    64.times do
      p = GC.malloc(size)
      w = p.as(UInt64*)
      (size // 8).times do |i|
        checked += 1
        dirty += 1 if w[i] != 0
      end
    end
  end
  puts "cleared allocations: #{dirty} non-zero words of #{checked}"
  if dirty > 0
    failures << "#{dirty} of #{checked} words came back non-zero from a cleared malloc — the " \
                "freelist-clean fast path handed out a poisoned block, which is a correctness " \
                "regression and not a debugging aid"
  end

  # ── Arm 3: use after free reads poison, not the old value ───────────────────
  victim = GC.malloc(64)
  vwords = victim.as(UInt64*)
  8.times { |i| vwords[i] = MARKER }
  GC.free(victim)
  stale = vwords[3]
  puts "stale read after free: 0x#{stale.to_s(16)}"
  if on
    unless stale == POISON
      failures << "a word read out of a freed block still returned 0x#{stale.to_s(16)} — a " \
                  "use-after-free would look like live data, which is the situation the " \
                  "2026-08-10 crash left us in"
    end
  else
    unless stale == MARKER
      failures << "with the knob off a freed block's word changed to 0x#{stale.to_s(16)}, so the " \
                  "control does not isolate the knob"
    end
  end

  # ── Arm 4: the knob does not stop the sweep reclaiming ──────────────────────
  #
  # Poisoning is a payload write, and the streaming bitmap sweep touches no
  # payload — so until 2026-09-04 an armed knob stood that whole arm down and
  # let the header walk run instead. That walk reclaims through a freelist and
  # never clears `occ`, which under `GCRY_BITMAP_ALLOC=1` is the only thing
  # the allocator reads: every reclaimed block stayed occupied for the rest of
  # the process. Measured before the fix, 200k objects a round holding 1 in
  # 500: **18.1 → 64.7 MB** over four rounds, +15.5 MB each, against a
  # plateau at 16.8 MB with the knob off.
  #
  # So the arm is about reclaim, not about the pattern: churn, and require the
  # heap to stop growing. It runs in both arms because the plateau must hold
  # with the knob off too, or the number it is compared against means nothing.
  #
  # *Stop* growing, not *never* grow, because a healthy heap may grow once.
  # One string in 500 survives, so every chunk of their class (80 B, atomic)
  # that a cycle fills keeps a few survivors and is never released: the heap
  # after a round is the most such chunks any one cycle so far has needed,
  # and a cycle is as long as the threshold. Pacing raises the threshold up
  # to 3× when a collection costs more than a tenth of the mutator time
  # before it, so one paced cycle steps the heap up for good, and every later
  # round reuses what it mapped. macos-15-intel read 9.4 → 10.1 → 16.4 → 16.4
  # MB that way (run 39073579395), and the test this replaced — last round
  # minus first, more than 4 MB — failed it; a probe run with the same shape
  # had the class's chunks go from 13 to 38 in the round a 300% pace made one
  # cycle three times as long, then stay there for eight more rounds. 0.37.0's
  # 8 MiB Darwin floor halves the mutator time between collections (a cycle
  # every 40 960 iterations here, 80 896 at 16 MiB) without halving the
  # collection: on the two macOS runners the control arm paced in 11 of
  # 1 280 rounds, and in none of 800 at v0.36.0; with pacing off or the old
  # 16 MiB floor fixed, none of 400 runs stepped. The shipped test failed 2
  # control runs in 440 there and 2 knob-on runs in 200
  # (`bench/log/macos/2026-10-18-poison-freed-step/`).
  #
  # Such a step is a running maximum: it rises only in a round whose longest
  # cycle beats every earlier one, and no further than the paced threshold
  # allocates — at most +7.0 MB over four rounds in 1 440 runs on those
  # runners and the failing one, 16.9 MB the highest any round read. The
  # defect grows the heap in *every* round by what the round allocated:
  # +15.5 MB a round then, +40 MB a round with the stand-down restored on the
  # 0.37.0 tree. So the heap test fails when each round after the first grew
  # by more than 4 MB: three of those are more than 12 MB, beyond any
  # schedule measured, and the defect clears each one tenfold.
  #
  # Arms 1-3 leave garbage behind; collect it, so that the occupancy baseline
  # below is what survives into the churn and nothing else.
  GC.collect
  occupied_before = occupied_blocks
  rounds = churn_rounds(ROUNDS, COUNTERS)
  sizes = rounds.map(&.heap_mb)
  churned = rounds.sum(&.poisoned)
  keep_size = rounds.last.kept
  puts "heap MB per round: #{sizes.map(&.round(1)).join(" -> ")} " \
       "(#{keep_size} kept, #{churned} poisoned)"
  # ~1 600 strings stay live, so the heap has nothing to grow for round on
  # round. Before the fix this arm went 18.1 → 64.7 MB.
  deltas = (1...sizes.size).map { |i| sizes[i] - sizes[i - 1] }
  if (least = deltas.min?) && least > 4.0
    failures << "the heap grew by more than 4 MB in every churn round " \
                "(#{sizes.map(&.round(1)).join(" -> ")}, at least +#{least.round(1)} MB " \
                "each) — reclaimed blocks are not being handed out again"
  end

  # The heap reads a leak only once it outgrows what the schedule can do, and
  # a leak that levels off never reads as one: with an eighth of every
  # reclaim left occupied (a scratch build, FINDINGS) the chunks fill with
  # lost blocks until the other seven eighths suffice, and the heap went
  # 22.7 → 26.5 → 28.6 → 29.6 MB, which the test above passes. So the
  # defect's mechanism is read as well, and that does not depend on the
  # schedule: `occ`, the bitmap the allocator reads to call a block taken,
  # may gain no more set bits over the churn than twice the strings kept —
  # the margin is for a block a conservative root retains. Read after the
  # last round's `GC.collect`, so every dead block has been swept. The tip
  # gains the kept strings plus 5 to 8; an eighth left occupied gains 50 700,
  # a sixty-fourth 6 100, the defect 2.4 million. The header allocator has
  # no `occ` and reads 0, which passes.
  occupied = rounds.map(&.occupied)
  added = occupied.last.to_i64 - occupied_before.to_i64
  puts "occupied blocks per round: #{occupied_before} before -> #{occupied.join(" -> ")} " \
       "(#{keep_size} strings kept)"
  if added > 2 * keep_size
    failures << "#{added} more blocks are occupied after the churn than before it, for " \
                "#{keep_size} strings kept — reclaimed blocks are staying occupied, and the " \
                "allocator will not hand them out"
  end
  if on && churned == 0
    failures << "the knob is on and no block was poisoned during the churn, so " \
                "this arm never exercised the sweep it is about"
  end
  raise "the live set was collected" unless rounds.last.live_intact

  puts "poisoned blocks: #{HEAP.poisoned_blocks}"

  if failures.empty?
    puts
    if control
      puts "ok — with the knob off freed payloads keep their bytes, so the poison arms are " \
           "attributable to the knob"
    else
      puts "ok — freed payloads read 0x#{POISON.to_s(16)}, cleared allocations still come back " \
           "zeroed, and a use-after-free reads poison rather than plausible data"
    end
    return 0
  else
    puts
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    return 1
  end
end

# One churn round's numbers, read after its closing `GC.collect`.
record Round, heap_mb : Float64, occupied : UInt64, poisoned : UInt64, kept : Int32,
  live_intact : Bool

# Occupied blocks over every size-class chunk, popcounted from `occ`. A header
# chunk has no `occ` and counts 0; a dormant one is skipped, its pages are
# released and it is empty by construction.
def occupied_blocks : UInt64
  total = 0_u64
  HEAP.each_chunk do |chunk|
    next if Gcry::ChunkHeader.large?(chunk) || Gcry::ChunkHeader.dormant?(chunk)
    total += HEAP.chunk_occupied_count(chunk)
  end
  total
end

# What a churn round leaves in the size-class chunks, per (class, kind), read
# after `GC.collect` with no other thread allocating — so the chunk list is
# stable and every chunk's `occ` is its final occupancy for the round.
struct ClassCensus
  property chunks = 0
  property mapped = 0_u64
  property occupied = 0_u64
  property empty = 0
  property dormant = 0

  def initialize
  end
end

# The arm-4 churn: `rounds` rounds of 200 000 strings, 1 in 500 kept.
#
# With `counters` it prints one `counters round=N …` line per round, in
# key=value form so a loop of runs can be tabulated:
#
#   heap      `heap_size` after the round's closing `GC.collect`, MB — the
#             number the gate reads; split below into
#   holding   size-class chunks with at least one occupied block,
#   empty     size-class chunks with none (dormant or still mapped), of which
#             warm / grace / dormant are what the last sweep did with them,
#   large     large mappings;
#   live      the last sweep's live size-class payload;
#   majors    collections inside the round, `GC.collect` included;
#   peak      the largest `heap_size` seen inside the round (read every 1 024
#             iterations);
#   mapped / unmapped   chunks mapped and MB unmapped inside the round;
#   cycles    for each collection the round ran into: the iteration it was
#             first seen at, and the threshold and pace it left behind.
#
# and one `counters round=N class=…` line per (size class, kind) that holds
# two chunks or more. Together they say whether a round's growth is chunks
# that hold survivors or empty ones, and whether it came from a cycle running
# longer than the ones before (`cycles`) or from every cycle needing fresh
# chunks (`mapped` stays high with the heap growing round on round — the
# 2026-09-04 defect).
def churn_rounds(rounds : Int32, counters : Bool) : Array(Round)
  keep = [] of String
  out = [] of Round
  # {iteration, threshold, pace} per collection seen inside the round.
  cycles = [] of {Int32, UInt64, UInt64}
  rounds.times do |r|
    poisoned_before = HEAP.poisoned_blocks
    majors_before = HEAP.major_collections
    mapped_before = HEAP.chunks_mapped
    unmapped_before = HEAP.unmapped_bytes
    seen_majors = majors_before
    peak = HEAP.heap_size
    cycles.clear
    200_000.times do |i|
      # Allocated on every iteration — the churn *is* the experiment. Putting
      # the allocation inside the `if` (which an earlier version did) leaves
      # 400 objects a round and the leak has nothing to leak.
      s = "poison-arm4-#{i}-#{"p" * 24}"
      keep << s if i % 500 == 0
      # Field reads every 1 024 iterations, and an append only when a
      # collection ran — five or so a round, and only with `--counters`.
      if counters && i & 1023 == 0
        h = HEAP.heap_size
        peak = h if h > peak
        if (m = HEAP.major_collections) != seen_majors
          cycles << {i, HEAP.gc_threshold, HEAP.threshold_pace_pct}
          seen_majors = m
        end
      end
    end
    GC.collect
    heap = HEAP.heap_size
    occupied = occupied_blocks
    out << Round.new(heap / 1_048_576.0, occupied, HEAP.poisoned_blocks - poisoned_before,
      keep.size, keep.all?(&.starts_with?("poison-arm4-")))
    if counters
      print_round(r + 1, heap, peak, cycles, HEAP.major_collections - majors_before,
        HEAP.chunks_mapped - mapped_before, HEAP.unmapped_bytes - unmapped_before)
    end
  end
  out
end

private def mb(bytes : UInt64) : String
  (bytes / 1_048_576.0).round(2).to_s
end

private def print_round(n : Int32, heap : UInt64, peak : UInt64, cycles, majors : UInt64,
                        chunks_mapped : UInt64, unmapped : UInt64) : Nil
  census = Hash({UInt32, Bool}, ClassCensus).new
  holding = 0_u64
  empty = 0_u64
  HEAP.each_chunk do |chunk|
    next if Gcry::ChunkHeader.large?(chunk)
    key = {chunk.value.size_class, Gcry::ChunkHeader.atomic?(chunk)}
    c = census[key]? || ClassCensus.new
    c.chunks += 1
    c.mapped += chunk.value.mapped_bytes
    # A dormant chunk's pages are released; reading its bitmap would fault
    # them back in, and it is empty by construction.
    occ = Gcry::ChunkHeader.dormant?(chunk) ? 0_u64 : HEAP.chunk_occupied_count(chunk)
    c.dormant += 1 if Gcry::ChunkHeader.dormant?(chunk)
    c.occupied += occ
    if occ == 0
      c.empty += 1
      empty += chunk.value.mapped_bytes
    else
      holding += chunk.value.mapped_bytes
    end
    census[key] = c
  end
  puts "counters round=#{n} heap=#{mb(heap)} holding=#{mb(holding)} empty=#{mb(empty)} " \
       "warm=#{mb(HEAP.last_empty_warm_bytes)} grace=#{mb(HEAP.last_empty_grace_bytes)} " \
       "dormant=#{mb(HEAP.dormant_chunk_bytes)} large=#{mb(HEAP.large_mapped_bytes)} " \
       "live=#{mb(HEAP.size_class_live_bytes)} majors=#{majors} peak=#{mb(peak)} " \
       "mapped=#{chunks_mapped} unmapped=#{mb(unmapped)} thr=#{mb(HEAP.gc_threshold)} " \
       "cycles=#{cycles.map { |(i, t, p)| "#{i}/#{mb(t)}/#{p}" }.join(",")}"
  census.to_a.sort_by { |(k, _)| {k[0], k[1] ? 1 : 0} }.each do |(k, c)|
    next if c.chunks < 2
    puts "counters round=#{n} class=#{k[0]}#{k[1] ? "a" : ""} " \
         "payload=#{Gcry::SizeClasses.payload(k[0].to_i32)} chunks=#{c.chunks} " \
         "mb=#{mb(c.mapped)} occupied=#{c.occupied} empty=#{c.empty} dormant=#{c.dormant}"
  end
end

control = ARGV.includes?("--control")
# Diagnostics, not part of the gate: `--counters` prints the per-round split
# above, `--rounds N` runs N churn rounds instead of 4.
COUNTERS = ARGV.includes?("--counters")
ROUNDS   = (idx = ARGV.index("--rounds")) ? ARGV[idx + 1].to_i : 4
puts "=== poison on free ==="
puts "mode: #{control ? "control (knob off; freed payloads must keep their bytes)" : "hold (knob on)"}"
exit run(control)
