#!/usr/bin/env bash
# Run a command with a deadline, and capture a stall instead of just killing it.
#
#   bench/run_bounded.sh <seconds> <log> -- <command> [args...]
#
# Exit 0 when the command passed, 1 when it failed, 2 when it was still running
# at the deadline — in which case `bench/stall_capture.sh` has appended every
# thread's state and a backtrace to <log> before the kill — and 3 when that
# stall is the known Crystal 1.21 Parallel-scheduler deadlock: two or more
# threads spinning in `Scheduler#resume` (`parallel/scheduler.cr:97`) and no
# collector frame anywhere. It reproduces under Boehm with no GC calls at all
# (`bench/log/linux/2026-09-25-parallel-scheduler-deadlock/`), so a sampler
# reports it without counting it against gcry.
#
# "Still running" is read from /proc, not `kill -0`: a child that has exited
# but not been waited for is a zombie, and `kill -0` succeeds on it. And a
# zombie *leader* with live threads is not finished — it is a process whose
# main thread exited while others ran on, the shape of the one stall this was
# written for (2026-09-25).
limit="$1"; log="$2"; shift 2; [ "$1" = "--" ] && shift
here="$(cd "$(dirname "$0")" && pwd)"

"$@" > "$log" 2>&1 &
pid=$!

running() {
  [ -d "/proc/$pid" ] || return 1
  state=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f1)
  [ "$state" != "Z" ] && return 0
  [ "$(ls "/proc/$pid/task" 2>/dev/null | wc -l)" -gt 1 ]
}

t=0
while running && [ "$t" -lt "$limit" ]; do
  sleep 1
  t=$((t + 1))
done
if running; then
  echo "STALLED: still running after ${t} s" >> "$log"
  "$here/stall_capture.sh" "$pid" >> "$log" 2>&1
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  spinning=$(grep -c "parallel/scheduler.cr:97" "$log")
  if [ "$spinning" -ge 2 ] && ! grep -q "stop_world\|run_collection\|Gcry::Heap#collect" "$log"; then
    echo "STALL CLASSIFIED: Crystal Parallel-scheduler resume deadlock (upstream, not gcry)" >> "$log"
    exit 3
  fi
  exit 2
fi
wait "$pid" && exit 0
exit 1
