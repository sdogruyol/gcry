#!/usr/bin/env bash
# gf_sweep.sh BIN TAG REPS BENCH...
bin=$1; tag=$2; reps=$3; shift 3
for r in $(seq 1 $reps); do
for b in "$@"; do
  for m in ctl hide; do
    out=raw/gf/$tag-$b-$m-$r
    BENCH=$b BIN=$bin MODE=$m LOG=$out.txt ENVS="GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE=$out.ndjson" timeout 250 gdb -q -batch -x gcry_frames.py >/dev/null 2>&1
    echo "$tag $b $m $r $(tail -1 $out.txt)"
  done
done
done
