#!/bin/sh
# usage: loop.sh <tag> <runs> <bin> <cwd> [VAR=val...]; each run takes the shared lock for itself only.
# Run numbers continue after the tag's existing logs.
tag=$1; runs=$2; bin=$3; cwd=$4; shift 4
R=/home/naruto/playground/.scratch/ScrubBand
mkdir -p $R/runs/$tag
n=0
while [ $n -lt $runs ]; do
  i=$(( $(ls $R/runs/$tag | grep -c '\.log$') + 1 ))
  log=$R/runs/$tag/$i.log
  (cd $cwd && env "$@" flock /home/naruto/playground/.scratch/heavy.lock $R/bin/$bin > $log 2>&1)
  rc=$?
  sum=$(grep -E '^[0-9]+ examples' $log | tail -1)
  f=$(grep -oE '^crystal spec [^ ]*/(61|21|1)_[a-z_]+spec\.cr|^crystal spec \./61_unfixed\.cr' $log | sed 's#.*/##' | sort -u | tr '\n' ' ')
  other=$(grep -E '^crystal spec ' $log | grep -vE '/(61|21|1)_[a-z_]+spec\.cr|61_unfixed' | sed 's#.*regression/##; s# .*##' | sort -u | tr '\n' ' ')
  echo "$tag $i rc=$rc fail=[$f] other=[$other] $sum" >> $R/runs/$tag/summary.txt
  n=$((n+1))
done
