#!/bin/bash
# usage: loop.sh <bin> <n> <tag> [env...]
BIN=$1; N=$2; TAG=$3; shift 3
pass=0; fail=0
for i in $(seq 1 $N); do
  env GCRY_BITMAP_ALLOC=0 "$@" $BIN > out.$TAG.$i 2>&1; rc=$?
  if [ $rc -eq 0 ]; then pass=$((pass+1)); rm -f out.$TAG.$i; else fail=$((fail+1)); echo "run $i rc=$rc" >> fails.$TAG; fi
done
echo "$TAG: n=$N pass=$pass fail=$fail" | tee -a summary.txt
