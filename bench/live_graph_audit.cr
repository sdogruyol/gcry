# What does the collector lose, and how?
#
# `bench/page_release_corruption.cr` established that turning on a page-release
# walk makes gcry free a chunk that still holds a live object — 9 of 80 runs
# with one of the two walks on, 0 of 40 with both off. What it could not say is
# *why*, because it checksums only leaf objects. Not one of those checksums ever
# failed. What went missing was the collector's path to a 2 MB buffer, not the
# buffer's contents, and a harness that verifies leaves cannot see a broken edge.
#
# So this one verifies the edges.
#
# Each worker builds a chain of `Node`s. A node holds a tag, a payload, and a
# reference to the next node — a real Crystal object graph, so every edge is one
# the collector has to trace. Alongside it, in `LibC.malloc` memory the
# collector never sees and never keeps alive, sits a shadow row per node: the
# node's address, its tag, its payload's address, and the payload's checksum.
#
# Each round the worker checks the graph against the shadow, and the shadow
# against raw memory. Three things can go wrong and they are reported apart,
# because they are three different defects:
#
#   BROKEN EDGE   the chain is shorter than the shadow, or a node's `nxt` is
#                 nil where the shadow says a node stands. The collector lost an
#                 edge — or something zeroed it.
#   ZEROED        the node's memory reads as all zeros. A live page was
#                 released: `madvise(MADV_DONTNEED)` on a page a live object sits
#                 on, which is the hazard the walks were suspected of.
#   REUSED        the node's memory changed and is *not* zeros. The object was
#                 freed and its block handed to someone else — a false free, a
#                 different defect with a different fix.
#
# Telling ZEROED from REUSED is the whole point. Both look like corruption from
# a distance and they come from opposite ends of the collector.
#
#   default (no walk)             must be clean
#   GCRY_PAGE_DONTNEED=1          the HOLED walk, MADV_DONTNEED
#   GCRY_MOSTLY_EMPTY=1 + DISABLE_PAGE_RELEASE=1   the sparse walk, MADV_FREE
#
#   crystal build -Dgc_none bench/live_graph_audit.cr -o bin/live_graph_audit
#   bin/live_graph_audit
require "../src/gcry"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "live_graph_audit requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS =   4
ROUNDS  = 130
# Long enough that the chain spans many chunks, short enough that a full verify
# each round stays cheap next to the churn that drives collections.
CHAIN   = 1500
PAYLOAD =   96
# Garbage per round. This is what makes chunks go HOLED: allocate a lot, keep
# almost none, so whole page runs inside a live chunk fall free.
CHURN = 12000
# Garbage laid between consecutive chain nodes at build time. Without it the
# chain lands back to back in chunks that are entirely live, and the churn lands
# in chunks that end up entirely dead — one is never HOLED and the other goes
# down the empty-chunk path. See the comment where it is used.
SCATTER = 40
# Every LARGE_EVERY-th node carries a payload over the 32 KiB large-object
# threshold, so the graph has edges into the large path as well as the size
# classes. That matters: the false free this harness exists to explain took a
# 1 970 176-byte Array buffer, released through `cache_large_chunk` ->
# `trim_large_cache`. A graph made only of small objects has no edge that path
# can break.
LARGE_EVERY = 50
LARGE_SIZE  = 40 * 1024
# Large payloads are checksummed over a prefix only. Summing 40 KiB × 30 nodes ×
# 130 rounds × 4 workers is minutes of byte comparison for no extra reach: a
# released page or a reissued block shows up in the first bytes as readily as
# the last, and the payload's *address* is checked in full either way.
LARGE_SUM_PREFIX = 512
# Room for the runtime's own threads, shadowed the same way the graph is.
RUNTIME_SLOTS = 64

# Diagnostics from a bare `Thread` cannot go through `STDERR`. Crystal's IO
# reaches for the current execution context and a thread started with
# `Thread.new` has none, so the first write raises
# `Thread#execution_context cannot be nil` — which killed every child of this
# harness for a stretch, silently, because the hunt was grepping for a segfault
# and this is not one. `write(2)` needs none of that machinery.
def raw_puts(line : String) : Nil
  s = line + "\n"
  LibC.write(2, s.to_unsafe.as(Void*), LibC::SizeT.new(s.bytesize))
