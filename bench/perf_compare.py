#!/usr/bin/env python3
"""Compare a perf-smoke run against a stored baseline.

Why this exists
---------------
`bench/perf_smoke.sh` gates on fixed floors — thr >= 65% of Boehm, RSS <= 1.25x,
pause_p50 <= 2.5 ms. Quiet tip holds ~85% @ ~0.8x @ ~0.6 ms, so the floors sit
far below where the collector actually is, and a regression that lands inside
them is invisible: 85% -> 70% passes every gate in the suite.

A baseline comparison closes that gap only if it is noise-aware. It is not, by
itself, more sensitive — it is more sensitive *and* more flaky, in the same
proportion, unless the tolerance is derived from measured spread rather than
chosen. So a baseline here carries three things per metric: the value, the
tolerance, and the spread the tolerance came from. A baseline without a
recorded spread reports and does not gate; saying "no baseline yet" out loud is
worth more than a number nobody measured.

Usage
-----
  perf_compare.py --baseline bench/baseline/perf_smoke.json \\
                  --summary bench/log/<run>/summary.json [--gate]

  perf_compare.py --record --out bench/baseline/perf_smoke.json \\
                  --runner ubuntu-latest --commit <sha> run1.json run2.json ...

  perf_compare.py --selftest
"""

import argparse
import json
import statistics
import sys

# name -> (label, higher_is_better)
METRICS = {
    "pct_json": ("/json thr, % of Boehm", True),
    "pct_root": ("/ thr, % of Boehm", True),
    "rss_x": ("post-GC RSS, x Boehm", False),
    "pause_p50_ms": ("pause p50, ms", False),
}

# Metrics that only ever warn, matching perf_smoke.sh: `/` is not the critical
# path and its number moves for reasons `/json` does not.
WARN_ONLY = {"pct_root"}

PASS, REGRESSED, IMPROVED, NO_BASELINE = "ok", "REGRESSED", "improved", "no baseline"


def verdict(name, value, entry):
    """Compare one metric. `entry` is a baseline record or None."""
    if entry is None or entry.get("value") is None:
        return NO_BASELINE, None
    base = float(entry["value"])
    tol = entry.get("tolerance")
    if tol is None:
        # A baseline whose tolerance was never measured cannot gate: every
        # comparison would be against zero noise, which no host has.
        return NO_BASELINE, value - base
    tol = float(tol)
    _, higher_better = METRICS[name]
    delta = value - base
    if higher_better:
        return (REGRESSED if delta < -tol else (IMPROVED if delta > tol else PASS)), delta
    return (REGRESSED if delta > tol else (IMPROVED if delta < -tol else PASS)), delta


def compare(baseline, summary, gate):
    metrics = baseline.get("metrics", {})
    prov = baseline.get("provenance", {})
    lines = []
    regressions = []
    ungated = []

    lines.append("=== perf vs baseline ===")
    if prov and prov.get("recorded"):
        commit = prov.get("commit") or "?"
        lines.append(
            "baseline: runner={} commit={} runs={} recorded={}".format(
                prov.get("runner") or "?", commit[:12],
                prov.get("runs", "?"), prov.get("recorded")))
        if prov.get("runner") and summary.get("runner") and prov["runner"] != summary["runner"]:
            lines.append(
                "NOTE: this run is on {}, the baseline was recorded on {} — "
                "absolute numbers do not carry across runner classes".format(
                    summary["runner"], prov["runner"]))
    else:
        lines.append("baseline: none recorded yet")

    for name, (label, higher_better) in METRICS.items():
        if name not in summary:
            continue
        value = float(summary[name])
        entry = metrics.get(name)
        state, delta = verdict(name, value, entry)
        base_txt = "—" if entry is None or entry.get("value") is None else "{:g}".format(float(entry["value"]))
        tol_txt = "—" if entry is None or entry.get("tolerance") is None else "±{:g}".format(float(entry["tolerance"]))
        delta_txt = "—" if delta is None else "{:+.2f}".format(delta)
        lines.append("  {:<24} {:>8.2f}  base {:>8}  tol {:>7}  delta {:>7}  {}".format(
            label, value, base_txt, tol_txt, delta_txt, state))
        if state == REGRESSED:
            (regressions if name not in WARN_ONLY else ungated).append((name, label, value, delta))
        elif state == NO_BASELINE:
            ungated.append((name, label, value, delta))

    for name, label, value, delta in ungated:
        if name in WARN_ONLY and delta is not None:
            lines.append("WARN: {} moved {:+.2f} (warn-only metric)".format(label, delta))

    if not metrics or all(m.get("tolerance") is None for m in metrics.values()):
        lines.append("")
        lines.append("No baseline with a measured tolerance, so nothing here can gate. Record one "
                     "from N green runs on the same runner class:")
        lines.append("  bench/perf_compare.py --record --out bench/baseline/perf_smoke.json \\")
        lines.append("      --runner <label> --commit <sha> bench/log/*/summary.json")
        return "\n".join(lines), 0

    if regressions:
        lines.append("")
        for name, label, value, delta in regressions:
            entry = metrics[name]
            lines.append("FAIL: {} is {:.2f} against a baseline of {:g} — {:+.2f}, outside ±{:g}".format(
                label, value, float(entry["value"]), delta, float(entry["tolerance"])))
        return "\n".join(lines), (1 if gate else 0)

    lines.append("")
    lines.append("PASS — every gated metric is within tolerance of the baseline")
    return "\n".join(lines), 0


