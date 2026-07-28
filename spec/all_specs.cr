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
require "./stack_scrub_spec"
require "./stw_sp_spec"
require "./array_shift_spec"
require "./metrics_spec"
require "./gcry_spec"
require "./phase6_spec"
require "./mt_spec"
require "./stress_spec"
require "./invariant_spec"
require "./api_misuse_spec"
require "./platform_darwin_spec"
require "./trace_dump_spec"
require "./regression/**"
