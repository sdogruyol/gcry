require "../../src/gcry"
require "spec"

# The mprotect page barrier's cards cover the heap span as it was at the arm
# (`arm_mprotect_on_old_chunks`: `mprotect_set_heap_range(@heap_min,
# @heap_max)`), and the dirty-page scan of every minor and of an incremental
# cycle's termination (`Heap#scan_mprotect_pages`) runs against them after
# the chunk set has moved on. Until 2026-11-02 it went wrong two ways, each
# killing the collection with "Invalid memory access":
#
# - *outside*: the scan protects the old chunks again afterwards, walking
#   the chunks as they are by then. A chunk mapped since the arm can lie
#   outside the cards — a large allocation gets a mapping of its own, and on
#   Linux the kernel places new mappings below the existing ones — and it
#   was made read-only all the same, with no protected bit anywhere
#   (`mprotect_protect_range` set only the bits inside the cards and
#   protected the whole range). The sweep of the same collection wrote its
#   header (the chunk-list rebuild, `ChunkHeader.link`; under an
#   incremental cycle's last slice, a new small chunk's occupancy bitmap),
#   the fault had no card to claim it, and the handler handed it to
#   Crystal's. Now `mprotect_protect_range` never protects outside the
#   cards, and an incremental slice's scan replaces cards the heap has
#   outgrown.
# - *stale*: the scan read every dirty page in the cards. A page of a
#   cached large chunk is dirtied when the chunk is unlinked from the cache
#   and stays dirty after the chunk is unmapped (`trim_large_cache`, which
#   the allocation path runs between collections), so the scan read a page
#   with nothing mapped. Now it reads the dirty pages of the chunks the heap
#   holds.
#
# The fix brought two more:
#
# - *rebuild*: an incremental slice that does not finish lets the mutators
#   run under the protection its scan left, so the chunk mapped outside the
#   cards must be covered by new ones after that scan, and a write to it
#   recorded (`mprotect_rebuild_outgrown_cards = false`, the clip alone,
#   leaves it untracked).
# - *nocards*: when no cards can be had — a span past 16 Mi pages, or a
#   refused `malloc`, forced here through `mprotect_refuse_cards` — the
#   backend goes to `None`, and an incremental cycle that lost its barrier
#   in a scan ends in a full collection. Kept `Mprotect`
#   (`mprotect_drop_without_cards = false`, the code before), the barrier
#   is blind: the cycle finishes and sweeps an object whose only heap
#   reference was stored after the cards were lost. (Before the clip, the
#   pages were protected anyway and the first write died.)
# - *race*: the slice that lost the barrier released the section with the
#   cycle still open, and a slice queued behind it (it checked
#   `@inc_active` before queueing) finished the cycle on those blind marks
#   ahead of the full collection. Now the losing slice drops the cycle
#   inside its stop, and a slice re-reads `@inc_active` once it holds the
#   section (`inc_lost_cycle_ends_in_stop = false` restores both).
# - *softdirty*: a termination scan that returns false with the backend
#   still up — soft-dirty's too-dirty fallback — let the slice finish on a
#   mark whose dirty set it never read. Any failed termination scan now
#   ends the cycle the same way (`inc_scan_false_is_lost = false` restores
#   the old rule). Its window is described at `mprotect99_softdirty`.
#
# *outside* and *stale* run the nursery with the mprotect barrier and a
# minor to arm it. *outside*: a large block big enough that no hole inside
# the cards holds it, freed into the large cache, then a second minor.
# *stale*: a large block held across the arm, freed (its first page
# dirtied), the cache trimmed to nothing (unmapped), then a second minor.
# Their control arms (`Gcry::Platform.mprotect_cards_cover_protection`,
# `mprotect_dirty_scan_by_chunk` = false, the code before) must die in that
# minor. *rebuild*, *nocards* and *race* begin an incremental cycle with
# automatic collection off and drive its slices
# (`mprotect99_incremental_window`); their controls must report the
# untracked chunk, the swept object and the queued slice's sweep. A
# fixed arm passes on nothing without its control. Every arm runs in a
# process of its own. A child that cannot build its construction — no
# nursery (the headerless layout), no mprotect barrier (Linux only), the
# block inside the cards after all, the free not cached or not dirtying —
# says so and the parent accepts it.
# `bench/log/linux/2026-11-02-nursery-mprotect/FINDINGS.md`.