def record(summaries, runner, commit, recorded):
    """Median per metric, with the observed spread the tolerance is derived from.

    Tolerance = max(half the observed range, 1.5 x IQR), floored per metric so a
    freakishly quiet recording session cannot produce a gate nothing can pass.
    With fewer than 3 runs there is no spread to speak of, so the tolerance is
    left null and the baseline reports instead of gating.
    """
    floors = {"pct_json": 2.0, "pct_root": 2.0, "rss_x": 0.05, "pause_p50_ms": 0.2}
    metrics = {}
    for name in METRICS:
        values = [float(s[name]) for s in summaries if name in s]
        if not values:
            continue
        entry = {"value": round(statistics.median(values), 4), "runs": len(values)}
        if len(values) >= 3:
            half_range = (max(values) - min(values)) / 2.0
            iqr = 0.0
            if len(values) >= 4:
                q = statistics.quantiles(values, n=4)
                iqr = q[2] - q[0]
            entry["observed_range"] = [round(min(values), 4), round(max(values), 4)]
            entry["tolerance"] = round(max(half_range, 1.5 * iqr, floors[name]), 4)
        else:
            entry["tolerance"] = None
            entry["note"] = "fewer than 3 runs: no spread measured, so this metric reports only"
        metrics[name] = entry
    return {
        "provenance": {
            "runner": runner,
            "commit": commit,
            "runs": len(summaries),
            "recorded": recorded,
            "note": "Ratios only. Absolute RPS is not comparable across hosts; these are "
                    "same-host, same-run ratios against Boehm.",
        },
        "metrics": metrics,
    }


