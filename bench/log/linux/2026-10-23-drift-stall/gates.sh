#!/usr/bin/env bash
# gates.sh <bin> <tag> <runs> <limit_s> — the whole gate, one run per hold of
# heavy.lock, each bounded by bench/run_bounded.sh (CHUNK_DRIFT_ROUNDS=1200, as
# `make chunk-list-drift`). Logs kept for every run that failed, stalled, or
# had a fast child hang.
set -u
BIN="$1"; TAG="$2"; RUNS="$3"; LIMIT="$4"
WT=/home/naruto/playground/.scratch/DriftStall/wt
OUT=/home/naruto/playground/.scratch/DriftStall/runs/$TAG
mkdir -p "$OUT"
for i in $(seq 1 "$RUNS"); do
  [ -e "$OUT/STOP" ] && break
  log="$OUT/gate-$i.log"
  s=$(date +%s)
  (cd "$WT" && flock /home/naruto/playground/.scratch/heavy.lock \
    bench/run_bounded.sh "$LIMIT" "$log" -- env CHUNK_DRIFT_ROUNDS=1200 "$BIN")
  rc=$?
  e=$(date +%s)
  hung=$(grep -o "fast arm: [0-9]* child(ren) hung" "$log" | grep -o "[0-9]*" | head -1)
  retried=$(grep -o "fast arm: [0-9]* child(ren) crashed or hung before" "$log" | grep -o "[0-9]*" | head -1)
  refused=$(grep -o "shipped: exited cleanly, [0-9]* release" "$log" | grep -o "[0-9]*" | head -1)
  rfast=$(grep -c "^  fast:    hung" "$log")
  fails=$(grep -c "^FAIL" "$log")
  echo "$i rc=$rc t=$((e - s)) fast_hung=${hung:-0} fast_retried=${retried:-0} refuse_shipped=${refused:-?} refuse_fast_hangs=$rfast fails=$fails" >> "$OUT/summary.txt"
  if [ "$rc" = 0 ] && [ -z "$hung" ]; then rm -f "$log"; fi
done
echo done >> "$OUT/summary.txt"