private MPROTECT99_SKIP_MARK  = "mprotect99: this heap cannot reach the window, skipped"
private MPROTECT99_FIXED_MARK = "mprotect99: the fixed arm ran to its end"
# Larger than any hole the spec runner's heap has when the child starts.
private MPROTECT99_OUTSIDE_BYTES = 16 * 1024 * 1024
private MPROTECT99_STALE_BYTES   = 1 * 1024 * 1024

# Held across the arm: a class variable is a static root.
private class Mprotect99Hold
  class_property block = Pointer(Void).null
end

private def mprotect99_say(text : String) : Nil
  STDOUT.puts text
  STDOUT.flush
end

private def mprotect99_page(addr : UInt64) : UInt64
  {% if flag?(:linux) %}
    addr & ~(Gcry::Platform::PAGE - 1)
  {% else %}
    addr
  {% end %}
end

# The nursery on with the mprotect barrier, armed by a minor. False when
# this heap has neither.
private def mprotect99_arm(heap : Gcry::Heap) : Bool
  heap.prefer_mprotect_barrier = true
  heap.nursery_enabled = true
  return false unless heap.nursery_enabled
  heap.minor_collect
  heap.barrier_backend_name == "mprotect"
end

private def mprotect99_outside : Nil
  {% if flag?(:linux) && flag?(:gcry_block_headers) %}
    heap = Gcry.default_heap
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: no nursery or no mprotect barrier") unless mprotect99_arm(heap)
    block = GC.malloc(MPROTECT99_OUTSIDE_BYTES)
    low = block.address
    if Gcry::Platform.mprotect_cards_cover?(low, low + MPROTECT99_OUTSIDE_BYTES.to_u64)
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the block landed inside the cards")
    end
    # Freed into the large cache, as the report's 300 000 bytes were; the
    # default retain (4 MiB) would unmap a block this big at once. Kept live
    # instead, it does not reach the window in this runner: the sweep wrote
    # no header of it.
    heap.large_cache_retain = 2_u64 * MPROTECT99_OUTSIDE_BYTES
    cached = heap.large_free_bytes
    GC.free(block)
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the free did not cache the chunk") unless heap.large_free_bytes > cached
    mprotect99_say("mprotect99 outside: a freed large chunk lies below or above the arm's cards")
    # Scans the dirty pages, protects the old chunks again, sweeps.
    heap.minor_collect
    mprotect99_say(MPROTECT99_FIXED_MARK)
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux with -Dgcry_block_headers only")
  {% end %}
end

private def mprotect99_stale : Nil
  {% if flag?(:linux) && flag?(:gcry_block_headers) %}
    heap = Gcry.default_heap
    Mprotect99Hold.block = GC.malloc(MPROTECT99_STALE_BYTES)
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: no nursery or no mprotect barrier") unless mprotect99_arm(heap)
    block = Mprotect99Hold.block
    Mprotect99Hold.block = Pointer(Void).null
    low = mprotect99_page(block.address)
    high = block.address + MPROTECT99_STALE_BYTES.to_u64
    cached = heap.large_free_bytes
    # Links the chunk into the cache: a write to its protected first page.
    GC.free(block)
    dirty = false
    Gcry::Platform.each_mprotect_dirty_page(low, high) { dirty = true }
    unless dirty && heap.large_free_bytes > cached
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the free did not cache or dirty the chunk")
    end
    heap.trim_large_cache(0_u64, defer: false)
    return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the trim left the cache") unless heap.large_free_bytes == 0
    mprotect99_say("mprotect99 stale: a dirtied large chunk is unmapped")
    heap.minor_collect
    mprotect99_say(MPROTECT99_FIXED_MARK)
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux with -Dgcry_block_headers only")
  {% end %}
end

# Incremental slices of this many marks. The chain is longer, so a
# termination scan that finds it leaves the slice unfinished.
private MPROTECT99_WORK  =  4096
private MPROTECT99_CHAIN = 20000

# Hidden while a cycle begins: kept complemented, so no root holds them and
# the cycle starts with them white.
private class Mprotect99Inc
  class_property chain_inv = 0_u64
  class_property x_inv = 0_u64
  class_property holder1 = Pointer(Void*).null
  class_property holder2 = Pointer(Void*).null
  class_property block = Pointer(Void).null
  class_property sink = 0_u64
