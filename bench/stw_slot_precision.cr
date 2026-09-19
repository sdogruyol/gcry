require "../src/gcry"
require "./bounded_child"

# What does a thread with no STW capture slot cost?
#
# Linux keeps its capture table at a fixed `MAX_STW_SP_SLOTS = 64` on purpose.
# The argument for that, written in `stw_slots.cr` and in `ROADMAP.md`, is that
# the loss is **precision and not roots**: the registers of an uncovered thread
# arrive in a signal `ucontext` that sits on the interrupted thread's own stack,
# and the scan of that stack is unclamped, so it still walks them. That much is
# true. What nobody had measured is what the unclamped walk *costs*, and the
# answer is not precision in the abstract — it is garbage that is never
# collected again:
#
#   98 threads, 96 unreachable 96-byte blocks    34 still allocated after 1, 2 and 3 collections
#   62 threads, 60 unreachable 96-byte blocks     0 still allocated
#
# and the survivors are exactly the blocks allocated by the threads past the
# 64th in list order (indices 62..95 of 96, with the main thread and the monitor
# taking the first two slots).
#
# The route, narrowed by measurement rather than by reading:
#
#   * not the pthread-mapping scan — `GCRY_STW_PTHREAD_LAG=65536` clamps that
#     path to the top 64 KiB and changes nothing.
#   * not the register scan — `GCRY_DISABLE_GREG_ROOTS=1` changes nothing.
#   * it is the **fiber** window. A Crystal thread's main fiber's stack *is* its
#     OS stack, and `fiber_stack_sp_scan_low` finds the window's low bound by
#     asking `Platform.thread_sp` for the thread whose SP lies in that stack.
#     With no capture slot there is no SP, so the lookup fails and
#     `fiber_stack_scan_top` falls back to `guard` — the whole 8 MiB, dead
#     frames included. The pointer a thread left in `GC.malloc`'s dead frames,
#     deeper than the parked SP, is then a root forever.
#
# So an uncovered thread does not lose roots; it **gains** them, and keeps the
# garbage it allocated for as long as it lives. That is a leak whose size is the
# thread's dead-frame history, and it is paid again on every collection as an
# 8 MiB conservative walk inside the pause.
#
# **This gate encodes the mechanism, not the defect.** The claim it asserts —
# blocks are retained exactly for the threads the capture table had no room for
# — is true of the fixed table today and true of a grown table tomorrow, where
# both sides are zero. It fails if retention appears *under* the cap (the
# mechanism is not the table), if it exceeds the uncovered count (something else
# retains too), or if a held pointer stops being a root (the coverage claim
# itself breaks).
#
# Three arms, each a bounded child:
#
#   covered     `COVERED_THREADS` threads, all unreachable garbage, every block
#               must be reclaimed. This is what makes the next arm's number
#               mean something.
#   uncovered   `THREADS` threads, all unreachable garbage. Retention must equal
#               the number of threads the table could not cover — `listed -
#               capacity`, clamped at zero.
#   held        `THREADS` threads, each holding its block in its own stack. All
#               must survive: past the cap the coverage must still be sound,
#               which is the half of the trade-off that was already argued.
#
#   crystal build -Dgc_none bench/stw_slot_precision.cr -o bin/stw_slot_precision
#   bin/stw_slot_precision
#   bin/stw_slot_precision --child=uncovered

{% unless flag?(:gc_none) %}
  {% raise "stw_slot_precision requires -Dgc_none (gcry as process GC)" %}
{% end %}

