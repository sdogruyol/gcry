# `find_block` from a mutator thread, while collections run, used to crash.
#
# The last-chunk cache in `chunk_containing_unlocked` tested `@last_chunk_idx`
# and then **read it again** to index with. Those are two loads, and a
# concurrent `invalidate_chunk_cache` between them turns a guard that saw a
# valid index into a read at `@chunk_index[-1]` — libc's malloc header for the
# array. That is why the bad value was the same small constant every single
# time: `0x91`, handed to `ChunkHeader.large?`, which is where the crash lands.
# One of the writers was unsynchronised too: a second `invalidate_chunk_cache`
# outside `@index_lock`, on the path every allocating thread takes when it maps
# a chunk.
#
# It needed a mutator *inside* `find_block`, which is what took four sessions to
# find: allocation at the same rate never crashes, because it does not look
# chunks up. `GC.realloc` and `Heap#live?` reach it by different routes and
# crashed alike, and TLAB reaches it on the allocation fast path — which is why
# the CI sighting was on the `--tlab --nursery` arm and nowhere else.
#
# Measured, four threads and 200 collections:
#
#              before      with the fix
#   alloc      0 of 8      0 of 8
#   idle       0 of 8      0 of 8
#   live       5 of 8      0 of 8
#   realloc    5 of 8      0 of 8
#
# And the race is not rare — it is constant. `index_cache_torn` counts a cache
# read whose index, bounds and array disagreed and which fell through to the
# binary search instead of trusting any of them: **7 849 in one run** of the
# `live` arm. It was firing thousands of times per run all along and only
# occasionally landing on a value that killed the process.
#
#   GCRY_INDEX_CACHE_UNCHECKED=1 restores both halves — the two-load read and
#   the unsynchronised invalidation — and takes `live` and `realloc` to **8 of
#   8**. Without that arm, "it does not crash any more" is not a measurement.
#
#   crystal build -Dgc_none bench/find_block_race.cr -o bin/find_block_race
#   bin/find_block_race
#   bin/find_block_race --child live

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "find_block_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS  =   4
ROUNDS   = 200
PER_ITER = 256
ARMS     = %w[alloc idle live realloc]

if ARGV.includes?("--child")
  arm = ARGV[ARGV.index("--child").not_nil! + 1]? || "live"
  heap = Gcry.default_heap
  stop = Atomic(Int32).new(0)
  threads = [] of Thread

  WORKERS.times do
    threads << Thread.new do
      probe = GC.malloc(64_u64)
      # Rooted, so the arms are about `find_block` and not about asking it for an
      # address whose chunk the sweep is releasing.
      heap.add_root(probe)
      scratch = GC.malloc(64_u64)
      while stop.get == 0
        case arm
        when "alloc"   then PER_ITER.times { GC.malloc(64_u64) }
        when "live"    then PER_ITER.times { heap.live?(probe) }
        when "realloc" then PER_ITER.times { scratch = GC.realloc(scratch, 64_u64) }
        else                Intrinsics.pause
        end
      end
      Gcry::Roots.keep_alive(scratch)
    end
  end

  ROUNDS.times { GC.collect }
  stop.set(1)
  threads.each(&.join)
  puts "arm=#{arm} survived index_cache_torn=#{heap.index_cache_torn} " \
       "index_unlocked_foreign=#{heap.index_unlocked_foreign}"
  exit 0
end

runs = (ENV["FIND_BLOCK_RACE_RUNS"]?.try(&.to_i?) || 4)
exe = Process.executable_path.not_nil!

puts "=== find_block race ==="
puts "#{WORKERS} threads, #{ROUNDS} collections, #{PER_ITER} calls per iteration, #{runs} runs per arm"
puts ""

failures = [] of String

def run_arm(exe : String, arm : String, runs : Int32, unchecked : Bool) : {Int32, String?}
  crashed = 0
  first = nil
  env = {"GCRY_INDEX_AUDIT" => "1"}
  env["GCRY_INDEX_CACHE_UNCHECKED"] = "1" if unchecked
  runs.times do
    captured = IO::Memory.new
    status = Process.run(exe, ["--child", arm], env: env, output: captured, error: captured)
    if status.success?
      first ||= captured.to_s.lines.find(&.starts_with?("arm="))
    else
      crashed += 1
    end
  end
  {crashed, first}
end

torn_seen = 0_u64
ARMS.each do |arm|
  crashed, line = run_arm(exe, arm, runs, false)
  puts "  %-8s crashed %d of %d%s" % [arm, crashed, runs,
                                      line ? "   #{line.sub("arm=#{arm} survived ", "")}" : ""]
  failures << "#{arm}: crashed #{crashed} of #{runs} — `find_block` from a mutator is not safe" if crashed > 0
  if line && (m = line.match(/index_cache_torn=(\d+)/))
    torn_seen += m[1].to_u64
  end
end

# The torn-read counter is what says the race is still *there* and being
# handled. A zero across every arm would mean this harness never reached the
# window, and the zeros above would be about nothing.
failures << "no torn cache read in any arm — the harness never reached the race, so its silence is not evidence" if torn_seen == 0

puts ""
puts "  restoring the old cache read (GCRY_INDEX_CACHE_UNCHECKED=1):"
%w[live realloc].each do |arm|
  crashed, _ = run_arm(exe, arm, runs, true)
  puts "  %-8s crashed %d of %d" % [arm, crashed, runs]
  if crashed == 0
    failures << "#{arm}: the old read was restored and nothing crashed, so the arms above " \
                "cannot be credited to the fix"
  end
end

puts ""
if failures.empty?
  puts "ok — a mutator inside `find_block` survives #{ROUNDS} collections, and the old read does not"
  exit 0
else
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
