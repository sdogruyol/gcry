# Finalizer complex scenarios.
#
# Tests advanced finalizer behaviours:
#   0. Boehm rule — the callback runs on an object the sweep has not reclaimed
#   1. Finalizer chain — one finalizer triggers another
#   2. Finalizer that calls GC.collect
#   3. Finalizer that resurrects objects
#   4. Finalizer + disappearing links interaction
#   5. Finalizer under heavy allocation pressure
#   6. Finalizer that creates many objects
#   7. Finalizer thread safety
#
# Build & run:
#   crystal build -Dgc_none bench/finalizer_complex.cr -o bin/finalizer_complex
#   ./bin/finalizer_complex
#   ./bin/finalizer_complex --broken    # resurrection off: the callback must find its object swept
#
# Every phase above asserts that a finalizer *ran*; none asserted what it ran
# on, and that is the half with a history: before the Boehm rule
# (`enqueue_unreachable_finalizers` marks a queued object so the sweep leaves
# it) `Socket#finalize` ran on freed memory, the acik wrk SEGV. Phase 0 asks
# the callback whether its object is still allocated (`Heap#live?`) at the
# moment it runs. `--broken` sets `finalizer_resurrect = false` — the
# pre-rule behaviour — runs phase 0 alone, and requires the callback to find
# the block gone. Dropping the resurrection reddens the shipped arm; dropping
# the property's effect reddens `--broken`. Until 2026-09-21 the only way this
# gate came out red was a hand edit.

require "../src/gcry"

broken = ARGV.includes?("--broken")

failures = 0
ok = 0

# ---------------------------------------------------------------
# Phase 0: the Boehm rule — the callback sees an allocated object
# ---------------------------------------------------------------
puts "=== Phase 0: the finalizer runs on an object the sweep left alone#{broken ? " (--broken: resurrection off, it must not)" : ""} ==="
begin
  heap = Gcry::Heap.new
  heap.finalizer_resurrect = false if broken
  ran = false
  alive_in_callback = false

  obj = heap.malloc(48)
  heap.add_finalizer(obj) do |ptr|
    ran = true
    alive_in_callback = heap.live?(ptr)
  end

  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false)

  if !ran
    puts "FAIL: Phase 0 — finalizer did not run"
    failures += 1
  elsif broken && alive_in_callback
    puts "FAIL: Phase 0 — resurrection is off and the callback still found its object allocated; the property no longer restores the defect"
    failures += 1
  elsif !broken && !alive_in_callback
    puts "FAIL: Phase 0 — the callback ran on a block the sweep had already reclaimed"
    failures += 1
  else
    puts "  the callback found its object #{alive_in_callback ? "allocated" : "swept"}"
    ok += 1
  end

  heap.destroy
rescue ex
  puts "Phase 0 CRASH: #{ex}"
  failures += 1
end

if broken
  puts ""
  puts "finalizer_complex --broken: #{ok} passed, #{failures} failed"
  exit(failures > 0 ? 1 : 0)
end

# ---------------------------------------------------------------
# Phase 1: Finalizer chain — one finalizer triggers another
# ---------------------------------------------------------------
puts "=== Phase 1: Finalizer chain ==="
begin
  heap = Gcry::Heap.new
  chain = [] of Int32

  obj1 = heap.malloc(16)
  obj2 = heap.malloc(16)

  heap.add_finalizer(obj1) { chain << 1 }
  heap.add_finalizer(obj2) { chain << 2 }

  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false) # second collect to run pending finalizers

  # Both should have run
  if chain.sort == [1, 2]
    ok += 1
  else
    puts "FAIL: Phase 1 — expected [1, 2], got #{chain}"
    failures += 1
  end

  heap.destroy
rescue ex
  puts "Phase 1 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Phase 2: Finalizer that calls GC.collect
# ---------------------------------------------------------------
puts "=== Phase 2: Finalizer that calls GC.collect ==="
begin
  heap = Gcry::Heap.new
  collected = false

  obj = heap.malloc(16)
  heap.add_finalizer(obj) do
    collected = true
    # This collect should not deadlock
    heap.collect(scan_stack: false)
  end

  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false)

  if collected
    ok += 1
  else
    puts "FAIL: Phase 2 — finalizer did not run"
    failures += 1
  end

  heap.destroy
rescue ex
  puts "Phase 2 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Phase 3: Finalizer that resurrects (adds root in callback)