end

@[NoInline]
private def mprotect99_hide_white : Nil
  head = Pointer(Void).null
  MPROTECT99_CHAIN.times do
    node = GC.malloc(16).as(Void**)
    node[0] = head
    head = node.as(Void*)
  end
  Mprotect99Inc.chain_inv = ~head.address
  x = GC.malloc_atomic(64).as(UInt8*)
  64.times { |i| x[i] = 0x99_u8 }
  Mprotect99Inc.x_inv = ~x.address
end

@[NoInline]
private def mprotect99_consume(words : UInt64*) : Nil
  Mprotect99Inc.sink = words[0] &+ words[4095]
end

# The cycle's first stop scans this thread's stack from the collector's
# frames up, and their unused slots can still hold what
# `mprotect99_hide_white`'s frames left there: zeroed first, so the chain
# and the object begin white.
@[NoInline]
private def mprotect99_scrub_stack : Nil
  buf = uninitialized StaticArray(UInt64, 8192)
  words = buf.to_unsafe
  8192.times { |i| words[i] = 0_u64 }
  mprotect99_consume(words)
end

# Stores *value* through *slot*, so the pointer sits in the caller's frame
# as it is, not as the complement it was computed from, and a full
# collection's stack scan finds it.
@[NoInline]
private def mprotect99_pin(slot : Void**, value : Void*) : Nil
  slot.value = value
end

{% if flag?(:linux) %}
  private def mprotect99_dirty?(low : UInt64, high : UInt64) : Bool
    dirty = false
    Gcry::Platform.each_mprotect_dirty_page(low, high) { dirty = true }
    dirty
  end
{% end %}

# Begins an incremental cycle on the mprotect barrier with automatic
# collection off, then, inside it: a small block in an old, protected chunk
# (allocated black, so never scanned) given the white chain — a dirty page
# the termination scan will find — and a 16 MiB block mapped outside the
# cards. Then drives slices until the termination scan has run (or the
# cycle has ended). Returns nil after saying why it skipped, else whether
# the cycle finished.
private def mprotect99_incremental_window(heap : Gcry::Heap, refuse : Bool, pin : Void** = Pointer(Void*).null,
                                          work : Int32 = MPROTECT99_WORK, before_slices : Proc(Nil)? = nil) : Bool?
  {% if flag?(:linux) %}
    heap.disable
    heap.prefer_mprotect_barrier = true
    mprotect99_hide_white
    mprotect99_scrub_stack
    heap.collect_a_little(1)
    unless heap.@inc_active && heap.barrier_backend_name == "mprotect"
      mprotect99_say("#{MPROTECT99_SKIP_MARK}: no incremental cycle on the mprotect barrier")
      return nil
    end
    # After the cycle's root scan. The terminating stop scans the stacks
    # again (regression 100), and *nocards*' control turns that off, or its
    # stack would keep the object it needs swept.
    mprotect99_pin(pin, Pointer(Void).new(~Mprotect99Inc.x_inv)) unless pin.null?
    holder1 = GC.malloc(64).as(Void**)
    Mprotect99Inc.holder1 = holder1
    page1 = mprotect99_page(holder1.address)
    unless Gcry::Platform.mprotect_cards_cover?(page1, page1 + Gcry::Platform::PAGE)
      mprotect99_say("#{MPROTECT99_SKIP_MARK}: the holder is in no card")
      return nil
    end
    block = GC.malloc(MPROTECT99_OUTSIDE_BYTES)
    Mprotect99Inc.block = block
    if Gcry::Platform.mprotect_cards_cover?(block.address, block.address + MPROTECT99_OUTSIDE_BYTES.to_u64)
      mprotect99_say("#{MPROTECT99_SKIP_MARK}: the block landed inside the cards")
      return nil
    end
    holder1[0] = Pointer(Void).new(~Mprotect99Inc.chain_inv)
    unless mprotect99_dirty?(page1, page1 + Gcry::Platform::PAGE)
      mprotect99_say("#{MPROTECT99_SKIP_MARK}: the holder's write left no dirty bit")
      return nil
    end
    Gcry::Platform.mprotect_refuse_cards = true if refuse
    before_slices.try &.call
    rescans = heap.barrier_dirty_rescans
    lost = heap.inc_barrier_lost_collections
    slices = 0
    until heap.barrier_dirty_rescans > rescans || heap.inc_barrier_lost_collections > lost
      return true if heap.collect_a_little(work)
      slices += 1
      fail "no termination scan in #{slices} slices" if slices > 100_000
    end
    false
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux only")
    nil
  {% end %}
