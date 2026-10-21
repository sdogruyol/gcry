#!/usr/bin/env bash
# After the overnight stress: a second, quieter crystal-metric and Kemal
# session (same 8b9e7eab binaries), then the in-stop claim arm on the fixed
# tree (release-0.38.0 tip). Each phase holds the heavy lock.
set -u
G=/home/naruto/playground/gcry
L=/home/naruto/playground/.scratch/heavy.lock
K=/home/naruto/playground/.scratch/kemal3
B=/home/naruto/playground/.scratch/cmbin3
O=/home/naruto/playground/.scratch/night038
F=/home/naruto/playground/.scratch/fix-src
BENCHES=Primes,JsonParsePure,Binarytrees,JsonGenerate,JsonParseSerializable,JsonParsePull,RegexDna,Revcomp,Knuckeotide,Brainfuck
echo "$(date -u +%FT%TZ) cm2 start"
flock "$L" python3 "$G/bench/log/linux/2026-10-14-rss-budget-recheck/ab.py" "$O/cm2" 11 "$BENCHES" \
  boehm="$B/cm-boehm" v037="$B/cm-v037" v038="$B/cm-tip" > "$O/cm2.md" 2> "$O/cm2.err"
echo "$(date -u +%FT%TZ) kemal2 start"
bash "$G/bench/log/linux/2026-10-18-0.37-kemal/kemal_ab.sh" "$O/kemal2" 9 \
  boehm="$K/kemal-boehm" v037="$K/kemal-v037" v038="$K/kemal-tip" > "$O/kemal2-summary.txt" 2> "$O/kemal2.err"
echo "$(date -u +%FT%TZ) fixed-tree claim start"
cd "$F" && mkdir -p bin && crystal build -Dgc_none --release bench/claim_stress.cr -o bin/claim_stress
S=$O/fixclaim; mkdir -p "$S"; p=0; f=0; u=0; s=0
for seed in $(seq 2001 2300); do
  log=$S/instop-$seed.log
  flock "$L" env GCRY_DISABLE_LAZY_SWEEP=1 GCRY_SEGV_REPORT=1 bench/run_bounded.sh 60 "$log" -- \
    bin/claim_stress --seconds=5 --workers=4 --seed=$seed > /dev/null 2>&1
  case $? in 0) p=$((p+1)); rm -f "$log";; 3) u=$((u+1));; 2) s=$((s+1));; *) f=$((f+1));; esac
done
echo "$(date -u +%FT%TZ) fixed-tree claim-instop: runs=300 pass=$p fail=$f stall=$s upstream_deadlock=$u" | tee "$S/summary.txt"
echo "$(date -u +%FT%TZ) night2 done"