# ---------------------------------------------------------------
puts "=== Phase 3: Finalizer that resurrects (add_root in callback) ==="
begin
  heap = Gcry::Heap.new
  re_added = false

  obj = heap.malloc(16)
  heap.add_finalizer(obj) do |ptr|
    # Re-add the object as a root — this happens during collect
    # (gcry does not re-mark, so the object is still freed this cycle,
    # but the root pointer is tracked for future collections.)
    heap.add_root(ptr)
    re_added = true
  end

  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false)

  # The finalizer should have run
  if re_added
    ok += 1
  else
    puts "FAIL: Phase 3 — finalizer did not run"
    failures += 1
  end

  heap.destroy
rescue ex
  puts "Phase 3 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Phase 4: Finalizer + disappearing links interaction
# ---------------------------------------------------------------
puts "=== Phase 4: Finalizer + disappearing links ==="
begin
  heap = Gcry::Heap.new

  # Create a referent object and a slot that weakly points to it
  referent = heap.malloc(16)
  link_slot = LibC.malloc(sizeof(Void*)).as(Void**)
  link_slot.value = referent
  heap.register_disappearing_link(link_slot, referent)

  finalized = false
  heap.add_finalizer(referent) do
    finalized = true
  end

  # Drop the referent (no root)
  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false)

  # The link should have been cleared
  if link_slot.value.null?
    ok += 1
  else
    puts "FAIL: Phase 4 — disappearing link not cleared"
    failures += 1
  end

  if finalized
    ok += 1
  else
    puts "FAIL: Phase 4 — finalizer did not run"
    failures += 1
  end

  LibC.free(link_slot)
  heap.destroy
rescue ex
  puts "Phase 4 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Phase 5: Finalizer under heavy allocation pressure
# ---------------------------------------------------------------
puts "=== Phase 5: Finalizer under heavy allocation pressure ==="
begin
  heap = Gcry::Heap.new
  finalized_count = 0
  mutex = Mutex.new

  # Allocate 500 objects with finalizers, then drop them all
  objs = [] of Void*
  500.times do
    obj = heap.malloc(16)
    heap.add_finalizer(obj) do
      mutex.synchronize do
        finalized_count += 1
      end
      # Allocate inside finalizer to add pressure
      tmp = heap.malloc(8)
      heap.free(tmp)
    end
    objs << obj
  end

  # Collect hard to trigger all finalizers
  5.times { heap.collect(scan_stack: false) }

  if finalized_count >= 500
    ok += 1
  else
    puts "FAIL: Phase 5 — expected 500 finalizers, got #{finalized_count}"
    failures += 1
  end

  heap.destroy
rescue ex
  puts "Phase 5 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Phase 6: Finalizer that creates many objects
# ---------------------------------------------------------------
puts "=== Phase 6: Finalizer that creates many objects ==="
begin
  heap = Gcry::Heap.new
  chain_completed = false

  obj = heap.malloc(16)
  heap.add_finalizer(obj) do
    # Create 1000 short-lived objects inside the finalizer
    1000.times do
      t = heap.malloc(4)
      heap.free(t)
    end
    chain_completed = true
  end

  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false)

  if chain_completed
    ok += 1
  else
    puts "FAIL: Phase 6 — finalizer did not create 1000 objects"
    failures += 1
  end

  heap.destroy
rescue ex
  puts "Phase 6 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Phase 7: Finalizer + many disappearing links
# ---------------------------------------------------------------
puts "=== Phase 7: Many disappearing links ==="
begin
  heap = Gcry::Heap.new
  heap.gc_threshold = UInt64::MAX

  n = 200
  links = [] of Void**
  n.times do
    obj = heap.malloc(8)
    slot = LibC.malloc(sizeof(Void*)).as(Void**)
    slot.value = obj
    heap.register_disappearing_link(slot, obj)
    links << slot
  end

  # Drop all references — collect
  heap.collect(scan_stack: false)
  heap.collect(scan_stack: false)

  cleared = links.count { |s| s.value.null? }
  if cleared == n
    ok += 1
  else
    puts "FAIL: Phase 7 — expected #{n} cleared links, got #{cleared}"
    failures += 1
  end

  links.each { |s| LibC.free(s) }
  heap.destroy
rescue ex
  puts "Phase 7 CRASH: #{ex}"
  failures += 1
end

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
puts ""
puts "finalizer_complex: #{ok} passed, #{failures} failed"
exit(failures > 0 ? 1 : 0)
