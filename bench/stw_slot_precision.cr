require "../src/gcry"
require "./bounded_child"

# What does a thread with no STW capture slot cost?
#
# Linux kept its capture table at a fixed 64 slots on the argument that the
# loss past it is **precision and not roots**: an uncovered thread's registers
# arrive in a signal `ucontext` that sits on its own stack, and the scan of that
# stack runs unclamped, so they are still walked. That half is true, and the
# `held` arm below checks it.
#
# The cost is the unclamped scan itself, and it is not small. With no recorded
# SP, `fiber_stack_sp_scan_low` finds none for that thread's own stack — a
# Crystal thread's main fiber's stack *is* its OS stack — so
# `fiber_stack_scan_top` falls back to `guard`, which is the whole 8 MiB
# mapping. Measured on a 20-core host, 98 threads, 8 collections:
#
#   table            capacity  no_slot  stacks from SP  from guard  per collection
#   growing (tip)         128        0             768           8        ~23-27 ms
#   pinned at 64           64      672             512         264      ~506-672 ms
#
# One stack per collection falls back even with the table grown — the
# collector's own running fiber — against 33 per collection when 34 threads have
# no slot, and the pause goes up about twentyfold. That is the whole reason this
# platform's table grows now
# (`bench/log/linux/2026-09-19-stw-slot-retention/FINDINGS.md`).
#
# **Retracted, in place:** the first version of this harness claimed the cost
# was *retention* — 34 unreachable blocks still allocated after three
# collections at 98 threads, zero at 62 — and attributed it to the uncovered
# threads' dead frames being scanned. It was lazy sweep.
# `GCRY_DISABLE_LAZY_SWEEP=1` reclaims all 96, with or without the capture
# slots, and the 34 was `98 - 64` by coincidence: the eager pass of one
# collection had simply not reached those chunks. The counters below replaced
# it because they are the mechanism and they do not move between runs.
#
# Three arms, each a bounded child:
#
#   grown    `THREADS` threads. No claim may be refused, and no parked stack may
#            fall back to the guard page beyond the collector's own fiber.
#   pinned   the same under `GCRY_STW_FIXED_SLOTS=1`, which holds the table at
#            the 64 slots that shipped. Claims must be refused and the fallback
#            must show up, or the arm above has no red direction.
#   held     `THREADS` threads under the same knob, each holding its block only
#            in its own stack. Every block must survive: the loss past the
#            capacity is supposed to be a wider scan, not a missing root.
#
#   crystal build -Dgc_none bench/stw_slot_precision.cr -o bin/stw_slot_precision
#   bin/stw_slot_precision
#   bin/stw_slot_precision --child=pinned

{% unless flag?(:gc_none) %}
  {% raise "stw_slot_precision requires -Dgc_none (gcry as process GC)" %}
{% end %}

