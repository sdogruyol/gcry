require "../../src/gcry"
require "spec"

# Two ways an incremental cycle (`GCRY_INCREMENTAL=1`, `collect_a_little`)
# swept an object the program held, both an object the mark had not reached
# moved out of a heap field, the field cleared, mid-cycle. The page barrier
# records the clear and no more; the finish needs to see where the pointer
# went.
#
# - Into a root. The cycle scanned the roots — the stacks, the registers,
#   static data — in its begin stop and in no stop after it, so the object
#   was held by a root alone and the finish swept it. The terminating stop
#   now marks the begin stop's root set again (`Heap#mark_incremental_roots`)
#   and sweeps only once what that found is drained, as Boehm's incremental
#   mode pushes the roots again in `GC_stopped_mark`.
# - Into an object in a chunk mapped since the barrier's arm. The mprotect
#   arm protects the chunks it finds; a new one stays writable with no dirty
#   bit for its writes, and what is allocated in it while marking is black
#   and never scanned. The termination scan now reads every page the cards
#   neither protect nor mark dirty (`Platform.each_mprotect_untracked_page`).
#
# The construction, deterministic: an object X, its 64 bytes a pattern, is
# held only by a field of a holder at the end of a 4 000-node chain from a
# static root. One slice of one unit begins the cycle; X is unmarked
# (checked). Then X's pointer moves out of the field and the field is
# cleared, and the cycle runs out. Four windows, by where X goes:
#
# - *stack*: a stack slot of the frame driving the slices;
# - *static*: a class variable (static data);
# - *thread*: a stack slot of a second thread, spinning until the cycle has
#   finished;
# - *newchunk*: the first word of a 4 MiB block allocated after the arm (a
#   mapping of its own, its page checked untracked), held by a class
#   variable.
#
# The fixed arm must find X allocated, its pattern intact after 4 096 more
# allocations of its size, and none of them X. The control arm must find X
# swept, or the fixed arm passes on nothing: the root windows' control turns
# the rescan off (`Heap.inc_finish_rescan_roots = false`), *newchunk*'s the
# untracked pages (`Platform.mprotect_scan_untracked = false`), each the code
# before. Each arm runs in a process of its own. The cycle runs on the
# mprotect barrier, as regressions 85, 91 and 95 do: Linux only. A heap that
# cannot reach the window prints `RESCAN100_SKIP_MARK` and passes, and the
# parent then does not ask for the control's mark.
# `bench/log/linux/2026-11-02-incremental-stack-rescan/FINDINGS.md`.

private RESCAN100_SKIP_MARK    = "rescan100: this heap cannot reach the window, skipped"
private RESCAN100_FIXED_MARK   = "rescan100: the moved object is alive"
private RESCAN100_CONTROL_MARK = "rescan100: the control arm swept the moved object"

private RESCAN100_WINDOWS = {"stack", "static", "thread", "newchunk"}

# Links between the static root and the holder: far more marking than the
# begin slice's one unit does.
private RESCAN100_CHAIN = 4000
private RESCAN100_BYTES =   64
# Large enough for a mapping of its own.
private RESCAN100_NEW_BYTES = 4 * 1024 * 1024

private class Rescan100Roots
  class_property head : Void* = Pointer(Void).null
  class_property moved : Void* = Pointer(Void).null
  class_property sink = 0_u64
end

class Gcry::Heap
  # Whether the mark has reached the object at *pointer*; nil when it is not
  # an allocated block.
  def rescan100_marked?(pointer : Void*) : Bool?
    header = find_object(pointer)
    return nil unless header
    heap_marked?(header)
  end
end

private def rescan100_say(text : String) : Nil
  STDOUT.puts text
  STDOUT.flush
end

