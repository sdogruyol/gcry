#!/usr/bin/env bash
# PROBE ONLY. Every arm runs whatever the one before it did.
set -u
mkdir -p bin

build_run() {
  local label=$1 src=$2 exe=$3
  shift 3
  echo "=== $label ==="
  if ! crystal build -Dgc_none "$src" -o "$exe" --error-trace; then
    echo "=== $label: BUILD FAILED"
    return
  fi
  "$exe" "$@"
  echo "=== $label: exit=$?"
}

s76=process_spec/regression/76_monitor_deep_frame_root_spec.cr
s77=process_spec/regression/77_library_collect_monitor_gate_spec.cr
uname -a
sysctl -n machdep.cpu.brand_string 2>/dev/null || true
build_run 'probe fixed' bench/monitor_probe.cr bin/monitor_probe
build_run 'spec76 alone fixed' $s76 bin/spec76 -v
build_run 'spec77 alone fixed' $s77 bin/spec77 -v
git apply probe/revert-fix.patch
build_run 'probe scan-nofix' bench/monitor_probe.cr bin/monitor_probe_nofix
build_run 'spec76 alone scan-nofix' $s76 bin/spec76_nofix -v
git apply -R probe/revert-fix.patch
git apply probe/revert-gate.patch
build_run 'spec77 alone gate-nofix' $s77 bin/spec77_nofix -v
git apply -R probe/revert-gate.patch
git status --short
exit 0
