#!/usr/bin/env bash
# cg.sh BIN BENCH [ENV...]: callgrind of one run under the heavy lock -> cg/BIN-BENCH.out
S=/home/naruto/playground/.scratch/RevcompHost
b=$1 bench=$2; shift 2
tag=$b-$bench${CGTAG:+-$CGTAG}
flock /home/naruto/playground/.scratch/heavy.lock env "$@" valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes --callgrind-out-file=$S/cg/$tag.out $S/bins/$b $bench > $S/cg/$tag.log 2>&1
grep -E "Collected|$bench" $S/cg/$tag.log
