#!/usr/bin/env bash
# gf_only.sh BIN BENCH REPS ONLY-regex TAG
bin=$1; b=$2; reps=$3; only=$4; tag=$5
for r in $(seq 1 $reps); do
  for m in ctl hide; do
    out=raw/gf/$tag-$b-$m-$r
    ONLY="$only" VERBOSE=1 BENCH=$b BIN=$bin MODE=$m LOG=$out.txt OUT=$out.out ENVS="GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE=$out.ndjson" timeout 250 gdb -q -batch -x gcry_frames.py >/dev/null 2>&1
    echo "$tag $b $m $r $(tail -1 $out.txt) $(head -1 $out.out | cut -c1-40)"
  done
done
