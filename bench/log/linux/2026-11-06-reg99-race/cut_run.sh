#!/usr/bin/env bash
# Regression 99 in suite order: the tree's process_spec glob order cut after
# regression 99 (12 files, reg99_cut99_entry.cr), one binary per arm and
# config, one run per process under the shared lock, arms interleaved.
# new = reg99-race-040, old = release-0.40.0 b339f533.
# hl122 = Crystal 1.22.2 headerless; ba0 = 1.21 headers + GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0.
# PIN=1 runs the whole binary, and so its children, on CPU 0 (taskset), the
# loaded host's wake-up order; its rates go to rates-<config>-pin1.txt.
# usage: [START=i] [PIN=1] cut_run.sh <config> <runs> [arms]
S=/home/naruto/playground/.scratch/Reg99Race
L=/home/naruto/playground/.scratch/heavy.lock
cfg=$1 n=$2 arms=${3:-new old} start=${START:-1}
envs=""; [ $cfg = ba0 ] && envs="GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0"
pin=""; tag=$cfg; [ "${PIN:-0}" = 1 ] && pin="taskset -c 0" && tag=$cfg-pin1
mkdir -p $S/runs/cut
for i in $(seq $start $((start + n - 1))); do
  for arm in $arms; do
    tree=$S/wt; [ $arm = old ] && tree=$S/old
    out=$S/runs/cut/out-$arm-$tag-$i.txt
    t0=$(date +%s)
    (cd $tree && flock $L env $envs $pin $S/bin/cut-$arm-$cfg > $out 2>&1)
    rc=$?
    fails=$(grep -E "^crystal spec .*_spec.cr:[0-9]+" $out | sed 's/ #.*//' | tr '\n' ' ')
    race=$(grep -o "mprotect99 race: the queued slice returned [a-z]*[^\n]*" $out | tr '\n' '|')
    summ=$(grep -E "^[0-9]+ examples" $out | tail -1)
    echo "$cfg $arm $i rc=$rc $(($(date +%s) - t0))s fails=[$fails] {$race} $summ" >> $S/runs/cut/rates-$tag.txt
    [ $rc = 0 ] && rm -f $out
  done
done
echo DONE
