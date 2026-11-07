#!/usr/bin/env bash
# session.sh NAME REPS BENCHES ARM...: one ab.py session under the heavy lock, load sampled.
S=/home/naruto/playground/.scratch/RevcompHost
name=$1; shift
mkdir -p $S/sess/$name
cd $S
flock /home/naruto/playground/.scratch/heavy.lock bash -c '
  ( while :; do echo "$(date +%T) $(cut -d" " -f1-3 /proc/loadavg)"; sleep 30; done ) > sess/'$name'/load.txt & lp=$!
  trap "kill $lp" EXIT
  python3 ab.py sess/'$name' "$@" > sess/'$name'/summary.md 2> sess/'$name'/progress.log
' _ "$@"
cat sess/$name/summary.md
