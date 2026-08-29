# gcry — a Crystal garbage collector
#
# Alternative to bdwgc. Integrate with:
#   require "gcry"  and  crystal build -Dgc_none
#
# See DESIGN.md and docs/INTEGRATION.md.
require "./gcry/clock"
require "./gcry/heap"
require "./gcry/layout"

module Gcry
  VERSION = "0.21.3"

  struct PauseStats
    getter last_ns : UInt64
    getter max_ns : UInt64
    getter total_ns : UInt64
    getter count : UInt64
    getter p50_ns : UInt64
    getter p99_ns : UInt64

    def initialize(@last_ns : UInt64, @max_ns : UInt64, @total_ns : UInt64, @count : UInt64,
                   @p50_ns : UInt64 = 0_u64, @p99_ns : UInt64 = 0_u64)
    end
  end
end

require "./gcry/metrics"
require "./gcry/monitor_gate"
require "./gcry/observability"
require "./gcry/stw_watchdog"
require "./gcry/raw_out"
require "./gcry/ec_queue_audit"
require "./gcry/birth_grace"
require "./gcry/mark_audit"
require "./gcry/address_space_audit"
require "./gcry/thread_block_audit"
require "./gcry/thread_list_tripwire"
require "./gcry/thread_birth_root"
require "./gcry/unowned_stack_roots"
require "./gcry/poison_holders"
require "./gcry/segv_report"

