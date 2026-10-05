#!/bin/bash
set -u
mkdir -p bin
crystal build -Dgc_none bench/find_block_race.cr -o bin/find_block_race --error-trace || exit 1
CDB=$(ls "/c/Program Files (x86)/Windows Kits/10/Debuggers/x64/cdb.exe" 2>/dev/null | head -1)
echo "FBR cdb=${CDB:-none}"
hangs=0; fails=0
for i in $(seq 40); do
  FIND_BLOCK_RACE_RUNS=3 GCRY_SEGV_REPORT=1 bin/find_block_race > /tmp/fbr.log 2>&1 &
  pid=$!
  t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt 270 ]; do sleep 2; t=$((t + 2)); done
  if kill -0 $pid 2>/dev/null; then
    hangs=$((hangs + 1))
    echo "FBR run $i HUNG after ${t}s; last lines:"; tail -5 /tmp/fbr.log | sed 's/^/FBR   /'
    winpid=$(cat /proc/$pid/winpid 2>/dev/null)
    echo "FBR winpid=$winpid"; tasklist //FI "IMAGENAME eq find_block_race.exe" 2>/dev/null | sed 's/^/FBR   /'
    if [ -n "$CDB" ] && [ -n "$winpid" ]; then "$CDB" -p "$winpid" -c "~*kb 25;qd" 2>&1 | grep -vE "^\s*$" | head -150 | sed 's/^/FBR cdb /'; fi
    kill -9 $pid 2>/dev/null; taskkill //F //IM find_block_race.exe > /dev/null 2>&1
  else
    wait $pid; rc=$?
    [ $rc -ne 0 ] && { fails=$((fails + 1)); echo "FBR run $i rc=$rc"; tail -3 /tmp/fbr.log | sed 's/^/FBR   /'; }
    echo "FBR run $i done in ${t}s rc=$rc"
  fi
done
echo "FBR summary: 40 runs, $hangs hung, $fails failed"
