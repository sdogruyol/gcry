#!/usr/bin/env bash
# survey.sh BIN: per bench, collections, median/min/max scanned bytes per collection and Σ mark of
# crystal-metric $S/bin/BIN. Run it under the heavy lock.
S=${MS_SCRATCH:-$PWD}
for b in Pidigits Binarytrees Brainfuck Brainfuck2 Fannkuchredux Fasta Knuckeotide Mandelbrot Matmul Nbody RegexDna Revcomp Spectralnorm Threadring Base64Encode Base64Decode Primes JsonGenerate JsonParsePure JsonParseSerializable JsonParsePull Mandelbrot2 Noise Sudoku TextRaytracer NeuralNet; do
  rm -f $S/ms/sv.ndjson
  GCRY_TRACE=1 GCRY_TRACE_FILE=$S/ms/sv.ndjson GCRY_TRACE_ALLOC_SAMPLE=0 taskset -c 0-3 $S/bin/$1 $b >/dev/null 2>&1
  python3 - "$b" <<'PY'
import json,sys,statistics
rs=[json.loads(l) for l in open(__import__('os').environ.get('MS_SCRATCH','.')+'/ms/sv.ndjson') if '"collect_end"' in l]
sc=[d['scanned_bytes'] for d in rs] or [0]
print(f"{sys.argv[1]:22} gcs {len(rs):4} scanned/gc med {statistics.median(sc)/1024:10.0f} KiB min {min(sc)/1024:8.0f} max {max(sc)/1024:9.0f} mark {sum(d['mark_ns'] for d in rs)/1e6:8.3f} ms")
PY
done