end

class Node
  property nxt : Node?
  property payload : Bytes
  property tag : UInt64

  def initialize(@tag : UInt64, @payload : Bytes)
    @nxt = nil
  end
end

# One shadow row per node, in memory gcry does not manage and cannot trace.
# Keeping it outside the heap matters twice: the collector's view of what is
# reachable stays exactly what it would be without this harness, and the rows
# survive whatever happens to the heap.
struct Shadow
  property node_addr : UInt64
  property tag : UInt64
  property payload_addr : UInt64
  property payload_sum : UInt64
  property payload_size : UInt64

  def initialize(@node_addr : UInt64, @tag : UInt64, @payload_addr : UInt64, @payload_sum : UInt64,
                 @payload_size : UInt64)
  end
end

def fill(b : Bytes, seed : UInt64) : UInt64
  sum = 0_u64
  i = 0
  while i < b.size
    v = ((seed &* 1103515245_u64 &+ i) >> 7).to_u8!
    b[i] = v
    sum = sum &* 31 &+ v
    i += 1
  end
  sum
end

def sum_of(b : Bytes) : UInt64
  sum = 0_u64
  i = 0
  while i < b.size
    sum = sum &* 31 &+ b[i]
    i += 1
  end
  sum
end

# Is every byte of the object's first `words` machine words zero? A released
# page reads back as zeros; a reused block almost never does.
def all_zero?(addr : UInt64, words : Int32) : Bool
  p = Pointer(UInt64).new(addr)
  i = 0
  while i < words
    return false if p[i] != 0
    i += 1
  end
  true
end

class Verdict
  @@edge = Atomic(Int32).new(0)
  @@zeroed = Atomic(Int32).new(0)
  @@reused = Atomic(Int32).new(0)
  @@payload = Atomic(Int32).new(0)
  @@reported = Atomic(Int32).new(0)

  def self.edge!
    @@edge.add(1)
  end

  def self.zeroed!
    @@zeroed.add(1)
  end

  def self.reused!
    @@reused.add(1)
  end

  def self.payload!
    @@payload.add(1)
  end

  @@threadlist = Atomic(Int32).new(0)

  def self.threadlist!
    @@threadlist.add(1)
  end

  def self.threadlist
    @@threadlist.get
  end

  @@freed = Atomic(Int32).new(0)

  def self.freed!
    @@freed.add(1)
  end

  # Only the first few details, and only once each — a wedged run can produce
  # thousands and the interesting part is the first.
  def self.detail? : Bool
    @@reported.add(1) < 3
  end

  def self.line : String
    "edges #{@@edge.get} zeroed #{@@zeroed.get} reused #{@@reused.get} payload #{@@payload.get} " \
    "threadlist #{@@threadlist.get} freed #{@@freed.get}"
  end

  def self.bad? : Bool
    @@edge.get + @@zeroed.get + @@reused.get + @@payload.get + @@threadlist.get + @@freed.get > 0
  end
end

