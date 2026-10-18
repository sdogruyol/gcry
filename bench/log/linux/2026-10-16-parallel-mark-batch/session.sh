#!/usr/bin/env bash
# session.sh <name> <trials> <pinned-configs> <unpinned-configs> <arm>...
#
# Builds each arm (`build.sh`, skipped with SKIP_BUILD=1), then one
# interleaved `marksum.py` session pinned to CPUs 0-3 and one unpinned on all
# 12, each under the heavy lock by itself. A config is `1`
# (GCRY_PARALLEL_MARK=1), `d` (no knob: the default worker count) or `4`
# (GCRY_PARALLEL_MARK=4); configs are comma-separated, `-` for none.
# Output: logs/<name>{p,u}.txt and logs/<name>{p,u}-raw.json.
set -x
S=/home/naruto/playground/.scratch/ParallelMarkBatch
L=$S/log
LOCK=/home/naruto/playground/.scratch/heavy.lock
cd $S
name=$1 trials=$2 pcfg=$3 ucfg=$4
shift 4
ARMS="$*"
[[ -n ${SKIP_BUILD:-} ]] || flock $LOCK bash -c "for a in $ARMS; do $L/build.sh \$a || exit 1; done"
BENCHES=${BENCHES:-Primes,JsonParsePure,JsonGenerate,Binarytrees}
spec() {
  local a=$1 c=$2
  case $c in
    d) echo "${a}_d=bin/cm-$a" ;;
    *) echo "${a}_$c=bin/cm-$a:GCRY_PARALLEL_MARK=$c" ;;
  esac
}
for side in p u; do
  cfg=$pcfg cpus=0-3
  [[ $side == u ]] && cfg=$ucfg cpus=all
  [[ $cfg == - ]] && continue
  specs=()
  for a in $ARMS; do
    for c in ${cfg//,/ }; do specs+=("$(spec $a $c)"); done
  done
  CPUS=$cpus flock $LOCK python3 $L/marksum.py $trials $BENCHES logs/$name$side-raw.json "${specs[@]}" \
    > logs/$name$side.txt 2> logs/$name$side.err
done
echo done
