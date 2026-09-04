# Entrypoint for kcov — requires all spec files.
# kcov needs a binary, not `crystal spec`, so we build this as a standalone
# executable that runs the full spec suite.
#
# NOTE: softdirty_spec is excluded because it depends on /proc/self/clear_refs
# which behaves differently in a standalone binary vs crystal spec (which forks
# per-file). It's still run via `crystal spec` in CI.
require "./spec_helper"
require "./heap_spec"
require "./collect_spec"
require "./fiber_spec"
require "./barrier_spec"
require "./layout_spec"
require "./blacklist_spec"
require "./type_id_gate_spec"
require "./sound_defaults_spec"
require "./stack_scrub_spec"
require "./stw_sp_spec"
require "./array_shift_spec"
require "./metrics_spec"
require "./version_spec"
require "./gcry_spec"
require "./phase6_spec"
require "./mt_spec"
require "./stress_spec"
require "./invariant_spec"
require "./api_misuse_spec"
require "./platform_darwin_spec"
require "./trace_dump_spec"
require "./stack_low_water_spec"
require "./stack_bounds_snapshot_spec"
require "./segv_report_spec"
require "./kernels_spec"
require "./chunk_layout_spec"
require "./chunk_kind_spec"
require "./finalizer_index_spec"
require "./block_payload_spec"
require "./large_contains_spec"
require "./bounded_scan_spec"
require "./dormant_revive_spec"
require "./headerless_switches_spec"
require "./large_scan_bounds_spec"
require "./allocate_black_spec"
require "./bitmap_marks_spec"
require "./chunk_radix_spec"
# The regression specs moved to `process_spec/regression/` on 2026-08-15. They
# call `GC.malloc` / `GC.collect`, and gcry only takes over `GC` under
# `-Dgc_none` — measured: without the flag, three `GC.collect` calls move gcry's
# collection count 0 → 0 and `GC.malloc`'s result is not in gcry's heap. Here
# they were exercising Boehm.