module StwSlotPrecision
  THREADS         = 96
  COVERED_THREADS = 56

  VICTIM_SIZE =                    96_u64
  FILL        =                   0xA5_u8
  KEY         = 0x9E37_79B9_7F4A_7C15_u64

  ARM_BUDGET = 120.seconds

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

  # Allocated in the worker so the parent never holds the plaintext: a copy in
  # the parent's frame would root every block and the whole measurement would
  # read as retention.
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
  # the obvious way — `slots[97] = hidden ^ KEY` and `return slots[97] ^ KEY` —
  # LLVM folds both away to `return hidden`, nothing reaches the stack, and the
  # held arm measures nothing.
  @[NoInline]
  def self.stash(slot : UInt64*, value : UInt64) : Nil
    slot.value = value
  end

  @[NoInline]
  def self.fetch(slot : UInt64*) : UInt64
    slot.value
  end

  @[NoInline]
  def self.park(stop : Gate) : Nil
    while stop.get == 0
      Thread.sleep(2.milliseconds)
    end
  end

  @[NoInline]
  def self.park_holding(hidden : UInt64, ready : Gate, stop : Gate, hold : Bool) : UInt64
    slots = uninitialized UInt64[256]
    i = 0
    while i < 256
      stash(slots.to_unsafe + i, 0_u64)
      i += 1
    end
    stash(slots.to_unsafe + 97, hold ? hidden ^ KEY : 0_u64)
    ready.set
    park(stop)
    fetch(slots.to_unsafe + 97)
  end

  def self.child(arm : String) : Int32
    heap = Gcry.default_heap.not_nil!
    hold = arm == "held"
    want = arm == "covered" ? COVERED_THREADS : THREADS

    puts "arm #{arm}: #{want} threads, #{hold ? "each holding its block in its own stack" : "nothing holding the blocks"}"

    ready = Array(Gate).new(want) { Gate.new }
    stop = Gate.new
    # A raw slice, not `Array(Atomic(UInt64))`: `Atomic` is a struct and
    # `Array#[]` returns a copy, so `hidden[i].set(h)` writes to a temporary and
    # every address reads back as `0 ^ KEY`.
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

    before_no_slot = heap.stw_capture_no_slot
    GC.collect
    GC.collect
    capacity = heap.stw_slot_capacity
    no_slot = heap.stw_capture_no_slot - before_no_slot

    stop.set
    threads.each(&.join)

    retained = 0
    damaged = 0
    first_retained = -1
    want.times do |i|
      victim = Pointer(Void).new(hidden[i] ^ KEY)
      next unless heap.live?(victim)
      retained += 1
      first_retained = i if first_retained < 0
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
    puts "  threads_on_list=#{listed} slot_capacity=#{capacity} uncovered=#{uncovered} " \
         "no_slot_claims=#{no_slot}"
    puts "  blocks=#{want} still_allocated=#{retained} damaged=#{damaged} " \
         "first_still_allocated=#{first_retained}"

    failures = [] of String

    if hold
      # The half of the trade that was already argued, now checked: an
      # uncovered thread's stack is scanned unclamped, so a pointer it holds is
      # still a root.
      if retained != want
        failures << "#{want - retained} of #{want} blocks were swept while the thread that " \
                    "allocated them held the only pointer in its own stack — past the capture " \
                    "table's capacity the coverage is supposed to be conservative, not absent"
      end
      if damaged != 0
        failures << "#{damaged} block(s) were overwritten after the collection"
      end
    elsif uncovered == 0
      if retained != 0
        failures << "#{retained} unreachable block(s) survived with every thread covered by " \
                    "the capture table — the retention this gate attributes to uncovered " \
                    "threads has another source, and the uncovered arm's number means nothing"
      end
    else
      # The correlation *is* the claim. Both sides go to zero when the table
      # grows, and this arm keeps working without an edit.
      if retained != uncovered
        failures << "#{retained} unreachable block(s) survived against #{uncovered} thread(s) " \
                    "the capture table could not cover: the retention no longer matches the " \
                    "threads whose SP was never recorded, so the mechanism this gate describes " \
                    "is not the one running"
      end
      if no_slot == 0
        failures << "#{uncovered} thread(s) are past the table's #{capacity} slots and not one " \
                    "claim was refused, so the counter that names the loss is not counting"
      end
    end

    if failures.empty?
      if hold
        puts "  ok — every held block survived, so an uncovered thread's stack is still scanned"
      elsif uncovered == 0
        puts "  ok — with every thread covered, unreachable blocks are all reclaimed"
      else
        puts "  ok — #{retained} block(s) retained for #{uncovered} uncovered thread(s): the " \
             "unclamped fallback keeps their dead frames' pointers alive"
      end
      return 0
    end
    failures.each { |f| STDERR.puts "  FAIL: #{f}" }
    1
  end

  def self.parent : Int32
    puts "=== what does a thread with no STW capture slot cost? ==="
    exe = Process.executable_path || PROGRAM_NAME
    failures = [] of String

    %w[covered uncovered held].each do |arm|
      result = BoundedChild.run(exe, ["--child=#{arm}"], timeout: ARM_BUDGET)
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
      puts "ok — unreachable blocks are retained exactly for the threads the capture table"
      puts "     could not cover, none are retained when every thread is covered, and a block"
      puts "     an uncovered thread holds is still a root. Both sides of that first line are"
      puts "     zero once the table covers every thread (src/gcry/platform/linux_stw.cr,"
      puts "     bench/log/linux/2026-09-19-stw-slot-retention/FINDINGS.md)."
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
                  "--child=covered|uncovered|held."
      return 64
    end
    return parent unless arm
    unless arm.in?("covered", "uncovered", "held")
      STDERR.puts "unknown arm #{arm.inspect}: expected covered, uncovered or held."
      return 64
    end
    child(arm)
  end
end

exit StwSlotPrecision.main
