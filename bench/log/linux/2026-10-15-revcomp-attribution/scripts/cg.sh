#!/usr/bin/env bash
# Callgrind (instruction counts per function + simulated I1/D1/LL caches and
# branch predictor) for each build x bench, one lock acquisition per run.
set -uo pipefail
S=/home/naruto/playground/.scratch/RevcompCounters
L=/home/naruto/playground/.scratch/heavy.lock
# The collector's stack scrub writes below SP to bounds valgrind's simulated
# main stack does not have (SEGV in collect_scrub -> clear on the first
# GC.collect, reported as "Stack overflow"); turn it off in every arm.
export GCRY_COLLECT_SCRUB=0
mkdir -p $S/cg
cd $S
for bench in "$@"; do
  for b in v0.35.0 6dc6e7d0 b1cdc0ed 48e7c749 v0.36.0; do
    echo "== $bench $b $(date +%T)"
    flock $L valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes \
      --callgrind-out-file=$S/cg/$bench-$b.out $S/bin/cm-$b $bench > $S/cg/$bench-$b.log 2>&1
    echo "rc=$? $(date +%T)"
  done
done
echo CG_DONE