# Builds static root → 4 000 nodes → holder → X, and returns X's address
# complemented, so no frame of this one keeps X.
@[NoInline]
private def rescan100_build : UInt64
  holder = GC.malloc(16).as(Void**)
  x = GC.malloc_atomic(RESCAN100_BYTES).as(UInt8*)
  RESCAN100_BYTES.times { |i| x[i] = 0x5A_u8 }
  holder[0] = x.as(Void*)
  last = holder.as(Void*)
  RESCAN100_CHAIN.times do
    node = GC.malloc(16).as(Void**)
    node[0] = last
    last = node.as(Void*)
  end
  Rescan100Roots.head = last
  ~x.address
end

# The begin stop scans this thread's stack from the collector's frames up,
# and their unused slots can still hold what `rescan100_build`'s frames left
# there: zeroed first, so X begins white.
@[NoInline]
private def rescan100_scrub_stack : Nil
  buf = uninitialized StaticArray(UInt64, 8192)
  words = buf.to_unsafe
  8192.times { |i| words[i] = 0_u64 }
  Rescan100Roots.sink = words[0] &+ words[8191]
end

@[NoInline]
private def rescan100_holder : Void**
  p = Rescan100Roots.head
  RESCAN100_CHAIN.times { p = p.as(Void**)[0] }
  p.as(Void**)
end

# The mutator's move: the field's pointer into *slot*, the field cleared.
@[NoInline]
private def rescan100_move(slot : Void**, holder : Void**) : Nil
  slot.value = holder[0]
  holder[0] = Pointer(Void).null
end

private def rescan100_finish(heap : Gcry::Heap) : Nil
  slices = 0
  until heap.collect_a_little(4096)
    slices += 1
    fail "the cycle did not finish in #{slices} slices" if slices > 100_000
  end
end

# The heap, ready for the window, or nil when it cannot reach it.
private def rescan100_heap : Gcry::Heap?
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    # No collection but the window's.
    heap.disable
    # The cycle needs a page barrier with the world running between slices;
    # mprotect works on Linux whatever the kernel's soft-dirty does.
    heap.prefer_mprotect_barrier = true
    heap
  {% else %}
    nil
  {% end %}
end

# Whether the page holding *address* is one the cards cannot vouch for.
private def rescan100_untracked?(address : UInt64) : Bool
  {% if flag?(:linux) %}
    page = address & ~(Gcry::Platform::PAGE - 1)
    found = false
    Gcry::Platform.each_mprotect_untracked_page(page, page + Gcry::Platform::PAGE) { found = true }
    found
  {% else %}
    false
  {% end %}
end

