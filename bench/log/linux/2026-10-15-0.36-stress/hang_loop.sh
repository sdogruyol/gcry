#!/usr/bin/env bash
# hang_loop.sh <tree> <binary> <runs> <outdir>: run the stw-mt property test
# release binary with fresh seeds, bounded at 60 s, capture stalls.
tree=$1 bin=$2 runs=$3 out=$4
mkdir -p "$out"; cd "$tree" || exit 1
pass=0 fail=0 stall=0 sched=0
for i in $(seq 1 "$runs"); do
  s=$RANDOM
  flock /home/naruto/playground/.scratch/heavy.lock bench/run_bounded.sh 60 "$out/run.log" -- "$bin" --seed=$s --iterations=400 --workers=2,4,8
  rc=$?
  case $rc in
    0) pass=$((pass+1)) ;;
    1) fail=$((fail+1)); cp "$out/run.log" "$out/fail-$i-seed$s.log" ;;
    2) stall=$((stall+1)); cp "$out/run.log" "$out/stall-$i-seed$s.log" ;;
    3) sched=$((sched+1)); cp "$out/run.log" "$out/sched-$i-seed$s.log" ;;
  esac
done
echo "runs=$runs pass=$pass fail=$fail stall=$stall known_scheduler_deadlock=$sched"
