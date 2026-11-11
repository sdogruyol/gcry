#!/usr/bin/env bash
# The whole gate, end to end, N times: one line per run with its verdict and
# the in-spin arm's row. usage: gate_loop.sh <runs> <outfile> <gate binary>
set -u
runs=$1; out=$2; bin=$3
: > "$out"
for ((i = 1; i <= runs; i++)); do
  text=$("$bin" 2>&1)
  rc=$?
  verdict=FAIL
  [[ $rc == 0 && $text == *"PASS — fires on a real stall"* ]] && verdict=PASS
  inspin=$(printf '%s\n' "$text" | grep -m1 'armed+in-spin' | tr -s ' ')
  echo "$i $verdict rc=$rc |$inspin" >> "$out"
  [[ $verdict == FAIL ]] && printf '%s\n' "$text" > "$out.fail-$i"
done