module Gcry
  @@default_heap : Heap? = nil

  # Process-wide heap used by the module-level allocators.
  def self.default_heap : Heap
    @@default_heap ||= Heap.new
  end

  # The heap if one exists, without creating it. `default_heap` would `Heap.new`
  # a missing one, which mmaps — not something a signal handler may do.
  def self.default_heap? : Heap?
    @@default_heap
  end

  # Replace the default heap (mainly for tests). Does NOT destroy the previous
  # heap — under -Dgc_none the process GC heap has live Crystal runtime objects
  # in its chunks and munmap would SIGILL on the next access.
  def self.default_heap=(heap : Heap) : Heap
    @@default_heap = heap
  end

  def self.malloc(size : Int) : Void*
    default_heap.malloc(size)
  end

  def self.malloc_atomic(size : Int) : Void*
    default_heap.malloc_atomic(size)
  end

  def self.realloc(pointer : Void*, size : Int) : Void*
    default_heap.realloc(pointer, size)
  end

  def self.free(pointer : Void*) : Nil
    default_heap.free(pointer)
  end

  def self.is_heap_ptr(pointer : Void*) : Bool
    default_heap.is_heap_ptr(pointer)
  end

  def self.collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
    default_heap.collect(scan_stack: scan_stack, roots: roots)
  end

  def self.minor_collect(scan_stack : Bool = true, roots : Array(Void*)? = nil) : Nil
    default_heap.minor_collect(scan_stack: scan_stack, roots: roots)
  end

  def self.collect_a_little(work_units : Int32 = Heap::DEFAULT_INCREMENTAL_WORK) : Bool
    default_heap.collect_a_little(work_units)
  end

  def self.pause_stats : PauseStats
    h = default_heap
    PauseStats.new(
      h.last_pause_ns,
      h.max_pause_ns,
      h.total_pause_ns,
      h.pause_count,
      h.pause_percentile_ns(50.0),
      h.pause_percentile_ns(99.0),
    )
  end

  def self.add_root(pointer : Void*) : Nil
    default_heap.add_root(pointer)
  end

  def self.enable : Nil
    default_heap.enable
  end

  def self.disable : Nil
    default_heap.disable
  end

  def self.live?(pointer : Void*) : Bool
    default_heap.live?(pointer)
  end

  # True when no root-completeness heuristic is armed: every ambient pointer
  # the collector can see is followed, and nothing below a parked SP is wiped.
  # Derived from the live fields, so it reports what the heap *is*, not what an
  # env var asked for. See docs/SOUND-DEFAULTS.md.
  #
  # Note `scan_static_roots`: a heap that never walks BSS/data misses roots by
  # construction. Process GC turns it on at boot; library heaps default it off,
  # so a library heap must opt in before it can report sound roots.
  def self.sound_roots?(heap : Heap = default_heap) : Bool
    heap.allow_interior_pointers &&
      heap.scan_unaligned_candidates &&
      heap.scan_static_roots &&
      !heap.type_id_gate &&
      !heap.type_id_gate_stacks &&
      heap.stw_multi_stack_lag == 0 &&
      heap.stw_multi_pthread_lag == 0 &&
      !heap.scrub_fibers_enabled &&
      !heap.blacklist_enabled &&
      # Exclusive stack maps replace conservative scans with incomplete
      # compiler data — the opposite of this profile (docs/STACK_MAPS.md).
      !heap.precise_stack_exclusive &&
      !heap.precise_stack_fibers_exclusive
  end

  # True when liveness does not depend on a page-dirty barrier.
  #
  # A separate axis from root completeness, and a real one: generational and
  # incremental collection both rely on the old→young / dirty-page remembered
  # set, and soft-dirty has measured false-negatives (the nursery note in
  # gc_override.cr cites Kemal Hash key UAF / SEGV under WSL). Both are off by
  # default; this exists so `GCRY_SOUND=1 GCRY_NURSERY=1` cannot report a
  # clean bill of health.
  def self.sound_barriers?(heap : Heap = default_heap) : Bool
    !heap.nursery_enabled && !heap.incremental_auto
  end

  # True only when both axes are sound. This is the label a correctness claim
  # should cite; the per-axis ones say *which* assumption is in play.
  def self.sound?(heap : Heap = default_heap) : Bool
    sound_roots?(heap) && sound_barriers?(heap)
  end

  # "sound" | "tuned" — labels for `/gc-stats` and bench logs.
  def self.root_soundness(heap : Heap = default_heap) : String
    sound_roots?(heap) ? "sound" : "tuned"
  end

  def self.barrier_soundness(heap : Heap = default_heap) : String
    sound_barriers?(heap) ? "sound" : "tuned"
  end

  # Aggregate label. Three values rather than two, so a failing config says
  # *which* assumption is in play:
  #
  #   "sound"             both axes complete — the label a claim may cite
  #   "sound-roots-only"  roots complete, but liveness depends on a page-dirty
  #                       barrier (nursery / incremental)
  #   "tuned"             a root-completeness heuristic is armed
  def self.soundness(heap : Heap = default_heap) : String
    return "tuned" unless sound_roots?(heap)
    sound_barriers?(heap) ? "sound" : "sound-roots-only"
  end

  def self.push_stack(stack_top : Void*, stack_bottom : Void*) : Nil
    default_heap.push_stack(stack_top, stack_bottom)
  end

  def self.before_collect(&block : -> Nil) : Nil
    default_heap.before_collect(&block)
  end

  def self.set_stackbottom(stack_bottom : Void*) : Nil
    default_heap.set_stackbottom(stack_bottom)
  end

  def self.current_thread_stack_bottom : {Void*, Void*}
    default_heap.current_thread_stack_bottom
  end

  def self.add_finalizer(object : Void*, callback : Finalizers::Callback) : Nil
    default_heap.add_finalizer(object, callback)
  end

  def self.add_finalizer(object : Void*, &block : Finalizers::Callback) : Nil
    default_heap.add_finalizer(object, &block)
  end

  def self.register_disappearing_link(link : Void**, object : Void* = Pointer(Void).null) : Nil
    default_heap.register_disappearing_link(link, object)
  end

  def self.lock_read : Nil
    default_heap.lock_read
  end

  def self.unlock_read : Nil
    default_heap.unlock_read
  end

  def self.lock_write : Nil
    default_heap.lock_write
  end

  def self.unlock_write : Nil
    default_heap.unlock_write
  end
end

{% if flag?(:gc_none) %}
  require "./gcry/gc_override"
  require "./gcry/crystal_process_compat"
{% end %}