end

private def mprotect99_finish_cycle(heap : Gcry::Heap) : Nil
  slices = 0
  until heap.collect_a_little(MPROTECT99_WORK)
    slices += 1
    fail "the cycle did not finish in #{slices} slices" if slices > 100_000
  end
end

# *rebuild*: after the termination scan of a slice that does not finish,
# the chunk mapped outside the arm's cards must be covered by new ones and
# a write to it recorded — the mutators run under this protection until
# the next slice.
private def mprotect99_rebuild(arm : String) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    finished = mprotect99_incremental_window(heap, refuse: false)
    return if finished.nil?
    if finished
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the termination scan found nothing and finished the cycle")
    end
    block = Mprotect99Inc.block
    covered = Gcry::Platform.mprotect_cards_cover?(block.address, block.address + MPROTECT99_OUTSIDE_BYTES.to_u64)
    page = mprotect99_page(block.address + Gcry::Platform::PAGE)
    Pointer(UInt8).new(page).value = 0x99_u8
    recorded = mprotect99_dirty?(page, page + Gcry::Platform::PAGE)
    mprotect99_say("mprotect99 rebuild: after an unfinished slice the new chunk is covered: #{covered}, its write recorded: #{recorded}")
    if arm == "control"
      covered.should be_false
      recorded.should be_false
      mprotect99_say("mprotect99 rebuild: control left the new chunk untracked")
    else
      covered.should be_true
      recorded.should be_true
    end
    mprotect99_finish_cycle(heap)
    mprotect99_say(MPROTECT99_FIXED_MARK) unless arm == "control"
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux only")
  {% end %}
end

# *nocards*: the termination scan's rebuild gets no cards (refused through
# the research hook, as a span past the limit or a failed `malloc` would).
# Then an object the cycle has not reached is stored into a block allocated
# black — the store the barrier exists to report — and the cycle runs out.
# Fixed: the cycle ends in a full collection at that slice, which finds the
# object on this stack, and it lives. Control (`mprotect_drop_without_cards
# = false`): the cycle finishes on its blind barrier and sweeps the object.
# Regression 100's two termination fixes would each find the object anyway
# — the root rescan on this stack, the untracked-page scan in a heap no
# cards vouch for — so the control turns both off
# (`inc_finish_rescan_roots`, `mprotect_scan_untracked`).
private def mprotect99_nocards(arm : String) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    slot = uninitialized StaticArray(Void*, 1)
    slot[0] = Pointer(Void).null
    finished = mprotect99_incremental_window(heap, refuse: true, pin: slot.to_unsafe)
    return if finished.nil?
    x = slot[0].as(UInt8*)
    if arm == "control"
      if finished
        return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the termination scan found nothing and finished the cycle")
      end
      heap.barrier_backend_name.should eq("mprotect")
      page1 = mprotect99_page(Mprotect99Inc.holder1.address)
      Gcry::Platform.mprotect_cards_cover?(page1, page1 + Gcry::Platform::PAGE).should be_false
    else
      finished.should be_true
      heap.inc_barrier_lost_collections.should eq(1)
      heap.barrier_backend_name.should eq("none")
    end
    holder2 = GC.malloc(64).as(Void**)
    holder2[0] = x.as(Void*)
    Mprotect99Inc.holder2 = holder2
    mprotect99_finish_cycle(heap) if heap.@inc_active
    alive = !heap.find_object(x.as(Void*)).nil?
    mprotect99_say("mprotect99 nocards: the object stored after the cards were lost is alive: #{alive}")
    if arm == "control"
      alive.should be_false
      mprotect99_say("mprotect99 nocards: control swept an object stored after the cards were lost")
      return
    end
    alive.should be_true
    heap.collect
    heap.find_object(x.as(Void*)).should_not be_nil
    64.times { |i| x[i].should eq(0x99_u8) }
    mprotect99_say(MPROTECT99_FIXED_MARK)
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux only")
  {% end %}
