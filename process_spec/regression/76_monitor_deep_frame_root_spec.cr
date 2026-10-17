require "../../src/gcry"
require "spec"

# The runtime's Monitor (SYSMON) is never signal-suspended on Linux, so a
# stop has no SP for it, and the single-mutator scan of another thread fell
# back to its current fiber's saved `stack_top`. The Monitor only ever runs
# its thread's main fiber, which has never switched: that `stack_top` is the
# SP `Fiber#initialize` read in the thread's birth, a few hundred bytes above
# the frames of the loop it has run ever since. Everything below it went
# unscanned, and an object only those frames held was swept while the
# Monitor still used it.
#
# Crystal 1.22's `Thread.sleep` is such a frame. Its `GC.syscall do ... end`
# block captures `ret`, `errno`, `req` and `rem`, so they live in a 48-byte
# closure on the heap, which the Monitor allocates every ~10 ms and writes
# `ret` and `errno` into when `nanosleep` returns. A collection during that
# sleep freed the closure, a mutator was handed the block, and the Monitor
# zeroed its bytes 32-39: the fifth entry of `bench/pattern_fuzz.cr`'s
# six-entry `Array(PatternPhase)` buffer, which `compute_phase_stats` read
# as a nil phase — SIGSEGV at 0x20 under `GCRY_BITMAP_ALLOC=0` in CI run
# 38966033174. Interleaved on the same runners, argv[0] as `make` gives it:
# 31 of 400 runs before (30 of 40 on an AMD EPYC 9V74 runner, 1 of 40 on a
# 9V45, 0 on EPYC 7763s), 0 of 400 after. A hardware watchpoint on the
# zeroed word caught the Monitor's `sleep` writing it. The scan of a thread
# with no SP now starts at the low end of its stack (the low-water mark when
# the platform can read one).
#
# Forced here rather than waited for: the Monitor is held, outside its gate,
# in a frame 64 KiB below anything its birth touched, holding the only
# reference to a block; the spec collects and asks whether the block is
# still allocated. The address crosses threads masked, so no word the
# collector scans names the block except the Monitor's own frame.

{% if @top_level.has_constant?("Fiber") && Fiber.has_constant?("ExecutionContext") && Fiber::ExecutionContext.has_constant?("Monitor") %}
  module MonitorDeepRoot
    CANARY = 0x6d6f_6e69_746f_7221_u64
    MASK   = 0xa5a5_a5a5_a5a5_a5a5_u64
    WORDS  =                         6

    @@armed = Atomic(Int32).new(0)
    @@addr = Atomic(UInt64).new(0_u64)
    @@release = Atomic(Int32).new(0)
    @@intact = Atomic(Int32).new(-1)

    def self.arm : Nil
      @@addr.set(0_u64)
      @@release.set(0)
      @@intact.set(-1)
      @@armed.set(1)
    end

    def self.masked_addr : UInt64
      @@addr.get
    end

    def self.release : Nil
      @@release.set(1)
    end

    def self.intact : Int32
      @@intact.get
    end

    # On the Monitor's thread, from `increase_parallelism`, before its gate.
    def self.run_if_armed : Nil
      return unless @@armed.swap(0) == 1
      padded
    end

    # Puts `hold`'s frame 64 KiB below the Monitor's loop.
    @[NoInline]
    def self.padded : Nil
      pad = uninitialized StaticArray(UInt64, 8192)
      pad[0] = 0_u64
      hold
      Gcry::Roots.keep_alive(pad.to_unsafe.as(Void*))
    end

    @[NoInline]
    def self.hold : Nil
      block = Pointer(UInt64).malloc(WORDS)
      WORDS.times { |i| block[i] = CANARY }
      @@addr.set(block.address ^ MASK)
      # A spin, not `sleep`: on 1.22 the latter's own closure is the very
      # object this spec is about, and `nanosleep` is not on Windows.
      until @@release.get == 1
        Intrinsics.pause
      end
      ok = true
      WORDS.times { |i| ok = false unless block[i] == CANARY }
      @@intact.set(ok ? 1 : 0)
      Gcry::Roots.keep_alive(block.as(Void*))
    end
  end

  class Fiber::ExecutionContext::Monitor
    private def increase_parallelism(now)
      MonitorDeepRoot.run_if_armed
      previous_def
    end
  end

  describe "Regression: the Monitor's stack below its birth" do
    it "is scanned while a collection runs" do
      heap = Gcry.default_heap
      MonitorDeepRoot.arm
      deadline = Time.instant + 10.seconds
      while MonitorDeepRoot.masked_addr == 0
        fail "the Monitor never reached the hold" if Time.instant > deadline
        sleep 1.millisecond
      end

      # Swept inside the collection, so an unmarked block reads free when it
      # returns rather than at its class's next refill.
      lazy = heap.lazy_sweep
      begin
        heap.lazy_sweep = false
        3.times { GC.collect }
      ensure
        heap.lazy_sweep = lazy
      end

      # Unmasked only now: a copy on this thread's stack during the
      # collections would have kept the block alive by itself.
      info = heap.debug_block_info(Pointer(Void).new(MonitorDeepRoot.masked_addr ^ MonitorDeepRoot::MASK))
      MonitorDeepRoot.release
      deadline = Time.instant + 10.seconds
      while MonitorDeepRoot.intact < 0
        fail "the Monitor never left the hold" if Time.instant > deadline
        sleep 1.millisecond
      end

      info[:found].should be_true
      info[:free].should be_false
      MonitorDeepRoot.intact.should eq(1)
    end
  end
{% end %}
