require "../../src/gcry"
require "spec"

# The `GC` facade against the contracts `gc/boehm.cr` gives Crystal programs
# (docs/DEFAULT-GC-READINESS.md rows m1, m2, m4, m5, m6).

private PATTERN_OWN   = 0x5A_u8
private PATTERN_OTHER = 0xA5_u8
private PATTERN_CHURN = 0x00_u8
# Published addresses are XORed with this so the published word is not itself
# a conservative root for the block it names.
private ADDRESS_MASK = 0x5555_5555_5555_5555_u64

private def fill(p : Void*, byte : UInt8, n : Int32) : Nil
  n.times { |i| p.as(UInt8*)[i] = byte }
end

private def intact?(p : Void*, byte : UInt8, n : Int32) : Bool
  n.times { |i| return false unless p.as(UInt8*)[i] == byte }
  true
end

describe "GC.disable / GC.enable (m1)" do
  it "nest like Boehm's counter: an inner pair leaves collection off" do
    heap = Gcry.default_heap
    GC.disable
    begin
      # A library's own critical section inside the caller's.
      GC.disable
      GC.enable
      heap.enabled?.should be_false

      collections = heap.collections
      sink = nil.as(Bytes?)
      # 64 MiB of garbage: far past any threshold the process heap adapts to.
      65_536.times { sink = Bytes.new(1024) }
      sink.should_not be_nil
      heap.collections.should eq(collections)
    ensure
      GC.enable
    end
    heap.enabled?.should be_true
    expect_raises(Exception, "GC is not disabled") { GC.enable }
  end
end

describe "GC.free (m4)" do
  it "ignores and counts a double free instead of raising into its C callers" do
    heap = Gcry.default_heap
    before = heap.double_frees
    p = GC.malloc(64)
    GC.free(p)
    GC.free(p)
    heap.double_frees.should eq(before + 1)
  end

  it "ignores and counts a pointer into the heap that is not a block, and frees nothing" do
    heap = Gcry.default_heap
    before = heap.stale_frees
    p = GC.malloc(64)
    fill(p, PATTERN_OWN, 64)
    GC.free(p + 8)
    heap.stale_frees.should eq(before + 1)
    heap.live?(p).should be_true
    intact?(p, PATTERN_OWN, 64).should be_true
    GC.free(p)
  end
end

describe "GC.prof_stats (m2)" do
  it "reports what is mapped from the OS now, not what ever was" do
    GC.collect
    bytes = 16 * 1024 * 1024
    big = GC.malloc_atomic(bytes)
    mapped = GC.prof_stats.obtained_from_os_bytes
    GC.free(big)
    GC.collect
    GC.collect
    prof = GC.prof_stats
    prof.obtained_from_os_bytes.should be <= mapped - bytes
    prof.obtained_from_os_bytes.should be >= prof.heap_size
  end

  it "counts the libc memory handed out before the heap existed as non-GC bytes" do
    before = GC.prof_stats.non_gc_bytes
    before.should be > 0
    GC.malloc(4096)
    GC.prof_stats.non_gc_bytes.should eq(before)
  end

  it "reports parallel mark helpers as markers_m1" do
    heap = Gcry.default_heap
    saved = heap.parallel_mark_workers
    begin
      heap.parallel_mark_workers = 3
      GC.prof_stats.markers_m1.should eq(2)
      heap.parallel_mark_workers = 1
      GC.prof_stats.markers_m1.should eq(0)
    ensure
      heap.parallel_mark_workers = saved
    end
  end
end

describe "GC.set_stackbottom (m5)" do
  it "cannot hide a thread's stack from the collector, and another thread's bottom does not overwrite this one's" do
    heap = Gcry.default_heap
    size = 256
    published = Atomic(UInt64).new(0_u64)
    release = Atomic(Int32).new(0)
    verdict = Atomic(Int32).new(0)
    other = Thread.new do
      held = GC.malloc_atomic(size)
      fill(held, PATTERN_OTHER, size)
      published.set(held.address ^ ADDRESS_MASK)
      until release.get != 0
        Thread.yield
      end
      verdict.set(intact?(held, PATTERN_OTHER, size) ? 1 : 2)
    end
    until published.get != 0
      Thread.yield
    end

    own = GC.malloc_atomic(size)
    fill(own, PATTERN_OWN, size)
    mine = heap.stack_bottom

    # Wrong on purpose, for both threads: the collector must not trust either.
    {% if flag?(:without_mt) %}
      # The legacy scheduler's one-argument form: always the running thread.
      GC.set_stackbottom(Pointer(Void).new(own.address + size))
    {% else %}
      GC.set_stackbottom(other, Pointer(Void).new(0x1000_u64))
      heap.stack_bottom.should eq(mine)
      GC.set_stackbottom(Thread.current, Pointer(Void).new(own.address + size))
    {% end %}

    3.times do
      GC.collect
      2_000.times { fill(GC.malloc_atomic(size), PATTERN_CHURN, size) }
    end

    theirs = Pointer(Void).new(published.get ^ ADDRESS_MASK)
    heap.live?(theirs).should be_true
    heap.live?(own).should be_true
    intact?(own, PATTERN_OWN, size).should be_true
    release.set(1)
    other.join
    verdict.get.should eq(1)
  end
end

{% unless flag?(:win32) %}
  describe "GC.sig_suspend / GC.sig_resume (m6)" do
    it "are defined, so stdlib asks gcry instead of guessing" do
      gc = GC
      gc.responds_to?(:sig_suspend).should be_true
      gc.responds_to?(:sig_resume).should be_true
      Crystal::System::Thread.sig_suspend.should eq(GC.sig_suspend)
      Crystal::System::Thread.sig_resume.should eq(GC.sig_resume)
    end

    {% if flag?(:linux) %}
      it "name the signals the stop-the-world handler is installed on and waits for" do
        GC.sig_suspend.value.should eq(Gcry::Platform::STW_SIG_SUSPEND)
        GC.sig_resume.value.should eq(Gcry::Platform::STW_SIG_RESUME)

        # gcry's suspend handler is the one installed with `SA_SIGINFO` whose
        # mask blocks the resume signal until `sigsuspend` (linux_stw.cr);
        # Crystal's own has an empty mask. Reading it back proves the handler
        # on `GC.sig_suspend` is gcry's and that it waits for `GC.sig_resume`.
        action = LibC::Sigaction.new
        LibC.sigaction(GC.sig_suspend.value, nil, pointerof(action)).should eq(0)
        (action.sa_flags & LibC::SA_SIGINFO).should_not eq(0)
        LibC.sigismember(pointerof(action.@sa_mask), GC.sig_resume.value).should eq(1)

        # And something is listening for the resume: Crystal's handler, which
        # `Thread#resume` (gcry's restart) signals.
        resume = LibC::Sigaction.new
        LibC.sigaction(GC.sig_resume.value, nil, pointerof(resume)).should eq(0)
        resume.sa_sigaction.pointer.null?.should be_false
      end
    {% end %}
  end
{% end %}