end

# *race*: the slice that loses its barrier must end the cycle inside its
# stop, and a slice queued behind it must not finish the cycle it left. A
# second thread is queued for the collection section from inside the
# losing slice — `Heap.inc_slice_locked_hook` releases it there, before
# the slice sets `@collecting`, and waits until it holds a ticket — so it
# runs the moment the losing slice lets the section go, ahead of the full
# collection. Fixed: it finds the cycle dropped and returns false. Control
# (`inc_lost_cycle_ends_in_stop = false`): it runs a slice on the marks the
# blind barrier left, finds nothing more to mark, and sweeps on them —
# finishing the cycle (true) before the full collection runs.
private module Mprotect99Race
  @@armed = Atomic(Int32).new(0)
  @@go = Atomic(Int32).new(0)
  # 0 not run, 1 returned false, 2 returned true.
  @@result = Atomic(Int32).new(0)
  # Whether the second thread took a ticket while the losing slice held
  # the section, rather than arriving after it.
  @@queued = Atomic(Int32).new(0)

  def self.queued? : Bool
    @@queued.get == 1
  end

  def self.arm : Nil
    @@armed.set(1)
  end

  # In the losing slice, holding the section. Allocates nothing.
  def self.locked : Nil
    return unless @@armed.swap(0) == 1
    heap = Gcry.default_heap
    queued = heap.@post_stw_next
    @@go.set(1)
    deadline = Gcry::Clock.monotonic_ns &+ 10_000_000_000_u64
    loop do
      Atomic::Ops.fence(LLVM::AtomicOrdering::SequentiallyConsistent, false)
      if heap.@post_stw_next != queued
        @@queued.set(1)
        break
      end
      break if Gcry::Clock.monotonic_ns > deadline
      Intrinsics.pause
    end
  end

  def self.second_slice : Nil
    until @@go.get == 1
      Intrinsics.pause
    end
    @@result.set(Gcry.default_heap.collect_a_little(MPROTECT99_WORK) ? 2 : 1)
  end

  def self.result : Int32
    @@result.get
  end
end

private def mprotect99_race(arm : String) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.inc_lost_cycle_ends_in_stop = arm == "fixed"
    second = Thread.new { Mprotect99Race.second_slice }
    Gcry::Heap.inc_slice_locked_hook = -> { Mprotect99Race.locked }
    finished = mprotect99_incremental_window(heap, refuse: true, work: Int32::MAX,
      before_slices: -> { Mprotect99Race.arm })
    if finished.nil?
      Mprotect99Race.arm
      Mprotect99Race.locked
      second.join
      return
    end
    second.join
    Gcry::Heap.inc_slice_locked_hook = nil
    finished.should be_true
    heap.inc_barrier_lost_collections.should eq(1)
    Mprotect99Race.queued?.should be_true
    result = Mprotect99Race.result
    mprotect99_say("mprotect99 race: the queued slice returned #{result == 2}")
    if arm == "control"
      result.should eq(2)
      mprotect99_say("mprotect99 race: control finished the cycle on the blind marks")
    else
      result.should eq(1)
      mprotect99_say(MPROTECT99_FIXED_MARK)
    end
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux only")
  {% end %}
end

# *softdirty*: on the soft-dirty backend the termination scan's too-dirty
# fallback (`scan_softdirty_pages`) returns false with the backend still
# up, and the slice used to finish on the mark, its dirty set unread. An
# object X reachable when the cycle begins only from the end of a chain is
# moved, before the mark gets there, into a block allocated black (never
# scanned) and the chain's field cleared: only the dirty page of that
# block holds it. `soft_dirty_max_pct = 1` makes the fallback certain (the
# mark's own writes dirty enough pages anyway: 335 of 538 in IncStack's
# probe). Fixed: the cycle ends in a full collection and X lives. Control
# (`inc_scan_false_is_lost = false`): the slice sweeps X. Nothing here is
# on a stack, so a root rescan at the finish cannot save it either.
private class Mprotect99Sd
  class_property head = Pointer(Void).null
  class_property moved = Pointer(Void*).null
end

private MPROTECT99_SD_CHAIN = 4000

