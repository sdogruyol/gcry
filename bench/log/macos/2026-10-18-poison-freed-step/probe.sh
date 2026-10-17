#!/usr/bin/env bash
# PROBE ONLY (branch probe/poison-freed-step). How often does `make
# poison-freed`'s churn arm step, on which build and schedule, and what is the
# step made of? Runs every arm N times, interleaved so runner noise lands on
# all of them alike, and writes one log per arm under $OUT.
#
#   g037  the gate command exactly: 0.37 tip, knob off, no counters
#   c037  0.37 tip, knob off                      (the arm that failed)
#   p037  0.37 tip, knob on                       (the gate's default arm)
#   t037  0.37 tip, knob off, GCRY_THRESHOLD=16 MiB  (the old Darwin floor;
#         a fixed threshold also turns adaptation and pacing off)
#   n037  0.37 tip, knob off, GCRY_THRESHOLD_PACE=100 (8 MiB floor, pacing off)
#   c036  v0.36.0, knob off
#   p036  v0.36.0, knob on
#   l037  0.37 tip, knob off, 12 rounds (does the plateau hold past a step?)
#   red   the 2026-09-04 defect restored (probe/defect.patch), knob on
set -u
N=${N:-100}
LONG=${LONG:-20}
RED=${RED:-10}
OUT=${OUT:-probe-out}
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
  run g037 bin/pf037 --control
  run c037 bin/pf037 --control --counters
  run p037 env GCRY_POISON_FREED=1 bin/pf037 --counters
  run t037 env GCRY_THRESHOLD=16777216 bin/pf037 --control --counters
  run n037 env GCRY_THRESHOLD_PACE=100 bin/pf037 --control --counters
  run c036 bin/pf036 --control --counters
  run p036 env GCRY_POISON_FREED=1 bin/pf036 --counters
  if [ "$i" -le "$LONG" ]; then run l037 bin/pf037 --control --counters --rounds 12; fi
  if [ "$i" -le "$RED" ]; then
    run red env GCRY_POISON_FREED=1 bin/pfdefect --counters
    run redc bin/pfdefect --control --counters
  fi
  echo "iteration $i done"
done
rm -f "$OUT/tmp.out"
