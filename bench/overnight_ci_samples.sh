#!/usr/bin/env bash
# Dispatch CI runs through the night, one every INTERVAL seconds, to buy the
# two things that only samples can buy:
#
#   1. Perf-smoke samples. `bench/baseline/perf_smoke.json` is recorded on 23
#      runs and its gates sit 2.16-2.50 sd from the mean — a 3.2% false-red rate
#      per run, which is why `PERF_GATE_BASELINE=1` is still off. The tolerance
#      is `max(half-range, 1.5x IQR, floor)` and both of the first two shrink
#      toward the true spread as n grows, so more runs are the whole lever.
#   2. Flake rates for the two jobs that went red this week on trees that could
#      not have caused it: `test (aarch64 native)`'s five chunk-residency specs
#      and `test (darwin native)`'s `ec-queue-audit`. Each dispatch is one more
#      Bernoulli trial for both.
#
# `soak_duration=0` opts the 5 h soak arms out — a dispatch that leaves the
# default alone starts them, and fifteen runner-hours is not what this is for.
set -u

RUNS="${RUNS:-18}"
INTERVAL="${INTERVAL:-1500}"
LOG="${LOG:-/tmp/gcry-overnight-ci.log}"

echo "$(date -Is) dispatching $RUNS runs, one every ${INTERVAL}s" | tee -a "$LOG"

for i in $(seq 1 "$RUNS"); do
  if gh workflow run CI -f soak_duration=0 >/dev/null 2>&1; then
    echo "$(date -Is) dispatch $i/$RUNS ok" | tee -a "$LOG"
  else
    echo "$(date -Is) dispatch $i/$RUNS FAILED" | tee -a "$LOG"
  fi
  [ "$i" -lt "$RUNS" ] && sleep "$INTERVAL"
done

echo "$(date -Is) done dispatching" | tee -a "$LOG"
