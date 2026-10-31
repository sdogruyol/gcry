#!/usr/bin/env bash
# Say what a stalled process is doing, before whoever called this kills it.
#
#   bench/stall_capture.sh <pid>
#
# Every thread's name, state and wait channel from /proc, then a backtrace of
# all threads from gdb, attached through a thread that is still alive: a
# process whose main thread has exited while others run on shows its leader as
# a zombie, and attaching to that pid fails. gdb needs ptrace permission —
# `kernel.yama.ptrace_scope=0`, or a target that declared itself traceable
# (`stw_mt_property_test` does, on Linux); without it the /proc half still
# prints. Linux; macOS and Windows below.
pid="$1"
# Windows (Git Bash): `<pid>` is a Windows process id (`run_bounded.sh` walks
# the Win32 process tree), and Git Bash's /proc does not describe native
# processes. cdb, from the SDK's Debugging Tools that the GitHub Windows
# images carry, attaches noninvasively (`-pv`: the threads are suspended and
# read, no debug port taken) and prints every thread's stack with the names and
# lines of the PDB the compiler wrote next to the executable. CDB overrides
# where it is looked for.
case $(uname -s) in
  MINGW* | MSYS* | CYGWIN*)
    arch=x64
    case ${PROCESSOR_ARCHITECTURE:-} in ARM64) arch=arm64 ;; esac
    cdb=${CDB:-"/c/Program Files (x86)/Windows Kits/10/Debuggers/$arch/cdb.exe"}
    if [ -x "$cdb" ]; then
      echo "--- stall capture: windows pid $pid (cdb, noninvasive)"
      timeout 120 "$cdb" -p "$pid" -pv -lines -c ".lines -e; ~*k 40; qd" 2>&1 | tail -n 3000
    else
      echo "--- no cdb backtrace (no $cdb)"
    fi
    exit 0
    ;;
esac
# macOS: no /proc and no gdb, but `sample` reads every thread's stack of a
# process the same user owns, without attaching a debugger.
if [ ! -d /proc ]; then
  kill -0 "$pid" 2>/dev/null || { echo "stall_capture: no process $pid"; exit 0; }
  echo "--- stall capture: pid $pid (macOS sample, 2 s)"
  out="${TMPDIR:-/tmp}/stall-sample-$pid.txt"
  sample "$pid" 2 -mayDie -file "$out" >/dev/null 2>&1
  cat "$out" 2>/dev/null | head -n 3000
  rm -f "$out"
  exit 0
fi
[ -n "$pid" ] && [ -d "/proc/$pid" ] || { echo "stall_capture: no process $pid"; exit 0; }
echo "--- stall capture: pid $pid, $(ls /proc/$pid/task | wc -l) thread(s)"
live=""
for tk in /proc/$pid/task/*; do
  tid=$(basename "$tk")
  state=$(sed 's/.*) //' "$tk/stat" 2>/dev/null | cut -d' ' -f1)
  echo "task $tid $(cat "$tk/comm" 2>/dev/null) state=$state wchan=$(cat "$tk/wchan" 2>/dev/null)"
  [ -z "$live" ] && [ "$state" != "Z" ] && live=$tid
done
if command -v gdb >/dev/null 2>&1 && [ -n "$live" ]; then
  echo "--- gdb, attached through task $live"
  timeout 120 gdb -q -batch -p "$live" -ex "set pagination off" -ex "info threads" \
    -ex "thread apply all bt 40" 2>&1 | tail -n 3000
  # And the innermost frames' arguments and locals: a scheduler spinning in
  # `resume` is waiting on a particular fiber, and which one — another thread's
  # current fiber, itself mid-switch — is what separates a scheduler deadlock
  # from anything the collector did (2026-09-25).
  echo "--- innermost frames with arguments and locals"
  timeout 120 gdb -q -batch -p "$live" -ex "set pagination off" \
    -ex "thread apply all bt full 8" 2>&1 | tail -n 3000
else
  echo "--- no gdb backtrace (gdb missing or no live task)"
fi
