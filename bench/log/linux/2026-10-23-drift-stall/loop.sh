#!/usr/bin/env bash
# loop.sh <bin> <tag> <batches> <par> <limit_s> [child args...]
# Each batch: one hold of heavy.lock, <par> bounded children in parallel.
set -u
BIN="$1"; TAG="$2"; BATCHES="$3"; PAR="$4"; LIMIT="$5"; shift 5
ARGS=("$@")
WT=/home/naruto/playground/.scratch/DriftStall/wt
OUT=/home/naruto/playground/.scratch/DriftStall/runs/$TAG
mkdir -p "$OUT"
SUM="$OUT/summary.txt"
: "${ROUNDS:=1200}"
for b in $(seq 1 "$BATCHES"); do
  [ -e "$OUT/STOP" ] && break
  flock /home/naruto/playground/.scratch/heavy.lock bash -c '
    WT="$1"; OUT="$2"; BIN="$3"; LIMIT="$4"; PAR="$5"; b="$6"; ROUNDS="$7"; shift 7
    pids=()
    for k in $(seq 1 "$PAR"); do
      (
        log="$OUT/run-$b-$k.log"
        s=$(date +%s)
        cd "$WT" && bench/run_bounded.sh "$LIMIT" "$log" -- env CHUNK_DRIFT_ROUNDS="$ROUNDS" "$BIN" "$@"
        rc=$?
        e=$(date +%s)
        echo "$b-$k rc=$rc t=$((e - s))" >> "$OUT/summary.txt"
        [ "$rc" = 0 ] && rm -f "$log"
      ) &
      pids+=($!)
    done
    wait "${pids[@]}"
  ' _ "$WT" "$OUT" "$BIN" "$LIMIT" "$PAR" "$b" "$ROUNDS" "${ARGS[@]}"
  if [ -z "${NOSTOP:-}" ] && grep -q "rc=2" "$SUM" 2>/dev/null; then
    echo "stall seen" >> "$SUM"
    break
  fi
done
echo "done" >> "$SUM"
