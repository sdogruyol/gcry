#!/usr/bin/env bash
# audit.sh <bin>: every crystal-metric bench under GCRY_MARK_AUDIT=1, one marker and default, CPUs 0-3.
ALL="Pidigits Binarytrees Brainfuck Brainfuck2 Fannkuchredux Fasta Knuckeotide Mandelbrot Matmul Nbody RegexDna Revcomp Spectralnorm Threadring Base64Encode Base64Decode Primes JsonGenerate JsonParsePure JsonParseSerializable JsonParsePull Mandelbrot2 Noise Sudoku TextRaytracer NeuralNet"
for b in $ALL; do
  echo "$b serial $(GCRY_MARK_AUDIT=1 GCRY_PARALLEL_MARK=1 taskset -c 0-3 timeout 600 $1 $b 2>&1 >/dev/null | grep -E 'AUDIT|dying audit' | head -3)"
  echo "$b default $(GCRY_MARK_AUDIT=1 taskset -c 0-3 timeout 600 $1 $b 2>&1 >/dev/null | grep -E 'AUDIT|dying audit' | head -3)"
done
