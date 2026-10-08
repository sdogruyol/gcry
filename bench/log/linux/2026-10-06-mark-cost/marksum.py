#!/usr/bin/env python3
"""marksum.py TRIALS BENCHES arm=bin[:ENV=V,...] ...
Interleaved, process-fresh; per run sums trace mark_ns / pause_ns over all
collections. Prints medians (min/max) of Σmark ms, Σpause ms, wall s."""
import sys, os, subprocess, json, random, statistics, re, tempfile
trials, benches = int(sys.argv[1]), sys.argv[2].split(',')
arms = []
for a in sys.argv[3:]:
    name, rest = a.split('=', 1)
    parts = rest.split(':', 1)
    env = {}
    if len(parts) > 1 and parts[1]:
        for kv in parts[1].split(','):
            k, v = kv.split('=', 1); env[k] = v
    arms.append((name, parts[0], env))
scratch = os.path.expanduser('~/.cache/gcry-work/MarkCost/ms')
os.makedirs(scratch, exist_ok=True)
line_re = re.compile(r"^(\w+):\s+(ok|err).*?\bin\s+([0-9.]+)s", re.M)
res = {}
for t in range(trials):
    for b in benches:
        order = arms[:]; random.shuffle(order)
        for name, bin_, env in order:
            tf = os.path.join(scratch, f"{name}.ndjson")
            if os.path.exists(tf): os.unlink(tf)
            e = dict(os.environ); e.update(env)
            e.update({"GCRY_TRACE": "1", "GCRY_TRACE_FILE": tf, "GCRY_TRACE_ALLOC_SAMPLE": "0"})
            p = subprocess.run([bin_, b], capture_output=True, text=True, env=e)
            m = line_re.search(p.stdout)
            mark = pause = 0; n = 0
            for ln in open(tf):
                if '"collect_end"' in ln:
                    d = json.loads(ln); mark += d["mark_ns"]; pause += d["pause_ns"]; n += 1
            res.setdefault(b, {}).setdefault(name, []).append((mark / 1e6, pause / 1e6, float(m.group(3)) if m else -1, n))
    print(f"trial {t+1}/{trials}", file=sys.stderr, flush=True)
for b in benches:
    for name, _, _ in arms:
        xs = res[b][name]
        def f(i):
            v = [x[i] for x in xs]
            return f"{statistics.median(v):8.2f} ({min(v):7.2f}-{max(v):7.2f})"
        print(f"{b:22} {name:10} mark {f(0)}  pause {f(1)}  wall {f(2)}  gcs {xs[0][3]}")
