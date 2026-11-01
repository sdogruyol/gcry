#!/usr/bin/env bash
S=/home/naruto/playground/.scratch/LargeCacheIncr
L=/home/naruto/playground/.scratch/heavy.lock
out=$S/incr-runs.txt; : > $out
for i in 1 2 3; do
  for b in Primes JsonParsePure Binarytrees JsonGenerate JsonParseSerializable JsonParsePull Revcomp RegexDna Knuckeotide; do
    for a in base var; do
      line=$(flock $L env GCRY_INCREMENTAL=1 /usr/bin/time -f "MAXRSS_KB=%M WALL=%e" $S/bin/$a-c $b 2>&1 | grep -E "^($b:|GCSTATS|MAXRSS)" | tr '\n' ' ')
      echo "$a $b $i $line" >> $out
    done
  done
done
echo done >> $out
