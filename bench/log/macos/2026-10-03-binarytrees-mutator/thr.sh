#!/bin/bash
set -e
cd bench/crystal_metric
rm -rf lib && mkdir -p lib/gcry && cp -r ../../src lib/gcry/src
crystal build --release main.cr -o ../../bin/boehm
crystal build -Dgc_none --release main.cr -o ../../bin/gcry
cd ../..
python3 - <<'PY'
import json, os, re, subprocess, statistics
arms = [("boehm", "bin/boehm", {}), ("gcry", "bin/gcry", {}),
        ("chunk128k", "bin/gcry", {"GCRY_CHUNK_BYTES": "131072"}),
        ("idle0", "bin/gcry", {"GCRY_IDLE_RELEASE_MS": "0"}),
        ("multi", "bin/gcry", {"GCRY_SINGLE_MUTATOR": "0"}),
        ("nofast", "bin/gcry", {"GCRY_ALLOC_FAST_PATH": "0"})]
res = {}
for rep in range(5):
    for name, exe, env in arms:
        e = {**os.environ, **env}
        if name != "boehm":
            e.update({"GCRY_TRACE": "1", "GCRY_TRACE_ALLOC_SAMPLE": "0", "GCRY_TRACE_FILE": "/tmp/t.ndjson"})
        p = subprocess.Popen([exe, "Binarytrees"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e)
        out = p.stdout.read().decode(errors="replace")
        _, st, ru = os.wait4(p.pid, 0)
        t = float(re.findall(r"Binarytrees:.*? in ([0-9.]+)s", out)[-1])
        n = pause = 0
        if name != "boehm":
            rows = [json.loads(l) for l in open("/tmp/t.ndjson") if '"collect_end"' in l]
            n = len(rows); pause = sum(r["pause_ns"] for r in rows) / 1e6
        res.setdefault(name, []).append((t, n, pause, ru.ru_maxrss))
for name, _, _ in arms:
    v = res[name]
    t = statistics.median(x[0] for x in v); p = statistics.median(x[2] for x in v)
    print(f"THR {name}: time {t:.3f}s majors {statistics.median(x[1] for x in v):.0f} pause {p:.0f}ms mutator {t - p/1000:.3f}s")
PY
