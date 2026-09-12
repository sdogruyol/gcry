# Does the after-world sweep's `occ[i] = mark[i]` erase fresh occupancy?
#
# It reads like it must. The bitmap sweep publishes occupancy with a
# whole-word store — a read-modify-write of a word the allocator writes with
# an atomic OR, from a mutator holding no lock. Between this pass reading
# `mark[i]` and storing it, a mutator could publish a block in that word and
# the store would erase it: one live block per race, and a chunk that then
# reads empty enough to release. That is the shape of the open "live large
# object released under load" item, and the comment at the store argued only
# that a *per-bit clear* would be worse, which is not the same claim.
#
# It does not happen, and this is the harness that says so. `in_flight` is a
# cursor slot's own answer to "which block am I handing out right now" — set
# before the occupancy store, cleared once the block is built, on both
# allocation paths. `GCRY_SWEEP_OCC_AUDIT=1` asks, per dead word, whether any
# slot points into a block this pass just called dead. That block would be
# occupied, live, unmarked and about to be returned to a caller.
#
# Recorded 2026-09-12 (`bench/log/linux/2026-09-12-sweep-occ-publish/`):
#
#   this harness          71 325 words published with mutators live, 12
#                         threads born per round, 120 rounds — in_flight 0,
#                         no kept block lost or overwritten
#   thread-churn-uaf      240 after-world sweeps per run, in_flight 0, while
#                         that harness's use-after-free still fired
#
# So the publish is sound, and it is sound for reasons that live in three
# other files: cursor sets are settled inside the stop (pinned if frozen
# mid-allocation, otherwise retired and forced back through the class lock),
# allocate-black gives every block handed out while `@collecting` a mark, and
# `@collecting` stays true through the whole post-STW section.
#
# This is not a gate: there is no arm of it that goes red, because there is no
# defect here to break on purpose. It is the instrument to re-run when the
# next sighting points at the sweep, so the question is answered in one
# command instead of an afternoon.
#
#   crystal build -Dgc_none bench/sweep_occ_race.cr -o bin/sweep_occ_race
#   GCRY_SWEEP_OCC_AUDIT=1 bin/sweep_occ_race

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "sweep_occ_race requires -Dgc_none (gcry as process GC)" %}
{% end %}

ROUNDS  = (ENV["ROUNDS"]?.try(&.to_i?) || 120)
THREADS = (ENV["THREADS"]?.try(&.to_i?) || 12)
# Small enough that a block and its neighbours share one bitmap word, which is
# the unit the publish stores: the erased bit and the surviving ones have to be
# in the same 64 blocks for the store to be able to lose anything.
PAYLOAD =   48
PER_THR = 4000
# Live blocks held through the collection, in a class variable the collector
# scans. Anything the sweep drops is a live object lost, not garbage.
KEPT = 4096

class Keeper
  @@slots = uninitialized StaticArray(Void*, KEPT)
  @@next = Atomic(Int32).new(0)

  def self.init : Nil
    i = 0
    while i < KEPT
      @@slots[i] = Pointer(Void).null
      i += 1
    end
  end

  def self.keep(p : Void*) : Nil
    @@slots[@@next.add(1).remainder(KEPT).abs] = p
  end

  def self.each(& : Void* ->) : Nil
    i = 0
    while i < KEPT
      p = @@slots[i]
      yield p unless p.null?
      i += 1
    end
  end
end

heap = Gcry.default_heap.not_nil!
Keeper.init

puts "=== does the after-world publish erase fresh occupancy? ==="
puts "#{ROUNDS} rounds × #{THREADS} threads born per round, #{PER_THR} × #{PAYLOAD} B each"
puts "audit: #{heap.sweep_occ_audit ? "on" : "OFF — set GCRY_SWEEP_OCC_AUDIT=1"}"
puts ""

lost = 0_u64
checked = 0_u64

ROUNDS.times do
  born = [] of Thread
  THREADS.times do
    born << Thread.new do
      n = 0
      while n < PER_THR
        p = GC.malloc(PAYLOAD)
        b = p.as(UInt8*)
        j = 4
        while j < PAYLOAD
          b[j] = 0x5c_u8
          j += 1
        end
        # A plausible type_id in the first word, so the root filter has no
        # reason to refuse the slot that holds it.
        p.as(Int32*).value = 0x7c
        Keeper.keep(p) if n.remainder(64) == 0
        n += 1
      end
    end
  end
  # The collection runs while those threads are being born and allocating.
  # Its sweep walks chunks after `start_world`, which is the window.
  GC.collect
  born.each(&.join)

  Keeper.each do |p|
    checked += 1
    unless heap.live?(p)
      lost += 1
      next
    end
    b = p.as(UInt8*)
    ok = p.as(Int32*).value == 0x7c
    j = 4
    while ok && j < PAYLOAD
      ok = false if b[j] != 0x5c_u8
      j += 1
    end
    lost += 1 unless ok
  end
end

puts "kept blocks checked:   #{checked}"
puts "lost or overwritten:   #{lost}"
puts "sweep_occ_in_flight:   #{heap.sweep_occ_in_flight}"
puts "sweep_occ_audit_words: #{heap.sweep_occ_audit_words}"
puts "sweep_cursor_pinned:   #{heap.sweep_cursor_pinned}"
puts "sweep_cursor_retired:  #{heap.sweep_cursor_retired}"
puts ""

if lost > 0
  puts "FAIL #{lost} of #{checked} live blocks were freed or overwritten while a"
  puts "slot the collector scans still held them."
  exit 1
end

if heap.sweep_occ_in_flight > 0
  puts "FAIL the after-world sweep called #{heap.sweep_occ_in_flight} block(s) dead while"
  puts "a cursor slot was mid-allocation inside them. Occupied, live, unmarked,"
  puts "and about to be handed to a caller — the publish is losing them."
  exit 1
end

if heap.sweep_occ_audit
  if heap.sweep_occ_audit_words == 0
    puts "INCONCLUSIVE — the audited pass never ran, so nothing here says anything"
    puts "about the publish. The after-world sweep needs the bitmap allocator and"
    puts "a lazy sweep; `GCRY_POISON_FREED=1` routes to the poisoning arm instead"
    puts "(which is audited too, and reports through the same counter)."
    exit 2
  end
  puts "ok — #{heap.sweep_occ_audit_words} words published with mutators live, and not one"
  puts "dead bit belonged to a block a cursor was mid-allocation inside."
else
  puts "ok — no kept block was lost, but without GCRY_SWEEP_OCC_AUDIT=1 this says"
  puts "nothing about the publish itself."
end
exit 0
