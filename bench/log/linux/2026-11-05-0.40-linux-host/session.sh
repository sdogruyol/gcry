#!/usr/bin/env bash
# session.sh: the 0.39 "clean session" method on the 0.40 tip. crystal-metric
# (11 reps, ten benches, seven arms) under one hold of the heavy lock, then Kemal
# (9 trials, kemal_ab.sh, which takes the lock per run). Load sampled every 30 s;
# uptime + top snapshot at start, between and end.
set -u
S=/home/naruto/playground/.scratch/Numbers2
WT=$S/wt
B=$S/bins
o=$S/sess
mkdir -p $o
snap() { { echo "== $1 $(date -u +%T)"; uptime; top -bn1 -o %CPU | sed -n '7,17p'; } >> $o/load-snapshots.txt; }
( while :; do echo "$(date -u +%T) $(cut -d' ' -f1-3 /proc/loadavg)"; sleep 30; done ) > $o/load.txt &
lp=$!
trap 'kill $lp' EXIT
snap start
flock /home/naruto/playground/.scratch/heavy.lock python3 $WT/bench/log/linux/2026-10-31-revcomp-host-placement/scripts/ab.py $o/cm 11 \
  Primes,JsonParsePure,Binarytrees,JsonGenerate,JsonParseSerializable,JsonParsePull,RegexDna,Revcomp,Knuckeotide,Brainfuck \
  boehm=$B/boehm v039=$B/v039 v040=$B/v040 v039p16=$B/v039p16 v039p64=$B/v039p64 v040p16=$B/v040p16 v040p64=$B/v040p64 \
  > $o/cm.md 2> $o/cm-progress.log
snap after-cm
bash $WT/bench/log/linux/2026-10-18-0.37-kemal/kemal_ab.sh $o/kemal 9 v039=$B/kv039 v040=$B/kv040 boehm=$B/kboehm \
  > $o/kemal-summary.txt 2> $o/kemal-progress.log
snap end
