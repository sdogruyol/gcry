#!/bin/sh
# usage: loop.sh <tag> <runs> <bin> [VAR=val...]; cwd = wt; each run takes the shared lock for itself only.
tag=$1; runs=$2; bin=$3; shift 3
R=/home/naruto/playground/.scratch/CI21
mkdir -p $R/runs/$tag
n=0
while [ $n -lt $runs ]; do
  i=$(( $(ls $R/runs/$tag | grep -c '\.log$') + 1 ))
  log=$R/runs/$tag/$i.log
  (cd $R/wt && env GCRY_BITMAP_ALLOC=0 "$@" flock /home/naruto/playground/.scratch/heavy.lock $R/bin/$bin > $log 2>&1)
  rc=$?
  moved=0; grep -q "tracking the main thread's stack bottom" $log && moved=1
  f21=0; grep -q "^crystal spec .*regression/21_" $log && f21=1
  fails=$(grep -E '^crystal spec ' $log | sed 's#.*regression/##; s# .*##' | tr '\n' ' ')
  echo "$tag $i rc=$rc f21=$f21 moved=$moved $(grep -E '^[0-9]+ examples' $log | tail -1) fails=[$fails]" >> $R/runs/$tag/summary.txt
  n=$((n+1))
done
