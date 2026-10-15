#!/usr/bin/env bash
# GC counters (stats-<build> wrapper, 3 runs each) and syscall counts
# (strace -c -f on the timing binary, 1 run each) for Revcomp per build.
set -uo pipefail
S=/home/naruto/playground/.scratch/RevcompCounters
L=/home/naruto/playground/.scratch/heavy.lock
mkdir -p $S/stats
cd $S
for r in 1 2 3; do
  for b in v0.35.0 6dc6e7d0 b1cdc0ed 48e7c749 v0.36.0; do
    flock $L bin/stats-$b Revcomp > $S/stats/$b-$r.log 2>&1
  done
done
for b in v0.35.0 6dc6e7d0 b1cdc0ed 48e7c749 v0.36.0; do
  flock $L strace -f -c -o $S/stats/strace-$b.txt bin/cm-$b Revcomp > /dev/null 2>&1
done
echo STATS_DONE
