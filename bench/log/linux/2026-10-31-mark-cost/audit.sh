#!/usr/bin/env bash
# audit.sh <bin>: every crystal-metric bench under GCRY_MARK_AUDIT=1, one marker and default, CPUs 0-3, each run bounded.
ALL="Pidigits Binarytrees Brainfuck Brainfuck2 Fannkuchredux Fasta Knuckeotide Mandelbrot Matmul Nbody RegexDna Revcomp Spectralnorm Threadring Base64Encode Base64Decode Primes JsonGenerate JsonParsePure JsonParseSerializable JsonParsePull Mandelbrot2 Noise Sudoku TextRaytracer NeuralNet"
rb=bench/run_bounded.sh
mkdir -p ms/audit
for b in $ALL; do
  for mode in serial default; do
    env=(GCRY_MARK_AUDIT=1); [ $mode = serial ] && env+=(GCRY_PARALLEL_MARK=1)
    f=ms/audit/$b-$mode.log
    env "${env[@]}" "$rb" 600 "$f" -- taskset -c 0-3 "$1" "$b"; rc=$?
    echo "$b $mode rc=$rc $(grep -E 'AUDIT|dying audit' "$f" | head -3 | tr '\n' ' ')"
  done
done
