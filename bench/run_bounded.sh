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
# (`bench/log/linux/2026-09-25-parallel-scheduler-deadlock/`, upstream
# crystal-lang/crystal#17486), so a sampler
# reports it without counting it against gcry.
#
# The command may be a wrapper — `make <gate>`, `bash -c`, `env`, `crystal
# spec` — whose stalled process is a descendant. The capture then goes to the
# leaves of the command's process tree (every descendant with no child of its
# own), not to the wrapper, and the kill takes the whole tree: killing only the
# wrapper left the harness running on, holding a CPU and the lock's slot, and
# its stall uncaptured (the 0.38.0 overnight header-layout hang,
# `bench/log/linux/2026-10-21-0.38-stress/`).
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

# macOS has no /proc: there `kill -0` is the test, and a zombie is reaped by
# the `wait` below rather than mistaken for a live child.
running() {
  if [ ! -d /proc ]; then
    kill -0 "$pid" 2>/dev/null || return 1
    [ "$(ps -o stat= -p "$pid" 2>/dev/null | cut -c1)" != "Z" ]
    return
  fi
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
# Every descendant of `$1`, depth first, from one `ps` listing (Linux and
# macOS both print `pid ppid` with these flags).
descendants() {
  ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    function walk(p,   n, a, i) { n = split(kids[p], a, " "); for (i = 1; i <= n; i++) { print a[i]; walk(a[i]) } }
    END { walk(root) }'
}

if running; then
  echo "STALLED: still running after ${t} s" >> "$log"
  tree=$(descendants "$pid")
  # The leaves: the processes doing the work, not the wrappers waiting on
  # them. With no descendants the command itself is the leaf.
  leaves=""
  for p in $tree; do
    [ -z "$(descendants "$p")" ] && leaves="$leaves $p"
  done
  [ -z "$leaves" ] && leaves=$pid
  for p in $leaves; do
    [ "$p" != "$pid" ] && echo "--- descendant $p: $(ps -o command= -p "$p" 2>/dev/null | cut -c1-200)" >> "$log"
    "$here/stall_capture.sh" "$p" >> "$log" 2>&1
  done
  # Leaves first, so no wrapper respawns or reports on a half-killed tree.
  for p in $leaves $tree; do kill -9 "$p" 2>/dev/null; done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # gdb names the line; macOS `sample` names the method and not the line.
  spinning=$(grep -c "parallel/scheduler.cr:97\|Parallel::Scheduler#resume" "$log")
  if [ "$spinning" -ge 2 ] && ! grep -q "stop_world\|run_collection\|Gcry::Heap#collect" "$log"; then
    echo "STALL CLASSIFIED: Crystal Parallel-scheduler resume deadlock (upstream, not gcry)" >> "$log"
    exit 3
  fi
  exit 2
fi
wait "$pid" && exit 0
exit 1