module StwSlotPrecision
  THREADS     = 96
  COLLECTIONS =  8

  VICTIM_SIZE =                    96_u64
  FILL        =                   0xA5_u8
  KEY         = 0x9E37_79B9_7F4A_7C15_u64

  ARM_BUDGET = 180.seconds

  class Gate
    def initialize
      @flag = Atomic(Int32).new(0)
    end

    def set : Nil
      @flag.set(1)
    end

    def get : Int32
      @flag.get
    end
  end

  # Through a macro branch, not directly: `stw_fixed_slots?` exists only on the
  # platforms that grow the table, and this file still type-checks on the
  # others — the mistake that broke two Windows jobs when a harness reached a
  # Unix-only module.
  def self.pinned_table? : Bool
    {% if flag?(:linux) || flag?(:darwin) || flag?(:win32) %}
      Gcry::Platform.stw_fixed_slots?
    {% else %}
      false
    {% end %}
  end

  @[NoInline]
  def self.make_victim_hidden : UInt64
    ptr = GC.malloc(VICTIM_SIZE).as(UInt8*)
    i = 0_u64
    while i < VICTIM_SIZE
      ptr[i] = FILL
      i += 1
    end
    ptr.address ^ KEY
  end

  # The store and the load go through `@[NoInline]` calls on purpose. Written
  # the obvious way — `slots[97] = hidden ^ KEY`, `return slots[97] ^ KEY` —
  # LLVM folds both away to `return hidden`, nothing reaches the stack, and the
  # held arm measures nothing.
  @[NoInline]
  def self.stash(slot : UInt64*, value : UInt64) : Nil
    slot.value = value
  end

  @[NoInline]
  def self.park(stop : Gate) : Nil
    while stop.get == 0
      Thread.sleep(2.milliseconds)
    end
  end

  @[NoInline]
  def self.park_holding(hidden : UInt64, ready : Gate, stop : Gate, hold : Bool) : Nil
    slots = uninitialized UInt64[256]
    i = 0
    while i < 256
      stash(slots.to_unsafe + i, 0_u64)
      i += 1
    end
    stash(slots.to_unsafe + 97, hold ? hidden ^ KEY : 0_u64)
    ready.set
    park(stop)
    stash(slots.to_unsafe + 98, slots.to_unsafe[97])
  end

  def self.child(arm : String) : Int32
    heap = Gcry.default_heap.not_nil!
    hold = arm == "held"
    pinned = arm != "grown"
    want = THREADS

    if pinned && !pinned_table?
      STDERR.puts "arm #{arm} needs GCRY_STW_FIXED_SLOTS=1; without it it would measure the " \
                  "shipped growing table."
      return 64
    end
    if !pinned && pinned_table?
      STDERR.puts "arm #{arm} measures the growing table and GCRY_STW_FIXED_SLOTS=1 is set."
      return 64
    end

    puts "arm #{arm}: #{want} threads, #{pinned ? "table pinned at its initial size" : "growing table"}" \
         "#{hold ? ", each holding its block in its own stack" : ""}"

    ready = Array(Gate).new(want) { Gate.new }
    stop = Gate.new
    # A raw slice, not `Array(Atomic(UInt64))`: `Atomic` is a struct and
    # `Array#[]` returns a copy, so `hidden[i].set(h)` writes to a temporary.
    hidden = Slice(UInt64).new(want, 0_u64)
    threads = [] of Thread

    want.times do |i|
      threads << Thread.new do
        h = make_victim_hidden
        hidden[i] = h
        park_holding(h, ready[i], stop, hold)
      end
    end
    want.times do |i|
      while ready[i].get == 0
        Thread.sleep(1.millisecond)
      end
    end

    listed = 0
    Thread.unsafe_each { listed += 1 }

    GC.collect # warm: the first collection of a fresh heap is not the subject
    before_no_slot = heap.stw_capture_no_slot
    before_sp = heap.fiber_scan_from_sp
    before_guard = heap.fiber_scan_from_guard
    started = Time.instant
    COLLECTIONS.times { GC.collect }
    elapsed = Time.instant - started
    no_slot = heap.stw_capture_no_slot - before_no_slot
    from_sp = heap.fiber_scan_from_sp - before_sp
    from_guard = heap.fiber_scan_from_guard - before_guard
    capacity = heap.stw_slot_capacity

    stop.set
    threads.each(&.join)

    swept = 0
    damaged = 0
    want.times do |i|
      victim = Pointer(Void).new(hidden[i] ^ KEY)
      unless heap.live?(victim)
        swept += 1
        next
      end
      bytes = victim.as(UInt8*)
      j = 0_u64
      while j < VICTIM_SIZE
        if bytes[j] != FILL
          damaged += 1
          break
        end
        j += 1
      end
    end

    uncovered = listed > capacity ? listed - capacity : 0
    per_collect = (elapsed.total_milliseconds / COLLECTIONS).round(2)
    puts "  threads=#{listed} capacity=#{capacity} uncovered=#{uncovered} no_slot=#{no_slot}"
    puts "  fiber_from_sp=#{from_sp} fiber_from_guard=#{from_guard} " \
         "per_collect=#{per_collect}ms swept=#{swept}/#{want}"

    failures = [] of String

    if from_sp + from_guard == 0
      failures << "no parked fiber stack was scanned at all across #{COLLECTIONS} collections, " \
                  "so nothing below is about the capture table"
    end

    if hold
      # The claim that made the fixed table defensible: past the capacity the
      # scan gets wider, not absent.
      if swept != 0
        failures << "#{swept} of #{want} blocks were swept while the thread that allocated " \
                    "them held the only pointer, in its own stack, with the table pinned — " \
                    "an uncovered thread is supposed to be scanned conservatively, not skipped"
      end
      if damaged != 0
        failures << "#{damaged} block(s) were overwritten after the collections"
      end
    elsif pinned
      if no_slot == 0
        failures << "the pinned table refused no claim with #{want} threads, so the knob no " \
                    "longer holds it at its initial size and the grown arm has no red direction"
      end
      if from_guard <= COLLECTIONS
        failures << "#{from_guard} guard-page fallbacks across #{COLLECTIONS} collections with " \
                    "#{uncovered} thread(s) uncovered: a thread with no recorded SP must cost " \
                    "its stack the SP window, and that is the cost this gate exists to show"
      end
    else
      if no_slot != 0
        failures << "#{no_slot} claim(s) were refused with the table growing, so #{uncovered} " \
                    "thread(s) were suspended with no SP and no registers"
      end
      # One per collection is the collector's own running fiber. More than that
      # means parked stacks are being walked from the guard page — the whole
      # mapping each — which is what the growth is for.
      if from_guard > COLLECTIONS
        failures << "#{from_guard} stacks were scanned from the guard page across " \
                    "#{COLLECTIONS} collections, against the #{COLLECTIONS} the collector's own " \
                    "fiber accounts for: some thread's SP was not recorded"
      end
    end

    if failures.empty?
      if hold
        puts "  ok — every held block survived, so an uncovered thread's stack is still scanned"
      elsif pinned
        puts "  ok — #{from_guard} stacks fell back to the guard page (8 MiB each) and " \
             "#{no_slot} claims were refused: the pre-growth cost, reconstructed"
      else
        puts "  ok — every thread had a slot and every parked stack was scanned from a " \
             "recorded SP"
      end
      return 0
    end
    failures.each { |f| STDERR.puts "  FAIL: #{f}" }
    1
  end

  def self.parent : Int32
    puts "=== what does a thread with no STW capture slot cost? ==="
    exe = Process.executable_path || PROGRAM_NAME
    pin = {"GCRY_STW_FIXED_SLOTS" => "1"}
    failures = [] of String

    [{"grown", {} of String => String}, {"pinned", pin}, {"held", pin}].each do |(arm, env)|
      result = BoundedChild.run(exe, ["--child=#{arm}"], env, ARM_BUDGET)
      result.output.each_line do |line|
        puts line.rstrip unless line.strip.empty?
      end
      next if result.ok
      failures << if result.timed_out
        "#{arm}: outlived its #{ARM_BUDGET.total_seconds.to_i}s budget"
      else
        "#{arm}: see the arm's own output above"
      end
    end

    puts ""
    if failures.empty?
      puts "ok — with the table grown every thread has a capture slot and every parked stack is"
      puts "     scanned from a recorded SP; pinned at 64 the claims are refused and the stacks"
      puts "     of the uncovered threads are walked from the guard page instead — 8 MiB each,"
      puts "     which on this host is about twentyfold on the pause — and a block held only in"
      puts "     an uncovered thread's stack still survives (src/gcry/platform/linux_stw.cr)."
      return 0
    end
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    1
  end

  def self.main : Int32
    arm = ARGV.find(&.starts_with?("--child=")).try(&.split('=', 2)[1])
    ARGV.each do |argument|
      next if argument.starts_with?("--child=")
      STDERR.puts "unknown argument #{argument.inspect}: this harness takes no arguments (it " \
                  "drives its arms as bounded children) or exactly one " \
                  "--child=grown|pinned|held."
      return 64
    end
    return parent unless arm
    unless arm.in?("grown", "pinned", "held")
      STDERR.puts "unknown arm #{arm.inspect}: expected grown, pinned or held."
      return 64
    end
    child(arm)
  end
end

exit StwSlotPrecision.main
