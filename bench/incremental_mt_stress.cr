# Incremental collection under several mutator threads is unsound today.
#
# Multi-thread allocation stress (from the PR #34 review): every block
# carries {tag, ~tag} in its first 16 bytes and the tag again in its last
# word; blocks are freed cross-thread, realloc'd, and one fiber forces
# collections. On a default build it runs clean; with `GCRY_INCREMENTAL=1`
# (auto slices) or `INC=1` (explicit `GC.collect_a_little`) and four workers
# under `-Dpreview_mt -Dexecution_context` it dies in seconds - SIGSEGV at
# 0x0 / 0x18 / a heap address, or CORRUPT (a block reissued while held).
# EC1 with the same knob, and MT with one worker, run clean: the failure
# needs incremental slices *and* a second mutator. Reproduced on 0.23.0,
# 3 of 3, both allocators. The fix is the write barrier on the roadmap;
# until then the knob is documented as unsound under MT.
#
#   crystal build -Dgc_none -Dpreview_mt -Dexecution_context bench/incremental_mt_stress.cr -o bin/incremental_mt_stress
#   W=4 SECS=8 bin/incremental_mt_stress                       # clean
#   GCRY_INCREMENTAL=1 W=4 SECS=8 bin/incremental_mt_stress    # dies
{% unless flag?(:gc_none) %}
  {% raise "incremental_mt_stress requires -Dgc_none (gcry as process GC)" %}
{% end %}

require "../src/gcry"

# Multi-thread hit-path stress: every block carries {tag, ~tag} in its first
# 16 bytes; a mismatch on verify means another owner wrote it (double
# allocation) or the sweep reclaimed and reissued it (live block reclaimed).
# Blocks are freed cross-thread (channel) and realloc'd; one thread forces
# collections.

WORKERS = (ENV["W"]? || "4").to_i
SECS    = (ENV["SECS"]? || "20").to_f
RING    = 512

record Blk, ptr : Void*, size : Int32, tag : UInt64

class Worker
  getter checked = 0_u64
  getter allocs = 0_u64
  getter reallocs = 0_u64
  getter xfrees = 0_u64
  getter bad = 0_u64

  def initialize(@id : Int32, @inbox : Channel(Blk), @peers : Array(Channel(Blk)))
    @ring = Array(Blk?).new(RING, nil)
    @seq = 0_u64
    @rng = Random.new(@id)
  end

  def tag_for(seq : UInt64) : UInt64
    (@id.to_u64 << 56) | seq
  end

  def stamp(p : Void*, size : Int32, tag : UInt64)
    w = p.as(UInt64*)
    w[0] = tag
    w[1] = ~tag
    if size >= 24
      last = (p.as(UInt8*) + size - 8).as(UInt64*)
      last.value = tag
    end
  end

  def verify(b : Blk)
    w = b.ptr.as(UInt64*)
    last = (b.ptr.as(UInt8*) + b.size - 8).as(UInt64*)
    @checked += 1
    if w[0] != b.tag || w[1] != ~b.tag || (b.size >= 24 && last.value != b.tag)
      @bad += 1
      STDERR.puts "CORRUPT worker=#{@id} ptr=#{b.ptr} size=#{b.size} want=#{b.tag.to_s(16)} got=#{w[0].to_s(16)}/#{(~w[1]).to_s(16)}/#{last.value.to_s(16)}"
    end
  end

  def pick_size : Int32
    case @rng.rand(10)
    when 0, 1, 2, 3 then 16 + @rng.rand(240)
    when 4, 5       then 256 + @rng.rand(1792)
    when 6, 7       then 2049 + @rng.rand(6144)
    when 8          then 8193 + @rng.rand(8192)
    else                 16385 + @rng.rand(16384)
    end
  end

  def run(deadline : Time::Span)
    until Time.monotonic > deadline
      64.times do
        loop do
          select
          when b = @inbox.receive
            verify(b)
            GC.free(b.ptr)
            @xfrees += 1
          else
            break
          end
        end
        size = pick_size
        atomic = @rng.rand(2) == 0
        p = atomic ? GC.malloc_atomic(size) : GC.malloc(size)
        @seq += 1
        tag = tag_for(@seq)
        stamp(p, size, tag)
        @allocs += 1
        slot = @rng.rand(RING)
        if old = @ring[slot]
          verify(old)
          case @rng.rand(5)
          when 0
            nsize = old.size + 16 + @rng.rand(4096)
            np = GC.realloc(old.ptr, nsize)
            verify(Blk.new(np, old.size, old.tag))
            stamp(np, nsize, old.tag)
            @ring[slot] = Blk.new(np, nsize, old.tag)
            @reallocs += 1
            @peers[@rng.rand(@peers.size)].send(Blk.new(p, size, tag))
            next
          when 1
            @peers[@rng.rand(@peers.size)].send(old)
          when 2
            GC.free(old.ptr)
          else
          end
        end
        @ring[slot] = Blk.new(p, size, tag)
      end
    end
    @ring.each { |b| verify(b) if b }
  end
end

inboxes = Array.new(WORKERS) { Channel(Blk).new(1 << 18) }
workers = Array.new(WORKERS) { |i| Worker.new(i, inboxes[i], inboxes) }
deadline = Time.monotonic + SECS.seconds
done = Channel(Nil).new

{% if flag?(:execution_context) %}
  ctx = Fiber::ExecutionContext::Parallel.new("w", WORKERS)
  workers.each do |w|
    ctx.spawn { w.run(deadline); done.send(nil) }
  end
{% else %}
  workers.each do |w|
    spawn { w.run(deadline); done.send(nil) }
  end
{% end %}

spawn do
  n = 0
  inc = ENV["INC"]? == "1"
  until Time.monotonic > deadline
    if inc
      GC.collect_a_little
      sleep 1.milliseconds
    else
      GC.collect
      sleep 5.milliseconds
    end
    n += 1
  end
  STDERR.puts "forced collections: #{n}"
end

WORKERS.times { done.receive }
total_bad = workers.sum(&.bad)
puts "workers=#{WORKERS} allocs=#{workers.sum(&.allocs)} reallocs=#{workers.sum(&.reallocs)} xfrees=#{workers.sum(&.xfrees)} checked=#{workers.sum(&.checked)} bad=#{total_bad}"
exit(total_bad == 0 ? 0 : 1)
