# Multi-threaded allocation, cross-thread `GC.free` and concurrent
# collections against the occupancy claim (`bitmap_alloc.cr`, "Occupancy is
# claimed a word at a time").
#
# A cursor sets a word's `occ` bits when it takes the word and hands the
# blocks out with no shared write; a `free` on another thread clears bits of
# the same words, and a collection retires, pins or sweeps the cursors in
# between. The two failures that design must not have:
#
#   * a lost occupancy bit — a block handed out while its bit is clear, which
#     the next cursor on the chunk hands out again;
#   * a block handed out twice for any other reason.
#
# Both show here the same way: every block carries a stamp naming its owner
# and serial in its first two words and its last, and every owner re-reads
# its stamps — before it frees or passes a block on, on a full pass of its
# ring every few hundred operations, and at the end. A second owner's stamp,
# or the zeroing a non-atomic allocation does, breaks the first owner's. A
# legitimate free refused as a double free shows as `double_frees` moving,
# and lost or doubled accounting as walk-against-counter drift once the
# workers are joined.
#
# Workers run in a `Fiber::ExecutionContext::Parallel` context (one OS thread
# each), the main fiber collects every millisecond or two. Sizes span the
# small classes and two medium ones, atomic and not, so the hit path, the
# locked path, word advances and refills all run under the stops.
#
#   crystal build --release -Dgc_none bench/claim_stress.cr -o bin/claim_stress
#   bin/claim_stress [--seconds=5] [--workers=4] [--seed=1] [--ring=512]
#
# `GCRY_DISABLE_LAZY_SWEEP=1` moves the sweep into the stop, where it sweeps
# the chunks of a set the stop froze mid-allocation, with that set's claim
# marked by the settle; with the default lazy sweep those chunks are skipped.
# Run both. Exit 0 when every stamp held and nothing drifted, 1 otherwise.

require "../src/gcry"
require "wait_group"

{% unless flag?(:gc_none) %}
  raise "claim_stress requires -Dgc_none (gcry as the process GC, with stops)"
{% end %}

seconds = 5.0
workers = 4
seed = 1_i64
ring_size = 512

ARGV.each do |arg|
  case arg
  when /\A--seconds=([\d.]+)\z/ then seconds = $1.to_f
  when /\A--workers=(\d+)\z/    then workers = $1.to_i
  when /\A--seed=(\d+)\z/       then seed = $1.to_i64
  when /\A--ring=(\d+)\z/       then ring_size = $1.to_i
  else
    STDERR.puts "unknown argument #{arg}"
    exit 64
  end
end

CLAIM_STRESS_MAGIC = 0x5EED_C1A1_0CC0_0001_u64
# Small classes on both sides of every word-boundary case, and two medium
# classes whose chunks hold a word or less.
CLAIM_STRESS_SIZES = [16, 24, 32, 48, 64, 96, 128, 200, 256, 400, 512, 1000, 2048, 3000, 6000]

# What crosses threads: the block, its size and its stamp.
alias ClaimStressBlock = {Void*, UInt64, UInt64}

