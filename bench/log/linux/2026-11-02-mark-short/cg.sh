#!/usr/bin/env bash
# cg.sh BIN BENCH [ENV=V...]: callgrind (cache + branch sim) of crystal-metric $S/bin/BIN, counting only inside
# the batch scan (`scan_batch_prefetched`; for the kept tree toggle `*scan_batch_compact*` and
# `*scan_batch_unrolled*` instead). Run it under the heavy lock.
S=${MS_SCRATCH:-$PWD}
b=$1 bench=$2; shift 2
tag=$b-$bench${CGTAG:+-$CGTAG}
env "$@" GCRY_COLLECT_SCRUB=0 taskset -c 0-3 valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes \
  --dump-instr=yes --collect-atstart=no --toggle-collect='*scan_batch_prefetched*' \
  --callgrind-out-file=$S/cg/$tag.out $S/bin/$b $bench > $S/cg/$tag.log 2>&1
grep -E "Collected|$bench:" $S/cg/$tag.log
