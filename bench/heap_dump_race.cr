# The debug dumps walk the chunk list with the world running.
#
# `Gcry.dump_heap`, `Gcry.dump_heap_addresses` and `Gcry.live_attr_json` are
# documented API (`docs/API.md`). All three walk `@chunks` from whatever thread
# called them, holding nothing, dereferencing every chunk header and then every
# block inside it. The collector unmaps chunks from `flush_pending_empty_chunks`,
# `flush_pending_large_release` and `trim_large_cache` — all outside STW, all
# while that walk is in progress.
#
# It does not even need a second thread. The walks allocate as they go: a Hash
# insert per type id in `json_live_attr`, a String per line in `dump_heap`. That
# allocation can trigger a collection on the walking thread itself, which sweeps,
# unlinks and unmaps — and then returns to the walk, which steps onto what it
# just released.
#
#   dumper   Gcry.live_attr_json / dump_heap in a loop
#   workers  allocate and drop, hard enough to keep collections coming
#
# `GCRY_UNMAP_GUARD=1` keeps chunk identity so the report names what was hit.
#
#   crystal build -Dgc_none bench/heap_dump_race.cr -o bin/heap_dump_race
#   bin/heap_dump_race

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "heap_dump_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS =     3
ROUNDS  = 3_000
DUMPS   =   400

class Verdict
  @@done = Atomic(Int32).new(0)

  def self.finish
    @@done.add(1)
  end

  def self.finished
    @@done.get
  end
end

if ARGV.includes?("--child")
  heap = Gcry.default_heap

  # Live ballast so the walk has a long list to cross and real blocks to read.
  ballast = Array(Bytes).new(20_000)
  20_000.times { ballast << Bytes.new(192) }

  threads = [] of Thread
  WORKERS.times do
    threads << Thread.new do
      ROUNDS.times do
        # A mix: size-class churn plus large blocks, so the empty-chunk flush
        # and the large trim both have something to release.
        junk = Array(Bytes).new(64)
        64.times { junk << Bytes.new(128) }
        big = GC.malloc_atomic(40_u64 * 1024)
        big.as(UInt8*)[0] = 1_u8
        GC.free(big)
      end
      Verdict.finish
    end
  end

  dumper = Thread.new do
    io = IO::Memory.new
    n = 0
    while Verdict.finished < WORKERS && n < DUMPS
      Gcry.live_attr_json(heap, 8)
      io.clear
      Gcry.dump_heap(io, heap)
      n += 1
    end
    n
  end

  threads.each(&.join)
  dumper.join
  heap = Gcry.default_heap
  puts "child: ballast #{ballast.size} still_linked #{heap.released_chunks_still_linked} guard_overflows #{heap.guard_overflows}"
  exit 0
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["HEAP_DUMP_RACE_ATTEMPTS"]?.try(&.to_i?) || 6)

puts "=== debug dump vs. the collector's unmap ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds, one dumper, #{attempts} attempts"
puts ""

env = {"GCRY_UNMAP_GUARD" => "1", "GCRY_SEGV_REPORT" => "1", "GCRY_MOSTLY_EMPTY" => "1"}
bad = 0
note = nil
attempts.times do
  captured = IO::Memory.new
  status = Process.run(exe, ["--child"], env: env, output: captured, error: captured)
  unless status.success?
    bad += 1
    note ||= captured.to_s.lines.find { |l| l.includes?("gcry:") || l.includes?("Invalid memory access") }
  end
end

puts "  dumping:  #{bad} of #{attempts} failed#{note ? "\n     #{note.strip}" : ""}"
puts ""
if bad == 0
  puts "ok — the dumps and the collector's unmap did not collide"
  exit 0
else
  STDERR.puts "FAIL: a debug dump stepped onto a chunk the collector released"
  exit 1
end
