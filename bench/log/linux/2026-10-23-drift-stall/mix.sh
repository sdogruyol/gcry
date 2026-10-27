#!/usr/bin/env bash
# mix.sh <tag> <limit_s> <batches> <cmdfile>
# Each batch: one hold of heavy.lock; every line of <cmdfile> (a shell command,
# run from the worktree) runs in parallel under bench/run_bounded.sh.
set -u
TAG="$1"; LIMIT="$2"; BATCHES="$3"; CMDS="$4"
WT=/home/naruto/playground/.scratch/DriftStall/wt
OUT=/home/naruto/playground/.scratch/DriftStall/runs/$TAG
mkdir -p "$OUT"
for b in $(seq 1 "$BATCHES"); do
  [ -e "$OUT/STOP" ] && break
  flock /home/naruto/playground/.scratch/heavy.lock bash -c '
    WT="$1"; OUT="$2"; LIMIT="$3"; CMDS="$4"; b="$5"
    k=0
    pids=()
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      k=$((k + 1))
      (
        log="$OUT/run-$b-$k.log"
        s=$(date +%s)
        cd "$WT" && bench/run_bounded.sh "$LIMIT" "$log" -- bash -c "$line"
        rc=$?
        e=$(date +%s)
        echo "$b-$k rc=$rc t=$((e - s)) :: $line" >> "$OUT/summary.txt"
      ) &
      pids+=($!)
    done < "$CMDS"
    wait "${pids[@]}"
  ' _ "$WT" "$OUT" "$LIMIT" "$CMDS" "$b"
done
echo "done" >> "$OUT/summary.txt"
