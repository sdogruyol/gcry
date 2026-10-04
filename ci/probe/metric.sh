#!/bin/bash
set -e
cd bench/crystal_metric
rm -rf lib && mkdir -p lib/gcry && cp -r ../../src lib/gcry/src
crystal build -Dgc_none --release main.cr -o ../../bin/gcry
cd ../..
python3 - <<'PY'
import json, os, random, re, statistics, subprocess
benches = ["Primes", "JsonParsePure", "Binarytrees", "JsonGenerate"]
arms = [("pm1", {}), ("pm4", {"GCRY_PARALLEL_MARK": "4"}), ("pm4min", {"GCRY_PARALLEL_MARK": "4", "GCRY_PARALLEL_MARK_MIN_LIVE": "33554432"})]
res = {}
for rep in range(6):
    for b in benches:
        order = arms[:]; random.shuffle(order)
        for name, env in order:
            e = {**os.environ, **env, "GCRY_TRACE": "1", "GCRY_TRACE_ALLOC_SAMPLE": "0", "GCRY_TRACE_FILE": "/tmp/pm.ndjson"}
            out = subprocess.run(["bin/gcry", b], env=e, capture_output=True, text=True).stdout
            t = float(re.findall(rf"{b}:.*? in ([0-9.]+)s", out)[-1])
            m = sum(json.loads(l)["mark_ns"] for l in open("/tmp/pm.ndjson") if '"collect_end"' in l) / 1e6
            res.setdefault((b, name), []).append((m, t))
for b in benches:
    base = statistics.median(x[0] for x in res[(b, "pm1")])
    print(f"ML {b}: " + "  ".join(f"{n} mark {statistics.median(x[0] for x in res[(b, n)]):.0f}ms ({statistics.median(x[0] for x in res[(b, n)]) / base - 1:+.0%}) time {statistics.median(x[1] for x in res[(b, n)]):.3f}s" for n, _ in arms))
PY
