"""Which function's cache-line phase predicts Revcomp's timed section?

usage: phase_fit.py MOD RUN_DIR...

Each RUN_DIR is a downloaded perf-ab artifact (runs.json + syms/ with full
symbol tables). Every arm of every run is one observation: its median timed
section and, per function, its address mod MOD. For each function present in
every binary, the arms are grouped by that phase and the fit is R² = 1 −
(within-group variance / total variance); 1.0 means the function's phase alone
explains which arms are fast. Functions that always move together tie, so
the output lists the 40 best fits, ties in name order.
"""
import json, os, re, statistics, sys
from collections import defaultdict

MOD = int(sys.argv[1])


def demangle(s):
    return re.sub(r"\.([0-9A-F]{2})\.", lambda m: chr(int(m.group(1), 16)), s)


def load(path):
    out = {}
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) >= 4 and re.fullmatch(r"0001:[0-9a-f]{8}", p[0]) and re.fullmatch(r"[0-9a-f]{16}", p[2]):
            out.setdefault(demangle(p[1]), int(p[2], 16))
        elif len(p) >= 3 and re.fullmatch(r"[0-9a-f]{8,16}", p[0]) and p[1] in "tT":
            out.setdefault(" ".join(p[2:]), int(p[0], 16))
    return out


obs = []  # (label, time, syms)
for d in sys.argv[2:]:
    runs = json.load(open(os.path.join(d, "runs.json")))
    for arm in runs["arms"]:
        ts = [r["time"] for r in runs["runs"] if r["arm"] == arm and r["bench"] == "Revcomp" and r["time"]]
        syms = load(os.path.join(d, "syms", f"ab-{arm}.txt"))
        obs.append((f"{os.path.basename(d.rstrip('/'))}:{arm}", statistics.median(ts), syms))

common = set.intersection(*(set(o[2]) for o in obs))
times = [o[1] for o in obs]
mean = statistics.fmean(times)
tot = sum((t - mean) ** 2 for t in times)
fits = []
for name in common:
    g = defaultdict(list)
    for _, t, s in obs:
        g[s[name] % MOD].append(t)
    within = sum(sum((t - statistics.fmean(v)) ** 2 for t in v) for v in g.values())
    fits.append((1 - within / tot, len(g), name))
fits.sort(key=lambda x: (-round(x[0], 9), x[1], x[2]))
print(f"{len(obs)} arms, {len(common)} functions in every binary, total variance {tot:.4f} s²")
for r2, groups, name in fits[:40]:
    print(f"R²={r2:.3f} phases={groups} {name[:100]}")
