#!/usr/bin/env bash
# Alternating v0.39.0 / tip runs of the stw-mt-property-test-release loop,
# each run under the shared heavy lock (the script locks per run).
S=/home/naruto/playground/.scratch/SpecHarden
export HEAVY_LOCK=/home/naruto/playground/.scratch/heavy.lock
for round in 1 2; do
  for arm in v039 tip; do
    echo "$(date -Is) start $arm round $round"
    $S/tip/bench/stress_overnight.sh --only='stw-mt-property-test-release' $S/$arm $S/stress/$arm-$round
    echo "$(date -Is) end $arm round $round rc=$?"
  done
done
echo DONE