# Runs one window. Returns whether X is allocated after the cycle, whether
# its pattern survived 4 096 allocations of its size, and whether one of
# them was X; nil after saying why it skipped.
@[NoInline]
private def rescan100_window(heap : Gcry::Heap, window : String) : {Bool, Bool, Bool}?
  GC.collect
  # Nothing cached for the *newchunk* block to be given instead of a mapping.
  heap.trim_large_cache(0_u64, defer: false)
  x_inv = rescan100_build
  rescan100_scrub_stack
  # The begin stop and one unit of marking.
  heap.collect_a_little(1) && fail "the cycle finished in its first slice"
  unless heap.incremental_in_progress? && heap.barrier_backend_name == "mprotect"
    rescan100_say("#{RESCAN100_SKIP_MARK}: no incremental cycle on the mprotect barrier")
    return nil
  end
  marked = heap.rescan100_marked?(Pointer(Void).new(~x_inv))
  fail "X is not an allocated block after the begin slice" if marked.nil?
  fail "X was marked before the move: the window was not reached" if marked

  slot = uninitialized StaticArray(Void*, 1)
  slot[0] = Pointer(Void).null
  holder = rescan100_holder
  moved = Atomic(Int32).new(0)
  done = Atomic(Int32).new(0)
  thread = nil
  case window
  when "stack"
    rescan100_move(slot.to_unsafe, holder)
  when "static"
    rescan100_move(slot.to_unsafe, holder)
    Rescan100Roots.moved = slot[0]
    slot[0] = Pointer(Void).null
  when "thread"
    thread = Thread.new do
      tslot = uninitialized StaticArray(Void*, 1)
      rescan100_move(tslot.to_unsafe, holder)
      moved.set(1)
      until done.get == 1
        Intrinsics.pause
      end
      Rescan100Roots.sink = tslot[0].address
    end
    deadline = Time.instant + 10.seconds
    until moved.get == 1
      fail "timed out waiting for the thread's move" if Time.instant >= deadline
      Intrinsics.pause
    end
  when "newchunk"
    block = GC.malloc(RESCAN100_NEW_BYTES).as(Void**)
    Rescan100Roots.moved = block.as(Void*)
    fail "the new block's page is under the barrier: the window was not reached" unless rescan100_untracked?(block.address)
    rescan100_move(slot.to_unsafe, holder)
    block[0] = slot[0]
    slot[0] = Pointer(Void).null
    block = Pointer(Void*).null
  else
    fail "unknown window #{window}"
  end
  holder = Pointer(Void*).null

  rescan100_finish(heap)
  done.set(1)
  thread.try &.join

  x = Pointer(UInt8).new(~x_inv)
  alive = !heap.find_object(x.as(Void*)).nil?
  again = [] of UInt8*
  reused = false
  4096.times do
    b = GC.malloc_atomic(RESCAN100_BYTES).as(UInt8*)
    RESCAN100_BYTES.times { |i| b[i] = 0xEE_u8 }
    reused = true if b == x
    again << b
  end
  intact = (0...RESCAN100_BYTES).all? { |i| x[i] == 0x5A_u8 }
  again.size.should eq(4096)
  slot[0] = Pointer(Void).null
  Rescan100Roots.moved = Pointer(Void).null
  {alive, intact, reused}
end

private def rescan100_child(window : String, fixed : Bool) : Nil
  return rescan100_say(RESCAN100_SKIP_MARK) unless heap = rescan100_heap
  unless fixed
    if window == "newchunk"
      {% if flag?(:linux) %}
        Gcry::Platform.mprotect_scan_untracked = false
      {% end %}
    else
      Gcry::Heap.inc_finish_rescan_roots = false
    end
  end
  result = rescan100_window(heap, window)
  return if result.nil?
  alive, intact, reused = result
  rescan100_say("rescan100 #{window}: alive=#{alive} pattern intact=#{intact} handed out again=#{reused}")
  if fixed
    alive.should be_true
    intact.should be_true
    reused.should be_false
    rescan100_say("#{RESCAN100_FIXED_MARK} (#{window})")
  else
    alive.should be_false
    rescan100_say("#{RESCAN100_CONTROL_MARK} (#{window})")
  end
end

describe "Regression: the incremental finish sees an object moved to a root or a new chunk" do
  RESCAN100_WINDOWS.each do |window|
    {"fixed", "control"}.each do |arm|
      it "#{window}: #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        env = {"GCRY_RESCAN100_CHILD" => "#{window}-#{arm}"} of String => String?
        # The control arm leaves a block swept under the program on purpose.
        env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
        status = Process.run(Process.executable_path.not_nil!,
          ["-e", "rescan100 child #{window}-#{arm}"],
          env: env, output: captured, error: captured)
        text = captured.to_s
        fail "child #{status.inspect}:\n#{text}" unless status.success?
        text.should contain("1 examples, 0 failures")
        unless text.includes?(RESCAN100_SKIP_MARK)
          text.should contain(arm == "control" ? RESCAN100_CONTROL_MARK : RESCAN100_FIXED_MARK)
        end
      end
    end
  end

  RESCAN100_WINDOWS.each do |window|
    {"fixed", "control"}.each do |arm|
      it "rescan100 child #{window}-#{arm}" do
        next unless ENV["GCRY_RESCAN100_CHILD"]? == "#{window}-#{arm}"
        rescan100_child(window, arm == "fixed")
      end
    end
  end
end
