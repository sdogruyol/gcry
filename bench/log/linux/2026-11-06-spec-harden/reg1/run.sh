#!/usr/bin/env bash
# Regression 1 in suite order: this tree's process_spec glob order cut after
# regression 1 (57 files), one binary per arm and config, one run per process,
# each run under the shared lock, arms interleaved.
#   new = spec-harden-040 (cycles in a child), old = release-0.40.0 4e3ba9be.
#   hl122 = Crystal 1.22.2 headerless; ba0 = 1.21 headers + GCRY_BITMAP_ALLOC=0.
# usage: [START=i] run.sh <config> <runs> [arms]
S=/home/naruto/playground/.scratch/SpecHarden
R=$S/reg1
L=/home/naruto/playground/.scratch/heavy.lock
C122=$HOME/.local/share/mise/installs/crystal/1.22.2/bin
cfg=$1 n=$2 arms=${3:-new old} start=${START:-1}
for arm in $arms; do
  tree=$S/wt; [ $arm = old ] && tree=$S/tip
  bin=$R/bin-$arm-$cfg
  [ -x $bin ] && continue
  case $cfg in
    hl122) (cd $tree && flock $L env PATH="$C122:$PATH" crystal build -Dgc_none reg1_prefix_entry.cr -o $bin) ;;
    ba0) (cd $tree && flock $L crystal build -Dgc_none -Dgcry_block_headers reg1_prefix_entry.cr -o $bin) ;;
  esac || { echo "BUILD FAIL $arm $cfg"; exit 1; }
done
envs=""; [ $cfg = ba0 ] && envs="GCRY_BITMAP=1 GCRY_BITMAP_ALLOC=0"
for i in $(seq $start $((start + n - 1))); do
  for arm in $arms; do
    out=$R/out-$arm-$cfg-$i.txt
    t0=$(date +%s)
    (cd $S/wt && flock $L env $envs $R/bin-$arm-$cfg > $out 2>&1)
    rc=$?
    fails=$(grep -o "1_live_objects_dormant_spec.cr:[0-9]*" $out | sort -u | tr '\n' ' ')
    other=$(grep -E "^crystal spec .*_spec.cr:[0-9]+" $out | grep -v 1_live_objects | sed 's/ #.*//' | tr '\n' ' ')
    drift=$(grep -o "count=10000 drift=[-0-9]* | count=1000 drift=[-0-9]*" $out | head -1)
    verdict=$(grep -o "live1 verdict:.*" $out | head -1)
    summ=$(grep -E "^[0-9]+ examples" $out | tail -1)
    echo "$cfg $arm $i rc=$rc $(($(date +%s) - t0))s reg1=[$fails] {$drift} {$verdict} other=[$other] $summ" | tee -a $R/rates-$cfg.txt
  done
done
echo DONE