# Returns X complemented; the chain's last node is the holder, X its field.
@[NoInline]
private def mprotect99_sd_graph : UInt64
  holder = GC.malloc(64).as(Void**)
  x = GC.malloc_atomic(64).as(UInt8*)
  64.times { |i| x[i] = 0x5A_u8 }
  holder[0] = x.as(Void*)
  last = holder.as(Void*)
  MPROTECT99_SD_CHAIN.times do
    node = GC.malloc(16).as(Void**)
    node[0] = last
    last = node.as(Void*)
  end
  Mprotect99Sd.head = last
  ~x.address
end

# Moves the holder's field into *target* and clears it, through no slot
# that outlives the call.
@[NoInline]
private def mprotect99_sd_move(target : Void**) : Nil
  p = Mprotect99Sd.head
  MPROTECT99_SD_CHAIN.times { p = p.as(Void**)[0] }
  holder = p.as(Void**)
  target[0] = holder[0]
  holder[0] = Pointer(Void).null
end

private def mprotect99_softdirty(arm : String) : Nil
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.disable
    heap.inc_scan_false_is_lost = arm == "fixed"
    heap.soft_dirty_max_pct = 1
    x_inv = mprotect99_sd_graph
    mprotect99_scrub_stack
    heap.collect_a_little(1)
    unless heap.@inc_active && heap.barrier_backend_name == "soft_dirty"
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: no incremental cycle on soft-dirty (backend #{heap.barrier_backend_name})")
    end
    target = GC.malloc(16).as(Void**)
    Mprotect99Sd.moved = target
    mprotect99_sd_move(target)
    target = Pointer(Void*).null
    fallbacks = heap.@soft_dirty_fallbacks
    mprotect99_finish_cycle(heap)
    if heap.@soft_dirty_fallbacks == fallbacks
      return mprotect99_say("#{MPROTECT99_SKIP_MARK}: the termination scan did not fall back")
    end
    x = Pointer(UInt8).new(~x_inv)
    alive = !heap.find_object(x.as(Void*)).nil?
    mprotect99_say("mprotect99 softdirty: the object only a dirty page held is alive: #{alive}")
    if arm == "control"
      alive.should be_false
      mprotect99_say("mprotect99 softdirty: control swept an object only the unread dirty set held")
      return
    end
    heap.inc_barrier_lost_collections.should eq(1)
    alive.should be_true
    64.times { |i| x[i].should eq(0x5A_u8) }
    mprotect99_say(MPROTECT99_FIXED_MARK)
  {% else %}
    mprotect99_say("#{MPROTECT99_SKIP_MARK}: Linux only")
  {% end %}
end

# Runs one child; kills it past *seconds*. Returns its status and output.
private def mprotect99_child(arm : String, seconds : Int32 = 90) : {Process::Status, String}
  captured = IO::Memory.new
  child = Process.new(Process.executable_path.not_nil!, ["-e", "mprotect-outside-cards child #{arm}"],
    env: {"GCRY_MPROTECT99_CHILD" => arm}, output: captured, error: captured)
  deadline = Time.instant + seconds.seconds
  until child.terminated? || Time.instant >= deadline
    sleep 100.milliseconds
  end
  child.terminate(graceful: false) unless child.terminated?
  status = child.wait
  {status, captured.to_s}
end

private def mprotect99_expect_fixed(arm : String) : Nil
  status, text = mprotect99_child(arm)
  fail "child #{arm} #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  text.should contain(MPROTECT99_FIXED_MARK) unless text.includes?(MPROTECT99_SKIP_MARK)
end

# The handler forwards the fault to Crystal's handler, which prints and
# exits with the signal number.
private def mprotect99_expect_death(arm : String, reached : String) : Nil
  status, text = mprotect99_child(arm)
  return if status.success? && text.includes?(MPROTECT99_SKIP_MARK)
  text.should contain(reached)
  fail "the control arm survived:\n#{text}" if status.success?
  text.should contain("Invalid memory access")
  text.should_not contain(MPROTECT99_FIXED_MARK)
end

# Passes with *mark* in the output unless the child skipped.
private def mprotect99_expect_mark(arm : String, mark : String) : Nil
  status, text = mprotect99_child(arm)
  fail "child #{arm} #{status.inspect}:\n#{text}" unless status.success?
  text.should contain("1 examples, 0 failures")
  text.should contain(mark) unless text.includes?(MPROTECT99_SKIP_MARK)
end

describe "Regression: the mprotect dirty-page scan against a chunk set that moved since the arm" do
  it "outside: fixed arm in a process of its own" do
    mprotect99_expect_fixed("outside-fixed")
  end

  it "outside: control arm protects a chunk no card covers and dies" do
    mprotect99_expect_death("outside-control", "mprotect99 outside: a freed large chunk lies")
  end

  it "stale: fixed arm in a process of its own" do
    mprotect99_expect_fixed("stale-fixed")
  end

  it "stale: control arm reads an unmapped dirty page and dies" do
    mprotect99_expect_death("stale-control", "mprotect99 stale: a dirtied large chunk is unmapped")
  end

  it "rebuild: fixed arm in a process of its own" do
    mprotect99_expect_mark("rebuild-fixed", MPROTECT99_FIXED_MARK)
  end

  it "rebuild: control arm leaves the new chunk untracked" do
    mprotect99_expect_mark("rebuild-control", "mprotect99 rebuild: control left the new chunk untracked")
  end

  it "nocards: fixed arm in a process of its own" do
    mprotect99_expect_mark("nocards-fixed", MPROTECT99_FIXED_MARK)
  end

  it "nocards: control arm sweeps an object stored after the cards were lost" do
    mprotect99_expect_mark("nocards-control", "mprotect99 nocards: control swept an object stored after the cards were lost")
  end

  it "race: fixed arm in a process of its own" do
    mprotect99_expect_mark("race-fixed", MPROTECT99_FIXED_MARK)
  end

  it "race: control arm finishes the cycle in a queued slice" do
    mprotect99_expect_mark("race-control", "mprotect99 race: control finished the cycle on the blind marks")
  end

  it "softdirty: fixed arm in a process of its own" do
    mprotect99_expect_mark("softdirty-fixed", MPROTECT99_FIXED_MARK)
  end

  it "softdirty: control arm sweeps what only the dirty set held" do
    mprotect99_expect_mark("softdirty-control", "mprotect99 softdirty: control swept an object only the unread dirty set held")
  end

  it "mprotect-outside-cards child outside-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "outside-fixed"
    mprotect99_outside
  end

  it "mprotect-outside-cards child outside-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "outside-control"
    {% if flag?(:linux) %}
      Gcry::Platform.mprotect_cards_cover_protection = false
    {% end %}
    mprotect99_outside
  end

  it "mprotect-outside-cards child stale-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "stale-fixed"
    mprotect99_stale
  end

  it "mprotect-outside-cards child stale-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "stale-control"
    {% if flag?(:linux) %}
      Gcry::Platform.mprotect_dirty_scan_by_chunk = false
    {% end %}
    mprotect99_stale
  end

  it "mprotect-outside-cards child rebuild-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "rebuild-fixed"
    mprotect99_rebuild("fixed")
  end

  it "mprotect-outside-cards child rebuild-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "rebuild-control"
    {% if flag?(:linux) %}
      Gcry::Platform.mprotect_rebuild_outgrown_cards = false
    {% end %}
    mprotect99_rebuild("control")
  end

  it "mprotect-outside-cards child nocards-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "nocards-fixed"
    mprotect99_nocards("fixed")
  end

  it "mprotect-outside-cards child nocards-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "nocards-control"
    {% if flag?(:linux) %}
      Gcry::Platform.mprotect_drop_without_cards = false
      Gcry::Platform.mprotect_scan_untracked = false
      Gcry::Heap.inc_finish_rescan_roots = false
    {% end %}
    mprotect99_nocards("control")
  end

  it "mprotect-outside-cards child race-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "race-fixed"
    mprotect99_race("fixed")
  end

  it "mprotect-outside-cards child race-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "race-control"
    mprotect99_race("control")
  end

  it "mprotect-outside-cards child softdirty-fixed" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "softdirty-fixed"
    mprotect99_softdirty("fixed")
  end

  it "mprotect-outside-cards child softdirty-control" do
    next unless ENV["GCRY_MPROTECT99_CHILD"]? == "softdirty-control"
    mprotect99_softdirty("control")
  end
end
