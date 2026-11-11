#!/bin/sh
# claim_stress --workers=72, both arms, fix and old tree, interleaved, one run per lock hold.
R=/home/naruto/playground/.scratch/Reg21d
L=/home/naruto/playground/.scratch/heavy.lock
mkdir -p $R/runs/cs
cd $R/wt
for seed in $(seq 1 50); do
  for tree in fix base; do
    for arm in lazy instop; do
      env=""; [ $arm = instop ] && env="GCRY_DISABLE_LAZY_SWEEP=1"
      log=$R/runs/cs/$tree-$arm-$seed.log
      flock $L env $env timeout 300 $R/bin/cs_$tree --seconds=5 --workers=72 --seed=$seed > $log 2>&1
      rc=$?
      echo "$tree $arm seed=$seed rc=$rc $(grep -o 'collections=[0-9]*\|fallback_passes=[0-9]*\|after_world_sweeps=[0-9]*\|sets_pinned=[0-9]*' $log | tr '\n' ' ')$(grep RESULT $log)" >> $R/runs/cs/summary.txt
    done
  done
done
echo CS DONE
