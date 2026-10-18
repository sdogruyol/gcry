#!/usr/bin/env python3
"""Tabulate verify.sh logs (run 2): `python3 verify.py DIR`.

Per arm: runs, exit codes, which FAIL lines fired, the heap per round, and
what the occupancy check read (blocks gained over the churn minus the strings
kept). `old*` arms run the shipped harness, which prints no occupancy. DIR
holds `<arm>.log` as verify.sh wrote them, or `<arm>.log.gz` as archived here.
"""
import gzip
import re
import sys
from collections import Counter
from pathlib import Path

ORDER = ["ctl", "hold", "hdrc", "hdrh", "oldc", "oldh", "red", "leak8", "leak64"]
OCC = re.compile(r"occupied blocks per round: (\d+) before -> ([\d >-]+) \((\d+) strings kept\)")


def log_of(out, arm):
    for name in (f"{arm}.log", f"{arm}.log.gz"):
        if (out / name).exists():
            return out / name
    return None


def parse(path):
    runs, cur = [], None
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", errors="replace") as f:
        lines = f.read().splitlines()
    for line in lines:
        if line.startswith("=== arm="):
            cur = {"rc": int(re.search(r"rc=(\d+)", line).group(1)), "mb": [], "excess": None, "fails": []}
            runs.append(cur)
        elif cur is None:
            continue
        elif line.startswith("heap MB per round:"):
            cur["mb"] = [float(x) for x in line.split(":", 1)[1].split("(")[0].split("->")]
        elif m := OCC.search(line):
            last = int(m.group(2).split("->")[-1])
            cur["excess"] = last - int(m.group(1)) - int(m.group(3))
        elif line.startswith("FAIL:"):
            cur["fails"].append("growth" if "every churn round" in line else
                                "occupied" if "more blocks are occupied" in line else
                                "shipped" if "over four churn rounds" in line else line[:60])
    return runs


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "verify-out")
    print("| arm | runs | rc≠0 | FAIL lines | round-1 MB median | max MB | max last−first | "
          "max round step | occupancy excess min/median/max |")
    print("|---|---|---|---|---|---|---|---|---|")
    for arm in ORDER:
        p = log_of(out, arm)
        if p is None:
            continue
        runs = parse(p)
        fails = Counter(f for r in runs for f in r["fails"])
        mbs = [r["mb"] for r in runs if r["mb"]]
        first = sorted(m[0] for m in mbs)
        growth = max(m[-1] - m[0] for m in mbs)
        step = max(max(b - a for a, b in zip(m, m[1:])) for m in mbs)
        ex = sorted(r["excess"] for r in runs if r["excess"] is not None)
        exs = f"{ex[0]}/{ex[len(ex) // 2]}/{ex[-1]}" if ex else "—"
        print(f"| {arm} | {len(runs)} | {sum(1 for r in runs if r['rc'])} | "
              f"{dict(fails) or '—'} | {first[len(first) // 2]:.1f} | {max(max(m) for m in mbs):.1f} | "
              f"{growth:+.1f} | {step:+.1f} | {exs} |")
    print()
    for arm in ORDER:
        p = log_of(out, arm)
        if p is None:
            continue
        shown = 0
        for r in parse(p):
            stepped = any(b - a > 1.0 for a, b in zip(r["mb"], r["mb"][1:]))
            if (stepped or r["rc"]) and shown < 6:
                print(f"- {arm} rc={r['rc']}: {' → '.join(f'{x:.1f}' for x in r['mb'])}, "
                      f"occupancy excess {r['excess']}, fails {r['fails'] or '—'}")
                shown += 1


if __name__ == "__main__":
    main()
