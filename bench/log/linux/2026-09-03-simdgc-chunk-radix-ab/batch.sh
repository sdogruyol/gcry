#!/usr/bin/env bash
set -uo pipefail
SP="/tmp/claude-1000/-home-steve-projects-scratch-gcry/7e41c2fd-f0a1-4087-b6f5-d7abf89777ca/scratchpad"
BIN=/home/steve/projects/scratch/gcry/bin/kemal-gcry-radixab
OUT="$SP/results.jsonl"
T="$SP/trial.sh"
rm -f "$OUT"
export DUR=10 CONN=50 PORT=3001
R=1  # radix arm env
N=32

echo "=== warmup (discarded) ==="
"$T" "$BIN" /json warmup "$SP/warmup.jsonl"
"$T" "$BIN" /      warmup "$SP/warmup.jsonl"

for r in $(seq 1 $N); do
  echo "=== round $r/$N  $(date +%H:%M:%S) ==="
  if (( r % 2 == 1 )); then
    # treatment block first this round
    "$T" "$BIN" /json default "$OUT"
    "$T" "$BIN" /json radix   "$OUT" GCRY_CHUNK_RADIX=1
    "$T" "$BIN" /      radix   "$OUT" GCRY_CHUNK_RADIX=1
    "$T" "$BIN" /      default "$OUT"
    "$T" "$BIN" /json nullA "$OUT"
    "$T" "$BIN" /json nullB "$OUT"
    "$T" "$BIN" /      nullB "$OUT"
    "$T" "$BIN" /      nullA "$OUT"
  else
    # null block first this round, and within-pair order flipped
    "$T" "$BIN" /json nullB "$OUT"
    "$T" "$BIN" /json nullA "$OUT"
    "$T" "$BIN" /      nullA "$OUT"
    "$T" "$BIN" /      nullB "$OUT"
    "$T" "$BIN" /json radix   "$OUT" GCRY_CHUNK_RADIX=1
    "$T" "$BIN" /json default "$OUT"
    "$T" "$BIN" /      default "$OUT"
    "$T" "$BIN" /      radix   "$OUT" GCRY_CHUNK_RADIX=1
  fi
done
echo "=== BATCH DONE $(date +%H:%M:%S) ==="
