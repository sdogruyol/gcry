#!/usr/bin/env bash
# livescan.sh BIN: per crystal-metric bench, collections and the live bytes the
# parallel-mark floor sees (size_class_live_bytes at collect_end; large bytes
# not in the trace) — how many collections fall in each floor band.
for b in Pidigits Binarytrees Brainfuck Brainfuck2 Fannkuchredux Fasta Knuckeotide Mandelbrot Matmul Nbody RegexDna Revcomp Spectralnorm Threadring Base64Encode Base64Decode Primes JsonGenerate JsonParsePure JsonParseSerializable JsonParsePull Mandelbrot2 Noise Sudoku TextRaytracer NeuralNet; do
  f=ms/live-$b.ndjson; rm -f $f
  GCRY_TRACE=1 GCRY_TRACE_FILE=$f GCRY_TRACE_ALLOC_SAMPLE=0 bench/run_bounded.sh 120 ms/stall-$b.log -- taskset -c 0-3 $1 $b >/dev/null 2>&1
  python3 - "$b" "$f" <<'P'
import json, sys
b, f = sys.argv[1:]
ev=[json.loads(l) for l in open(f) if '"collect_end"' in l]
bands=[0,0,0,0]  # <4, 4-8, 8-16, 16-32, >=32 MiB
cnt={"<4":0,"4-8":0,"8-16":0,"16-32":0,">=32":0}; mk={k:0.0 for k in cnt}
for e in ev:
    m=e["size_class_live_bytes"]/2**20
    k="<4" if m<4 else "4-8" if m<8 else "8-16" if m<16 else "16-32" if m<32 else ">=32"
    cnt[k]+=1; mk[k]+=e["mark_ns"]/1e6
print(f"{b:22} gcs {len(ev):4} " + " ".join(f"{k}:{cnt[k]}/{mk[k]:.1f}ms" for k in cnt))
P
done
