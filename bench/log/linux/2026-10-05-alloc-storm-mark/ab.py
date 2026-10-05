#!/usr/bin/env python3
"""Interleaved A/B: ab.py OUTDIR TRIALS BENCHES ARM=bin[:ENV=V,ENV=V] ...
Each arm/bench/trial is one fresh process; order of arms shuffled per (trial, bench).
Records in-run wall (bench line), whole-process user+sys CPU and peak RSS."""
import sys, os, subprocess, json, random, re, statistics, resource, time
out, trials, benches = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(',')
arms = []
for a in sys.argv[4:]:
    name, rest = a.split('=', 1)
    parts = rest.split(':', 1)
    env = {}
    if len(parts) > 1 and parts[1]:
        for kv in parts[1].split(','):
            k, v = kv.split('=', 1); env[k] = v
    arms.append((name, parts[0], env))
os.makedirs(out, exist_ok=True)
line_re = re.compile(r"^(\w+):\s+(ok|err).*?\bin\s+([0-9.]+)s", re.M)
res = {}
def run(bin_, env, bench):
    e = dict(os.environ); e.update(env)
    p = subprocess.run(["/usr/bin/time", "-f", "TIME %U %S %M", bin_, bench], capture_output=True, text=True, env=e)
    m = line_re.search(p.stdout)
    t = re.search(r"TIME ([0-9.]+) ([0-9.]+) (\d+)", p.stderr)
    return (float(m.group(3)) if m else None, float(t.group(1)) + float(t.group(2)) if t else None, int(t.group(3)) if t else None)
for t in range(trials):
    for b in benches:
        order = arms[:]; random.shuffle(order)
        for name, bin_, env in order:
            w, cpu, rss = run(bin_, env, b)
            res.setdefault(b, {}).setdefault(name, []).append((w, cpu, rss))
    print(f"trial {t+1}/{trials} done", file=sys.stderr, flush=True)
json.dump(res, open(os.path.join(out, "raw.json"), "w"), indent=1)
lines = []
base = arms[0][0]
hdr = f"{'bench':24} {'arm':12} {'wall med':>9} {'min':>7} {'max':>7} {'Δ vs ' + base:>10} {'cpu med':>8} {'rss MiB':>8}"
lines.append(hdr)
for b in benches:
    bw = statistics.median([x[0] for x in res[b][base]])
    for name, _, _ in arms:
        xs = res[b][name]
        w = [x[0] for x in xs]; c = [x[1] for x in xs]; r = [x[2] for x in xs]
        mw = statistics.median(w)
        lines.append(f"{b:24} {name:12} {mw:9.4f} {min(w):7.3f} {max(w):7.3f} {(mw/bw-1)*100:+9.1f}% {statistics.median(c):8.2f} {statistics.median(r)/1024:8.0f}")
s = "\n".join(lines)
open(os.path.join(out, "summary.txt"), "w").write(s + "\n")
print(s)
