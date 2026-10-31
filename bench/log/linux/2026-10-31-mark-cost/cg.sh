#!/usr/bin/env bash
# cg.sh <bin-name> <tag> <bench> [ENV=V...]: callgrind + cache sim (D1 48 KiB 12-way, LL 32 MiB), one marker,
# collection limited to the batch scan (scan_edges_run inlined into it), scan_object and mark_impl.
set -euo pipefail
S=${MS_SCRATCH:-$PWD}
bin=$1 tag=$2 bench=$3; shift 3
env "$@" GCRY_COLLECT_SCRUB=0 GCRY_PARALLEL_MARK=1 taskset -c 0-3 valgrind --tool=callgrind --cache-sim=yes --D1=49152,12,64 --LL=33554432,16,64 \
  --dump-instr=yes --collect-atstart=no --toggle-collect='*scan_batch_prefetched*' --toggle-collect='*scan_object*' --toggle-collect='*mark_impl*' \
  --callgrind-out-file=$S/cg/$tag-$bench.out $S/bin/cm-$bin $bench 2>&1 | tail -12
