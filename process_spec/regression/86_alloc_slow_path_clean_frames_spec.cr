require "../../src/gcry"
require "spec"

# The frames an allocation-triggered collection runs on held whatever the
# stack had at their depth before. The allocation entry (`GC.malloc_atomic`,
# with `Heap#malloc_atomic` and the hit path inlined) called `allocate`
# itself, so its frame was live across the collection, and the slots only the
# hit path writes were not written on the way there. The conservative scan
# read them as roots. That is how the occupancy claim lowered crystal-metric
# RegexDna's peak by 19% without touching what RegexDna allocates: before it,
# `Heap#malloc_atomic`'s `0x58(%rsp)` held the dead `Fasta` (left there by
# `GC.realloc`'s push of a callee-saved register during the Fasta phase), and
# through it the 64 MiB output buffer, at three collections; the claim
# changed the inlining and the slot went away. On 0.39.0 the entry's slots
# held Knuckeotide's dead hash buffers instead
# (`bench/log/linux/2026-10-22-regexdna-peak/`).
#
# Now the slow path is three tail calls: the entry pops its frame and jumps
# to `Heap#allocate_entry`, which reads the wipe's bound (`Roots.wipe_limit`)
# and jumps to `allocate_wipe`, which has no frame (a frame record on
# Darwin), zeroes the stack below the SP it was entered with
# (`Roots.wipe_below_sp`) and jumps to `allocate_traced`. The slow path's
# frames and the collector's are built over zeros.
#
# Three checks, all in a `--release` build (the tail calls and the inlined
# wipe are the release build's), on x86-64 and arm64, Windows included:
#
# - Stale words: at a collection an allocation triggers, the words between
#   the allocating call and the collector's entry SP that still hold a
#   pattern a deeper call wrote there just before: words no frame on the way
#   wrote (the measure regression 79 bounds). The fixed arm must find none.
#   The control arm (`slow_entry_wipe = false`: the tail calls without the
#   wipe) must find some, or the fixed arm could pass on a layout where
#   nothing is left to wipe; both run in this process, one after the other,
#   from the same depth. Measured on x86-64 Linux, Crystal 1.21.0: 13 on the
#   tree before the tail calls (the entry's frame, live across the
#   collection), 2 in the control arm (slots of the frames built below it
#   that they do not write), 0 fixed. The control arm's count is the
#   layout's, so only x86-64 Linux, where it was measured, requires it to be
#   non-zero.
# - Where the wipe starts: the SP `allocate_wipe` ran at
#   (`Heap#slow_wipe_sp`, recorded while `slow_wipe_watch` holds an SP
#   above it) must be within 16 bytes (a frame record) of the SP the
#   allocation entry was called with, so the wipe covers every frame the
#   slow path built above it. The first bounded version read the bound in
#   the frame that wiped, and on aarch64 Darwin that frame (`sub sp, #0x60`)
#   left `[sp]` unwritten and unwiped: whether a stale word survived there
#   depended on whether `allocate_traced`'s frame happened to write the same
#   slot, which the stale-word count cannot see (on the M1 it did; on Intel
#   macOS one stale word survived). Red on that tree: the wipe started 56
#   bytes below the entry SP on x86-64 Linux, 96 on the M1, 72 on Intel
#   macOS (`bench/log/linux/2026-10-23-wipe-platforms/`).
# - Debug builds say they skipped (`stale86: … skipped`).
private STALE86_PATTERN   = 0x5a5a_c3c3_5a5a_c386_u64
private STALE86_WORDS     =                      1024
private STALE86_SKIP_MARK = "stale86: needs a --release build on x86-64 or arm64, skipped"

@[NoInline]
private def stale86_fill_below : Nil
  buf = uninitialized StaticArray(UInt64, STALE86_WORDS)
  STALE86_WORDS.times { |i| buf[i] = STALE86_PATTERN }
  # Keep the stores: the array is otherwise dead.
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

# One allocation that collects, from the same depth as the fill. Not a tail
# call (the result is used after it), so the SP read here is the SP the
# allocation entry is called with (less the return address x86-64 pushes).
@[NoInline]
private def stale86_alloc_collecting(sp_out : UInt64*) : Void*
  sp_out.value = Gcry::Roots.hardware_stack_pointer.address
  ptr = GC.malloc_atomic(LibC::SizeT.new(64))
  asm("" :: "r"(ptr) : "memory" : "volatile")
  ptr
end

# The SP the allocation entry starts with when called from a body whose SP
# is *body_sp*: x86-64's `call` pushes the return address, arm64's `bl` does
# not.
private def stale86_entry_sp(body_sp : UInt64) : UInt64
  {% if flag?(:x86_64) %}
    body_sp &- 8
  {% else %}
    body_sp
  {% end %}
end

