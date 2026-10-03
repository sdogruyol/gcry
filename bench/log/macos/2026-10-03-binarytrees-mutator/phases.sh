#!/bin/bash
set -e
cd bench/crystal_metric
rm -rf lib && mkdir -p lib/gcry && cp -r ../../src lib/gcry/src
crystal build --release main.cr -o ../../bin/boehm
crystal build -Dgc_none --release main.cr -o ../../bin/gcry
cd ../..
for b in Binarytrees Knuckeotide JsonParsePure; do
  for i in 1 2 3; do
    echo "BOEHM $b $(bin/boehm $b 2>&1 | grep -oE 'in [0-9.]+s' | tail -1)"
    GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE=/tmp/t.ndjson bin/gcry $b > /tmp/o.txt 2>&1
    echo "GCRY $b $(grep -oE 'in [0-9.]+s' /tmp/o.txt | tail -1)"
    python3 - "$b" <<'PY'
import json, statistics, sys
rows=[json.loads(l) for l in open('/tmp/t.ndjson') if '"collect_end"' in l]
keys=[k for k in rows[0] if k.endswith('_ns') and k!='ts_ns']
tot={k: sum(r[k] for r in rows)/1e6 for k in keys}
med={k: statistics.median(r[k] for r in rows)/1e3 for k in keys}
print(f"PHASES {sys.argv[1]} n={len(rows)} " + " ".join(f"{k[:-3]}={tot[k]:.0f}ms/{med[k]:.0f}us" for k in sorted(keys, key=lambda k:-tot[k])))
PY
  done
done
