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
#   neither protect nor mark dirty (`Platform.each_mprotect_untracked_page`),
#   and every page of a chunk the barrier did not protect itself: the bits
#   over one mapped where a chunk unmapped mid-cycle was can still be that
#   chunk's, protected and clean.
#
# The construction, deterministic: an object X, its 64 bytes a pattern, is
# held only by a field of a holder at the end of a 4 000-node chain from a
# static root. One slice of one unit begins the cycle; X is unmarked
# (checked). Then X's pointer moves out of the field and the field is
# cleared, and the cycle runs out. Five windows, by where X goes:
#
# - *stack*: a stack slot of the frame driving the slices;
# - *static*: a class variable (static data);
# - *thread*: a stack slot of a second thread, spinning until the cycle has
#   finished;
# - *newchunk*: the first word of a 4 MiB block allocated after the arm (a
#   mapping of its own, its page checked untracked), held by a class
#   variable;
# - *remap*: a word 16 KiB into the same, but the block is mapped where a
#   4 MiB block the arm protected was freed and unmapped mid-cycle (no root
#   held that block at the begin stop, checked unmarked — a false root in
#   static data marks it about 1 run in 100, and then that cycle is run out
#   and the window built again, at most three times), so the cards still
#   call its pages protected and clean (checked); the termination reads
#   such a chunk whole, the barrier never having protected it
#   (`ChunkHeader::Flags::BARRIER_ARMED`). It prints X's mark state at each
#   stop, read by a collection event hook that zeroes the stack its reads
#   used: the hook runs inside each stop just before the root scan, and a
#   copy of X's address left in that band is a root to it.
#
# The fixed arm must find X allocated, its pattern intact after 4 096 more
# allocations of its size, and none of them X, and the cycle must not end
# in the lost-barrier full collection. The control arm must find X swept,
# or the fixed arm passes on nothing: the root windows' control turns the
# rescan off (`Heap.inc_finish_rescan_roots = false`), *newchunk*'s the
# untracked pages (`Platform.mprotect_scan_untracked = false`), *remap*'s
# the whole read of an unarmed chunk
# (`Platform.mprotect_scan_unarmed_chunks = false`), each the code before.
# Each arm runs in a process of its own. The cycle runs on the mprotect
# barrier, as regressions 85, 91 and 95 do: Linux only. A heap that cannot
# reach the window prints `RESCAN100_SKIP_MARK` and passes, and the parent
# then does not ask for the control's mark.
# `bench/log/linux/2026-11-02-incremental-stack-rescan/FINDINGS.md`.

private RESCAN100_SKIP_MARK    = "rescan100: this heap cannot reach the window, skipped"
private RESCAN100_FIXED_MARK   = "rescan100: the moved object is alive"
private RESCAN100_CONTROL_MARK = "rescan100: the control arm swept the moved object"

private RESCAN100_WINDOWS = {"stack", "static", "thread", "newchunk", "remap"}

# Links between the static root and the holder: far more marking than the
# begin slice's one unit does.
private RESCAN100_CHAIN = 4000
private RESCAN100_BYTES =   64
# Large enough for a mapping of its own.
private RESCAN100_NEW_BYTES = 4 * 1024 * 1024

private class Rescan100Roots
  class_property head : Void* = Pointer(Void).null
  class_property moved : Void* = Pointer(Void).null
  class_property big : Void* = Pointer(Void).null
  # *remap*: old blocks a false root marked, held so the next is mapped
  # elsewhere.
  class_property spares = [] of Void*
  class_property sink = 0_u64
  # *remap*: the old block's address, complemented, and X's, for the stop
  # trace.
  class_property big_inv = 0_u64
  class_property x_inv = 0_u64
  # *remap*'s stop trace, written by the collection event hook (which must
  # not allocate): the stops seen, the first one X was marked on entering
  # (-1 for none), whether X and the old block were marked when the begin
  # stop ended, and whether X was marked when the finishing mark ended (the
  # sweep after it clears the marks).
  class_property stops = 0
  class_property x_first_marked_stop = -1
  class_property x_marked_begin = false
  class_property big_marked_begin = false
  class_property x_marked_mark_end = false
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

# *remap*'s old block: mapped and collected once before the cycle, so the
# arm protects it as an old chunk, and returned as its address complemented.
# No root may hold it when the cycle begins: the begin stop would push it,
# and the mark, popping it after the remap, would read the new block at its
# address and find X there whatever the termination does. Its own frame, so
# no slot or register of the window's frame keeps the block, as
# `rescan100_build` for X.
@[NoInline]
private def rescan100_old_block : UInt64
  Rescan100Roots.big = GC.malloc(RESCAN100_NEW_BYTES)
  GC.collect
  inv = ~Rescan100Roots.big.address
  Rescan100Roots.big = Pointer(Void).null
  inv
end

# The begin stop scans this thread's stack from the collector's frames up,
# and their unused slots can still hold what `rescan100_build`'s and
# `rescan100_old_block`'s frames left there: zeroed first, so X and the old
# block begin white.
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

# Runs the cycle out. A fixed arm must not pass through the lost-barrier
# full collection, which marks from every root whatever the slices missed.
private def rescan100_finish(heap : Gcry::Heap) : Nil
  lost = heap.inc_barrier_lost_collections
  slices = 0
  until heap.collect_a_little(4096)
    slices += 1
    fail "the cycle did not finish in #{slices} slices" if slices > 100_000
  end
  heap.inc_barrier_lost_collections.should eq(lost)
end

