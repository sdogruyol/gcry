#!/usr/bin/env python3
"""Tabulates sample.py outputs: peak-sample Rss by category, kB.

Usage: attr_table.py LABEL=attr/file.json ...   (median per label if a label
repeats). Columns in the order given; rows are the categories, largest first.
"""
import json, statistics, sys

runs = {}
for arg in sys.argv[1:]:
    label, path = arg.split("=", 1)
    runs.setdefault(label, []).append(json.load(open(path)))
labels = list(runs)


def med(label, f):
    return statistics.median(f(r) for r in runs[label])


cats = set()
for rs in runs.values():
    for r in rs:
        cats |= set(r["peak"]["cats"])
order = sorted(cats, key=lambda c: -max(med(l, lambda r: r["peak"]["cats"].get(c, 0)) for l in labels))
print("| category (peak sample, kB) | " + " | ".join(labels) + " |")
print("|---|" + "---:|" * len(labels))
for c in order:
    cells = [f"{med(l, lambda r: r['peak']['cats'].get(c, 0)):.0f}" for l in labels]
    if all(x == "0" for x in cells):
        continue
    print(f"| {c} | " + " | ".join(cells) + " |")
print("| **total** | " + " | ".join(f"**{med(l, lambda r: r['peak']['total']):.0f}**" for l in labels) + " |")
print("| VmHWM | " + " | ".join(f"{med(l, lambda r: r['vmhwm_kb']):.0f}" for l in labels) + " |")
print("| post-`/gc-collect` total | " + " | ".join(f"{med(l, lambda r: sum(r['post_collect'].values())):.0f}" for l in labels) + " |")
print("| req/s (one run) | " + " | ".join(f"{med(l, lambda r: r['reqs']):.0f}" for l in labels) + " |")


def stat(l, k):
    vals = [r["end_stats"].get(k) for r in runs[l] if r.get("end_stats") and r["end_stats"].get(k) is not None]
    return f"{statistics.median(vals):.0f}" if vals else "–"


for k in ["prof_gc_no", "gc_threshold", "prof_heap_size", "small_mapped_bytes", "large_mapped_bytes",
          "size_class_live_bytes", "empty_chunk_warm_retain"]:
    print(f"| {k} (end) | " + " | ".join(stat(l, k) for l in labels) + " |")