if ARGV.includes?("--child")
  threads = [] of Thread
  WORKERS.times do |w|
    threads << Thread.new do
      heap = Gcry.default_heap
      sweep = ENV["LIVE_GRAPH_SWEEP"]? != "0"
      tlprobe = ENV["LIVE_GRAPH_TLPROBE"]? != "0"
      runtime = Pointer(UInt64).new(LibC.malloc(LibC::SizeT.new(8 * RUNTIME_SLOTS)).address)
      runtime_seen = 0
      shadow = Pointer(Shadow).new(LibC.malloc(LibC::SizeT.new(sizeof(Shadow) * CHAIN)).address)
      root : Node? = nil
      seed = (w.to_u64 &+ 1) &* 2_654_435_761_u64

      # Build the chain, newest at the head, and shadow every node as it goes.
      #
      # The garbage between nodes is what makes this reach the walk at all. A
      # chain built back to back lands in chunks that are entirely live, and the
      # churn lands in chunks that end up entirely dead — one is never HOLED and
      # the other goes down the empty-chunk path. HOLED means a chunk with a few
      # survivors and whole free page runs between them, so the survivors have
      # to be laid down sparsely. Built without this, the harness released
      # 200 KB over six collections and would have called that clean.
      CHAIN.times do |i|
        SCATTER.times do
          filler = Bytes.new(PAYLOAD)
          filler[0] = 2_u8
        end
        large = (i % LARGE_EVERY) == 0
        payload = Bytes.new(large ? LARGE_SIZE : PAYLOAD)
        seed &+= 1
        psum = fill(payload, seed)
        psum = sum_of(payload[0, LARGE_SUM_PREFIX]) if large
        node = Node.new(seed, payload)
        node.nxt = root
        root = node
        shadow[i] = Shadow.new(
          node_addr: node.as(Void*).address,
          tag: seed,
          payload_addr: payload.to_unsafe.address,
          payload_sum: psum,
          payload_size: payload.size.to_u64)
      end

      # One line per worker naming where its large payloads live, so a crash
      # address can be matched against them afterwards instead of guessed at
      # from its low bits.
      # Every address this worker will ever touch, so a crash address can be
      # matched against them afterwards instead of guessed at from its low
      # bits. Two lines per worker rather than one per node: the point is to be
      # greppable after the fact, not readable during.
      #
      # Off by default (`LIVE_GRAPH_DUMP=1` enables it) because it is itself a
      # growing-buffer allocation of exactly the kind the ledger named as the
      # victim — a 76 KiB large chunk. A harness whose diagnostic might be the
      # thing being freed cannot answer whether it is.
      if ENV["LIVE_GRAPH_DUMP"]? == "1"
        big = String.build do |io|
          io << "shadow-nodes:"
          j = 0
          while j < CHAIN
            io << " " << shadow[j].node_addr
            j += 1
          end
        end
        raw_puts(big)
        big = String.build do |io|
          io << "shadow-payloads:"
          j = 0
          while j < CHAIN
            io << " " << shadow[j].payload_addr << "+" << shadow[j].payload_size
            j += 1
          end
        end
        raw_puts(big)
      end

      ROUNDS.times do
        gone = false
        # The runtime's own long-lived objects. These are shadowed like the
        # graph is, and for the same reason: walking `Thread.unsafe_each`
        # dereferences every `Thread` the runtime holds, and if one of them is
        # in a chunk that has been released, the walk faults inside this proc
        # with nothing to show. Recording their addresses on the first round
        # and asking the heap about them before walking turns that into a
        # report naming the object.
        # `LIVE_GRAPH_TLPROBE=0` removes this probe. `Thread.unsafe_each` walks
        # a `Thread::LinkedList`, and the list's *own nodes* are heap objects
        # this harness never shadows — the one thing the worker touches that a
        # shadow miss cannot explain. If the crash needs this walk, the victim
        # is the runtime's thread-list machinery, which is also what the `0x18`
        # crashes point at.
        if tlprobe && runtime_seen == 0
          Thread.unsafe_each do |t|
            if runtime_seen < RUNTIME_SLOTS
              runtime[runtime_seen] = t.as(Void*).address
              runtime_seen += 1
            end
          end
        elsif tlprobe
          k = 0
          while sweep && k < runtime_seen
            unless heap.address_in_live_chunk?(runtime[k])
              Verdict.freed!
              raw_puts("  runtime Thread object #{k} at #{runtime[k]} is in no live chunk — the " \
                       "collector released a thread the runtime still holds") if Verdict.detail?
              gone = true
            end
            k += 1
          end
        end
        next if gone

        #
        # `stop_world` calls `Thread.lock`, which is `threads.@mutex.lock` over
        # `@@threads = uninitialized Thread::LinkedList(Thread)`. Both crashes
        # this harness produces are that base reading zero — a fault at exactly
        # `0x18`. By the time the collector hits it the round it happened in is
        # long gone. `Thread.unsafe_each` goes through `@@threads.try`, so it
        # reports the same emptiness without faulting, and it reports it here.
        seen = 0
        Thread.unsafe_each { seen += 1 } if tlprobe
        if tlprobe && seen == 0
          Verdict.threadlist!
          raw_puts("  the thread list is empty — Thread.@@threads read null") if Verdict.detail?
        end

        # Churn: allocate and drop, so chunks holding the chain go sparse and
        # whole page runs inside them fall free.
        CHURN.times do
          junk = Bytes.new(PAYLOAD)
          junk[0] = 1_u8
        end

        # 0. Before touching anything: is every address the shadow knows about
        #    still inside a chunk this heap has mapped? This asks the heap
        #    rather than the memory, so a released chunk becomes a report with
        #    an index, a kind and a size attached instead of a segfault with
        #    nothing attached. Without this pass the run dies inside the walk
        #    below and takes its own findings with it.
        # `LIVE_GRAPH_SWEEP=0` turns this pass off. It is not a convenience:
        # the sweep asks the heap 3000 times a round per worker and every ask
        # takes `@index_lock`, which is enough mutator-side synchronisation to
        # change the timing of the very race it was added to describe. Whether
        # it does is a measurement, not a guess — run both ways.
        i = 0
        while sweep && i < CHAIN
          row = shadow[i]
          unless heap.address_in_live_chunk?(row.node_addr)
            Verdict.freed!
            raw_puts("  node #{i} at #{row.node_addr} is in no live chunk — released while the " \
                     "chain still pointed at it") if Verdict.detail?
            gone = true
          end
          unless heap.address_in_live_chunk?(row.payload_addr)
            Verdict.freed!
            raw_puts("  payload of node #{i} at #{row.payload_addr} (#{row.payload_size} B, " \
                     "#{row.payload_size > 32768 ? "large" : "size-class"}) is in no live chunk") if Verdict.detail?
            gone = true
          end
          i += 1
        end
        # Nothing below is safe to read once an address is gone, and the point
        # has already been made.
        next if gone

        # 1. Walk the graph the way the collector has to: edge by edge. The
        #    shadow rows are in reverse build order, so row CHAIN-1-i is the
        #    node i hops from the head.
        cursor = root
        hops = 0
        while node = cursor
          row = shadow[CHAIN - 1 - hops]
          if node.as(Void*).address != row.node_addr
            Verdict.edge!
            raw_puts("  hop #{hops}: chain reached #{node.as(Void*).address} where the shadow " \
                     "says #{row.node_addr}") if Verdict.detail?
            break
          end
          if node.tag != row.tag
            Verdict.reused!
            raw_puts("  hop #{hops}: tag #{node.tag} where the shadow says #{row.tag}") if Verdict.detail?
          end
          if node.payload.to_unsafe.address != row.payload_addr
            Verdict.edge!
            raw_puts("  hop #{hops}: payload moved to #{node.payload.to_unsafe.address} from " \
                     "#{row.payload_addr}") if Verdict.detail?
          else
            got = node.payload.size > LARGE_SUM_PREFIX ? sum_of(node.payload[0, LARGE_SUM_PREFIX]) : sum_of(node.payload)
            if got != row.payload_sum
              Verdict.payload!
              raw_puts("  hop #{hops}: payload at #{row.payload_addr} (#{node.payload.size} B) " \
                       "checksums #{got} not #{row.payload_sum}") if Verdict.detail?
            end
          end
          hops += 1
          cursor = node.nxt
        end

        if hops != CHAIN
          Verdict.edge!
          raw_puts("  chain walked #{hops} of #{CHAIN} nodes — an edge is gone") if Verdict.detail?
        end

        # 2. And now the part the graph walk cannot do: reach every node by the
        #    address it had, whether or not anything still points at it. A node
        #    the collector dropped is still at that address; what is *in* it is
        #    the evidence.
        i = 0
        while i < CHAIN
          row = shadow[i]
          # Ask before reading. A node whose chunk has been released is the
          # finding; dereferencing it turns that finding into a segfault with
          # nothing attached, which is exactly what happened before this check
          # existed.
          unless heap.address_in_live_chunk?(row.node_addr)
            Verdict.freed!
            raw_puts("  node #{row.node_addr} is in no live chunk — its chunk was released " \
                     "while the chain still pointed at it") if Verdict.detail?
            i += 1
            next
          end
          revived = Pointer(Void).new(row.node_addr).as(Node)
          if revived.tag != row.tag
            if all_zero?(row.node_addr, 4)
              Verdict.zeroed!
              raw_puts("  node #{row.node_addr} reads as zeros — a live page was released") if Verdict.detail?
            else
              Verdict.reused!
              raw_puts("  node #{row.node_addr} holds #{revived.tag} not #{row.tag} — the block " \
                       "was handed out again") if Verdict.detail?
            end
          end
          i += 1
        end
      end

      # Keep the chain alive to the very end: without this the tail is garbage
      # halfway through and the audit is auditing nothing. `raw_puts` rather
      # than `STDERR` for the same reason as everything else in this thread.
      raw_puts("") if root.nil?
    end
  end
  threads.each(&.join)

  # Same reason as `page_release_corruption`: a run that never marks a chunk
  # HOLED releases nothing, and its silence is about nothing.
  heap = Gcry.default_heap
  puts "child: #{Verdict.line} dontneed #{heap.dontneed_bytes} collections #{heap.collections} " \
       "range_rejects #{heap.madvise_range_rejects} realloc_overlaps #{heap.realloc_collect_overlaps}"
  exit(Verdict.bad? ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["LIVE_GRAPH_ATTEMPTS"]?.try(&.to_i?) || 6)

