#!/usr/bin/env python3
"""Summarise the probe's runs.csv files: per arm and shape, runs, failures,
release-check failures, and the last gap's idle collection timing."""
import csv, sys, statistics

rows = []
for path in sys.argv[1:]:
    rows += list(csv.DictReader(open(path)))

def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None

keys = []
for r in rows:
    k = (r["arm"], r["variant"])
    if k not in keys:
        keys.append(k)
for arm, v in sorted(keys):
    rs = [r for r in rows if r["arm"] == arm and r["variant"] == v]
    rc = {}
    for r in rs:
        rc[r["rc"]] = rc.get(r["rc"], 0) + 1
    kept = [r for r in rs if r["kept"] not in ("", "0")]
    starts = [num(r["idle_start_ms"]) for r in rs if num(r["idle_start_ms"]) is not None and num(r["idle_start_ms"]) >= 0]
    ends = [num(r["idle_end_ms"]) for r in rs if num(r["idle_end_ms"]) is not None and num(r["idle_end_ms"]) >= 0]
    none = sum(1 for r in rs if num(r["idle_start_ms"]) is not None and num(r["idle_start_ms"]) < 0)
    line = f"{arm:7s} {v:5s} runs={len(rs):4d} rc={dict(sorted(rc.items()))} kept_nonzero={len(kept)}"
    if starts:
        s = sorted(starts)
        line += (f" idle_start p50={statistics.median(s):.1f} p99={s[int(len(s) * 0.99) - 1 if len(s) > 1 else 0]:.1f}"
                 f" max={s[-1]:.1f} ms; end max={max(ends):.1f}; no idle gc in last gap: {none}")
    print(line)
    for r in kept:
        print(f"    kept={r['kept']} reread={r['reread']} idle_start={r['idle_start_ms']} idle_end={r['idle_end_ms']}"
              f" slept={r['slept_ms']} idle={r['idle_collections']}/{r['collections']} shard={r['tag']} round={r['round']} p{r['proc']}")
