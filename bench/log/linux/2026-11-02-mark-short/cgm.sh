#!/usr/bin/env bash
# cgm.sh VARIANT KIND N [EVICT_MIB]: callgrind (cache sim) of the micro $S/micro/mm-VARIANT, one marker,
# counting only inside the program's own `GC.collect` calls (the held graph, the same in every variant).
# Prints the collections, Σ scanned bytes and callgrind's totals. Run it under the heavy lock.
S=${MS_SCRATCH:-$PWD}
v=$1 kind=$2 n=$3 ev=${4:-0}
tag=$v-$kind-$n-$ev
rm -f $S/micro/tr-$tag.ndjson
env GCRY_COLLECT_SCRUB=0 GCRY_PARALLEL_MARK=1 GCRY_TRACE=1 GCRY_TRACE_FILE=$S/micro/tr-$tag.ndjson GCRY_TRACE_ALLOC_SAMPLE=0 \
  taskset -c 0-3 valgrind --tool=callgrind --cache-sim=yes --dump-instr=yes --collect-atstart=no \
  --toggle-collect='*GC::collect:Nil' \
  --callgrind-out-file=$S/micro/cg-$tag.out $S/micro/mm-$v $kind $n $ev > $S/micro/cg-$tag.log 2>&1
python3 - $S/micro/tr-$tag.ndjson "$(grep Collected $S/micro/cg-$tag.log)" "$tag" <<'PY'
import json,sys
rs=[json.loads(l) for l in open(sys.argv[1]) if '"collect_end"' in l]
print(sys.argv[3], len(rs), sum(d['scanned_bytes'] for d in rs), sys.argv[2].split(':',1)[1].strip())
PY
