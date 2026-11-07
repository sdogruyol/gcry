#!/usr/bin/env bash
# buildall.sh SPEC...: SPEC = rev:name[:prepad[:counters]]; each build is one hold of the heavy lock.
S=/home/naruto/playground/.scratch/RevcompHost
export TMPDIR=$S/tmp
for spec in "$@"; do
  IFS=: read -r rev name pad cnt <<<"$spec"
  [ -x "$S/bins/$name" ] && { echo "have $name"; continue; }
  t0=$(date +%s)
  flock /home/naruto/playground/.scratch/heavy.lock "$S/build.sh" "$rev" "$name" "${pad:-0}" "${cnt:-0}" > "$S/logs/build-$name.log" 2>&1 && echo "built $name $(( $(date +%s)-t0 ))s" || echo "FAIL $name"
done
