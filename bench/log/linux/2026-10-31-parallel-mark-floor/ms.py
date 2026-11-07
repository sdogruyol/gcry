#!/usr/bin/env python3
"""ms.py TRIALS BENCHES RAW.json CPUS arm=bin[:ENV=V,...] ...

Interleaved, process-fresh runs under `taskset -c CPUS`, arm order shuffled per
(trial, bench). Records the bench's own wall time (crystal-metric's "in X s"),
the process' user+sys CPU (wait4 rusage), and for gcry arms Σ mark_ns, Σ
pause_ns, max pause, collections and parallel cycles from GCRY_TRACE=1. An arm
whose env sets GC_MARKERS is Boehm (no trace). Prints medians (min-max).
"""
import sys, os, subprocess, json, random, statistics, re, resource

trials, benches, raw_path, cpus = int(sys.argv[1]), sys.argv[2].split(','), sys.argv[3], sys.argv[4]
arms = []
for a in sys.argv[5:]:
    name, rest = a.split('=', 1)
    parts = rest.split(':', 1)
    env = {}
    if len(parts) > 1 and parts[1]:
        for kv in parts[1].split(','):
            k, v = kv.split('=', 1)
            env[k] = v
    arms.append((name, parts[0], env))
scratch = os.environ.get('MS_SCRATCH', 'ms')
os.makedirs(scratch, exist_ok=True)
line_re = re.compile(r"^(\w+):\s+(ok|err).*?\bin\s+([0-9.]+)s", re.M)
res = {}
for t in range(trials):
    for b in benches:
        order = arms[:]
        random.shuffle(order)
        for name, bin_, env in order:
            e = dict(os.environ)
            e.update(env)
            boehm = "GC_MARKERS" in env
            tf = os.path.join(scratch, f"{name}.ndjson")
            if not boehm:
                if os.path.exists(tf):
                    os.unlink(tf)
                e.update({"GCRY_TRACE": "1", "GCRY_TRACE_FILE": tf, "GCRY_TRACE_ALLOC_SAMPLE": "0"})
            r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
            p = subprocess.Popen(["taskset", "-c", cpus, bin_, b], stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, env=e)
            out, err = p.communicate()
            r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
            cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
            # rusage of the reaped child: Popen reaps via waitpid; use resource of children delta.
            m = line_re.search(out)
            rec = {"trial": t, "wall_s": float(m.group(3)) if m else -1, "cpu_s": cpu,
                   "sys_s": r1.ru_stime - r0.ru_stime}
            if not boehm:
                mark = pause = n = live = 0
                mx = 0
                for ln in open(tf):
                    if '"collect_end"' in ln:
                        d = json.loads(ln)
                        mark += d["mark_ns"]
                        pause += d["pause_ns"]
                        mx = max(mx, d["pause_ns"])
                        n += 1
                        live += d.get("live_objects", 0)
                rec.update({"mark_ms": mark / 1e6, "pause_ms": pause / 1e6, "max_pause_ms": mx / 1e6, "gcs": n, "ns_obj": mark / live if live else 0.0})
            res.setdefault(b, {}).setdefault(name, []).append(rec)
    print(f"trial {t+1}/{trials}", file=sys.stderr, flush=True)
with open(raw_path, "w") as f:
    json.dump({"trials": trials, "cpus": cpus, "arms": [{"name": n, "bin": b, "env": e} for n, b, e in arms], "runs": res}, f, indent=1)
for b in benches:
    for name, _, _ in arms:
        xs = res[b][name]

        def f(k):
            v = [x[k] for x in xs if k in x]
            if not v:
                return "      -"
            return f"{statistics.median(v):7.3f} ({min(v):6.3f}-{max(v):6.3f})"
        print(f"{b:14} {name:10} wall {f('wall_s')} cpu {f('cpu_s')} mark {f('mark_ms')} pause {f('pause_ms')} maxp {f('max_pause_ms')} gcs {f('gcs')} ns/obj {f('ns_obj')}")
