#!/usr/bin/env bash
# cgi.sh BIN BENCH [ENV=V...]: callgrind instructions only, one marker, counting only inside the batch scan.
# Run it under the heavy lock.
S=${MS_SCRATCH:-$PWD}
b=$1 bench=$2; shift 2
env "$@" GCRY_COLLECT_SCRUB=0 GCRY_PARALLEL_MARK=1 taskset -c 0-3 valgrind --tool=callgrind \
  --dump-instr=yes --collect-atstart=no --toggle-collect='*scan_batch_prefetched*' \
  --callgrind-out-file=$S/cg/$b-$bench.ir.out $S/bin/$b $bench > $S/cg/$b-$bench.ir.log 2>&1
grep -E "Collected|$bench:" $S/cg/$b-$bench.ir.log
