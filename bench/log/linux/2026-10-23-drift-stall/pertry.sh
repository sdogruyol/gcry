#!/usr/bin/env bash
# pertry.sh <bin> <rounds> <deadline_s> <batches> <per_batch> <tag>
# The refused-releases arm's fast child, alone and serially as the gate runs
# it, one lock hold per batch. One line per child: hung (killed at the
# deadline), clean, or crashed, with its last bucket.
set -u
BIN="$1"; R="$2"; D="$3"; B="$4"; N="$5"; TAG="$6"
OUT=/home/naruto/playground/.scratch/DriftStall/runs/pertry-$TAG.txt
for b in $(seq 1 "$B"); do
  flock /home/naruto/playground/.scratch/heavy.lock bash -c '
    BIN="$1"; R="$2"; D="$3"; N="$4"; OUT="$5"
    for k in $(seq 1 "$N"); do
      tmp=$(mktemp)
      s=$(date +%s%N)
      CHUNK_DRIFT_ROUNDS=$R GCRY_REFUSE_EMPTY_RELEASE=1000000000 timeout -s KILL "$D" "$BIN" --child --fast > "$tmp" 2>&1
      rc=$?
      ms=$(( ($(date +%s%N) - s) / 1000000 ))
      last=$(grep "^bucket" "$tmp" | tail -1 | cut -d" " -f2)
      ref=$(grep "^refused" "$tmp" | tail -1 | cut -d" " -f2)
      # `timeout` exits 124 when it killed the child, signal or not.
      case $rc in 0) st=clean;; 124|137) st=hung;; *) st=crashed;; esac
      echo "$st rc=$rc ms=$ms last_bucket=${last:-none} refused=${ref:-0}" >> "$OUT"
    done' _ "$BIN" "$R" "$D" "$N" "$OUT"
done
echo done >> "$OUT"
