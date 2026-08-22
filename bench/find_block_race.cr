# `find_block` from a mutator thread, while collections run, crashes.
#
# Four threads, 200 collections, and one difference between the arms: whether
# the threads call `Heap#find_block` at all. Measured on x86_64 Linux —
#
#   alloc    256 `GC.malloc` per iteration ......... 0 of 8 runs crashed
#   idle     `Intrinsics.pause` .................... 0 of 8
#   live     256 `Heap#live?` per iteration ........ 5 of 8
#   realloc  256 `GC.realloc` per iteration ........ 5 of 8
#
# So it is not allocation rate and not thread count: it needs a mutator to be
# inside `find_block`. `live?` and `realloc` reach it by different routes and
# crash alike, which is what rules out one caller being at fault — `GC.realloc`
# is a supported public API and hammering it from four threads is not exotic.
#
# The crash is always the same shape: `ChunkHeader.large?(chunk)` on a chunk
# pointer that is not one (`0x91`, `0xa1`), i.e. `chunk_containing` handed back
# something impossible. That is the same function the unattributed CI crash
# faults in — `find_block` ← `tlab_alloc_small` — and TLAB is exactly what puts
# `find_block` on a real program's allocation fast path.
#
# **What is already ruled out**, each by measurement rather than argument:
#
#   * The `@world_stopped` window closed on 2026-08-22 (`stw-index-race`). Same
#     crash rate with the fix and with `GCRY_STW_LATE_CLEAR=1` restoring the old
#     ordering — 22 of 25 against 13 of 25 — and `GCRY_INDEX_AUDIT=1` reports
#     zero foreign unlocked reads in the fixed arm.
#   * The chunk index itself, as far as its own invariants go:
#     `GCRY_INDEX_AUDIT=1` validates every chunk the cache path and the search
#     path return, and checks the cached slot is inside the array. Zero
#     violations in the runs that survive.
#   * Anything introduced today: 6 of 8 at `daa994b`, before any of it.
#
# **Not a gate.** The defect is open, so this exits 0 whatever happens: a step
# expected to fail either blocks every pull request or teaches everyone to
# ignore a red mark. What it produces is a rate, per arm, per platform — which
# is the thing nobody has for this crash.
#
#   crystal build -Dgc_none bench/find_block_race.cr -o bin/find_block_race
#   bin/find_block_race              # parent: every arm, RUNS times each
#   bin/find_block_race --child live # one run of one arm

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
  puts "arm=#{arm} survived index_cache_bad=#{heap.index_cache_bad} " \
       "index_search_bad=#{heap.index_search_bad} index_cache_oob=#{heap.index_cache_oob} " \
       "index_unlocked_foreign=#{heap.index_unlocked_foreign}"
  exit 0
end

runs = (ENV["FIND_BLOCK_RACE_RUNS"]?.try(&.to_i?) || 8)
exe = Process.executable_path.not_nil!

puts "=== find_block race ==="
puts "#{WORKERS} threads, #{ROUNDS} collections, #{PER_ITER} calls per iteration, #{runs} runs per arm"
puts "NOT A GATE — the defect is open; this reports a rate (bench/find_block_race.cr)"
puts ""

ARMS.each do |arm|
  crashed = 0
  audits = [] of String
  runs.times do
    captured = IO::Memory.new
    status = Process.run(exe, ["--child", arm], env: {"GCRY_INDEX_AUDIT" => "1"},
      output: captured, error: captured)
    if status.success?
      if line = captured.to_s.lines.find(&.starts_with?("arm="))
        audits << line.strip
      end
    else
      crashed += 1
    end
  end
  puts "  %-8s crashed %d of %d" % [arm, crashed, runs]
  # The audit's silence is only worth something from a run that finished.
  if a = audits.first?
    puts "           %s" % a.sub("arm=#{arm} survived ", "")
  end
end

puts ""
puts "reported, not gated"
