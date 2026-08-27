#!/bin/sh
# Catch the ~0.5% silent hang live: any child alive past 90 s gets
# `gdb -p` (thread apply all bt) before it is killed. Stops at first capture.
set -u
BIN=bin/dfr_fix2
OUT=bench/log/linux/2026-08-27-stw-write-protocols/rawhang2
mkdir -p "$OUT"
i=0
while [ "$i" -lt 150 ] && [ ! -e "$OUT/CAPTURED" ]; do
  pids=""
  for t in a b c d; do
    GCRY_MOSTLY_EMPTY=1 GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1 \
      "$BIN" --child >"$OUT/w-$i-$t.log" 2>&1 &
    pids="$pids $!"
  done
  start=$(date +%s)
  while :; do
    alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break
    el=$(( $(date +%s) - start ))
    if [ "$el" -gt 90 ]; then
      for p in $pids; do
        if kill -0 "$p" 2>/dev/null; then
          gdb -p "$p" -batch -ex 'set pagination off' -ex 'thread apply all bt' \
            >"$OUT/gdb-$i-$p.txt" 2>&1
          touch "$OUT/CAPTURED"
          kill -9 "$p" 2>/dev/null
        fi
      done
      break
    fi
    sleep 2
  done
  wait
  i=$((i + 1))
done
echo done
