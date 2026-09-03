#!/usr/bin/env bash
set -uo pipefail
SP="/tmp/claude-1000/-home-steve-projects-scratch-gcry/7e41c2fd-f0a1-4087-b6f5-d7abf89777ca/scratchpad"
GCRY=/home/steve/projects/scratch/gcry/bin/kemal-gcry-bmab
BOEHM=/home/steve/projects/scratch/gcry/bin/kemal-boehm-bmab
OUT="$SP/results.jsonl"
T="$SP/trial.sh"
rm -f "$OUT"
export DUR=10 CONN=50 PORT=3001

echo "=== warmup (discarded) ==="
"$T" "$GCRY" /json warmup "$SP/warmup.jsonl"
"$T" "$GCRY" /      warmup "$SP/warmup.jsonl"

echo "=== boehm reference (start) ==="
"$T" "$BOEHM" /json boehm_start "$OUT"
"$T" "$BOEHM" /      boehm_start "$OUT"

N=16
for r in $(seq 1 $N); do
  echo "=== round $r/$N ==="
  if (( r % 2 == 1 )); then
    "$T" "$GCRY" /json default "$OUT"
    "$T" "$GCRY" /json bitmap  "$OUT" GCRY_BITMAP=1
    "$T" "$GCRY" /      bitmap "$OUT" GCRY_BITMAP=1
    "$T" "$GCRY" /      default "$OUT"
  else
    "$T" "$GCRY" /json bitmap  "$OUT" GCRY_BITMAP=1
    "$T" "$GCRY" /json default "$OUT"
    "$T" "$GCRY" /      default "$OUT"
    "$T" "$GCRY" /      bitmap "$OUT" GCRY_BITMAP=1
  fi
  # null control: default-vs-default, 4 pairs per path, spread through the batch
  if (( r % 4 == 0 )); then
    echo "--- null control (round $r) ---"
    if (( (r/4) % 2 == 1 )); then
      "$T" "$GCRY" /json nullA "$OUT"; "$T" "$GCRY" /json nullB "$OUT"
      "$T" "$GCRY" /      nullB "$OUT"; "$T" "$GCRY" /      nullA "$OUT"
    else
      "$T" "$GCRY" /json nullB "$OUT"; "$T" "$GCRY" /json nullA "$OUT"
      "$T" "$GCRY" /      nullA "$OUT"; "$T" "$GCRY" /      nullB "$OUT"
    fi
  fi
done

echo "=== boehm reference (end) ==="
"$T" "$BOEHM" /json boehm_end "$OUT"
"$T" "$BOEHM" /      boehm_end "$OUT"
echo "=== BATCH DONE ==="
