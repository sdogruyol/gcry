# HTTP helpers that expose gcry metrics (JSON + Prometheus).
# Use under `-Dgc_none` after `require "gcry"`.
#
#   get "/metrics" { Gcry.prometheus_text }
#   get "/gc-stats" { Gcry::Observability.json_stats }

require "json"

module Gcry
  module Observability
    # Full dogfood snapshot (same fields as historical Kemal `/gc-stats`).
    def self.json_stats(heap : Heap = Gcry.default_heap) : String
      p = PauseStats.new(
        heap.last_pause_ns,
        heap.max_pause_ns,
        heap.total_pause_ns,
        heap.pause_count,
        heap.pause_percentile_ns(50.0),
        heap.pause_percentile_ns(99.0),
      )
      {
        collections:                 heap.collections,
        major_collections:           heap.major_collections,
        minor_collections:           heap.minor_collections,
        heap_size:                   heap.heap_size,
        free_bytes:                  heap.free_bytes,
        bytes_since_gc:              heap.bytes_since_gc,
        unmapped_bytes:              heap.unmapped_bytes,
        live_objects:                heap.live_objects,
        pause_count:                 p.count,
        pause_last_ns:               p.last_ns,
        pause_p50_ns:                p.p50_ns,
        pause_p99_ns:                p.p99_ns,
        pause_max_ns:                p.max_ns,
        pause_total_ns:              p.total_ns,
        phase_clear_ns:              heap.last_phase_clear_ns,
        phase_scrub_ns:              heap.last_phase_scrub_ns,
        header_mark_gen:             heap.header_mark_gen.to_u64,
        header_mark_gen_full_clears: heap.header_mark_gen_full_clears,
        phase_roots_ns:              heap.last_phase_roots_ns,
        phase_static_ns:             heap.last_phase_static_ns,
        phase_stacks_ns:             heap.last_phase_stacks_ns,
        phase_mark_ns:               heap.last_phase_mark_ns,
        phase_sweep_ns:              heap.last_phase_sweep_ns,
        phase_post_stw_wait_ns:      heap.last_phase_post_stw_wait_ns,
        phase_stw_stop_ns:           heap.last_phase_stw_stop_ns,
        phase_stw_start_ns:          heap.last_phase_stw_start_ns,
        phase_flush_ns:              heap.last_phase_flush_ns,
        max_post_stw_wait_ns:        heap.max_post_stw_wait_ns,
        post_stw_wait_total_ns:      heap.post_stw_wait_total_ns,
        post_stw_wait_count:         heap.post_stw_wait_count,
        collect_coalesced:           heap.collect_coalesced,
        large_free_bytes:            heap.large_free_bytes,
        large_mapped_bytes:          heap.large_mapped_bytes,
        small_mapped_bytes:          heap.small_mapped_bytes,
        small_free_bytes:            heap.small_free_bytes,
        large_cache_retain:          heap.large_cache_retain,
        size_class_chunk_count:      heap.size_class_chunk_count,
        fully_free_chunk_bytes:      heap.fully_free_chunk_bytes,
        released_chunk_bytes:        heap.released_chunk_bytes,
        size_class_live_bytes:       heap.size_class_live_bytes,
        chunk_fill_lt25:             heap.chunk_fill_lt25,
        chunk_fill_lt50:             heap.chunk_fill_lt50,
        chunk_fill_lt75:             heap.chunk_fill_lt75,
        chunk_fill_ge75:             heap.chunk_fill_ge75,
        small_chunk_bytes:           heap.small_chunk_bytes,
        soft_dirty_armed:            heap.soft_dirty_armed?,
        soft_dirty_page_scans:       heap.soft_dirty_page_scans,
        soft_dirty_fallbacks:        heap.soft_dirty_fallbacks,
        soft_dirty_last_dirty:       heap.last_soft_dirty_pages,
        soft_dirty_last_total:       heap.last_soft_dirty_total,
        soft_dirty_max_pct:          heap.soft_dirty_max_pct,
        dormant_chunk_bytes:         heap.dormant_chunk_bytes,
        sweep_dormant_skips:         heap.sweep_dormant_skips,
        dontneed_bytes:              heap.dontneed_bytes,
        mostly_empty_release:        heap.mostly_empty_release,
        mostly_empty_dontneed:       heap.mostly_empty_dontneed,
        mostly_empty_max_live_pct:   heap.mostly_empty_max_live_pct,
        mostly_empty_budget:         heap.mostly_empty_budget,
        mostly_empty_bytes:          heap.mostly_empty_bytes,
        mostly_empty_chunks:         heap.mostly_empty_chunks,
        tight_grow:                  heap.tight_grow,
        tight_grow_gc:               heap.tight_grow_gc,
        tight_grow_gc_pct:           heap.tight_grow_gc_pct,
        tight_grow_collects:         heap.tight_grow_collects,
        tight_grow_prefer_allocs:    heap.tight_grow_prefer_allocs,
        tight_grow_maps:             heap.tight_grow_maps,
        empty_chunk_retain:          heap.empty_chunk_retain,
        empty_chunk_warm_retain:     heap.empty_chunk_warm_retain,
        layout_precise_scans:        heap.layout_precise_scans,
        layout_conservative_scans:   heap.layout_conservative_scans,
        # Root-completeness state (docs/SOUND-DEFAULTS.md). Reported as the
        # actual field values, not as "GCRY_SOUND was set" — a measurement
        # should prove the profile applied, not trust that it did.
        soundness:                             Gcry.soundness(heap),
        root_soundness:                        Gcry.root_soundness(heap),
        barrier_soundness:                     Gcry.barrier_soundness(heap),
        allow_interior_pointers:               heap.allow_interior_pointers,
        scan_unaligned_candidates:             heap.scan_unaligned_candidates,
        scan_static_roots:                     heap.scan_static_roots,
        type_id_gate:                          heap.type_id_gate,
        type_id_gate_stacks:                   heap.type_id_gate_stacks,
        stw_multi_stack_lag:                   heap.stw_multi_stack_lag,
        stw_multi_pthread_lag:                 heap.stw_multi_pthread_lag,
        scrub_fibers_enabled:                  heap.scrub_fibers_enabled,
        blacklist_enabled:                     heap.blacklist_enabled,
        nursery_enabled:                       heap.nursery_enabled,
        incremental_auto:                      heap.incremental_auto,
        layout_precise:                        heap.layout_precise,
        precise_stack_roots:                   heap.precise_stack_roots,
        precise_stack_exclusive:               heap.precise_stack_exclusive,
        precise_stack_fibers_exclusive:        heap.precise_stack_fibers_exclusive,
        precise_stack_fiber_leaf_bytes:        heap.precise_stack_fiber_leaf_bytes,
        precise_stack_fiber_fp_fill:           heap.precise_stack_fiber_fp_fill,
        precise_stack_fiber_fp_fill_miss_only: heap.precise_stack_fiber_fp_fill_miss_only,
        precise_stack_roots_marked:            heap.precise_stack_roots_marked,
        parked_fp_fill_frames:                 heap.parked_fp_fill_frames,
        parked_fp_fill_bytes:                  heap.parked_fp_fill_bytes,
        parked_fp_fill_skipped_frames:         heap.parked_fp_fill_skipped_frames,
        parked_fp_fill_skipped_bytes:          heap.parked_fp_fill_skipped_bytes,
        live_attr_roots:                       heap.live_attr_roots,
        first_mark_stack_objects:              heap.first_mark_stack_objects,
        first_mark_stack_bytes:                heap.first_mark_stack_bytes,
        first_mark_stack_atomic_bytes:         heap.first_mark_stack_atomic_bytes,
        first_mark_parked_objects:             heap.first_mark_parked_objects,
        first_mark_parked_bytes:               heap.first_mark_parked_bytes,
        first_mark_parked_atomic_bytes:        heap.first_mark_parked_atomic_bytes,
        first_mark_static_objects:             heap.first_mark_static_objects,
        first_mark_static_bytes:               heap.first_mark_static_bytes,
        first_mark_static_atomic_bytes:        heap.first_mark_static_atomic_bytes,
        first_mark_thread_objects:             heap.first_mark_thread_objects,
        first_mark_thread_bytes:               heap.first_mark_thread_bytes,
        first_mark_thread_atomic_bytes:        heap.first_mark_thread_atomic_bytes,
        first_mark_precise_objects:            heap.first_mark_precise_objects,
        first_mark_precise_bytes:              heap.first_mark_precise_bytes,
        first_mark_precise_atomic_bytes:       heap.first_mark_precise_atomic_bytes,
        first_mark_heap_objects:               heap.first_mark_heap_objects,
        first_mark_heap_bytes:                 heap.first_mark_heap_bytes,
        first_mark_heap_atomic_bytes:          heap.first_mark_heap_atomic_bytes,
        stack_maps_loaded:                     StackMaps.loaded?,
        stack_maps_records:                    StackMaps.record_count,
        stack_maps_hits:                       StackMaps.hits,
        stack_maps_near_hits:                  StackMaps.near_hits,
        stack_maps_lookups:                    StackMaps.lookups,
        stack_maps_roots_yielded:              StackMaps.roots_yielded,
        stack_maps_misses:                     StackMaps.misses,
        stack_maps_parked_misses:              StackMaps.parked_misses,
        stack_maps_parked_oob_misses:          StackMaps.parked_oob_misses,
        stack_maps_parked_rbp_offstack:        StackMaps.parked_rbp_offstack,
        stack_maps_miss_log:                   StackMaps.miss_log?,
        stack_maps_near_delta:                 StackMaps.near_delta,
        stack_maps_top_miss_pcs:               StackMaps.top_miss_pcs,
        layout_entries:                        Layout.size,
        layout_unsafe_skips:                   Layout.unsafe_skips_count,
        type_id_root_rejects:                  heap.type_id_root_rejects,
        type_id_stack_rejects:                 heap.type_id_stack_rejects,
        type_id_static_rejects:                heap.type_id_static_rejects,
        type_id_thread_rejects:                heap.type_id_thread_rejects,
        type_id_root_false_negatives:          heap.type_id_root_false_negatives,
        sp_clamp_hits:                         heap.sp_clamp_hits,
        sp_clamp_fallbacks:                    heap.sp_clamp_fallbacks,
        thread_greg_candidates:                heap.thread_greg_candidates,
        ec_root_pins:                          heap.ec_root_pins,
        ec_root_unpinned_ivars:                heap.ec_root_unpinned_ivars,
        ec_queue_audit_ring_slots:             heap.ec_queue_audit_ring_slots,
        ec_queue_audit_list_slots:             heap.ec_queue_audit_list_slots,
        ec_queue_audit_faults:                 heap.ec_queue_audit_faults,
        mark_audit_edges:                      heap.mark_audit_edges,
        mark_audit_misses:                     heap.mark_audit_misses,
        thread_census_checks:                  heap.thread_census_checks,
        thread_census_gaps:                    heap.thread_census_gaps,
        thread_census_gap_max:                 heap.thread_census_gap_max,
        thread_census_unanswered:              heap.thread_census_unanswered,
        thread_census_staged_covered:          heap.thread_census_staged_covered,
        thread_staged_now:                     Gcry::Platform.staged_count,
        thread_staged_total:                   Gcry::Platform.staged_total,
        thread_staged_overflows:               Gcry::Platform.staged_overflows,
        stack_bounds_visited:                  Gcry::Platform.stack_bounds_visited,
        stack_bounds_read:                     Gcry::Platform.stack_bounds_read,
        birth_grace_rooted:                    heap.birth_grace_rooted,
        birth_grace_saved:                     heap.birth_grace_saved,
        birth_grace_overflows:                 heap.birth_grace_overflows,
        ec_queue_audit_last_fault:             heap.ec_queue_audit_last_fault,
        poisoned_blocks:                       heap.poisoned_blocks,
        low_water_skips:                       heap.low_water_skips,
        low_water_skipped_bytes:               heap.low_water_skipped_bytes,
        finalizer_entries:                     heap.finalizer_entry_count,
        weak_links:                            heap.finalizer_link_count,
        blacklist_hits:                        heap.blacklist_hits,
        blacklist_skips:                       heap.blacklist_skips,
        tlab_refills:                          heap.tlab_refills,
        tlab_steals:                           heap.tlab_steals,
        tlab_hits:                             heap.tlab_hits,
        tlab_hit_rate_pct:                     heap.tlab_refills + heap.tlab_hits > 0 ? (heap.tlab_hits * 100) // (heap.tlab_refills + heap.tlab_hits) : 100_u64,
        alloc_batch:                           heap.alloc_batch,
        alloc_batch_hits:                      heap.alloc_batch_hits,
        alloc_batch_refills:                   heap.alloc_batch_refills,
        parallel_mark_workers:                 heap.parallel_mark_workers,
        parallel_mark_runs:                    heap.parallel_mark_runs,
        parallel_mark_stolen:                  heap.parallel_mark_stolen,
        clear_stack_calls:                     heap.clear_stack_calls,
        clear_stack_bytes_total:               heap.clear_stack_bytes_total,
        fiber_scrub_bytes:                     heap.fiber_scrub_bytes,
        fiber_scrub_runs:                      heap.fiber_scrub_runs,
        fiber_scrub_bytes_total:               heap.fiber_scrub_bytes_total,
        fiber_scrub_foreign_sp_scrubs:         heap.fiber_scrub_foreign_sp_scrubs,
        fiber_scrub_live_frame_overlaps:       heap.fiber_scrub_live_frame_overlaps,
        fiber_scrub_running_foreign_sp:        heap.fiber_scrub_running_foreign_sp,
        fiber_scrub_midswap_skips:             heap.fiber_scrub_midswap_skips,
        pthread_bounds_misses:                 Platform.stack_bounds_snapshot_misses,
        monitor_gate_enabled:                  MonitorGate.enabled?,
        monitor_gate_stw_waits:                MonitorGate.stw_waits,
        monitor_gate_stw_wait_ns:              MonitorGate.stw_wait_ns,
        monitor_gate_stw_wait_max_ns:          MonitorGate.stw_wait_max_ns,
        monitor_gate_monitor_blocks:           MonitorGate.monitor_blocks,
        barrier_backend:                       heap.barrier_backend_name,
        barrier_dirty_rescans:                 heap.barrier_dirty_rescans,
        nursery_survival_bytes:                heap.nursery_survival_bytes,
        nursery_alloc_before_minor:            heap.nursery_alloc_before_minor,
        nursery_survival_rate_pct:             heap.nursery_survival_rate_pct,
        adaptive_nursery:                      heap.adaptive_nursery,
      }.to_json
    end

    # Max size for a plausible Reference *header* (Array=24B, most refs ≪ this).
    # Larger blocks with a type_id-looking first word are treated as collisions
    # unless they look like inline String (atomic + bytesize/length).
    LIVE_ATTR_MAX_TYPED_HEADER = 512_u64

    # Post-collect size-class + type_id live summary (docs/STACK_MAPS.md attribution).
    # Walks USED blocks; call after GC.collect. top_n caps type_id ranking by bytes.
    #
    # Classification:
    #   typed      — plausible type_id + small header, or atomic String shape
    #   collision  — plausible type_id on an oversized block (false root bait)
    #   raw        — no plausible type_id (Pointer buffers, etc.)
    def self.json_live_attr(heap : Heap = Gcry.default_heap, top_n : Int32 = 40) : String
      sc_count = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      sc_bytes = StaticArray(UInt64, SIZE_CLASS_COUNT).new(0_u64)
      large_count = 0_u64
      large_bytes = 0_u64
      total_count = 0_u64
      total_bytes = 0_u64
      typed_count = 0_u64
      typed_bytes = 0_u64
      collision_count = 0_u64
      collision_bytes = 0_u64
      raw_count = 0_u64
      raw_bytes = 0_u64
      by_tid_count = Hash(Int32, UInt64).new(0_u64)
      by_tid_bytes = Hash(Int32, UInt64).new(0_u64)
      by_collision_count = Hash(Int32, UInt64).new(0_u64)
      by_collision_bytes = Hash(Int32, UInt64).new(0_u64)

      max_idx = SIZE_CLASS_COUNT - 1
      max_payload = SizeClasses.payload(max_idx).to_i32
      max_typed_c = 0_u64
      max_typed_b = 0_u64
      max_coll_c = 0_u64
      max_coll_b = 0_u64
      max_raw_c = 0_u64
      max_raw_b = 0_u64
      max_atomic_c = 0_u64
      max_atomic_b = 0_u64
      max_ptrish_c = 0_u64
      max_ptrish_b = 0_u64
      max_byteish_c = 0_u64
      max_byteish_b = 0_u64

      heap_min = heap.@heap_min
      heap_max = heap.@heap_max

      heap.each_chunk do |chunk|
        if ChunkHeader.large?(chunk)
          header = ChunkHeader.data_start(chunk).as(BlockHeader*)
          next if BlockHeader.free?(header)
          size = header.value.size.to_u64
          large_count += 1
          large_bytes += size
          total_count += 1
          total_bytes += size
          kind, tid = live_attr_kind(header, size)
          case kind
          when :typed
            typed_count += 1
            typed_bytes += size
            if t = tid
              by_tid_count[t] += 1
              by_tid_bytes[t] += size
            end
          when :collision
            collision_count += 1
            collision_bytes += size
            if t = tid
              by_collision_count[t] += 1
              by_collision_bytes[t] += size
            end
          else
            raw_count += 1
            raw_bytes += size
          end
        else
          class_index = chunk.value.size_class.to_i32
          next if class_index < 0 || class_index >= SIZE_CLASS_COUNT
          payload = SizeClasses.payload(class_index)
          block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
          cursor = ChunkHeader.data_start(chunk).as(UInt8*)
          limit = ChunkHeader.data_end(chunk).as(UInt8*)
          is_max = class_index == max_idx
          while (cursor + block_bytes) <= limit
            header = cursor.as(BlockHeader*)
            unless BlockHeader.free?(header)
              size = header.value.size.to_u64
              sc_count[class_index] += 1
              sc_bytes[class_index] += size
              total_count += 1
              total_bytes += size
              kind, tid = live_attr_kind(header, size)
              case kind
              when :typed
                typed_count += 1
                typed_bytes += size
                if t = tid
                  by_tid_count[t] += 1
                  by_tid_bytes[t] += size
                end
                if is_max
                  max_typed_c += 1
                  max_typed_b += size
                end
              when :collision
                collision_count += 1
                collision_bytes += size
                if t = tid
                  by_collision_count[t] += 1
                  by_collision_bytes[t] += size
                end
                if is_max
                  max_coll_c += 1
                  max_coll_b += size
                end
              else
                raw_count += 1
                raw_bytes += size
                if is_max
                  max_raw_c += 1
                  max_raw_b += size
                end
              end
              if is_max
                if BlockHeader.atomic?(header)
                  max_atomic_c += 1
                  max_atomic_b += size
                end
                if kind != :typed
                  if live_attr_ptrish?(header, size, heap_min, heap_max)
                    max_ptrish_c += 1
                    max_ptrish_b += size
                  else
                    max_byteish_c += 1
                    max_byteish_b += size
                  end
                end
              end
            end
            cursor += block_bytes
          end
        end
      end

      size_classes = [] of {idx: Int32, payload: Int32, count: UInt64, bytes: UInt64}
      SIZE_CLASS_COUNT.times do |i|
        next if sc_count[i] == 0
        size_classes << {
          idx:     i,
          payload: SizeClasses.payload(i).to_i32,
          count:   sc_count[i],
          bytes:   sc_bytes[i],
        }
      end
      size_classes.sort_by! { |h| -h[:bytes].to_i64 }

      n = top_n.clamp(1, 256)
      top_types = rank_tid_bytes(by_tid_count, by_tid_bytes, n)
      top_collisions = rank_tid_bytes(by_collision_count, by_collision_bytes, n)

      {
        total_objects:                   total_count,
        total_bytes:                     total_bytes,
        typed_objects:                   typed_count,
        typed_bytes:                     typed_bytes,
        collision_objects:               collision_count,
        collision_bytes:                 collision_bytes,
        raw_objects:                     raw_count,
        raw_bytes:                       raw_bytes,
        large_objects:                   large_count,
        large_bytes:                     large_bytes,
        size_class_live_bytes:           heap.size_class_live_bytes,
        live_objects:                    heap.live_objects,
        live_attr_roots:                 heap.live_attr_roots,
        first_mark_stack_objects:        heap.first_mark_stack_objects,
        first_mark_stack_bytes:          heap.first_mark_stack_bytes,
        first_mark_stack_atomic_bytes:   heap.first_mark_stack_atomic_bytes,
        first_mark_parked_objects:       heap.first_mark_parked_objects,
        first_mark_parked_bytes:         heap.first_mark_parked_bytes,
        first_mark_parked_atomic_bytes:  heap.first_mark_parked_atomic_bytes,
        first_mark_static_objects:       heap.first_mark_static_objects,
        first_mark_static_bytes:         heap.first_mark_static_bytes,
        first_mark_static_atomic_bytes:  heap.first_mark_static_atomic_bytes,
        first_mark_thread_objects:       heap.first_mark_thread_objects,
        first_mark_thread_bytes:         heap.first_mark_thread_bytes,
        first_mark_thread_atomic_bytes:  heap.first_mark_thread_atomic_bytes,
        first_mark_precise_objects:      heap.first_mark_precise_objects,
        first_mark_precise_bytes:        heap.first_mark_precise_bytes,
        first_mark_precise_atomic_bytes: heap.first_mark_precise_atomic_bytes,
        first_mark_heap_objects:         heap.first_mark_heap_objects,
        first_mark_heap_bytes:           heap.first_mark_heap_bytes,
        first_mark_heap_atomic_bytes:    heap.first_mark_heap_atomic_bytes,
        live_attr_watch_tid:             heap.live_attr_watch_tid,
        first_mark_watch_stack:          heap.first_mark_watch_stack,
        first_mark_watch_parked:         heap.first_mark_watch_parked,
        first_mark_watch_static:         heap.first_mark_watch_static,
        first_mark_watch_thread:         heap.first_mark_watch_thread,
        first_mark_watch_precise:        heap.first_mark_watch_precise,
        first_mark_watch_heap:           heap.first_mark_watch_heap,
        size_classes:                    size_classes,
        top_type_ids:                    top_types,
        top_collision_type_ids:          top_collisions,
        max_size_class:                  {
          payload:           max_payload,
          typed_objects:     max_typed_c,
          typed_bytes:       max_typed_b,
          collision_objects: max_coll_c,
          collision_bytes:   max_coll_b,
          raw_objects:       max_raw_c,
          raw_bytes:         max_raw_b,
          atomic_objects:    max_atomic_c,
          atomic_bytes:      max_atomic_b,
          ptrish_objects:    max_ptrish_c,
          ptrish_bytes:      max_ptrish_b,
          byteish_objects:   max_byteish_c,
          byteish_bytes:     max_byteish_b,
        },
      }.to_json
    end

    private def self.rank_tid_bytes(counts : Hash(Int32, UInt64), bytes : Hash(Int32, UInt64), n : Int32)
      ranked = bytes.map { |tid, b| {tid, counts[tid], b} }
      ranked.sort_by! { |t| -t[2].to_i64 }
      ranked.first(n).map { |tid, count, b| {type_id: tid, count: count, bytes: b} }
    end

    # Returns {kind, type_id?}.
    private def self.live_attr_kind(header : BlockHeader*, size : UInt64) : Tuple(Symbol, Int32?)
      return {:raw, nil} if size < 4
      tid = BlockHeader.user_from(header).as(Int32*).value
      return {:raw, nil} if tid <= 0 || tid > 1_000_000

      if BlockHeader.atomic?(header) && live_attr_string_shaped?(header, size)
        return {:typed, tid}
      end

      if size <= LIVE_ATTR_MAX_TYPED_HEADER
        return {:typed, tid}
      end

      {:collision, tid}
    end

    # Crystal String: type_id + bytesize + length + inline bytes (atomic).
    private def self.live_attr_string_shaped?(header : BlockHeader*, size : UInt64) : Bool
      return false if size < 16
      user = BlockHeader.user_from(header).as(Int32*)
      bytesize = user[1]
      length = user[2]
      return false if bytesize < 0 || length < 0
      return false if bytesize.to_u64 > size - 16
      return false if length > bytesize
      true
    end

    # ≥25% of sampled words look like heap pointers → Array/Hash buffer-ish.
    private def self.live_attr_ptrish?(header : BlockHeader*, size : UInt64, heap_min : UInt64, heap_max : UInt64) : Bool
      return false if heap_max <= heap_min || size < 64
      words = (size // sizeof(Void*).to_u64).to_i32
      sample = Math.min(words, 256)
      cursor = BlockHeader.user_from(header).as(UInt64*)
      hits = 0
      align_mask = sizeof(Void*).to_u64 - 1
      sample.times do |i|
        w = cursor[i]
        next if (w & align_mask) != 0
        hits += 1 if w >= heap_min && w < heap_max
      end
      hits * 4 >= sample
    end

    def self.prometheus(heap : Heap = Gcry.default_heap, prefix : String = "gcry") : String
      Gcry.prometheus_text(heap, prefix)
    end
  end
end
