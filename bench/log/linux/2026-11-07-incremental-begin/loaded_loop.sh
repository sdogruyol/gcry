#!/usr/bin/env bash
# Regression 110's children under a 10-process CPU load (nice 10 busy loops),
# headers + GCRY_BITMAP_ALLOC=0, unpinned. Usage: loaded_loop.sh BIN N
BIN=$1 N=$2
for i in $(seq 10); do timeout 3600 nice -n 10 sh -c 'while :; do :; done' & done
for arm in fixed control; do
  f=0
  for _ in $(seq "$N"); do
    out=$(GCRY_BITMAP_ALLOC=0 GCRY_INC110_CHILD=$arm GCRY_IDLE_RELEASE_MS=0 timeout 60 "$BIN" -e "inc110 child $arm" 2>&1)
    case $arm in
      control) grep -q "inc110: control began a cycle" <<<"$out" || { f=$((f+1)); echo "$out" | grep -m3 -E "Error|never|inc110"; } ;;
      fixed) grep -q "1 examples, 0 failures" <<<"$out" || { f=$((f+1)); echo "$out" | grep -m3 -E "Error|never|inc110"; } ;;
    esac
  done
  echo "110-$arm loaded $N $f"
done
kill $(jobs -p) 2>/dev/null
wait
