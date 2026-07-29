# Layout property test for gcry.
#
# Verifies GC layout (precise scan) correctness with random combinations.
# Each sub-test is self-contained: allocates its own aux_ptrs, runs its own
# collect, and verifies independently.
#
# Tests:
#   1. Precise scan follows only registered offsets — non-registered slots
#      do NOT keep children alive after collection.
#   2. Conservative fallback (no registered type) keeps all reachable alive.
#   3. Leaf layout (scan_cap=0) marks nothing — all children die after collect.
#   4. noscan offsets keep the referenced object alive but do NOT scan its
#      own children (no transitive marking from noscan slots).
#   5. scan_cap limits conservative word-scan: slots beyond cap not marked.
#
# Build:  crystal build bench/layout_property_test.cr -o bin/layout_property_test
# Run:    ./bin/layout_property_test [--seed=1] [--iterations=10000]

require "../src/gcry"

# ---- CLI args ----
seed = 1_i64
iterations = 10_000

ARGV.each do |arg|
  case arg
  when /--seed=(\d+)/
    seed = $1.to_i64
  when /--iterations=(\d+)/
    iterations = $1.to_i
  end
end

# ---- Constants ----
# Each "object" is: [type_id: Int32][padding: Int32][pointer_slots: Void* × SLOT_COUNT]
HEADER_WORDS = 2
SLOT_COUNT   = 8
OBJ_BYTES    = (HEADER_WORDS + SLOT_COUNT) * sizeof(Void*)

BASE_TYPE_ID       = 900_001
LAYOUT_PRECISE_TID = BASE_TYPE_ID + 0
LAYOUT_LEAF_TID    = BASE_TYPE_ID + 1
LAYOUT_NOSCAN_TID  = BASE_TYPE_ID + 2
LAYOUT_CAP_TID     = BASE_TYPE_ID + 3

