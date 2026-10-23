#!/usr/bin/env bash
# prof.sh <bin-name> <tag> <reps> <bench,...> [ENV=V ...]: SIGPROF-sample runs under taskset -c 0-3.
set -euo pipefail
S=/home/naruto/playground/.scratch/MarkCost-2
bin=$S/bin/cm-$1 tag=$2 reps=$3 benches=$4; shift 4
mkdir -p $S/prof
for b in ${benches//,/ }; do
  for r in $(seq 1 $reps); do
    env "$@" SAMPLER_OUT=$S/prof/$tag-$b-$r.txt SAMPLER_US=${SAMPLER_US:-500} LD_PRELOAD=$S/sampler.so taskset -c 0-3 $bin $b | grep -E "ok|err" || true
  done
done
