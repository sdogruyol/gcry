#!/usr/bin/env bash
# Runs regression children N times per arm. Usage:
#   child_loop.sh BIN N PIN(0|1) -- prints "<spec> <arm> <runs> <failures>"
# BIN is a spec binary built from quick-entry.cr (99, 108, 110).
set -u
BIN=$1
N=$2
PIN=${3:-0}
pre=()
[ "$PIN" = 1 ] && pre=(taskset -c 0)
one() { # name env-var value filter
  local name=$1 var=$2 val=$3 filter=$4 fails=0
  for _ in $(seq "$N"); do
    out=$(env "$var=$val" GCRY_IDLE_RELEASE_MS=0 timeout 60 "${pre[@]}" "$BIN" -e "$filter" 2>&1)
    st=$?
    case "$name" in
      110-control) echo "$out" | grep -q "inc110: control began a cycle" || st=1 ;;
      110-raise-control) echo "$out" | grep -q "inc110 raise: control kept the section" || st=1 ;;
      *) echo "$out" | grep -q "1 examples, 0 failures" || st=1 ;;
    esac
    if [ $st -ne 0 ]; then
      fails=$((fails + 1))
      [ $fails -le 2 ] && echo "--- $name failure:" && echo "$out" | head -30
    fi
  done
  echo "$name $N $fails"
}
one 110-fixed GCRY_INC110_CHILD fixed "inc110 child fixed"
one 110-control GCRY_INC110_CHILD control "inc110 child control"
one 110-raise-fixed GCRY_INC110_CHILD raise-fixed "inc110 child raise-fixed"
one 110-raise-control GCRY_INC110_CHILD raise-control "inc110 child raise-control"
one 108-fixed GCRY_COLLECT108_CHILD fixed "collect108 child fixed"
one 108-control GCRY_COLLECT108_CHILD control "collect108 child control"
for arm in race-fixed race-control nocards-fixed nocards-control softdirty-fixed softdirty-control; do
  one "99-$arm" GCRY_MPROTECT99_CHILD "$arm" "mprotect-outside-cards child $arm"
done
