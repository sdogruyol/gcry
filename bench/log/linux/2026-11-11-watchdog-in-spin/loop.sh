#!/usr/bin/env bash
# Interleaved loop of the gate's in-spin arm (the child, with the arm's env)
# over several builds. One line per run:
#   <label> <run> <fired 0|1> rc=<rc> <probe line or noprobe> <dropped/resends or nocounts>
# usage: loop.sh <runs> <outfile> <label>=<binary>[:fix] ...
#   :fix runs the fixed arm's env (one dropped suspend, resend spins 200000);
#   without it, the arm as CI ran it (threshold at one spin only).
set -u
runs=$1; out=$2; shift 2
: > "$out"
for ((i = 1; i <= runs; i++)); do
  for spec in "$@"; do
    label=${spec%%=*}; rest=${spec#*=}
    bin=${rest%%:*}
    env=(GCRY_STW_WATCHDOG_MS=200 GCRY_SUSPEND_STALL_SPINS=1)
    [[ $rest == *:fix ]] && env+=(GCRY_STW_TEST_DROP_SUSPENDS=1 GCRY_STW_RESEND_SPINS=200000)
    err=$(env "${env[@]}" "$bin" --child 2>&1 >/dev/null)
    rc=$?
    fired=0
    [[ $err == *"SUSPEND STALLED on thread 0x"* && $err == *"the handle is live"* ]] && fired=1
    probe=$(printf '%s\n' "$err" | grep -m1 '^gcry-probe:' || true)
    counts=$(printf '%s\n' "$err" | grep -m1 '^dropped=' || true)
    echo "$label $i $fired rc=$rc ${probe:-noprobe} ${counts:-nocounts}" >> "$out"
  done
done
