#!/usr/bin/env python3
"""Summarize results-night.tsv: per-lane runs, failures, timeouts, lane-hours."""
import collections, sys

path = sys.argv[1] if len(sys.argv) > 1 else "/home/naruto/.cache/campaign/results-night.tsv"
runs = collections.Counter()
secs = collections.Counter()
bad = collections.defaultdict(list)
first = last = None
for line in open(path):
    f = line.rstrip("\n").split("\t")
    if len(f) < 5 or not f[0].isdigit():
        continue
    ts, job, seed, rc, dt = int(f[0]), f[1], f[2], f[3], float(f[4])
    first = ts if first is None else min(first, ts)
    last = ts if last is None else max(last, ts)
    runs[job] += 1
    secs[job] += dt
    if rc != "0":
        bad[job].append((seed, rc, dt))
total = sum(runs.values())
print(f"{total} runs, {sum(secs.values()) / 3600:.1f} lane-hours, wall {(last - first) / 3600:.1f} h")
print()
print("| lane | runs | failed | timed out | lane-hours |")
print("|---|---:|---:|---:|---:|")
for job in sorted(runs):
    b = bad[job]
    to = sum(1 for _, rc, _ in b if rc == "TIMEOUT")
    print(f"| `{job}` | {runs[job]} | {len(b) - to} | {to} | {secs[job] / 3600:.1f} |")
print()
for job, b in sorted(bad.items()):
    for seed, rc, dt in b:
        print(f"- `{job}` seed {seed}: rc={rc} after {dt:.0f} s")
