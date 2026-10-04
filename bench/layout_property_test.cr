# Layout property test for gcry.
#
# A registered plain layout must never cost an edge. The key `Gcry::Layout`
# reads is a block's first Int32, and a raw buffer of a mixed union starts
# with exactly such an id, so only a Hash — behind its own shape check — may
# narrow a scan. Every other registration, whatever it claims, scans like an
# unregistered block (`bench/log/linux/2026-10-04-layout-union-collision/`).
# Each sub-test is self-contained: allocates its own aux_ptrs, runs its own
# collect, and verifies independently.
#
# Tests:
#   1. Every slot of a block keeps its target alive, for each synthetic plain
#      layout (precise offsets, leaf, noscan, scan cap) and for no layout.
#   2. The target of a noscan offset is traced: its own children survive.
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
      0_u16, 0_u16)

    # Layout 2: leaf — no offsets, scan_cap = 0 (truly leaf: nothing to scan)
    Gcry::Layout.install_full(LAYOUT_LEAF_TID,
      Pointer(UInt16).null, 0,
      Pointer(UInt16).null, 0,
      alloc_size, 0_u32,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16)

    # Layout 3: noscan — scan slot 0 (offset 16), noscan slot 1 (offset 24)
    Gcry::Layout.install_full(LAYOUT_NOSCAN_TID,
      [16_u16].to_unsafe, 1,
      [24_u16].to_unsafe, 1,
      alloc_size, alloc_size,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16)

    # Layout 4: cap-only — scan_cap = 32 bytes (slots 0-1), no precise offsets
    Gcry::Layout.install_full(LAYOUT_CAP_TID,
      Pointer(UInt16).null, 0,
      Pointer(UInt16).null, 0,
      alloc_size, 32_u32,
      0_u8, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u8, 0_u16,
      0_u16, 0_u16)
  end

  # ---- Test 1: no layout loses a slot ----
  # Fill all 8 slots of a block carrying *tid* (0: none) with aux_ptrs. After
  # a collect with only the block as a root, every target must survive.
  def test_keeps_every_slot(tid : Int32, label : String) : Bool
    pass = true
    aux = make_aux(SLOT_COUNT)

    obj = alloc
    set_type_id(obj, tid) unless tid == 0
    SLOT_COUNT.times { |s| write_slot(obj, s, aux[s]) }

    @heap.collect(scan_stack: false, roots: [obj])

    SLOT_COUNT.times do |s|
      unless @heap.live?(aux[s])
        @errors << "#{label}: slot #{s} target is DEAD (every slot must survive)"
        pass = false
      end
    end

    pass
  end

  # ---- Test 2: a noscan offset's target is still traced ----
  # Parent (noscan layout) slot 1 → container, whose slots hold children.
  # Under a collision the "blob" a noscan offset names can be an ordinary
  # object, so its children must survive too.
  def test_noscan_target_traced : Bool
    pass = true

    children = make_aux(2)
    container = alloc
    set_type_id(container, LAYOUT_PRECISE_TID)
    write_slot(container, 1, children[0])
    write_slot(container, 5, children[1])

    parent = alloc
    set_type_id(parent, LAYOUT_NOSCAN_TID)
    write_slot(parent, 1, container)

    @heap.collect(scan_stack: false, roots: [parent])

    unless @heap.live?(container)
      @errors << "NOSCAN: container (noscan offset) is DEAD"
      pass = false
    end
    children.each_with_index do |child, i|
      unless @heap.live?(child)
        @errors << "NOSCAN: container child #{i} is DEAD (noscan target must be traced)"
        pass = false
      end
    end

    pass
  end

  # ---- Run all tests ----
  def run_all_tests : Bool
    pass = true

    pass &= test_keeps_every_slot(LAYOUT_PRECISE_TID, "PRECISE")
    pass &= test_keeps_every_slot(0, "CONSERVATIVE")
    pass &= test_keeps_every_slot(LAYOUT_LEAF_TID, "LEAF")
    pass &= test_keeps_every_slot(LAYOUT_NOSCAN_TID, "NOSCAN")
    pass &= test_keeps_every_slot(LAYOUT_CAP_TID, "SCAN_CAP")
    pass &= test_noscan_target_traced

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
