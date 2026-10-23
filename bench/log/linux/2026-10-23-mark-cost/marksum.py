#!/usr/bin/env python3
"""marksum.py TRIALS BENCHES RAW.json arm=bin[:ENV=V,...] ...

Interleaved, process-fresh, every run under `taskset -c 0-3`. The arm order is
shuffled for every (trial, bench).

- A gcry arm sums `mark_ns` and `pause_ns` over every `collect_end` event of
  `GCRY_TRACE=1` (alloc sampling off).
- An arm whose environment sets `GC_MARKERS` is a Boehm binary: it runs with
  `GC_PRINT_STATS=1` and sums the "World-stopped marking took" lines (which
  include Boehm's root scan; gcry's `mark_ns` is the drain alone, so the
  ratio flatters Boehm slightly). Its pause column repeats the mark.

Both record the bench's own wall time. A gcry run also sums `scanned_bytes`
and `live_objects`: the collection count and the heap at each collection
move from run to run (pacing), so Σ mark per Σ live object is reported beside
Σ mark. Prints medians (min-max) of Σ mark ms, Σ pause ms, wall s and mark ns
per live object, and writes every run to RAW.json.

Same method as ../2026-10-06-mark-cost/marksum.py and boehmmark.py, plus the
raw dump, the affinity prefix (that session ran the whole script under
taskset) and Boehm in the same interleave."""
import sys, os, subprocess, json, random, statistics, re

trials, benches, raw_path = int(sys.argv[1]), sys.argv[2].split(','), sys.argv[3]
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
scratch = os.path.expanduser('/home/naruto/playground/.scratch/MarkCost-2/ms')
os.makedirs(scratch, exist_ok=True)
line_re = re.compile(r"^(\w+):\s+(ok|err).*?\bin\s+([0-9.]+)s", re.M)
boehm_re = re.compile(r"World-stopped marking took (\d+) ms (\d+) ns")
inuse_re = re.compile(r"In-use heap: \d+% \((\d+) KiB pointers")
res = {}
for t in range(trials):
    for b in benches:
        order = arms[:]
        random.shuffle(order)
        for name, bin_, env in order:
            e = dict(os.environ)
            e.update(env)
            boehm = "GC_MARKERS" in env
            if boehm:
                e["GC_PRINT_STATS"] = "1"
            else:
                tf = os.path.join(scratch, f"{name}.ndjson")
                if os.path.exists(tf):
                    os.unlink(tf)
                e.update({"GCRY_TRACE": "1", "GCRY_TRACE_FILE": tf, "GCRY_TRACE_ALLOC_SAMPLE": "0"})
            p = subprocess.run(["taskset", "-c", "0-3", bin_, b], capture_output=True, text=True, env=e)
            m = line_re.search(p.stdout)
            mark = pause = scanned = live = 0
            n = 0
            # Per collection: (mark ms, heap measure). gcry's measure is
            # live_objects, Boehm's the "In-use heap" pointer KiB printed after
            # each marking line.
            per = []
            if boehm:
                text = p.stderr + p.stdout
                marks = [int(a) * 1e6 + int(b_) for a, b_ in boehm_re.findall(text)]
                inuse = [int(x) for x in inuse_re.findall(text)]
                for i, v in enumerate(marks):
                    mark += v
                    n += 1
                    per.append((v / 1e6, inuse[i] if i < len(inuse) else 0))
                pause = mark
            else:
                for ln in open(tf):
                    if '"collect_end"' in ln:
                        d = json.loads(ln)
                        mark += d["mark_ns"]
                        pause += d["pause_ns"]
                        scanned += d.get("scanned_bytes", 0)
                        live += d.get("live_objects", 0)
                        n += 1
                        per.append((d["mark_ns"] / 1e6, d.get("live_objects", 0)))
            # Mean mark of the collections at ≥95% of the run's largest heap
            # measure: a per-collection cost at a matched (full) heap.
            top = max((h for _, h in per), default=0)
            big = [ms for ms, h in per if top and h >= 0.95 * top]
            res.setdefault(b, {}).setdefault(name, []).append(
                {"trial": t, "mark_ms": mark / 1e6, "pause_ms": pause / 1e6,
                 "wall_s": float(m.group(3)) if m else -1, "gcs": n,
                 "scanned_mb": scanned / 2**20, "live_objects": live,
                 "ns_per_obj": mark / live if live else 0.0,
                 "per_gc_ms": mark / 1e6 / n if n else 0.0,
                 "full_heap_ms": sum(big) / len(big) if big else 0.0, "full_heap_gcs": len(big),
                 "per": per})
    print(f"trial {t+1}/{trials}", file=sys.stderr, flush=True)
with open(raw_path, "w") as f:
    json.dump({"trials": trials, "arms": [{"name": n, "bin": b, "env": e} for n, b, e in arms], "runs": res}, f, indent=1)
for b in benches:
    for name, _, _ in arms:
        xs = res[b][name]

        def f(k):
            v = [x[k] for x in xs]
            return f"{statistics.median(v):8.2f} ({min(v):7.2f}-{max(v):7.2f})"
        gcs = sorted(x['gcs'] for x in xs)
        print(f"{b:22} {name:12} mark {f('mark_ms')}  pause {f('pause_ms')}  wall {f('wall_s')}  ns/live-obj {f('ns_per_obj')}  per-gc {f('per_gc_ms')}  full-heap {f('full_heap_ms')}  gcs {gcs[0]}-{gcs[-1]}")
