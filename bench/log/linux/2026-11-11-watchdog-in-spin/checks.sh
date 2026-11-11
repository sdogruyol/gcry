#!/usr/bin/env bash
# Pre-push checks for this branch, from the repo root, one line of verdict per
# step after its output. Run under the shared heavy lock.
set -u
step() {
  local name=$1; shift
  echo "=== $name: $*"
  if "$@"; then echo "--- $name: ok"; else echo "--- $name: FAILED ($?)"; fi
}
step format crystal tool format --check
rm -rf lib/ameba bin/ameba
step lint make lint
step knob-doc-check make knob-doc-check
step stw-watchdog make stw-watchdog
step windows-typecheck make windows-typecheck
step darwin-typecheck make darwin-typecheck
for t in x86_64-windows-msvc aarch64-windows-msvc x86_64-apple-darwin aarch64-apple-darwin; do
  step "gate-typecheck-$t" crystal build --cross-compile --target "$t" -Dgc_none bench/stw_watchdog.cr \
    -o "bin/stw_watchdog_typecheck_$t"
done
rm -f bin/stw_watchdog_typecheck_*
step alloc-entry-frame make alloc-entry-frame
step process-spec make spec-process
