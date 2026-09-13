#!/usr/bin/env bash
# Rates for the gates that have gone red on CI and never locally, plus the five
# aarch64 specs that failed together twice this week. A rate is the only thing
# that separates "this gate is flaky" from "that runner is", and the only way to
# get one is to run the thing a few hundred times.
#
# Each loop prints `<name> <failures>/<runs>` and appends every failing run's
# output to $LOG so a sighting is not lost to a counter.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
LOG="${LOG:-/tmp/gcry-overnight-loops.log}"
: > "$LOG"

loop() {
  local name="$1" runs="$2"; shift 2
  local fails=0 i out
  for i in $(seq 1 "$runs"); do
    if ! out="$("$@" 2>&1)"; then
      fails=$((fails + 1))
      {
        echo "=== $name run $i FAILED $(date -Is) ==="
        echo "$out" | tail -40
      } >> "$LOG"
    fi
  done
  echo "$(date -Is) $name ${fails}/${runs} failed" | tee -a "$LOG"
}

# The three whose CI reds started this: the holders search dying inside its own
# report (now named rather than silent), the mark-clear control that was asking
# a rare question of a tiny sample, and the drift gate those two produced.
loop poison-holders   120 timeout 300 make poison-holders
loop mark-clear-index  40 timeout 600 make mark-clear-index
loop chunk-list-drift  12 timeout 900 make chunk-list-drift
loop counter-loss      12 timeout 600 make counter-loss

# The five that failed together on `test (aarch64 native)` on two
# documentation-only commits. They pass here — the question is at what rate, on
# a host with a different page size and core count, because 0 of 200 locally
# against 2 of 3 runs there is the asymmetry, and the asymmetry is the finding.
loop retention-specs   80 timeout 600 crystal spec \
  spec/dormant_revive_spec.cr spec/empty_chunk_grace_spec.cr spec/invariant_spec.cr

loop thread-churn-uaf   6 timeout 900 make thread-churn-uaf

echo "$(date -Is) loops done" | tee -a "$LOG"
