#!/usr/bin/env python3
"""JsonGenerate high-peak rate per arm from perf-ab runs.json files.

A rep is high when its peak is more than MARGIN MiB above the lowest peak any
gcry arm reached on that runner in that run (the floor): one more dead buffer
kept is +26 MiB or more (bench/log/macos/2026-10-23-jsongen-m1/, section 1).
Boehm's arm is counted against its own floor.

    hp.py DIR...           # per arm; each DIR holds <runner>/runs.json
    hp.py --pool DIR...    # every gcry arm of every DIR pooled per runner
"""
import json
import os
import sys

MARGIN = 15  # MiB
BENCH = "JsonGenerate"


def peaks_of(path):
    peaks = {}
    # Not filtered on `rc`: JsonGenerate exits 1 on every arm, Boehm's
    # included.
    for r in json.load(open(path))["runs"]:
        if r["bench"] == BENCH:
            peaks.setdefault(r["arm"], []).append(r["peak"] / 2**20)
    return peaks


def per_arm(tops):
    for top in tops:
        print(f"== {top}")
        for runner in sorted(os.listdir(top)):
            path = os.path.join(top, runner, "runs.json")
            if not os.path.exists(path):
                continue
            peaks = peaks_of(path)
            gcry = [p for a, ps in peaks.items() if a != "boehm" for p in ps]
            if not gcry:
                continue
            floor = min(gcry)
            print(f"{runner}: floor {floor:.0f} MiB")
            for arm in sorted(peaks):
                ps = sorted(peaks[arm])
                lo = floor if arm != "boehm" else min(ps)
                hi = [p for p in ps if p > lo + MARGIN]
                levels = " ".join(f"{p:.0f}" for p in hi)
                print(f"  {arm:8} {len(hi):2}/{len(ps):2} high  median {ps[len(ps) // 2]:.0f}  high: {levels}")


def pooled(tops):
    agg = {}
    for top in tops:
        for runner in sorted(os.listdir(top)):
            path = os.path.join(top, runner, "runs.json")
            if not os.path.exists(path):
                continue
            peaks = peaks_of(path)
            gcry = [p for a, ps in peaks.items() if a != "boehm" for p in ps]
            if not gcry:
                continue
            floor = min(gcry)
            hi = sum(1 for p in gcry if p > floor + MARGIN)
            a = agg.setdefault(runner, [0, 0, []])
            a[0] += hi
            a[1] += len(gcry)
            a[2].append(f"{os.path.basename(top.rstrip('/'))}:{hi}/{len(gcry)}")
    for runner, (hi, n, per) in sorted(agg.items()):
        print(f"{runner}: {hi}/{n} = {100 * hi / n:.0f}%  ({' '.join(per)})")


if sys.argv[1] == "--pool":
    pooled(sys.argv[2:])
else:
    per_arm(sys.argv[1:])