# Pattern words in `[collect_entry_sp, caller SP)` at the collection, with the
# slow path's wipe on or off, and the SP the wipe started at.
private def stale86_count(wipe : Bool) : {Int32, UInt64, UInt64}
  heap = Gcry.default_heap
  saved_threshold = heap.gc_threshold
  caller_sp = 0_u64
  stale = -1
  collections_before = heap.collections
  heap.slow_entry_wipe = wipe
  heap.post_stw_hook = ->(stage : Symbol) do
    if stage == :after_start_world && stale < 0
      h = Gcry.default_heap
      n = 0
      p = h.collect_entry_sp & ~7_u64
      while p < caller_sp
        n += 1 if Pointer(UInt64).new(p).value == STALE86_PATTERN
        p &+= 8
      end
      stale = n
    end
    nil
  end
  begin
    # The first slow path below this frame on this stack records where its
    # wipe started: the allocation below (set after the closure above, which
    # allocates; gcry's own threads allocate too, on their own stacks).
    heap.slow_wipe_sp = 0_u64
    heap.slow_wipe_watch = Gcry::Roots.hardware_stack_pointer.address
    stale86_fill_below
    heap.gc_threshold = 1_u64
    stale86_alloc_collecting(pointerof(caller_sp))
  ensure
    heap.gc_threshold = saved_threshold
    heap.post_stw_hook = nil
    heap.slow_entry_wipe = true
    heap.slow_wipe_watch = 0_u64
  end
  heap.collections.should be > collections_before
  caller_sp.should_not eq(0)
  {stale, stale86_entry_sp(caller_sp), heap.slow_wipe_sp}
end

describe "Regression: an allocation's slow path collects on frames built over zeros" do
  it "leaves no stale word between the allocation and the collector" do
    {% if flag?(:release) && (flag?(:x86_64) || flag?(:aarch64)) %}
      control, _, _ = stale86_count(wipe: false)
      fixed, entry_sp, wipe_sp = stale86_count(wipe: true)
      STDERR.puts "stale86: control #{control}, fixed #{fixed}; wipe starts #{entry_sp.to_i64 - wipe_sp.to_i64} bytes below the entry SP"
      {% if flag?(:x86_64) && flag?(:linux) %}
        control.should be > 0
      {% end %}
      fixed.should eq(0)
      # The wipe starts at the SP the slow path was entered with, less at
      # most a frame record: no frame of the slow path is above it.
      wipe_sp.should_not eq(0)
      wipe_sp.should be <= entry_sp
      (entry_sp - wipe_sp).should be <= 16
    {% else %}
      STDERR.puts STALE86_SKIP_MARK
    {% end %}
  end
end

# The wipe stores below the SP, so it must stay inside the running fiber's
# stack: a fiber with less than 1 KiB of stack left would otherwise fault on
# a slow path that does not go that deep itself (the review of the first
# version, 2026-10-22, `bench/log/linux/2026-10-22-regexdna-peak/`). A child
# fiber recurses until it has little room left below its SP and wipes there:
# the fixed child uses `Roots.wipe_below_sp(Roots.wipe_limit(sp))` and must
# survive with the floor clamped (not skipped); the control child runs the
# first version's unbounded 1 KiB loop. Each in a process of its own, any
# build, x86-64 and arm64.
#
# Outside Windows the room is 340-640 bytes above the guard page (the page
# above the stack's lowest): the fixed child lives with its floor at the
# guard's top, the control child dies on the guard page ("Stack overflow"),
# or the fixed child would pass on a layout where 1 KiB was never past it.
#
# On Windows a stack grows by touching the `PAGE_GUARD` page below its
# committed part, and the room is 700-1000 bytes above the thread's
# `NT_TIB.StackLimit`, the lowest committed address (a deep fiber never gets
# near the reserve's end there: Windows raises `STATUS_STACK_OVERFLOW` 64 KiB
# earlier). The fixed child must leave `StackLimit` where it was, its floor
# at it: it stored into committed pages only. The control child's loop runs
# past it into the guard page, and Windows commits that page and lowers
# `StackLimit`: it must move, or the fixed child would pass on a layout where
# 1 KiB never reached the guard page.
private GUARD86_SKIP_MARK = "guard86: no wipe on this target, skipped"
private GUARD86_FIXED_OK  = "guard86: fixed child wiped down to its bound and stayed above it"
private GUARD86_CTL_PAST  = "guard86: control child's wipe went past the committed stack"

