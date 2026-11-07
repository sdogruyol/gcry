# The heap fields the allocation hit path reads (`Heap#fast_alloc`, inlined
# into `Heap#malloc` and `Heap#malloc_atomic`), declared first.
#
# Crystal lays out a class's instance variables with every typed declaration
# first, in the order the program declares them, and every inferred one
# (`@x = value`) after, in the order it meets them. Declared typed here, and
# this file required before anything else that opens `Heap`, these fields
# take the lowest offsets, so a field added anywhere else never moves them.
# In 0.40 three typed fields added to `bitmap_alloc.cr` moved them by 32
# bytes, and the pace's and the barrier's by 8 to 32 more; on macos-15-intel
# that shift was one of the two causes of Binarytrees reading 3–6% slower
# than 0.39.0 (`bench/log/macos/2026-11-02-intel-binarytrees/`).
# `spec/heap_hot_fields_spec.cr` checks that every field here sits below
# every other. A field the hit path starts reading belongs here; one it stops
# reading goes back where it is used.
module Gcry
  class Heap
    # Whether the hit path may run at all (`refresh_fast_path`).
    @fast_path : Bool = false
    # A collection or an incremental cycle is under way, or a lazy sweep is
    # due: the hit path stands aside (`collect.cr`).
    @collecting : Bool = false
    @incremental_marking : Bool = false
    @lazy_sweep_pending : Bool = false

    {% if flag?(:darwin) %}
      # This thread's cursor set through the heap's pthread key slot; see
      # `bitmap_alloc.cr`, "Darwin: the hit path reads this thread's set".
      @cursor_tsd_slot : UInt64 = 0_u64
    {% end %}

    # Bytes allocated since the last collection, against which the hit path
    # weighs its set's uncredited bytes (`bytes_since_gc_now`).
    @bytes_since_gc : Atomic(UInt64) = Atomic(UInt64).new(0_u64)
    property gc_threshold : UInt64 = DEFAULT_GC_THRESHOLD
    # Bytes ahead of the allocation cursor to prefetch-for-write
    # (`GCRY_ALLOC_PFW`, default 2 KiB, 0 = off). simdgc measured 7.1 -> 4.2 ns
    # on fresh memory; the sweet spot is machine-dependent, so it is a knob.
    property alloc_pfw : UInt64 = 2048_u64

    # Why an allocation left the hit path for the locked one (`bitmap_alloc.cr`,
    # with `cursor_word_advances`).
    getter fast_miss_collecting : UInt64 = 0_u64
    getter fast_miss_size : UInt64 = 0_u64
    getter fast_miss_no_set : UInt64 = 0_u64
    getter fast_miss_refill : UInt64 = 0_u64
    getter fast_miss_threshold : UInt64 = 0_u64

    # Per size class, the block size, and per 8-byte request size up to
    # 2 KiB, the class and its payload (`init_fast_path_tables`).
    @block_bytes = uninitialized StaticArray(UInt64, SIZE_CLASS_COUNT)
    @fit_index = uninitialized StaticArray(UInt8, 257)
    @fit_payload = uninitialized StaticArray(UInt32, 257)
  end
end
