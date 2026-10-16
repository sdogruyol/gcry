#!/usr/bin/env bash
# Session 3: the kept commit against its base, and the bitmap interleave on
# top of it, in one interleave.
#
#   base    release-0.37.0 at 4fcee559
#   kept    50b1315e (this log's commit), from `git archive`
#   keptil  kept + measured-bitmap-interleave.patch
#
# First every crystal-metric bench once per arm, unpinned, to compare the
# benches' own result lines (the interleave rewrites every bitmap reader).
# Then 7 interleaved trials pinned to CPUs 0-3 with one marker, the default
# (two workers) and four, and 7 unpinned with the default (four workers).
set -x
S=/home/naruto/playground/.scratch/ParallelMarkBatch
L=$S/log
LOCK=/home/naruto/playground/.scratch/heavy.lock
cd $S
[[ -n ${SKIP_BUILD:-} ]] || flock $LOCK bash -c "for a in base kept keptil; do $L/build.sh \$a || exit 1; done"
ALL="Pidigits Binarytrees Brainfuck Brainfuck2 Fannkuchredux Fasta Knuckeotide Mandelbrot Matmul Nbody RegexDna Revcomp Spectralnorm Threadring Base64Encode Base64Decode Primes JsonGenerate JsonParsePure JsonParseSerializable JsonParsePull Mandelbrot2 Noise Sudoku TextRaytracer NeuralNet"
flock $LOCK bash -c "for b in $ALL; do for a in base kept keptil; do
  out=\$(bin/cm-\$a \$b 2>&1); rc=\$?
  echo \"\$b \$a exit=\$rc \$(echo \"\$out\" | grep -E '^\w+: (ok|err)' | sed -E 's/ in [0-9.]+s.*//')\"
done; done" > logs/s3-results.txt 2>&1
SKIP_BUILD=1 $L/session.sh s3 7 1,d,4 d base kept keptil
echo done
