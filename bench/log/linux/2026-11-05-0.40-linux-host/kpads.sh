#!/usr/bin/env bash
# kpads.sh: Kemal with 16- and 64-byte pad arms of both trees (9 trials, kemal_ab.sh,
# the lock per run), after the main session read /json 0.40 against 0.39.0 slower.
set -u
S=/home/naruto/playground/.scratch/Numbers2
B=$S/bins o=$S/sess
b=$S/scripts/build.sh
flock /home/naruto/playground/.scratch/heavy.lock bash -c "set -e; bash $b kemal v0.39.0 kv039p16 16; bash $b kemal v0.39.0 kv039p64 64; bash $b kemal HEAD kv040p16 16; bash $b kemal HEAD kv040p64 64" >> $S/build.log 2>&1 || exit 1
( while :; do echo "$(date -u +%T) $(cut -d' ' -f1-3 /proc/loadavg)"; sleep 30; done ) > $o/load-kpads.txt &
lp=$!
trap 'kill $lp' EXIT
bash $S/wt/bench/log/linux/2026-10-18-0.37-kemal/kemal_ab.sh $o/kpads 9 \
  v039=$B/kv039 v040=$B/kv040 boehm=$B/kboehm v039p16=$B/kv039p16 v039p64=$B/kv039p64 v040p16=$B/kv040p16 v040p64=$B/kv040p64 \
  > $o/kpads-summary.txt 2> $o/kpads-progress.log
