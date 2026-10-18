#!/usr/bin/env python3
"""attrib.py BINARY SAMPLES[,SAMPLES...] FUNC LABEL=START-END [LABEL=START-END ...]

SIGPROF samples (sampler.c) inside one function, grouped by instruction
ranges given as hex offsets from the function's start (END exclusive). A
sample lands on the instruction after the one that stalled (skid), so each
range is drawn to start one instruction after the load it is named for; see
FINDINGS.md for the ranges used. Samples in the function outside every
range are reported as "other"."""
import sys, subprocess, collections, bisect

binary, paths, func = sys.argv[1], sys.argv[2].split(","), sys.argv[3]
ranges = []
for spec in sys.argv[4:]:
    label, span = spec.split("=", 1)
    lo, hi = span.split("-")
    ranges.append((label, int(lo, 16), int(hi, 16)))

syms = []
for ln in subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout.splitlines():
    p = ln.split(" ", 2)
    if len(p) == 3 and p[0] and p[1] in "tTwW":
        syms.append((int(p[0], 16), p[2]))
start = end = None
for i, (a, n) in enumerate(syms):
    if n == func:
        start, end = a, syms[i + 1][0]
        break
if start is None:
    sys.exit(f"no symbol {func!r}")

bin_name = binary.split("/")[-1]
total = 0
per = collections.Counter()
infunc = 0
for path in paths:
    samples, maps = [], []
    for line in open(path):
        if line.startswith("S "):
            samples.append(int(line[2:], 16))
        elif line.startswith("M "):
            parts = line[2:].split()
            lo, hi = (int(x, 16) for x in parts[0].split("-"))
            maps.append((lo, hi, int(parts[2], 16), parts[5] if len(parts) > 5 else ""))
    total += len(samples)
    for pc in samples:
        for lo, hi, off, name in maps:
            if lo <= pc < hi:
                if name.endswith(bin_name):
                    o = pc - lo + off
                    if start <= o < end:
                        infunc += 1
                        rel = o - start
                        for label, a, b in ranges:
                            if a <= rel < b:
                                per[label] += 1
                                break
                        else:
                            per["other"] += 1
                break
print(f"{func[:90]}: {infunc} of {total} samples ({100.0 * infunc / max(total, 1):.1f}%)")
for label, _, _ in ranges + [("other", 0, 0)]:
    c = per[label]
    print(f"  {label:28} {c:6d}  {100.0 * c / max(infunc, 1):5.1f}% of function")
