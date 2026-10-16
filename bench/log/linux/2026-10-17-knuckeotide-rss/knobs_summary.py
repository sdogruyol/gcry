#!/usr/bin/env python3
"""Median / range of knobs.sh output per arm: peak RSS (MB), collections,
timed-run seconds. Usage: knobs_summary.py OUT.tsv"""
import collections, csv, statistics, sys

d = collections.defaultdict(list)
for r in csv.DictReader(open(sys.argv[1]), delimiter="\t"):
    d[r["arm"]].append((int(r["hwm_kb"]) / 1024, int(r["collections"]), float(r["run_s"])))
print("| arm | peak MB median [min, max] | collections | run s median [min, max] |")
print("|---|---:|---:|---:|")
for a, v in d.items():
    h = sorted(x[0] for x in v)
    t = sorted(x[2] for x in v)
    print(f"| {a} | {statistics.median(h):.1f} [{h[0]:.1f}, {h[-1]:.1f}] | "
          f"{statistics.median(x[1] for x in v):.0f} | {statistics.median(t):.3f} [{t[0]:.3f}, {t[-1]:.3f}] |")
