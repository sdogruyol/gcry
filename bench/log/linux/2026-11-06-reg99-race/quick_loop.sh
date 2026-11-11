#!/usr/bin/env bash
# usage: quick_loop.sh <bin> <n> <tag> [taskset-prefix...]
bin=$1 n=$2 tag=$3; shift 3
cd ${TREE:-/home/naruto/playground/.scratch/Reg99Race/wt}
for arm in ${ARMS:-race-fixed race-control c108-fixed c108-control}; do
  f=0
  for i in $(seq 1 $n); do
    case $arm in
      race-*) out=$(GCRY_MPROTECT99_CHILD=$arm "$@" $bin -e "mprotect-outside-cards child $arm" 2>&1) ;;
      c108-*) a=${arm#c108-}; envx=""; [ $a = control ] && envx="GCRY_DEBUG_INVARIANTS="; out=$(env $envx GCRY_COLLECT108_CHILD=$a "$@" $bin -e "collect108 child $a" 2>&1) ;;
    esac
    if ! grep -q "1 examples, 0 failures" <<<"$out"; then f=$((f+1)); echo "$out" > ../runs/quick/$tag-$arm-$i.txt; fi
  done
  echo "$tag $arm fails=$f/$n"
done
