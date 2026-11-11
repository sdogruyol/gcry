#!/bin/sh
# loop.sh <spec binary> <runs> <log>: runs the whole spec binary (every arm in
# a process of its own) <runs> times; prints passes, failures, and keeps each
# failing run's output in <log>.
bin=$1; n=$2; log=$3; ok=0; bad=0; : > "$log"
i=0
while [ $i -lt "$n" ]; do
  i=$((i + 1))
  out=$("$bin" 2>&1)
  if [ $? -eq 0 ] && printf '%s' "$out" | grep -q ' 0 failures, 0 errors'; then
    ok=$((ok + 1))
  else
    bad=$((bad + 1)); printf '=== run %s\n%s\n' "$i" "$out" >> "$log"
  fi
done
echo "$(basename "$bin") runs=$n pass=$ok fail=$bad"
