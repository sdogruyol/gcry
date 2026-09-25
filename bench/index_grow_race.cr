# Does growing the chunk index hand a stopped-world collector freed memory?
#
# It did. `index_ensure_cap` grew `@chunk_index` with `realloc`, which frees the
# old array before the growing thread stores the new pointer, and
# `chunk_containing` reads `@chunk_index` *unlocked* while the world is
# stopped. A mutator suspended between the two left the collector marking
# through a freed block for a whole collection: glibc has rewritten its first
# words (the tcache link, `block >> 12` under safe-linking, and key), so the
# lowest chunks' entries are garbage, the roots in them are not found, and
# their live objects are reclaimed — or a lookup dereferences the garbage and
# faults at `block >> 12` plus an offset. Seen as 13 pinned objects lost in one
# chunk (`stw_mt_property_test --tlab`, ~1 run in 900) and as the churn gate's
# out-of-span faults, and not understood until 2026-09-25.
#
# The window is two instructions wide and opens only when the index doubles,
# so this widens it: `GCRY_INDEX_GROW_TEST_STALL_MS` holds every growth at the
# point where the old array is about to stop being the one the index names,
# while the main thread collects back to back. One thread grows the heap to
# ~1300 chunks (seven doublings of the index), stamping every object; at the
# end every object must still be allocated and still carry its stamp.
#
#   shipped   allocate, copy, publish, then free — every run clean.
#   red       `GCRY_INDEX_GROW_FREE_FIRST=1`: the old array freed before the
#             new one is published, which is what `realloc` did whenever it
#             moved the block. At least one of five runs must lose objects or
#             fault, or this gate is not reaching the window and the shipped
#             arm's silence proves nothing. (Calling `realloc` itself made a red arm of 1 in
#             3: glibc grows in place when it can, and in place frees nothing.)
#
#   crystal build -Dgc_none bench/index_grow_race.cr -o bin/index_grow_race
#   bin/index_grow_race

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "index_grow_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

STAMP     = 0x1D6E_6A2C_0000_0000_u64
OBJ_BYTES =                      2048
HEAP_GOAL = 160_u64 * 1024 * 1024
STALL_MS  = "50"
# The red arm faults or loses objects in ~3 runs of 4 (6 of 8 measured at
# 50 ms): a stall-driven race, not a construction, so it must go red in at
# least one of RED_RUNS (all clean at that rate: ~0.1%). The shipped arm must
# be clean in every run.
RUNS     = 3
RED_RUNS = 5

if ARGV.includes?("--child")
  done = Atomic(Int32).new(0)
  result = Channel({Int32, Int32}).new(1)
  Fiber::ExecutionContext::Isolated.new("grower") do
    held = [] of Pointer(UInt64)
    heap = Gcry.default_heap
    while heap.heap_size < HEAP_GOAL
      # Atomic: the index lookups under test are the ones for the held
      # array's pointers, and an unscanned payload keeps each collection short.
      p = GC.malloc_atomic(OBJ_BYTES).as(UInt64*)
      p.value = STAMP | held.size.to_u64
      held << p
    end
    done.set(1)
    GC.collect
    lost = 0
    held.each_with_index do |p, i|
      next if heap.live?(p.as(Void*)) && p.value == (STAMP | i.to_u64)
      lost += 1
    end
    result.send({held.size, lost})
  end
  collections = 0
  while done.get == 0
    GC.collect
    collections += 1
  end
  objects, lost = result.receive
  puts "child: objects=#{objects} lost=#{lost} collections=#{collections}"
  exit lost == 0 ? 0 : 1
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
base = {"GCRY_INDEX_GROW_TEST_STALL_MS" => STALL_MS, "GCRY_POISON_FREED" => "1", "GCRY_SEGV_REPORT" => "1"}

puts "=== chunk index growth vs a stopped-world reader ==="
puts "#{RUNS} runs per arm, growth held #{STALL_MS} ms, heap grown to #{HEAP_GOAL >> 20} MiB while main collects"
puts ""

failures = [] of String
note = ->(r : BoundedChild::Result) {
  r.timed_out ? "killed on the deadline" : (r.output.lines.find(&.starts_with?("child:")) || r.output.lines.first? || "no output").strip
}

clean = 0
RUNS.times do
  r = BoundedChild.run(exe, ["--child"], base, 120.seconds)
  ok = r.ok && r.output.includes?("lost=0")
  clean += 1 if ok
  puts "  shipped: #{note.call(r)}"
end
failures << "shipped: #{RUNS - clean} of #{RUNS} runs lost objects or died while the index grew" if clean < RUNS

red = 0
RED_RUNS.times do
  r = BoundedChild.run(exe, ["--child"], base.merge({"GCRY_INDEX_GROW_FREE_FIRST" => "1"}), 120.seconds)
  red += 1 unless r.ok && r.output.includes?("lost=0")
  puts "  free-first: #{note.call(r)}"
end
if red == 0
  failures << "red arm: all #{RED_RUNS} free-first runs came out clean — the harness no longer reaches " \
              "the window, so the shipped arm's silence proves nothing"
end

puts ""
if failures.empty?
  puts "ok — growth publishes an intact array; freeing first went red in #{red} of #{RED_RUNS}"
else
  failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
