#!/usr/bin/env bash
# cg.sh <bin-name> <tag> <bench> [ENV=V...]: callgrind + branch sim, one marker,
# collection limited to the batch scan (scan_edges_run inlined into it), scan_object and mark_impl.
set -euo pipefail
S=${MS_SCRATCH:-$PWD}
bin=$1 tag=$2 bench=$3; shift 3
env "$@" GCRY_COLLECT_SCRUB=0 GCRY_PARALLEL_MARK=1 taskset -c 0-3 valgrind --tool=callgrind --branch-sim=yes \
  --dump-instr=yes --collect-atstart=no --toggle-collect='*scan_batch_prefetched*' --toggle-collect='*scan_object*' --toggle-collect='*mark_impl*' \
  --callgrind-out-file=$S/cg/$tag-$bench.br.out $S/bin/cm-$bin $bench 2>&1 | tail -12
