#!/usr/bin/env bash
# Night of 2026-10-20: Linux crystal-metric and Kemal (Boehm / 0.37.0 / 0.38),
# then the overnight stress of release-0.38.0. Each phase holds the heavy lock.
set -u
G=/home/naruto/playground/gcry
L=/home/naruto/playground/.scratch/heavy.lock
K=/home/naruto/playground/.scratch/kemal3
B=/home/naruto/playground/.scratch/cmbin3
O=/home/naruto/playground/.scratch/night038
mkdir -p "$O"
BENCHES=Primes,JsonParsePure,Binarytrees,JsonGenerate,JsonParseSerializable,JsonParsePull,RegexDna,Revcomp,Knuckeotide,Brainfuck
echo "$(date -u +%FT%TZ) cm start"
flock "$L" python3 "$G/bench/log/linux/2026-10-14-rss-budget-recheck/ab.py" "$O/cm" 11 "$BENCHES" \
  boehm="$B/cm-boehm" v037="$B/cm-v037" v038="$B/cm-tip" > "$O/cm.md" 2> "$O/cm.err"
echo "$(date -u +%FT%TZ) kemal start"
bash "$G/bench/log/linux/2026-10-18-0.37-kemal/kemal_ab.sh" "$O/kemal" 9 \
  boehm="$K/kemal-boehm" v037="$K/kemal-v037" v038="$K/kemal-tip" > "$O/kemal-summary.txt" 2> "$O/kemal.err"
echo "$(date -u +%FT%TZ) stress start"
flock "$L" bash /home/naruto/playground/.scratch/stress038/stress038.sh "$K/tip-src" "$O/stress"
echo "$(date -u +%FT%TZ) night done"