# *remap*'s stop trace: X's mark state at each stop, so a control that keeps
# X says where it was marked.
private def rescan100_trace(heap : Gcry::Heap) : Nil
  Rescan100Roots.stops = 0
  Rescan100Roots.x_first_marked_stop = -1
  heap.collection_event_hook = ->(event : Gcry::Heap::CollectionEvent) do
    rescan100_trace_event(heap, event)
    # The hook runs inside the stop, `PostStopWorld` just before the root
    # scan, at about the depth of the scan's own frames: the reads' frames
    # below this one leave X's address in slots the scan then reads, and
    # the stop marks X through its own trace (every run of both arms on
    # aarch64 with the freelist allocator). Zeroed here, as
    # `rescan100_scrub_stack` zeroes the window's dead frames.
    rescan100_scrub_stack
    nil
  end
end

# The hook's reads, in a frame of their own below the hook's, so X's and the
# old block's addresses exist only in it and the lookups it calls, all of
# which the hook's scrub then zeroes. Allocates nothing.
@[NoInline]
private def rescan100_trace_event(heap : Gcry::Heap, event : Gcry::Heap::CollectionEvent) : Nil
  x = Pointer(Void).new(~Rescan100Roots.x_inv)
  if event.post_stop_world?
    stop = Rescan100Roots.stops
    Rescan100Roots.stops = stop + 1
    marked = heap.rescan100_marked?(x) || false
    Rescan100Roots.x_first_marked_stop = stop if marked && Rescan100Roots.x_first_marked_stop < 0
  elsif event.pre_start_world? && Rescan100Roots.stops == 1
    Rescan100Roots.x_marked_begin = heap.rescan100_marked?(x) || false
    Rescan100Roots.big_marked_begin = heap.rescan100_marked?(Pointer(Void).new(~Rescan100Roots.big_inv)) || false
  elsif event.mark_end?
    Rescan100Roots.x_marked_mark_end = heap.rescan100_marked?(x) || false
  end
end

private def rescan100_say_trace : Nil
  rescan100_say("rescan100 remap trace: stops=#{Rescan100Roots.stops} " \
                "X marked at the begin stop's end=#{Rescan100Roots.x_marked_begin} " \
                "old block marked there=#{Rescan100Roots.big_marked_begin} " \
                "first stop X was marked entering=#{Rescan100Roots.x_first_marked_stop} " \
                "X marked at the finishing mark's end=#{Rescan100Roots.x_marked_mark_end}")
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
  x_inv = 0_u64
  attempt = 0
  loop do
    attempt += 1
    Rescan100Roots.big_inv = rescan100_old_block if window == "remap"
    x_inv = rescan100_build
    Rescan100Roots.x_inv = x_inv
    rescan100_scrub_stack
    rescan100_trace(heap) if window == "remap"
    # The begin stop and one unit of marking.
    heap.collect_a_little(1) && fail "the cycle finished in its first slice"
    unless heap.incremental_in_progress? && heap.barrier_backend_name == "mprotect"
      rescan100_say("#{RESCAN100_SKIP_MARK}: no incremental cycle on the mprotect barrier")
      return nil
    end
    marked = heap.rescan100_marked?(Pointer(Void).new(~x_inv))
    fail "X is not an allocated block after the begin slice" if marked.nil?
    fail "X was marked before the move: the window was not reached" if marked
    break unless window == "remap"
    old_marked = heap.rescan100_marked?(Pointer(Void).new(~Rescan100Roots.big_inv))
    fail "the old block is not an allocated block: the window was not reached" if old_marked.nil?
    break unless old_marked
    # A false root marked the old block in the begin stop: a word of static
    # data (the first-mark attribution said so) pointing into its 4 MiB,
    # about 1 run in 100 with ASLR. Then it is grey, and its entry, popped
    # after the remap, reads the new block: no window. Run this cycle out
    # and build the window again on a new old block, this one held so the
    # next is mapped elsewhere.
    fail "the old block was marked in the begin slice #{attempt} times: the window was not reached" if attempt == 3
    rescan100_say("rescan100 remap: a false root marked the old block, attempt #{attempt} run out and built again")
    Rescan100Roots.spares << Pointer(Void).new(~Rescan100Roots.big_inv)
    rescan100_finish(heap)
  end

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
  when "remap"
    old = Pointer(Void).new(~Rescan100Roots.big_inv)
    GC.free(old)
    heap.trim_large_cache(0_u64, defer: false)
    block = GC.malloc(RESCAN100_NEW_BYTES).as(Void**)
    Rescan100Roots.moved = block.as(Void*)
    fail "the new block is not where the old one was: the window was not reached" unless block.address == old.address
    old = Pointer(Void).null
    # 16 KiB in, past the first page, which the free's header write dirtied.
    far = block + 2048
    fail "the cards do not call the new block protected: the window was not reached" if rescan100_untracked?(far.address)
    rescan100_move(slot.to_unsafe, holder)
    far.value = slot[0]
    slot[0] = Pointer(Void).null
    block = Pointer(Void*).null
    # The move's frame and the calls since leave X's address in dead stack
    # slots the terminating stop's root rescan reads; the control must find
    # X through the block alone.
    rescan100_scrub_stack
  else
    fail "unknown window #{window}"
  end
  holder = Pointer(Void*).null

  rescan100_finish(heap)
  if window == "remap"
    heap.collection_event_hook = nil
    rescan100_say_trace
  end
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
    elsif window == "remap"
      {% if flag?(:linux) %}
        Gcry::Platform.mprotect_scan_unarmed_chunks = false
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