class ClaimStress
  getter errors = Atomic(Int32).new(0)
  getter ops = Atomic(UInt64).new(0)
  getter allocs = Atomic(UInt64).new(0)
  getter local_frees = Atomic(UInt64).new(0)
  getter remote_frees = Atomic(UInt64).new(0)
  getter drops = Atomic(UInt64).new(0)
  getter checks = Atomic(UInt64).new(0)
  @messages = [] of String
  @messages_lock = Mutex.new

  def initialize(@workers : Int32, @ring_size : Int32, @deadline : Time::Instant)
    @inboxes = Array(Channel(ClaimStressBlock)).new(@workers) { Channel(ClaimStressBlock).new(1024) }
    @running = Atomic(Bool).new(true)
  end

  def running? : Bool
    @running.get && Time.instant < @deadline
  end

  def stop : Nil
    @running.set(false)
  end

  def inbox(i : Int32) : Channel(ClaimStressBlock)
    @inboxes[i]
  end

  def record(msg : String) : Nil
    @errors.add(1)
    @messages_lock.synchronize { @messages << msg if @messages.size < 40 }
  end

  def messages : Array(String)
    @messages_lock.synchronize { @messages.dup }
  end

  def self.stamp(ptr : Void*, size : UInt64, id : UInt64) : Nil
    w = ptr.as(UInt64*)
    w[0] = CLAIM_STRESS_MAGIC ^ id
    w[1] = id
    w[(size // 8) - 1] = ~id if size >= 24
  end

  def check(ptr : Void*, size : UInt64, id : UInt64, where : String) : Bool
    @checks.add(1)
    w = ptr.as(UInt64*)
    ok = w[0] == (CLAIM_STRESS_MAGIC ^ id) && w[1] == id && (size < 24 || w[(size // 8) - 1] == ~id)
    unless ok
      last = size >= 24 ? w[(size // 8) - 1] : 0_u64
      record("#{where}: block #{ptr} (#{size} B, owner #{id >> 40}, serial #{id & 0xFF_FFFF_FFFF}) " \
             "reads 0x#{w[0].to_s(16)} 0x#{w[1].to_s(16)} last 0x#{last.to_s(16)}; " \
             "live?=#{Gcry.default_heap.live?(ptr)} " \
             "block=#{Gcry.default_heap.debug_block_info(ptr)}")
    end
    ok
  end

  def worker(wid : Int32, rng : Random) : Nil
    ptrs = Array(Void*).new(@ring_size, Pointer(Void).null)
    sizes = Array(UInt64).new(@ring_size, 0_u64)
    ids = Array(UInt64).new(@ring_size, 0_u64)
    serial = 0_u64
    inbox = @inboxes[wid]
    n = 0
    while running?
      i = rng.rand(@ring_size)
      unless ptrs[i].null?
        if check(ptrs[i], sizes[i], ids[i], "worker #{wid} before release")
          case rng.rand(3)
          when 0
            @drops.add(1)
          when 1
            GC.free(ptrs[i])
            @local_frees.add(1)
          else
            peer = rng.rand(@workers)
            peer = (peer + 1) % @workers if peer == wid && @workers > 1
            select
            when @inboxes[peer].send({ptrs[i], sizes[i], ids[i]})
            else
              GC.free(ptrs[i])
              @local_frees.add(1)
            end
          end
        end
        ptrs[i] = Pointer(Void).null
      end

      size = CLAIM_STRESS_SIZES[rng.rand(CLAIM_STRESS_SIZES.size)].to_u64
      ptr = rng.rand(2) == 0 ? GC.malloc(size) : GC.malloc_atomic(size)
      serial &+= 1
      id = (wid.to_u64 << 40) | serial
      ClaimStress.stamp(ptr, size, id)
      ptrs[i] = ptr
      sizes[i] = size
      ids[i] = id
      @allocs.add(1)

      # Frees passed from other workers: the owner of the claim on the
      # block's word is someone else, or no one any more.
      loop do
        select
        when blk = inbox.receive
          p, s, d = blk
          GC.free(p) if check(p, s, d, "worker #{wid} receiving")
          @remote_frees.add(1)
        else
          break
        end
      end

      n += 1
      if n % 256 == 0
        @ring_size.times do |j|
          check(ptrs[j], sizes[j], ids[j], "worker #{wid} ring pass") unless ptrs[j].null?
        end
        Fiber.yield
      end
      @ops.add(1)
    end
    @ring_size.times do |j|
      check(ptrs[j], sizes[j], ids[j], "worker #{wid} final") unless ptrs[j].null?
    end
  rescue ex
    record("worker #{wid}: #{ex.class}: #{ex.message}")
    stop
  end

  # The walk against the counter at a quiescent point: read until two
  # readings 10 ms apart agree (a runtime thread may be allocating), as
  # `bench/counter_loss.cr` does.
  def self.settled_drift(& : -> Int64?) : Int64?
    last = nil
    100.times do
      d = yield
      return d if d && d == last
      last = d
      sleep 10.milliseconds
    end
    last
  end
end

heap = Gcry.default_heap
unless heap.stop_the_world && heap.bitmap_alloc?
  STDERR.puts "claim_stress: needs the process heap with stops and the bitmap allocator"
  exit 64
end

puts "claim_stress seconds=#{seconds} workers=#{workers} seed=#{seed} ring=#{ring_size} " \
     "lazy_sweep=#{heap.lazy_sweep} headers=#{{{ flag?(:gcry_block_headers) }}}"

double_frees = heap.double_frees
released = heap.cursor_claims_released
pinned = heap.cursor_sets_pinned
collections = heap.collections
deadline = Time.instant + seconds.seconds
test = ClaimStress.new(workers, ring_size, deadline)
ctx = Fiber::ExecutionContext::Parallel.new("claim-stress", workers)
wg = WaitGroup.new(workers)
workers.times do |w|
  wid = w
  rng = Random.new(seed &* 7919 &+ wid)
  ctx.spawn do
    test.worker(wid, rng)
  ensure
    wg.done
  end
end

rng = Random.new(seed)
while test.running?
  GC.collect
  sleep (rng.rand(2000) + 200).microseconds
end
test.stop
wg.wait

# Whatever is still in flight between workers is checked and freed here.
workers.times do |w|
  loop do
    select
    when blk = test.inbox(w).receive
      p, s, d = blk
      GC.free(p) if test.check(p, s, d, "main draining")
    else
      break
    end
  end
end

3.times { GC.collect }
# Chunks the index knows and the chunk list does not. The walks below read
# the list, so a chunk that fell off it takes its blocks out of the walk and
# leaves them in the counters. The in-stop sweep of a multi-mutator heap
# (`GCRY_DISABLE_LAZY_SWEEP=1`) lost chunks this way until 272d73e5
# (process_spec/regression/75); this harness found it, on the tree before the
# claim too (`bench/log/linux/2026-10-17-occupancy-claim/FINDINGS.md`). Any
# such chunk now fails the run, and so does any drift. The set is sized up
# front: an allocation inside either walk can map a chunk the walk has passed.
listed = Set(UInt64).new(initial_capacity: 1 << 16)
heap.each_chunk { |c| listed << c.address }
unlisted = 0
heap.each_indexed_chunk { |c| unlisted += 1 unless listed.includes?(c.address) }
live_drift = ClaimStress.settled_drift { Gcry::Invariant.live_objects_drift(heap) }
free_drift = ClaimStress.settled_drift { Gcry::Invariant.free_bytes_drift(heap) }
refused = heap.double_frees - double_frees

puts "  ops=#{test.ops.get} allocs=#{test.allocs.get} local_frees=#{test.local_frees.get} " \
     "remote_frees=#{test.remote_frees.get} drops=#{test.drops.get} checks=#{test.checks.get}"
puts "  collections=#{heap.collections - collections} claims_released=#{heap.cursor_claims_released - released} " \
     "sets_pinned=#{heap.cursor_sets_pinned - pinned} hits=#{heap.cursor_hit_allocations} " \
     "locked=#{heap.bitmap_locked_allocations}"
puts "  refused_frees=#{refused} live_objects_drift=#{live_drift.inspect} free_bytes_drift=#{free_drift.inspect} " \
     "unlisted_chunks=#{unlisted}"

failed = test.errors.get > 0
if refused != 0
  STDERR.puts "  FAIL: #{refused} legitimate free(s) refused as double frees"
  failed = true
end
if live_drift != 0 || free_drift != 0
  STDERR.puts "  FAIL: walk against counter drifted (live #{live_drift.inspect}, free bytes #{free_drift.inspect})"
  failed = true
end
if unlisted != 0
  STDERR.puts "  FAIL: #{unlisted} chunk(s) indexed and not on the chunk list"
  failed = true
end
if test.remote_frees.get == 0 || heap.collections == collections
  STDERR.puts "  FAIL: the run did not exercise cross-thread frees and collections"
  failed = true
end
test.messages.each { |m| STDERR.puts "  ERROR: #{m}" }
if failed
  puts "RESULT: FAIL seed=#{seed}"
  exit 1
end
puts "RESULT: PASS"
