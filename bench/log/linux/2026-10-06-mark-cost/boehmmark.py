#!/usr/bin/env python3
"""boehmmark.py TRIALS BENCHES BIN [GC_MARKERS] — Σ 'World-stopped marking took' per run."""
import sys, os, subprocess, re, statistics
trials, benches, bin_ = int(sys.argv[1]), sys.argv[2].split(','), sys.argv[3]
markers = sys.argv[4] if len(sys.argv) > 4 else "1"
pat = re.compile(r"World-stopped marking took (\d+) ms (\d+) ns")
wall = re.compile(r"in\s+([0-9.]+)s")
for b in benches:
    ms, ws = [], []
    for _ in range(trials):
        e = dict(os.environ); e.update({"GC_MARKERS": markers, "GC_PRINT_STATS": "1"})
        p = subprocess.run([bin_, b], capture_output=True, text=True, env=e)
        tot = sum(int(a) + int(n) / 1e6 for a, n in pat.findall(p.stderr + p.stdout))
        ms.append(tot)
        m = wall.search(p.stdout); ws.append(float(m.group(1)) if m else -1)
    print(f"{b:22} boehm markers={markers} mark {statistics.median(ms):8.2f} ({min(ms):.1f}-{max(ms):.1f})  wall {statistics.median(ws):.3f}")