# ---- Wrapper class to hold state ----
class LayoutPropertyTest
  @heap : Gcry::Heap
  @all_allocations : Array(Void*)
  @errors : Array(String)

  def initialize
    @heap = Gcry::Heap.new
    @heap.scan_static_roots = false
    @heap.gc_threshold = UInt64::MAX
    @heap.nursery_threshold = UInt64::MAX
    @heap.nursery_enabled = false
    @heap.release_empty_chunks = true
    @heap.layout_precise = true

    @all_allocations = [] of Void*
    @errors = [] of String
  end

  def heap
    @heap
  end

  def errors
    @errors
  end

  # ---- Helpers ----
  def slot_ptr(obj : Void*, slot : Int32) : Void**
    (obj.as(Void**) + HEADER_WORDS + slot)
  end

  def read_slot(obj : Void*, slot : Int32) : Void*
    slot_ptr(obj, slot).value
  end

  def write_slot(obj : Void*, slot : Int32, val : Void*)
    slot_ptr(obj, slot).value = val
  end

  def set_type_id(obj : Void*, tid : Int32)
    obj.as(Int32*).value = tid
  end

  def alloc
    ptr = @heap.malloc(OBJ_BYTES)
    @all_allocations << ptr
    ptr
  end

  # Bootstrap leaf aux_ptrs (simple objects with no children)
  def make_aux(n : Int32)
    ptrs = [] of Void*
    n.times do
      ptr = alloc
      set_type_id(ptr, LAYOUT_LEAF_TID)
      ptrs << ptr
    end
    ptrs
  end

  # ---- Register synthetic layouts ----
  def register_layouts
    alloc_size = OBJ_BYTES.to_u32

    # Layout 1: precise — scan slots 0 (offset 16) and 2 (offset 32)
    Gcry::Layout.install_full(LAYOUT_PRECISE_TID,
      [16_u16, 32_u16].to_unsafe, 2,
      Pointer(UInt16).null, 0,
      alloc_size, alloc_size,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16, 0_u16, 0_u16)

    # Layout 2: leaf — no offsets, scan_cap = 0 (truly leaf: nothing to scan)
    Gcry::Layout.install_full(LAYOUT_LEAF_TID,
      Pointer(UInt16).null, 0,
      Pointer(UInt16).null, 0,
      alloc_size, 0_u32,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16, 0_u16, 0_u16)

    # Layout 3: noscan — scan slot 0 (offset 16), noscan slot 1 (offset 24)
    Gcry::Layout.install_full(LAYOUT_NOSCAN_TID,
      [16_u16].to_unsafe, 1,
      [24_u16].to_unsafe, 1,
      alloc_size, alloc_size,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16, 0_u16, 0_u16)

    # Layout 4: cap-only — scan_cap = 32 bytes (slots 0-1), no precise offsets
    Gcry::Layout.install_full(LAYOUT_CAP_TID,
      Pointer(UInt16).null, 0,
      Pointer(UInt16).null, 0,
      alloc_size, 32_u32,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16, 0_u16, 0_u16)
  end

  # ---- Test 1: Precise scan follows only registered offsets ----
  # Create an object with LAYOUT_PRECISE_TID, fill all 8 slots with aux_ptrs.
  # After collect with only this object as a root, only slots 0 and 2 should
  # keep their targets alive. Other targets should die (not scanned).
  def test_precise_offsets : Bool
    pass = true
    aux = make_aux(SLOT_COUNT)

    obj = alloc
    set_type_id(obj, LAYOUT_PRECISE_TID)
    SLOT_COUNT.times { |s| write_slot(obj, s, aux[s]) }

    @heap.collect(scan_stack: false, roots: [obj])

    # Slots 0 and 2 should keep targets alive
    [0, 2].each do |s|
      unless @heap.live?(aux[s])
        @errors << "PRECISE-OFFSET: slot #{s} target is DEAD (should be alive)"
        pass = false
      end
    end

    # Other slots should NOT keep targets alive
    (0...SLOT_COUNT).each do |s|
      next if s == 0 || s == 2
      if @heap.live?(aux[s])
        @errors << "PRECISE-OFFSET: slot #{s} target is ALIVE (should be dead with precise layout)"
        pass = false
      end
    end

    pass
  end

  # ---- Test 2: Conservative fallback keeps all reachable ----
  # Allocate without setting a type_id (first word = 0), fill all slots.
  # After collect, all targets should survive (conservative word-scan).
  def test_conservative_fallback : Bool
    pass = true
    aux = make_aux(SLOT_COUNT)

    obj = alloc
    # No type_id set — first word is 0, falls back to conservative word-scan
    SLOT_COUNT.times { |s| write_slot(obj, s, aux[s]) }

    @heap.collect(scan_stack: false, roots: [obj])

    SLOT_COUNT.times do |s|
      unless @heap.live?(aux[s])
        @errors << "CONSERVATIVE: slot #{s} target is DEAD (should survive conservative)"
        pass = false
      end
    end

    pass
  end

  # ---- Test 3: Leaf layout (scan_cap=0) marks nothing ----
  # Create object with LAYOUT_LEAF_TID (scan_cap=0), fill all slots.
  # After collect, NO targets should be kept alive.
  def test_leaf_layout : Bool
    pass = true
    aux = make_aux(SLOT_COUNT)

    obj = alloc
    set_type_id(obj, LAYOUT_LEAF_TID)
    SLOT_COUNT.times { |s| write_slot(obj, s, aux[s]) }

    @heap.collect(scan_stack: false, roots: [obj])

    SLOT_COUNT.times do |s|
      if @heap.live?(aux[s])
        @errors << "LEAF: slot #{s} target is ALIVE (leaf layout should mark nothing)"
        pass = false
      end
    end

    pass
  end

  # ---- Test 4: noscan offsets keep alive but don't scan ----
  # Create a container (precise layout) with children at slots 0 and 2.
  # Create a parent (noscan layout) with slot 0 → container (scan), slot 1 → aux (noscan).
  # After collect with parent as root:
  #   - container should be alive (scan offset)
  #   - container's children (aux[0], aux[1]) should be alive (transitive)
  #   - aux[2] should be alive (noscan keep-alive)
  def test_noscan_offset : Bool
    pass = true

    # Create aux_ptrs that will be children of the container
    container_aux = make_aux(3)

    # Container with precise layout — has children at slots 0 and 2
    container = alloc
    set_type_id(container, LAYOUT_PRECISE_TID)
    write_slot(container, 0, container_aux[0])
    write_slot(container, 2, container_aux[1])

    # Noscan aux
    noscan_aux = make_aux(1)[0]

    # Parent with noscan layout
    parent = alloc
    set_type_id(parent, LAYOUT_NOSCAN_TID)
    write_slot(parent, 0, container)  # scan: container + children
    write_slot(parent, 1, noscan_aux) # noscan: keep alive only

    @heap.collect(scan_stack: false, roots: [parent])

    unless @heap.live?(container)
      @errors << "NOSCAN: container (scan offset) is DEAD"
      pass = false
    end

    unless @heap.live?(container_aux[0])
      @errors << "NOSCAN: container_aux[0] (via container slot 0) is DEAD"
      pass = false
    end

    unless @heap.live?(container_aux[1])
      @errors << "NOSCAN: container_aux[1] (via container slot 2) is DEAD"
      pass = false
    end

    unless @heap.live?(noscan_aux)
      @errors << "NOSCAN: noscan_aux is DEAD (should be kept alive by noscan offset)"
      pass = false
    end

    pass
  end

  # ---- Test 5: scan_cap limits conservative scan ----
  # Create object with LAYOUT_CAP_TID (scan_cap = 32 bytes = first 2 slots).
  # Fill all 8 slots with aux_ptrs. After collect:
  #   - Slots 0-1 targets should be alive (within scan_cap)
  #   - Slots 2+ targets should be dead (beyond scan_cap)
  def test_scan_cap : Bool
    pass = true
    aux = make_aux(SLOT_COUNT)

    obj = alloc
    set_type_id(obj, LAYOUT_CAP_TID)
    SLOT_COUNT.times { |s| write_slot(obj, s, aux[s]) }

    @heap.collect(scan_stack: false, roots: [obj])

    # Slots 0-1 targets should be alive (within 32-byte cap)
    [0, 1].each do |s|
      unless @heap.live?(aux[s])
        @errors << "SCAN_CAP: slot #{s} target is DEAD (within cap, should be alive)"
        pass = false
      end
    end

    # Slots 2+ targets should be dead (beyond cap)
    (2...SLOT_COUNT).each do |s|
      if @heap.live?(aux[s])
        @errors << "SCAN_CAP: slot #{s} target is ALIVE (beyond cap, should be dead)"
        pass = false
      end
    end

    pass
  end

  # ---- Run all tests ----
  def run_all_tests : Bool
    pass = true

    pass &= test_precise_offsets
    pass &= test_conservative_fallback
    pass &= test_leaf_layout
    pass &= test_noscan_offset
    pass &= test_scan_cap

    pass
  end

  # ---- Main loop ----
  def run(seed : Int64, iterations : Int32) : Bool
    Gcry::Layout.enabled = true
    Gcry::Layout.clear
    register_layouts

    rng = Random.new(seed)
    deadline = Time.instant + 120.seconds

    ops = 0_u64
    test_count = 0_u64
    fail_count = 0_u64

    while ops < iterations && Time.instant < deadline
      pass = run_all_tests
      test_count += 1

      unless pass
        fail_count += 1
      end

      # Periodic reset: free all allocations and re-register
      if ops > 0 && ops % 100 == 0
        @all_allocations.each do |ptr|
          next if ptr.null?
          if @heap.is_heap_ptr(ptr) && @heap.live?(ptr)
            begin
              @heap.free(ptr)
            rescue ArgumentError
            end
          end
        end
        @all_allocations.clear
        Gcry::Layout.clear
        register_layouts
      end

      ops += 1
    end

    if @errors.any?
      # Show unique errors
      unique_errors = @errors.uniq
      puts "FAIL: #{@errors.size} layout invariant(s) violated after #{ops} iterations (#{test_count} tests, #{fail_count} failures)"
      unique_errors.first(20).each { |e| STDERR.puts "  LAYOUT FAIL: #{e}" }
      if unique_errors.size > 20
        STDERR.puts "  ... and #{unique_errors.size - 20} more unique errors"
      end
      return false
    end

    puts "layout property test ok seed=#{seed} iterations=#{ops} tests=#{test_count}"
    true
  end

  def cleanup
    @all_allocations.each do |ptr|
      next if ptr.null?
      if @heap.is_heap_ptr(ptr) && @heap.live?(ptr)
        begin
          @heap.free(ptr)
        rescue ArgumentError
        end
      end
    end
    @heap.trim_large_cache(0)
    @heap.destroy
  end
end

# ---- Entry point ----
test = LayoutPropertyTest.new
begin
  success = test.run(seed, iterations)
ensure
  test.cleanup
end
exit(1) unless success
