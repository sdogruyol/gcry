#!/usr/bin/env bash
# cg.sh <bin-name> <tag> <bench>: callgrind with cache simulation (D1 64 KiB, LL 16 MiB),
# one marker, collection limited to the mark scan functions. The collector's
# stack scrub faults under valgrind (it clears below SP), so it is off here.
set -euo pipefail
S=/home/naruto/playground/.scratch/MarkCost
mkdir -p $S/cg
GCRY_COLLECT_SCRUB=0 GCRY_PARALLEL_MARK=1 taskset -c 0-3 valgrind --tool=callgrind --cache-sim=yes --D1=65536,8,64 --LL=16777216,16,64 \
  --dump-instr=yes --collect-atstart=no --toggle-collect='*scan_object*' --toggle-collect='*mark_impl_unlocked*' \
  --callgrind-out-file=$S/cg/$2-$3.out $S/bin/cm-$1 $3 2>&1 | tail -12