def selftest():
    """Fixtures, including both directions of every verdict."""
    base = {
        "provenance": {"runner": "test", "commit": "0" * 40, "runs": 5, "recorded": "1970-01-01"},
        "metrics": {
            "pct_json": {"value": 85.0, "tolerance": 3.0},
            "pct_root": {"value": 80.0, "tolerance": 3.0},
            "rss_x": {"value": 0.80, "tolerance": 0.05},
            "pause_p50_ms": {"value": 0.60, "tolerance": 0.20},
        },
    }
    cases = [
        ("within noise", {"pct_json": 83.0, "rss_x": 0.83, "pause_p50_ms": 0.7}, 0, "PASS"),
        ("thr regression", {"pct_json": 70.0, "rss_x": 0.80, "pause_p50_ms": 0.6}, 1, "FAIL"),
        ("rss regression", {"pct_json": 85.0, "rss_x": 0.95, "pause_p50_ms": 0.6}, 1, "FAIL"),
        ("pause regression", {"pct_json": 85.0, "rss_x": 0.80, "pause_p50_ms": 1.0}, 1, "FAIL"),
        ("improvement", {"pct_json": 95.0, "rss_x": 0.70, "pause_p50_ms": 0.3}, 0, "PASS"),
    ]
    # A metric the run reports and the baseline does not: it must show as "no
    # baseline" and take no part in the verdict. Left out of the fixtures above
    # because the crash it caused was in the *failure* path, which only the
    # regression cases reach.
    partial = {"provenance": {}, "metrics": {"pct_json": {"value": 85.0, "tolerance": 3.0}}}
    text, code = compare(partial, {"pct_json": 70.0, "rss_x": 0.9, "pause_p50_ms": 9.0}, gate=True)
    if code != 1 or "no baseline" not in text:
        failures_partial = "partial baseline: exit {} (want 1), or missing 'no baseline'".format(code)
    else:
        failures_partial = None
    failures = []
    if failures_partial:
        failures.append(failures_partial)
    for label, summary, want_code, want_word in cases:
        text, code = compare(base, summary, gate=True)
        if code != want_code or want_word not in text:
            failures.append("{}: exit {} (want {}), text missing {!r}".format(
                label, code, want_code, want_word))

    # A regression must NOT fail the run when --gate is off: the report is
    # useful before anyone is willing to block a PR on it.
    _, code = compare(base, {"pct_json": 70.0}, gate=False)
    if code != 0:
        failures.append("ungated regression exited {} (want 0)".format(code))

    # A baseline with no measured tolerance must report, never gate — otherwise
    # the first run after recording gates against zero noise.
    no_tol = {"provenance": {}, "metrics": {"pct_json": {"value": 85.0, "tolerance": None}}}
    text, code = compare(no_tol, {"pct_json": 40.0}, gate=True)
    if code != 0 or "nothing here can gate" not in text:
        failures.append("tolerance-less baseline gated (exit {})".format(code))

    # The shape this repo actually ships: provenance present but every field null.
    # It crashed on `commit[:12]` before this fixture existed.
    unrecorded = {
        "provenance": {"runner": None, "commit": None, "runs": 0, "recorded": None},
        "metrics": {"pct_json": {"value": None, "tolerance": None}},
    }
    text, code = compare(unrecorded, {"pct_json": 40.0}, gate=True)
    if code != 0 or "none recorded yet" not in text:
        failures.append("unrecorded baseline: exit {} (want 0)".format(code))

    # An empty baseline must say how to record one rather than passing silently.
    text, code = compare({"metrics": {}}, {"pct_json": 85.0}, gate=True)
    if code != 0 or "--record" not in text:
        failures.append("empty baseline did not print the recording command")

    # Recording: 5 runs -> a tolerance at least as wide as the observed spread.
    rec = record([{"pct_json": v, "rss_x": 0.8, "pause_p50_ms": 0.6} for v in
                  (84.0, 85.0, 86.0, 82.0, 88.0)], "test", "abc", "now")
    tol = rec["metrics"]["pct_json"]["tolerance"]
    if tol < 3.0:
        failures.append("recorded tolerance {} narrower than the observed ±3.0 range".format(tol))
    if rec["metrics"]["rss_x"]["tolerance"] < 0.05:
        failures.append("recorded tolerance ignored the floor for a metric with zero spread")

    # Recording: 2 runs -> no tolerance, so the baseline cannot gate on a spread
    # nobody measured.
    rec2 = record([{"pct_json": 85.0}, {"pct_json": 60.0}], "test", "abc", "now")
    if rec2["metrics"]["pct_json"]["tolerance"] is not None:
        failures.append("two runs produced a tolerance")

    if failures:
        for f in failures:
            print("SELFTEST FAIL: " + f, file=sys.stderr)
        return 1
    print("perf_compare selftest ok — {} comparison fixtures, both gate modes, "
          "tolerance-less and empty baselines, and both recording paths".format(len(cases)))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline")
    ap.add_argument("--summary")
    ap.add_argument("--gate", action="store_true",
                    help="exit 1 on a regression (default: report only)")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--runner", default="unknown")
    ap.add_argument("--commit", default="unknown")
    ap.add_argument("--recorded", default="unknown",
                    help="timestamp for provenance; passed in rather than read from the clock "
                         "so a re-record is reproducible")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("summaries", nargs="*")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.record:
        if not args.summaries or not args.out:
            ap.error("--record needs --out and at least one summary.json")
        summaries = [json.load(open(p)) for p in args.summaries]
        baseline = record(summaries, args.runner, args.commit, args.recorded)
        with open(args.out, "w") as f:
            f.write(json.dumps(baseline, indent=2) + "\n")
        print(json.dumps(baseline, indent=2))
        return 0

    if not args.baseline or not args.summary:
        ap.error("need --baseline and --summary (or --record / --selftest)")
    baseline = json.load(open(args.baseline))
    summary = json.load(open(args.summary))
    text, code = compare(baseline, summary, args.gate)
    print(text)
    return code


if __name__ == "__main__":
    sys.exit(main())
