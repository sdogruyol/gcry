#!/usr/bin/env python3
"""Strict paired analysis: mean per-round ratios, t and CI on the same ratios."""

import argparse
import json
import math
from pathlib import Path
import statistics as stats

# Two-sided 95% Student-t quantiles; use the next SMALLER df for gaps so the
# interval is conservative, never the narrower normal approximation at small n.
CRITICAL = dict(enumerate([
    12.7062, 4.3027, 3.1824, 2.7764, 2.5706, 2.4469, 2.3646, 2.3060,
    2.2622, 2.2281, 2.2010, 2.1788, 2.1604, 2.1448, 2.1314, 2.1199,
    2.1098, 2.1009, 2.0930, 2.0860, 2.0796, 2.0739, 2.0687, 2.0639,
    2.0595, 2.0555, 2.0518, 2.0484, 2.0452, 2.0423,
], start=1))
CRITICAL.update({40: 2.0211, 60: 2.0003, 120: 1.9799})


def paired_ratios(xs, ys):
    ratios = [x / y for x, y in zip(xs, ys)]
    mean = stats.mean(ratios)
    se = stats.stdev(ratios) / math.sqrt(len(ratios))
    critical = CRITICAL[max(df for df in CRITICAL if df <= len(ratios) - 1)]
    t = (mean - 1) / se if se else (0.0 if mean == 1 else math.copysign(math.inf, mean - 1))
    return dict(ratio=mean, ci_low=mean - critical * se, ci_high=mean + critical * se, t=t)


def analyze(rows, reference):
    by = {}
    for row in rows:
        if row.get("error") or row.get("exit_code", 0) or any(row.get("errors", {}).values()):
            raise ValueError(f"failed trial: {row.get('round')}/{row.get('arm')}: {row.get('error', row.get('errors'))}")
        for key in ("rps", "requests", "clk_tck", "hwm_kb"):
            if not math.isfinite(row[key]) or row[key] <= 0:
                raise ValueError(f"invalid {key} in trial")
        for key in ("cpu_ticks", "minflt"):
            if not math.isfinite(row[key]) or row[key] < 0:
                raise ValueError(f"invalid {key} in trial")
        arm = by.setdefault(row["arm"], {})
        if row["round"] in arm:
            raise ValueError("duplicate arm/round")
        arm[row["round"]] = row
    if reference not in by:
        raise ValueError("reference arm missing")
    rounds = sorted(by[reference])
    if len(rounds) < 2:
        raise ValueError("at least two complete rounds required")
    out = {}
    for arm, trials in by.items():
        if sorted(trials) != rounds:
            raise ValueError(f"incomplete paired rounds: {arm}")
        xs = [trials[r] for r in rounds]
        ys = [by[reference][r] for r in rounds]
        result = paired_ratios([r["rps"] for r in xs], [r["rps"] for r in ys])
        result.update(n=len(rounds), rps=stats.mean(r["rps"] for r in xs),
                      rss_ratio=stats.mean(r["hwm_kb"] for r in xs) / stats.mean(r["hwm_kb"] for r in ys),
                      faults_per_1k=stats.mean(r["minflt"] / r["requests"] * 1000 for r in xs),
                      cpu_ms_per_10k=stats.mean(r["cpu_ticks"] / r["clk_tck"] * 1000 / r["requests"] * 10000 for r in xs))
        out[arm] = result
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trials", type=Path)
    parser.add_argument("reference")
    args = parser.parse_args()
    try:
        rows = [json.loads(line) for line in args.trials.read_text().splitlines() if line.strip() and not line.startswith("#")]
        manifest_path = args.trials.parent / "manifest.json"
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text())
            expected = {(r, arm["name"]) for r in range(manifest["config"]["rounds"])
                        for arm in manifest["arms"]}
            if {(row["round"], row["arm"]) for row in rows} != expected:
                raise ValueError("trial set differs from the run manifest (incomplete run)")
        results = analyze(rows, args.reference)
    except (ValueError, KeyError) as error:
        parser.error(str(error))
    print("arm                     n   req/s    ratio [95% CI]             t     RSS×  faults/1k  CPU ms/10k")
    for arm, r in results.items():
        print(f"{arm:23} {r['n']:2} {r['rps']:7.0f} {r['ratio']*100:6.1f}% "
              f"[{r['ci_low']*100:6.1f}, {r['ci_high']*100:6.1f}] {r['t']:8.2f} "
              f"{r['rss_ratio']:7.2f} {r['faults_per_1k']:9.1f} {r['cpu_ms_per_10k']:11.1f}")


if __name__ == "__main__":
    main()
