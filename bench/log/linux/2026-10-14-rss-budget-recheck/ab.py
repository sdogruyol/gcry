#!/usr/bin/env python3
"""Interleaved crystal-metric A/B: arms differ only by binary/env.

Usage: ab.py OUTDIR REPS BENCH[,BENCH...] ARM=bin[:ENV=V;ENV=V] ...
Each (rep, bench) runs every arm once in a random order; whole-process wall
time and ru_maxrss (KiB) per run, medians reported.
"""
import json, os, random, resource, statistics, subprocess, sys, time

out, reps, benches = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(",")
arms = {}
for spec in sys.argv[4:]:
    name, rest = spec.split("=", 1)
    binp, _, envs = rest.partition(":")
    env = dict(os.environ)
    for kv in filter(None, envs.split(";")):
        k, v = kv.split("=", 1)
        env[k] = v
    arms[name] = (binp, env)

os.makedirs(out, exist_ok=True)
rows = []
random.seed(20261014)
for r in range(reps):
    for b in benches:
        order = list(arms)
        random.shuffle(order)
        for a in order:
            binp, env = arms[a]
            t0 = time.monotonic()
            p = subprocess.Popen([binp, b], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            _, status, ru = os.wait4(p.pid, 0)
            wall = time.monotonic() - t0
            text = p.stdout.read().decode(errors="replace")
            ok = (" ok " in text or ": ok" in text) and os.waitstatus_to_exitcode(status) == 0
            rows.append(dict(rep=r, bench=b, arm=a, wall=wall, rss_kb=ru.ru_maxrss, ok=ok, exit=os.waitstatus_to_exitcode(status)))
            if not ok:
                print(f"WARN {a} {b} rep {r}: exit {os.waitstatus_to_exitcode(status)} {text[-300:]!r}", file=sys.stderr)
        print(f"rep {r} {b} done", file=sys.stderr, flush=True)
    with open(os.path.join(out, "runs.json"), "w") as f:
        json.dump(rows, f, indent=0)

base = next(iter(arms))
print(f"| bench | " + " | ".join(arms) + " |")
print("|---|" + "---|" * len(arms))
for b in benches:
    med = {}
    for a in arms:
        rs = [x for x in rows if x["bench"] == b and x["arm"] == a]
        med[a] = (statistics.median(x["wall"] for x in rs), statistics.median(x["rss_kb"] for x in rs))
    bw, br = med[base]
    cells = [f"{bw:.3f} s, {br/1024:.0f} MB"]
    for a in list(arms)[1:]:
        w, rk = med[a]
        cells.append(f"{100*bw/w:.0f}% / {rk/br:.2f}×  ({w:.3f} s, {rk/1024:.0f} MB)")
    print(f"| {b} | " + " | ".join(cells) + " |")
