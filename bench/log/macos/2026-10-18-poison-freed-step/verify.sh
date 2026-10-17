#!/usr/bin/env bash
# PROBE ONLY (branch probe/poison-freed-step, second run). The new churn-arm
# criteria on the macOS runners: the gate's own four commands N times, the
# shipped harness on the same tree interleaved with them (the before), and
# three defect builds that must fail. One log per arm under $OUT.
#
#   ctl / hold      bin/poison_freed --control / GCRY_POISON_FREED=1 (the gate)
#   hdrc / hdrh     the header build's two gate commands
#   oldc / oldh     the shipped bench/poison_freed.cr, same tree, same commands
#   red             the 2026-09-04 stand-down restored (probe/defect.patch)
#   leak8 / leak64  an eighth / a sixty-fourth of every reclaim left occupied
#                   (probe/leak.patch), knob on
set -u
N=${N:-100}
HDR=${HDR:-20}
RED=${RED:-10}
OUT=${OUT:-verify-out}
mkdir -p "$OUT"

# BSD `date` has no %N.
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

run() { # name, then the command
  local name=$1; shift
  local start rc
  start=$(now)
  "$@" >"$OUT/tmp.out" 2>&1
  rc=$?
  {
    echo "=== arm=$name rc=$rc secs=$(echo "$(now) - $start" | bc)"
    cat "$OUT/tmp.out"
  } >>"$OUT/$name.log"
}

for i in $(seq 1 "$N"); do
  run ctl bin/poison_freed --control
  run hold env GCRY_POISON_FREED=1 bin/poison_freed
  run oldc bin/pf_shipped --control
  run oldh env GCRY_POISON_FREED=1 bin/pf_shipped
  if [ "$i" -le "$HDR" ]; then
    run hdrh env GCRY_BITMAP_ALLOC=0 GCRY_POISON_FREED=1 bin/poison_freed_hdr
    run hdrc env GCRY_BITMAP_ALLOC=0 bin/poison_freed_hdr --control
  fi
  if [ "$i" -le "$RED" ]; then
    run red env GCRY_POISON_FREED=1 bin/pfdefect
    run leak8 env GCRY_POISON_FREED=1 bin/pfleak8
    run leak64 env GCRY_POISON_FREED=1 bin/pfleak64
  fi
  echo "iteration $i done"
done
rm -f "$OUT/tmp.out"
