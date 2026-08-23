# Does a mutator ever read the chunk index without the lock?
#
# `Heap#chunk_containing` skips `@index_lock` while `@world_stopped` is set, on
# the grounds that only the collector can be reading the chunk index then. That
# is the assumption this gate holds it to, and until 2026-08-22 it was false:
# `start_world` resumed every thread and cleared the flag *after* the resume
# loop, so between those two points every mutator was running while the flag
# still said stopped — taking the unlocked path against an `index_insert` or
# `index_remove` from any peer that maps or unmaps a chunk. A binary search over
# an array that is being shifted under it yields a garbage `ChunkHeader*`, and
# the first thing done with that is `chunk.value.mapped_bytes`.
#
# This gate does not use TLAB: what it needs is a high rate of index lookups
# from mutator threads, and `Heap#live?` gives that directly without putting the
# harness at the mercy of the allocator's own limits. TLAB is how a *real*
# program gets that rate, which is why the crash is on that arm:
# `tlab_alloc_small` calls `find_block` on the allocation fast path to validate
# its freelist head, so a TLAB program is in `chunk_containing` constantly —
# 11.5 million unlocked lookups a run against 193 thousand without it. Both
# sightings of the unattributed crash are on the `--tlab --nursery` arm, and the
# Darwin one faults in exactly that call: `find_block` ← `tlab_alloc_small`.
#
#   default             no mutator may read the index unlocked. Requires 0.
#   GCRY_STW_LATE_CLEAR=1
#                       the old ordering. Requires **non-zero**, or the arm
#                       above is passing for a reason that is not the fix.
#
#   crystal build -Dgc_none bench/stw_index_race.cr -o bin/stw_index_race
#   bin/stw_index_race

require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "stw_index_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS =   4
ROUNDS  = 200

# ── Child: allocate hard on several threads while collections run ────────────
if ARGV.includes?("--child")
  heap = Gcry.default_heap
  stop = Atomic(Int32).new(0)
  threads = [] of Thread

  # `Heap#live?` goes straight through `find_block` → `chunk_containing`, which
  # is the call under test. Hammering it directly rather than through TLAB keeps
  # the harness out of the allocator's own limits — the point is the rate of
  # index lookups from mutator threads, and TLAB is only one way to get it.
  WORKERS.times do
    threads << Thread.new do
      probe = GC.malloc(64_u64)
      # Rooted: otherwise the collection frees it, releases its chunk, and the
      # lookups below are asking about an address the heap no longer owns —
      # which is a different question from the one this gate asks.
      heap.add_root(probe)
      req = LibC::Timespec.new(tv_sec: 0, tv_nsec: 50_000)
      while stop.get == 0
        16.times { heap.live?(probe) }
        LibC.nanosleep(pointerof(req), Pointer(LibC::Timespec).null)
      end
    end
  end

  ROUNDS.times { GC.collect }
  stop.set(1)
  threads.each(&.join)

  STDERR.puts "owner=#{heap.index_unlocked_owner} foreign=#{heap.index_unlocked_foreign} " \
              "foreign_id=0x#{heap.index_unlocked_foreign_id.to_s(16)}"
  exit 0
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
failures = [] of String

puts "=== STW chunk-index race ==="
puts "#{WORKERS} allocating threads, #{ROUNDS} collections per arm"

# TLAB is what puts `find_block` on the allocation fast path; the nursery is
# what makes the collections frequent. Same shape as the arm that crashes.
base = {"GCRY_INDEX_AUDIT" => "1"}

{"default" => {} of String => String, "late-clear" => {"GCRY_STW_LATE_CLEAR" => "1"}}.each do |arm, extra|
  env = base.merge(extra)
  result = BoundedChild.run(exe, ["--child"], env)
  text = result.output
  line = text.lines.find(&.starts_with?("owner="))
  unless line && result.ok
    failures << "#{arm}: the child did not report#{result.timed_out ? " (killed on the deadline)" : ""}. It said:\n#{text.lines.first(6).join("\n")}"
    next
  end
  fields = line.split(' ').to_h { |f| {f.split('=')[0], f.split('=')[1]} }
  owner = fields["owner"].to_u64
  foreign = fields["foreign"].to_u64
  puts "  %-11s unlocked reads: collector %d, other threads %d (last 0x%s)" %
       [arm, owner, foreign, fields["foreign_id"].lchop("0x")]

  # A zero on either side is only evidence if the path ran at all.
  if owner == 0
    failures << "#{arm}: the collector never took the unlocked path, so this arm never " \
                "exercised the window and its foreign count says nothing"
  end

  if arm == "default"
    if foreign > 0
      failures << "default: #{foreign} unlocked chunk-index read(s) by a thread that is not the " \
                  "collector, while the world was stopped — the lock skip is unsound"
    end
  else
    if foreign == 0
      failures << "late-clear: the old ordering produced no unlocked reads, so the arm above " \
                  "cannot be credited to the new one"
    end
  end
end

if failures.empty?
  puts
  puts "ok — with the flag cleared before the resume loop no mutator reads the index unlocked, " \
       "and with it cleared after they do"
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
