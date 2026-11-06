#!/usr/bin/env bash
# Regression 74 proof: {old, fixed, control} x {headerless, headers} x
# {polluted, clean}, each binary run N times, one process per run.
P=/home/naruto/playground/.scratch/SpecHarden/p74
L=/home/naruto/playground/.scratch/heavy.lock
N=${N:-10}
for layout in hl hdr; do
  flags="-Dgc_none"; [ $layout = hdr ] && flags="$flags -Dgcry_block_headers"
  for arm in old fixed control; do
    (cd $P/$arm && flock $L crystal build $flags entry.cr -o $P/bin-$arm-$layout) || { echo "BUILD FAIL $arm $layout"; continue; }
  done
  for pol in 1 0; do
    for arm in old fixed control; do
      red=0
      for i in $(seq 1 $N); do
        POLLUTE74=$pol flock $L $P/bin-$arm-$layout > $P/out-$arm-$layout-p$pol-$i.txt 2>&1 || red=$((red + 1))
      done
      first=$(grep -h -m1 -A2 "Failure\|Expected" $P/out-$arm-$layout-p$pol-*.txt | grep -m1 "got\|Expected" | tr -s ' ')
      echo "$layout polluted=$pol $arm: $red of $N red  [$first]"
    done
  done
done
echo DONE
