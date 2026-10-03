#!/bin/bash
set -e
cd bench/crystal_metric
rm -rf lib && mkdir -p lib/gcry && cp -r ../../src lib/gcry/src
crystal build --release main.cr -o ../../bin/boehm
crystal build -Dgc_none --release main.cr -o ../../bin/gcry
cd ../..
python3 - <<'PY'
import os, re, subprocess, statistics, sys
arms = [("boehm", "bin/boehm", {}), ("gcry", "bin/gcry", {}),
        ("gcry-keep", "bin/gcry", {"GCRY_KEEP_CHUNKS": "1"}),
        ("gcry-warm64", "bin/gcry", {"GCRY_EMPTY_CHUNK_WARM_RETAIN": "67108864"})]
for b in ("Binarytrees", "Knuckeotide", "Matmul"):
    res = {}
    for rep in range(5):
        for name, exe, env in arms:
            p = subprocess.Popen([exe, b], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env={**os.environ, **env})
            out = p.stdout.read().decode(errors="replace")
            _, st, ru = os.wait4(p.pid, 0)
            t = float(re.findall(rf"{b}:.*? in ([0-9.]+)s", out)[-1])
            rss = ru.ru_maxrss // (1024 if sys.platform == "darwin" else 1)
            res.setdefault(name, []).append((t, ru.ru_minflt, ru.ru_majflt, rss))
    for name, _, _ in arms:
        v = res[name]
        print(f"FAULTS {b} {name}: time {statistics.median(x[0] for x in v):.3f}s minflt {statistics.median(x[1] for x in v):.0f} majflt {statistics.median(x[2] for x in v):.0f} peak {statistics.median(x[3] for x in v)/1024:.1f}MiB")
PY
