#!/usr/bin/env bash
# Session 1: the pop batch sweep. Builds every arm, then 7 interleaved trials
# pinned to CPUs 0-3 (default = 2 workers, and GCRY_PARALLEL_MARK=4), then 7
# unpinned on all 12 CPUs (default = 4 workers, the same as
# GCRY_PARALLEL_MARK=4 there). Each step takes the heavy lock by itself.
set -x
S=/home/naruto/playground/.scratch/ParallelMarkBatch
L=$S/log
LOCK=/home/naruto/playground/.scratch/heavy.lock
cd $S
ARMS="base pb64 pb256 pb1024 pb1024w256"
[[ -n ${SKIP_BUILD:-} ]] || flock $LOCK bash -c "for a in $ARMS; do $L/build.sh \$a || exit 1; done"
B=bin/cm-
BENCHES=Primes,JsonParsePure,JsonGenerate,Binarytrees
pinned=() unpinned=()
for a in $ARMS; do
  pinned+=("${a}_d=${B}$a" "${a}_4=${B}$a:GCRY_PARALLEL_MARK=4")
  unpinned+=("${a}_d=${B}$a")
done
CPUS=0-3 flock $LOCK python3 $L/marksum.py 7 $BENCHES logs/s1p-raw.json "${pinned[@]}" > logs/s1p.txt 2> logs/s1p.err
CPUS=all flock $LOCK python3 $L/marksum.py 7 $BENCHES logs/s1u-raw.json "${unpinned[@]}" > logs/s1u.txt 2> logs/s1u.err
echo done
