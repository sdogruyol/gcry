# Does the large-freelist page release cover the chunk's own metadata page?
#
# `release_large_freelist_pages_locked` computed its lower bound as
# `chunk.address` and rounded up. A chunk base is already page-aligned, so that
# round-up was a no-op and the range began at page 0 — the page holding the
# chunk's `ChunkHeader` and the large object's `BlockHeader`, including the
# `next_free` link that threads the very bucket chain the loop is walking. It
# ran unconditionally in the post-STW flush (collect.cr, `release_large_freelist_pages`),
# not behind a knob.
#
# What that costs, when the kernel acts on it: `mapped_bytes` reads 0 so
# `take_large_free` stops matching, and `next_free` reads null so the bucket
# chain truncates at the first reclaimed entry — every large chunk behind it is
# orphaned while `@large_free_bytes` still counts it, and `trim_large_cache`
# then walks a chain it can no longer reach.
#
# ## Why this gate asserts on the range and not on the corruption
#
# Linux uses `MADV_FREE` here and Darwin `MADV_FREE_REUSABLE`. Both *preserve
# content until the kernel actually reclaims*, which happens under memory
# pressure at a time nothing in this process controls. So "read the header back
# and see zeros" is not a test, it is a race that usually loses — which is
# exactly why this survived in the tree: the damage is real, rare, and
# load-dependent.
#
# What is deterministic is the range itself. `madvise_range_ok?` now requires
# `run_start >= data_start(chunk)`, so a range that reaches the metadata page is
# counted in `madvise_range_rejects` and refused. Two arms:
#
#   hold     — default bound. Releases must happen (so the walk is real) and
#              `madvise_range_rejects` must be 0.
#   control  — `GCRY_LARGE_RELEASE_FROM_BASE=1` restores the old bound. The
#              guard must catch it: rejects > 0. This is the arm that proves the
#              old code aimed at the header page, and that the hold arm's zero
#              is earned rather than vacuous.
#
# ~2 s.

require "../src/gcry"

LARGE     = 40_000_u64 # > SizeClasses::THRESHOLD, so every one is its own chunk
ROUNDS    =          6
PER_ROUND =         24

# `@dontneed_bytes` is reset at the top of every major sweep
# (collect_sweep.cr:32), so it reports the last cycle, not the run. Sample it
# per round and total it, or the "did the walk actually release anything?"
# check reads zero for the wrong reason.
def churn_large : UInt64
  released = 0_u64
  ROUNDS.times do
    held = [] of Void*
    PER_ROUND.times { held << GC.malloc(LARGE) }
    # Write through every one so the pages are genuinely resident before the
    # release walk looks at them.
    held.each { |p| Slice.new(p.as(UInt8*), 64).fill(0xA5_u8) }
    held.clear
    # Sample after *each* collect, not once per round: the counter is reset at
    # the top of every major sweep, so a round-granular read reports whichever
    # collection happened to be last and reads zero for the wrong reason.
    GC.collect
    released &+= Gcry.default_heap.try(&.dontneed_bytes) || 0_u64
    # A second collection: the first puts the chunks on the large freelist, the
    # post-STW flush of the next one is what runs the release walk over them.
    GC.collect
    released &+= Gcry.default_heap.try(&.dontneed_bytes) || 0_u64
  end
  released
end

control = ARGV.includes?("--control")

dontneed = churn_large

heap = Gcry.default_heap
unless heap
  STDERR.puts "no default heap — build with -Dgc_none"
  exit 2
end

rejects = heap.madvise_range_rejects

puts "large-freelist release: madvise_range_rejects=#{rejects} dontneed_bytes=#{dontneed}"

if control
  # Positive control: the old bound must be caught by the guard. If this arm is
  # quiet, the guard is not looking at what it claims to look at and the hold
  # arm's zero means nothing.
  if rejects == 0
    puts "FAIL: GCRY_LARGE_RELEASE_FROM_BASE=1 produced no rejected range."
    puts "      The old bound started at the chunk base, so every large-freelist"
    puts "      release should have been refused for covering the header page."
    puts "      Either the walk never ran (no large chunks reached the freelist)"
    puts "      or the guard is not bounding on data_start."
    exit 1
  end
  puts "ok — the pre-fix bound is refused #{rejects} times; the guard has teeth"
else
  if rejects != 0
    puts "FAIL: #{rejects} release ranges were refused for reaching a chunk's metadata."
    exit 1
  end
  if dontneed == 0
    puts "FAIL: no pages were released at all, so a zero reject count proves nothing."
    puts "      The walk has to actually run for this arm to mean anything."
    exit 1
  end
  puts "ok — every large-freelist release started above data_start, and #{dontneed} bytes were released"
end
