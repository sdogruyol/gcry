#!/usr/bin/env bash
# Run stw_mt (+diag env) over seeds; on a run still alive after 60 s, dump
# every thread's state and a gdb backtrace through a live thread, then kill.
cd "$(dirname "$0")"
ulimit -Sv unlimited
start=${1:-7000}; n=${2:-200}
hangs=0
for s in $(seq $start $((start + n - 1))); do
  GCRY_POISON_FREED=1 GCRY_SEGV_REPORT=1 ./stw_mt --seed=$s --iterations=200 --workers=2,4,8 > hh.txt 2>&1 &
  pid=$!
  t=0
  while [ $t -lt 60 ] && [ -d /proc/$pid ] && [ "$(awk '{print $3}' /proc/$pid/stat 2>/dev/null)" != "Z" -o "$(ls /proc/$pid/task 2>/dev/null | wc -l)" -gt 1 ]; do
    if ! kill -0 $pid 2>/dev/null; then break; fi
    # a fully finished process: leader zombie and no other task
    [ "$(ls /proc/$pid/task 2>/dev/null | wc -l)" -le 1 ] && [ "$(awk '{print $3}' /proc/$pid/stat 2>/dev/null)" = "Z" ] && break
    sleep 1; t=$((t + 1))
  done
  if [ $t -ge 60 ]; then
    hangs=$((hangs + 1))
    out=hang_$s.txt
    { echo "seed $s pid $pid"; cat hh.txt; echo "--- tasks"
      for tk in /proc/$pid/task/*; do echo "$(basename $tk) $(cat $tk/comm) state=$(awk '{print $3}' $tk/stat) wchan=$(cat $tk/wchan 2>/dev/null)"; done
      live=$(for tk in /proc/$pid/task/*; do [ "$(awk '{print $3}' $tk/stat)" != "Z" ] && basename $tk; done | head -1)
      echo "--- gdb via tid $live"
      gdb -q -batch -p "$live" -ex "set pagination off" -ex "info threads" -ex "thread apply all bt 30" 2>&1
    } > $out
    kill -9 $pid 2>/dev/null
    echo "seed $s: stalled, dumped to $out"
  fi
  wait $pid 2>/dev/null
done
echo "hunt done: $hangs stall(s) in $n runs"
