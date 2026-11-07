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
#
# Windows (Git Bash): the harnesses are native processes, and Git Bash's `ps`
# has no `-o` and does not list a native process's native children. There the
# tree is read from Win32_Process by Windows process id, from the one the
# command's pid stands for (/proc/<pid>/winpid); the capture is cdb's
# (`stall_capture.sh`), and the kill is `taskkill /T` on that tree.
limit="$1"; log="$2"; shift 2; [ "$1" = "--" ] && shift
here="$(cd "$(dirname "$0")" && pwd)"
case $(uname -s) in MINGW* | MSYS* | CYGWIN*) windows=1 ;; *) windows=0 ;; esac

# Appended to, not truncated by the redirection: the stall lines and the
# capture below go to the same file while the command still holds it, and a
# wrapper that writes once its child is killed (Windows, where the kill takes
# a while) wrote at its own offset over them.
: > "$log"
"$@" >> "$log" 2>&1 &
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
# `pid ppid` for every process: from `ps` on Linux and macOS (both print it
# with these flags), from Win32_Process on Windows.
ptable() {
  if [ "$windows" = 1 ]; then
    powershell.exe -NoProfile -Command \
      'Get-CimInstance Win32_Process | ForEach-Object { "$($_.ProcessId) $($_.ParentProcessId)" }' 2>/dev/null | tr -d '\r'
  else
    ps -A -o pid= -o ppid= 2>/dev/null
  fi
}
# Every descendant of `$1`, depth first, from the one listing in `$table`.
descendants() {
  printf '%s\n' "$table" | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    function walk(p,   n, a, i) { n = split(kids[p], a, " "); for (i = 1; i <= n; i++) { print a[i]; walk(a[i]) } }
    END { walk(root) }'
}
# A process's command line, for the log.
command_of() {
  if [ "$windows" = 1 ]; then
    powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Process -Filter 'ProcessId=$1').CommandLine" 2>/dev/null | tr -d '\r' | cut -c1-200
  else
    ps -o command= -p "$1" 2>/dev/null | cut -c1-200
  fi
}

if running; then
  echo "STALLED: still running after ${t} s" >> "$log"
  # The root of the tree: on Windows the native process this pid stands for.
  root=$pid
  [ "$windows" = 1 ] && root=$(cat "/proc/$pid/winpid" 2>/dev/null || echo "$pid")
  table=$(ptable)
  tree=$(descendants "$root")
  # The leaves: the processes doing the work, not the wrappers waiting on
  # them. With no descendants the command itself is the leaf.
  leaves=""
  for p in $tree; do
    [ -z "$(descendants "$p")" ] && leaves="$leaves $p"
  done
  [ -z "$leaves" ] && leaves=$root
  for p in $leaves; do
    [ "$p" != "$root" ] && echo "--- descendant $p: $(command_of "$p")" >> "$log"
    "$here/stall_capture.sh" "$p" >> "$log" 2>&1
  done
  # Leaves first, so no wrapper respawns or reports on a half-killed tree. On
  # Windows `taskkill /T` takes the whole tree in one call, and a process
  # whose parent exited before the walk is not in it, so the leaves after.
  if [ "$windows" = 1 ]; then
    taskkill //F //T //PID "$root" > /dev/null 2>&1
    for p in $leaves; do taskkill //F //PID "$p" > /dev/null 2>&1; done
  else
    for p in $leaves $tree; do kill -9 "$p" 2>/dev/null; done
  fi
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  # gdb names the line; macOS `sample` names the method and not the line; cdb
  # names both, the line as `parallel\scheduler.cr @ 97`.
  spinning=$(grep -c 'parallel/scheduler.cr:97\|parallel\\scheduler.cr @ 97\|Parallel::Scheduler#resume' "$log")
  if [ "$spinning" -ge 2 ] && ! grep -q "stop_world\|run_collection\|Gcry::Heap#collect" "$log"; then
    echo "STALL CLASSIFIED: Crystal Parallel-scheduler resume deadlock (upstream, not gcry)" >> "$log"
    exit 3
  fi
  exit 2
fi
wait "$pid" && exit 0
exit 1
