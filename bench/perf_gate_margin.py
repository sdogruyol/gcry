#!/usr/bin/env python3
"""Can `PERF_GATE_BASELINE=1` be turned on yet? Answer it with arithmetic.

`bench/perf_compare.py --record` derives each metric's tolerance from the
observed spread, `max(half-range, 1.5 x IQR, floor)`. That makes a baseline
honest, and it does *not* make it safe to gate on: a tolerance two standard
deviations out fires on ordinary host noise, and this branch takes several
pushes a day.

So this collects every green master run's `perf-smoke-report` on the current
layout, records a baseline from them, and prints the distance from each metric's
mean to its gate in units of that metric's own spread -- plus the per-run false
alarm probability that follows, and the combined rate across the three gated
metrics. The criterion: ~3.3 sd per metric, i.e. about one false red per 690 runs. Under
the pre-2026-09-13 rule (half-range or 1.5x IQR, both proportional to the
spread) that number was unreachable by sampling — 2.28 sd at n=23 and 3.24 at
n=1000 — which is why the rule now states the tolerance in standard deviations
and this tool reports the margin in the same unit.

    bench/perf_gate_margin.py                 # collect, record to a temp file, report
    bench/perf_gate_margin.py --out FILE      # also write the baseline it recorded
    bench/perf_gate_margin.py --limit 60      # how many master runs to consider

Needs `gh` with artifact download rights. Artifacts expire after 30 days, which
bounds how far back this can look.
"""

import argparse
import json
import math
import pathlib
import statistics
import subprocess
import sys
import tempfile

METRICS = ("pct_json", "pct_root", "rss_x", "pause_p50_ms")
GATED = ("pct_json", "rss_x", "pause_p50_ms")  # pct_root is warn-only
HIGHER_BETTER = {"pct_json", "pct_root"}
TARGET_SD = 3.3


def sh(*args, check=True):
    out = subprocess.run(args, capture_output=True, text=True)
    if check and out.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(args)}\n{out.stderr.strip()}")
    return out.stdout


def green_runs(limit):
    raw = sh("gh", "run", "list", "--branch", "master", "--workflow", "CI",
             "--limit", str(limit), "--json", "databaseId,conclusion,headSha,createdAt")
    return [(str(r["databaseId"]), r["headSha"][:7], r["createdAt"])
            for r in json.loads(raw) if r["conclusion"] == "success"]


def summary_for(run_id, cache):
    """The run's own summary, not the checked-in logs the artifact also carries."""
    d = cache / run_id
    if not d.exists():
        d.mkdir(parents=True)
        out = subprocess.run(["gh", "run", "download", run_id, "-n", "perf-smoke-report",
                              "-D", str(d)], capture_output=True, text=True)
        if out.returncode != 0:
            return None
    best = None
    for f in (d / "linux").glob("*/summary.json"):
        try:
            s = json.loads(f.read_text())
        except Exception:
            continue
        if s.get("runner") == "ubuntu-latest" and s.get("layout"):
            if best is None or f.stat().st_mtime > best[0].stat().st_mtime:
                best = (f, s)
    return best[1] if best else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=60,
                    help="master runs to consider, newest first (default 60)")
    ap.add_argument("--layout", default=None,
                    help="only runs on this layout; default is the newest run's layout")
    ap.add_argument("--out", help="write the recorded baseline here as well")
    ap.add_argument("--cache", default=None, help="artifact download cache directory")
    args = ap.parse_args()

    cache = pathlib.Path(args.cache or (tempfile.gettempdir() + "/gcry-perf-artifacts"))
    cache.mkdir(parents=True, exist_ok=True)

    runs = green_runs(args.limit)
    if not runs:
        raise SystemExit("no green master runs found")

    rows = []
    for run_id, sha, created in runs:
        s = summary_for(run_id, cache)
        if s:
            rows.append((run_id, sha, created, s))
    if not rows:
        raise SystemExit("no perf-smoke-report artifacts found (they expire after 30 days)")

    layout = args.layout or rows[0][3]["layout"]
    rows = [r for r in rows if r[3]["layout"] == layout]
    print(f"layout {layout}: {len(rows)} green runs with a summary "
          f"({rows[-1][2][:10]} .. {rows[0][2][:10]})")
    if len(rows) < 3:
        raise SystemExit("fewer than 3 runs: no spread to derive a tolerance from")

    summaries = [str(cache / r[0]) for r in rows]
    # Record through perf_compare so the tolerance rule has exactly one home.
    root = pathlib.Path(__file__).resolve().parent
    files = []
    for r in rows:
        for f in (cache / r[0] / "linux").glob("*/summary.json"):
            s = json.loads(f.read_text())
            if s.get("runner") == "ubuntu-latest" and s.get("layout") == layout:
                files.append(str(f))
    out_path = args.out or (tempfile.gettempdir() + "/gcry-perf-baseline-candidate.json")
    sh(sys.executable, str(root / "perf_compare.py"), "--record", "--out", out_path,
       "--runner", "ubuntu-latest", "--commit", rows[0][1],
       "--recorded", rows[0][2][:10], *files)
    base = json.loads(pathlib.Path(out_path).read_text())

    cdf = lambda z: 0.5 * (1 + math.erf(z / math.sqrt(2)))
    print()
    print(f"{'metric':<14}{'n':>4}{'median':>10}{'tol':>9}{'gate':>10}{'mean':>10}"
          f"{'sd':>8}{'sd out':>8}{'P/run':>8}{'self-fires':>12}")
    per_run_ok = 1.0
    for name in METRICS:
        entry = base["metrics"].get(name)
        if not entry or entry.get("tolerance") is None:
            continue
        vals = [float(r[3][name]) for r in rows if name in r[3]]
        hb = name in HIGHER_BETTER
        edge = entry["value"] - entry["tolerance"] if hb else entry["value"] + entry["tolerance"]
        mu, sd = statistics.mean(vals), statistics.stdev(vals)
        z = (mu - edge) / sd if hb else (edge - mu) / sd
        p = cdf(-z)
        fires = sum(1 for v in vals if (v < edge if hb else v > edge))
        tag = "" if name in GATED else "  (warn-only)"
        print(f"{name:<14}{len(vals):>4}{entry['value']:>10}{entry['tolerance']:>9}"
              f"{edge:>10.4g}{mu:>10.4g}{sd:>8.4g}{z:>8.2f}{p:>8.2%}"
              f"{fires:>7} of {len(vals)}{tag}")
        if name in GATED:
            per_run_ok *= (1 - p)

    combined = 1 - per_run_ok
    print()
    print(f"combined false-red rate: {combined:.2%} per run"
          f" = one every {round(1/combined) if combined else 0} runs")
    target = 1 - (1 - cdf(-TARGET_SD)) ** len(GATED)
    print(f"the criterion ({TARGET_SD} sd per metric): {target:.3%} per run"
          f" = one every {round(1/target)} runs")
    print()
    if combined <= target:
        print("VERDICT the margins are there — PERF_GATE_BASELINE=1 is worth turning on, and the")
        print("        baseline this recorded is the one to commit alongside it.")
        return 0
    print("VERDICT not yet, and more runs are not the lever — the tolerance rule is. Both of")
    print("        its terms are proportional to the spread, so the gate sits at a fixed number")
    print("        of standard deviations whatever n is: measured over normal samples, 2.28 sd")
    print("        at n=23, 2.51 at 100, 3.04 at 500, 3.24 at 1000. Reaching 3.3 takes ~1200")
    print("        runs against a 30-day artifact retention. State the tolerance in sd instead.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