puts "=== live graph audit ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds, chain of #{CHAIN}, #{CHURN} dropped per round"
puts "#{attempts} attempts per arm"
puts ""

ARMS = {
  "no walk"      => {"GCRY_DISABLE_MADVISE" => "1"},
  "HOLED"        => {"GCRY_PAGE_DONTNEED" => "1"},
  "mostly-empty" => {"GCRY_MOSTLY_EMPTY" => "1", "GCRY_DISABLE_PAGE_RELEASE" => "1"},
}

failures = [] of String
results = {} of String => Tuple(Int32, Int32, String?)
releases = {} of String => UInt64

ARMS.each do |name, env|
  bad = 0
  hung = 0
  released = 0_u64
  first = nil
  attempts.times do
    result = BoundedChild.run(exe, ["--child"], env.to_h, 300.seconds)
    unless result.ok
      bad += 1
      hung += 1 if result.timed_out
      first ||= result.output.lines.find { |l| l.includes?("zeros") || l.includes?("handed out") ||
        l.includes?("edge is gone") || l.includes?("Invalid memory access") }
    end
    if m = result.output.match(/dontneed (\d+)/)
      released += m[1].to_u64
    end
  end
  results[name] = {bad, hung, first}
  releases[name] = released
  puts "  %-13s %d of %d, released %d B%s%s" % [name, bad, attempts, released,
                                                hung > 0 ? " (#{hung} killed on the deadline)" : "",
                                                first ? "\n     #{first.strip}" : ""]
end

puts ""

no_walk = results["no walk"][0]
failures << "the no-walk arm failed #{no_walk} of #{attempts} — this harness breaks without either " \
            "release walk, so it is not measuring them" if no_walk > 0

# An engaged walk releases orders of magnitude more than the dormant flush the
# control arm still does, so the floor is the control and never zero.
floor = {releases["no walk"] * 4, 8_u64 * 1024 * 1024}.max
["HOLED", "mostly-empty"].each do |arm|
  failures << "#{arm} released #{releases[arm]} B against a #{releases["no walk"]} B control — the " \
              "walk did not run, so a clean result says nothing about it" if releases[arm] <= floor
end

if failures.empty? && results["HOLED"][0] == 0 && results["mostly-empty"][0] == 0
  puts "ok — every edge and every node survived both release walks"
  exit 0
end

results.each do |name, (bad, _hung, _first)|
  failures << "#{name}: #{bad} of #{attempts}" if bad > 0 && name != "no walk"
end
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
