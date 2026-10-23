"""Speed against Boehm under each environment pad and with the profiler
preloaded idle (probe.sh, PROBE_ENVPAD / PROBE_PRELOAD_ARMS).

usage: envpad.py RUNS_JSON [FIELD]

For each gcry arm and each condition (`` = none, `-e<n>`, `-pre`) prints
Boehm's wall time over the arm's under the *same* condition, as the median of
per-rep paired ratios with the interquartile range, then each arm's median
wall time per condition, so a condition that moves one collector but not the
other shows as a moved ratio. FIELD defaults to `wall` (`time`: the timed
section, `utime`: user CPU).
"""
import collections, json, statistics, sys


def quart(v):
    v = sorted(v)
    n = len(v)
    return v[n // 4], statistics.median(v), v[(3 * n) // 4]


def main():
    data = json.load(open(sys.argv[1]))
    field = sys.argv[2] if len(sys.argv) > 2 else "wall"
    runs = data["runs"] if isinstance(data, dict) and "runs" in data else data
    by = collections.defaultdict(dict)
    arms = set()
    for r in runs:
        by[r["rep"]][r["arm"]] = r
        arms.add(r["arm"])
    conds = sorted({a[len("boehm"):] for a in arms if a.startswith("boehm")},
                   key=lambda c: (c != "", c != "-pre", int(c[2:]) if c.startswith("-e") else 0))
    bases = sorted({a.split("-")[0] for a in arms} - {"boehm"})
    print(f"Boehm / arm, {field}, median [IQR] of paired reps")
    print("| condition | " + " | ".join(bases) + " |")
    print("|---|" + "---:|" * len(bases))
    for c in conds:
        cells = []
        for b in bases:
            rat = [by[r]["boehm" + c][field] / by[r][b + c][field] for r in by
                   if "boehm" + c in by[r] and b + c in by[r] and by[r][b + c].get(field)]
            if not rat:
                cells.append("–")
                continue
            lo, m, hi = quart(rat)
            cells.append(f"{100 * m:.1f}% [{100 * lo:.0f}, {100 * hi:.0f}]")
        print(f"| {c or 'none'} | " + " | ".join(cells) + " |")
    print(f"\nmedian {field} (s) per arm and condition")
    print("| condition | boehm | " + " | ".join(bases) + " |")
    print("|---|" + "---:|" * (len(bases) + 1))
    for c in conds:
        cells = []
        for b in ["boehm"] + bases:
            v = [by[r][b + c][field] for r in by if b + c in by[r] and by[r][b + c].get(field)]
            cells.append(f"{statistics.median(v):.3f}" if v else "–")
        print(f"| {c or 'none'} | " + " | ".join(cells) + " |")


main()
