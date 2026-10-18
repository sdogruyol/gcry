#!/usr/bin/env python3
"""marksum.py TRIALS BENCHES RAW.json arm=bin[:ENV=V,...] ...

`../2026-10-15-mark-cost/marksum.py` with two changes: the affinity comes
from `CPUS` (default `0-3`, as in that log; `CPUS=all` runs unpinned on every
CPU), and the `PROBE` line `main_probe.cr` prints at exit is parsed, so each
run also records the parallel mark's runs, helper-stolen entries and wakes,
and the mark stack's mapped size. Boehm arms are gone (none here).

Interleaved, process-fresh. The arm order is shuffled for every (trial,
bench). Each run sums `mark_ns` and `pause_ns` over every `collect_end`
event of `GCRY_TRACE=1` (alloc sampling off), and `live_objects`; the bench's
own wall time is its `in X s`. The collection count and the heap at each
collection move from run to run (pacing), so Σ mark per Σ live object (ns
per object marked) is the main metric. From session s4 on it also sums
`sweep_ns` (`sweep_ms`). Prints medians (min-max) and writes every run to
RAW.json."""
import sys, os, subprocess, json, random, statistics, re

trials, benches, raw_path = int(sys.argv[1]), sys.argv[2].split(','), sys.argv[3]
cpus = os.environ.get("CPUS", "0-3")
prefix = [] if cpus == "all" else ["taskset", "-c", cpus]
arms = []
for a in sys.argv[4:]:
    name, rest = a.split('=', 1)
    parts = rest.split(':', 1)
    env = {}
    if len(parts) > 1 and parts[1]:
        for kv in parts[1].split(','):
            k, v = kv.split('=', 1)
            env[k] = v
    arms.append((name, parts[0], env))
scratch = "/home/naruto/playground/.scratch/ParallelMarkBatch/ms"
os.makedirs(scratch, exist_ok=True)
line_re = re.compile(r"^(\w+):\s+(ok|err).*?\bin\s+([0-9.]+)s", re.M)
probe_re = re.compile(r"PROBE workers=(\d+) runs=(\d+) stolen=(\d+) wakes=(\d+) markstack=(\d+) gcs=(\d+)")
res = {}
for t in range(trials):
    for b in benches:
        order = arms[:]
        random.shuffle(order)
        for name, bin_, env in order:
            e = dict(os.environ)
            e.update(env)
            tf = os.path.join(scratch, f"{name}.ndjson")
            if os.path.exists(tf):
                os.unlink(tf)
            e.update({"GCRY_TRACE": "1", "GCRY_TRACE_FILE": tf, "GCRY_TRACE_ALLOC_SAMPLE": "0"})
            p = subprocess.run(prefix + [bin_, b], capture_output=True, text=True, env=e)
            m = line_re.search(p.stdout)
            pr = probe_re.search(p.stderr)
            mark = pause = scanned = live = sweep = 0
            n = 0
            for ln in open(tf):
                if '"collect_end"' in ln:
                    d = json.loads(ln)
                    mark += d["mark_ns"]
                    pause += d["pause_ns"]
                    sweep += d.get("sweep_ns", 0)
                    scanned += d.get("scanned_bytes", 0)
                    live += d.get("live_objects", 0)
                    n += 1
            row = {"trial": t, "mark_ms": mark / 1e6, "pause_ms": pause / 1e6, "sweep_ms": sweep / 1e6,
                   "wall_s": float(m.group(3)) if m else -1, "gcs": n,
                   "scanned_mb": scanned / 2**20, "live_objects": live,
                   "ns_per_obj": mark / live if live else 0.0, "exit": p.returncode}
            if pr:
                w, runs, stolen, wakes, ms, _ = (int(x) for x in pr.groups())
                row.update({"workers": w, "pm_runs": runs, "stolen": stolen, "wakes": wakes,
                            "markstack_mapped": ms,
                            "stolen_share": stolen / live if live else 0.0})
            # Exit 1 with a result line is the bench's own check reporting
            # `err`: seven crystal-metric benches do that on every build here,
            # Boehm's included, with the same values (FINDINGS.md). A crash
            # has no result line or dies of a signal.
            if not m or p.returncode < 0 or p.returncode > 1:
                print(f"RUN FAILED {b} {name} exit={p.returncode}: {p.stderr[-400:]}", file=sys.stderr)
            res.setdefault(b, {}).setdefault(name, []).append(row)
    print(f"trial {t+1}/{trials}", file=sys.stderr, flush=True)
with open(raw_path, "w") as f:
    json.dump({"trials": trials, "cpus": cpus, "arms": [{"name": n, "bin": b, "env": e} for n, b, e in arms], "runs": res}, f, indent=1)
for b in benches:
    for name, _, _ in arms:
        xs = res[b][name]

        def f(k, w=8, p=2):
            v = [x.get(k, 0) for x in xs]
            return f"{statistics.median(v):{w}.{p}f} ({min(v):.{p}f}-{max(v):.{p}f})"
        gcs = sorted(x['gcs'] for x in xs)
        print(f"{b:14} {name:12} mark {f('mark_ms')}  pause {f('pause_ms')}  wall {f('wall_s')}  "
              f"ns/obj {f('ns_per_obj')}  gcs {gcs[0]}-{gcs[-1]}  pm-runs {f('pm_runs', 3, 0)}  "
              f"stolen/obj {f('stolen_share', 4, 2)}  sweep {f('sweep_ms')}")