{% if flag?(:x86_64) || flag?(:aarch64) %}
  # The first version's wipe: 1 KiB below the SP, no bound.
  @[AlwaysInline]
  private def guard86_unbounded_wipe : Nil
    {% if flag?(:x86_64) %}
      asm("leaq -1024(%rsp), %r11
           1:
           movq $$0, (%r11)
           movq $$0, 8(%r11)
           addq $$16, %r11
           cmpq %rsp, %r11
           jb 1b" ::: "r11", "memory", "cc" : "volatile")
    {% else %}
      asm("mov x10, sp
           sub x9, x10, #1024
           1:
           stp xzr, xzr, [x9], #16
           cmp x9, x10
           b.lo 1b" ::: "x9", "x10", "memory", "cc" : "volatile")
    {% end %}
  end

  # The bound the descent measures its room against: the guard page's top
  # outside Windows, the committed stack's lowest address on Windows.
  @[AlwaysInline]
  private def guard86_bound : UInt64
    {% if flag?(:win32) %}
      Gcry::Roots.committed_stack_limit
    {% else %}
      Fiber.current.@stack.pointer.address &+ Gcry::Roots.runtime_page_size
    {% end %}
  end

  private GUARD86_ROOM_MAX = {% if flag?(:win32) %} 1000 {% else %} 640 {% end %}

  # Near the bound nothing deeper may be called than the wipe itself: the
  # floor and the bound are only recorded here and checked once the descent
  # has unwound. `res[0]` the bound before the wipe, `res[1]` after it,
  # `res[2]` the fixed arm's floor.
  @[NoInline]
  private def guard86_wipe(arm : String, res : UInt64*) : Nil
    res[0] = guard86_bound
    if arm == "fixed"
      sp = Gcry::Roots.hardware_stack_pointer.address
      res[2] = Gcry::Roots.wipe_floor(sp)
      Gcry::Roots.wipe_below_sp(Gcry::Roots.wipe_limit(sp))
    else
      guard86_unbounded_wipe
    end
    res[1] = guard86_bound
  end

  # Each level holds 128 bytes of its own, so the descent stops with
  # 340-640 (Windows: 700-1000) bytes above the bound.
  @[NoInline]
  private def guard86_descend(arm : String, res : UInt64*) : Nil
    pad = uninitialized StaticArray(UInt64, 16)
    asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
    if Gcry::Roots.hardware_stack_pointer.address &- guard86_bound > GUARD86_ROOM_MAX
      guard86_descend(arm, res)
    else
      guard86_wipe(arm, res)
    end
    # Not a tail call: the frame stays while the deeper levels run.
    asm("" :: "r"(pad.to_unsafe) : "memory" : "volatile")
  end

  private def guard86_child(arm : String) : Nil
    done = Channel(Nil).new
    spawn do
      res = StaticArray(UInt64, 3).new(0_u64)
      guard86_descend(arm, res.to_unsafe)
      before, after, floor = res[0], res[1], res[2]
      STDERR.puts "guard86: #{arm}: bound #{before} -> #{after}, floor #{floor}"
      if arm == "fixed"
        # Clamped to the bound: not skipped, and not past it.
        raise "guard86: floor #{floor} not clamped to #{before}" unless floor >= before && floor < before + 16
        raise "guard86: the wipe moved the committed stack #{before} -> #{after}" unless after == before
        STDERR.puts GUARD86_FIXED_OK
      else
        {% if flag?(:win32) %}
          STDERR.puts GUARD86_CTL_PAST if after < before
        {% end %}
      end
      done.send(nil)
    end
    done.receive
  end
{% end %}

describe "Regression: the slow path's wipe stays inside the fiber's stack" do
  it "wipes down to its bound and no further" do
    {% if flag?(:x86_64) || flag?(:aarch64) %}
      {"fixed", "control"}.each do |arm|
        captured = IO::Memory.new
        status = Process.run(Process.executable_path.not_nil!, ["-e", "wipe-guard child #{arm}"],
          env: {"GCRY_WIPE_GUARD86_CHILD" => arm}, output: captured, error: captured)
        text = captured.to_s
        # The child's bound and floor, for the log.
        text.each_line { |l| STDERR.puts l if l.starts_with?("guard86: #{arm}:") }
        if arm == "fixed"
          fail "fixed child #{status.inspect}:\n#{text}" unless status.success? && text.includes?(GUARD86_FIXED_OK)
        else
          {% if flag?(:win32) %}
            # Windows commits the guard page the loop reached and lowers
            # `StackLimit`; the child lives.
            fail "control child's wipe stayed inside the committed stack (#{status.inspect}):\n#{text}" unless status.success? && text.includes?(GUARD86_CTL_PAST)
          {% else %}
            # Crystal's handler reports the fault on a guard page as a stack
            # overflow and exits non-zero.
            fail "control child did not fault on the guard page (#{status.inspect}):\n#{text}" if status.success?
          {% end %}
        end
      end
    {% else %}
      STDERR.puts GUARD86_SKIP_MARK
    {% end %}
  end

  it "wipe-guard child fixed" do
    next unless ENV["GCRY_WIPE_GUARD86_CHILD"]? == "fixed"
    {% if flag?(:x86_64) || flag?(:aarch64) %}
      guard86_child("fixed")
    {% else %}
      STDERR.puts GUARD86_SKIP_MARK
    {% end %}
  end

  it "wipe-guard child control" do
    next unless ENV["GCRY_WIPE_GUARD86_CHILD"]? == "control"
    {% if flag?(:x86_64) || flag?(:aarch64) %}
      guard86_child("control")
    {% else %}
      STDERR.puts GUARD86_SKIP_MARK
    {% end %}
  end
end
