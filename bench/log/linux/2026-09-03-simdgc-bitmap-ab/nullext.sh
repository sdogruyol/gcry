#!/usr/bin/env bash
set -uo pipefail
SP="/tmp/claude-1000/-home-steve-projects-scratch-gcry/7e41c2fd-f0a1-4087-b6f5-d7abf89777ca/scratchpad"
GCRY=/home/steve/projects/scratch/gcry/bin/kemal-gcry-bmab
OUT="$SP/nullext.jsonl"; T="$SP/trial.sh"
rm -f "$OUT"; export DUR=10 CONN=50 PORT=3001
for r in $(seq 1 12); do
  echo "=== null-ext round $r/12 ==="
  if (( r % 2 == 1 )); then
    "$T" "$GCRY" /json nullA "$OUT"; "$T" "$GCRY" /json nullB "$OUT"
    "$T" "$GCRY" /      nullB "$OUT"; "$T" "$GCRY" /      nullA "$OUT"
  else
    "$T" "$GCRY" /json nullB "$OUT"; "$T" "$GCRY" /json nullA "$OUT"
    "$T" "$GCRY" /      nullA "$OUT"; "$T" "$GCRY" /      nullB "$OUT"
  fi
done
echo "=== NULLEXT DONE ==="
