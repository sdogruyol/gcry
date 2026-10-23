#!/usr/bin/env bash
# JsonGenerate's high-peak holder on a runner (probe/jsongen-m1 only).
#
# Builds crystal-metric with `-Dgcry_hold_probe` from three trees: this one
# (var), this one with scan-wipe.patch (the wipe before the mutator-stack scan),
# and BASE_SHA (the slow path before its tail call) with probe.patch. Runs
# PROBE_REPS interleaved reps of JsonGenerate in four arms (var, fix, fix
# with GCRY_SCAN_WIPE=0, base), then up to PROBE_LLDB lldb runs of var
# and fix that name the frame owning each root word that first-marks a large
# block (ll.py). Everything goes to $OUT.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
OUT="${OUT:-$root/bench/log/_probe}"
mkdir -p "$OUT/bin"
OUT="$(cd "$OUT" && pwd)"
BASE_SHA="${BASE_SHA:-32ce703aac1c10baeddff2e744a3702c1b4089c6}"

build() { # tree out
  (cd "$1/bench/crystal_metric" && (shards install --production >/dev/null 2>&1 || shards install >/dev/null) &&
    crystal build -Dgc_none -Dgcry_hold_probe --release main.cr -o "$2")
}

build "$root" "$OUT/bin/cm-var"
git -C "$root" worktree add --detach "$OUT/fix" HEAD >/dev/null
git -C "$OUT/fix" apply "$here/scan-wipe.patch"
build "$OUT/fix" "$OUT/bin/cm-fix"
git -C "$root" worktree add --detach "$OUT/base" "$BASE_SHA" >/dev/null
git -C "$OUT/base" apply "$here/probe.patch"
build "$OUT/base" "$OUT/bin/cm-base"

python3 "$here/reps.py" "$OUT/reps" "${PROBE_REPS:-20}" \
  "var=$OUT/bin/cm-var" "fix=$OUT/bin/cm-fix" "fixoff=$OUT/bin/cm-fix:GCRY_SCAN_WIPE=0" "base=$OUT/bin/cm-base" |
  tee "$OUT/reps.txt"

if command -v lldb >/dev/null; then
  for i in $(seq 1 "${PROBE_LLDB:-6}"); do
    for arm in var fix; do
      BIN="$OUT/bin/cm-$arm" OUT="$OUT/lldb-$arm-$i.stdout" MAXSTOPS=6 \
        perl -e 'alarm shift; exec @ARGV' 300 lldb -b -o "command script import $here/ll.py" > "$OUT/lldb-$arm-$i.txt" 2>&1 || true
      grep -h "STOP\|OWNER" "$OUT/lldb-$arm-$i.txt" | sed "s/^/$arm $i: /" || true
    done
  done
fi
