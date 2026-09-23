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
import os
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
# path and its number moves for reasons `/json` does not. A baseline can add to
# this with `"warn_only": true` on a metric (`--record --warn-only NAME`): whether
# a metric can gate is a property of the runner class's spread, and on macOS
# `pct_json`'s is ~4x Linux's (sd 15.4 pp over 16 runs, 2026-09-23), which puts
# a 3.3 sd gate below the fixed floor it would replace.
WARN_ONLY = {"pct_root"}

# Standard deviations from the mean to the gate. 3.3 puts one false red per
# ~690 runs across the three gated metrics; see `record`'s docstring for why
# this is a constant here rather than something the recording session derives.
TARGET_SD = 3.3

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


# A single run has to be 3.3 sd out before the gate fires, which on this runner
# class is ~14 pp of `/json` throughput: anything smaller is invisible. Two
# runs in a row on the wrong side of 2 sd is 0.05% per pair under normality,
# so it buys back sensitivity — ~9 pp — at a *lower* false-alarm rate than the
# single-run gate. Measured against the 24 recording runs: 1 single excursion
# past 2 sd in 72 metric-runs and **no consecutive pairs at all**, including
# across the hours a shared runner pool is slow, which is the case this rule
# could otherwise have mistaken for a regression.
STREAK_SD = 2.0


def deviation_sd(name, value, entry):
    """How far out `value` is, in sd, signed so negative is always worse."""
    if entry is None or entry.get("value") is None or not entry.get("sd"):
        return None
    sd = float(entry["sd"])
    if sd <= 0:
        return None
    delta = (value - float(entry["value"])) / sd
    _, higher_better = METRICS[name]
    return delta if higher_better else -delta


def compare(baseline, summary, gate, prev=None):
    metrics = baseline.get("metrics", {})
    warn_only = WARN_ONLY | {n for n, e in metrics.items() if e.get("warn_only")}
    prov = baseline.get("provenance", {})
    lines = []
    regressions = []
    ungated = []
    streaks = []

    lines.append("=== perf vs baseline ===")
    if prov and prov.get("recorded"):
        commit = prov.get("commit") or "?"
        lines.append(
            "baseline: runner={} commit={} runs={} recorded={}".format(
                prov.get("runner") or "?", commit[:12],
                prov.get("runs", "?"), prov.get("recorded")))
        if prov.get("runner") and summary.get("runner") and prov["runner"] != summary["runner"]:
            lines.append(
                "STALE: this run is on {}, the baseline was recorded on {}. "
                "Ratios are same-host but their spread is not: a macOS runner's "
                "`rss_x` and a GHA Linux runner's are different distributions, "
                "so a tolerance measured on one cannot gate the other. Record a "
                "baseline on this runner class. Reporting only.".format(
                    summary["runner"], prov["runner"]))
    else:
        lines.append("baseline: none recorded yet")
    # A baseline recorded on another object layout or allocator default is not
    # a baseline for this run: it happened twice (0.24.0 flipped the allocator,
    # 0.26.0 the layout) and both times the file kept comparing and kept
    # reading as authority — the second one would have failed every green run
    # on `rss_x` alone. Report, never gate, until it is re-recorded.
    stale_runner = bool(prov.get("runner") and summary.get("runner")
                        and prov["runner"] != summary["runner"])
    # The sampling protocol, for the same reason as the two above: a median of
    # one surviving draw and a median of five are different measurements of the
    # same collector — the Darwin job read /json at 65.6% of Boehm on the first
    # and 111.6% on the second, same host and commit — and a tolerance is a
    # statement about a distribution. Compared only when the baseline records
    # it; the ones recorded before 2026-09-22 do not.
    stale_protocol = False
    protocol_diff = []
    for key in ("wrk_duration_s", "wrk_connections", "bench_runs"):
        want, got = prov.get(key), summary.get(key)
        if want is not None and got is not None and want != got:
            stale_protocol = True
            protocol_diff.append("{}={} against the baseline's {}".format(key, got, want))
    if stale_protocol:
        lines.append(
            "STALE: this run was sampled with {} — a median of one surviving "
            "draw and a median of five are different measurements. Re-record "
            "under this sampling. Reporting only.".format(", ".join(protocol_diff)))
    stale_layout = (prov.get("layout") and summary.get("layout")
                    and prov["layout"] != summary["layout"])
    if stale_layout:
        lines.append(
            "STALE: this run is the {} layout, the baseline was recorded on {}. "
            "Re-record from green runs on this layout; comparing across a "
            "default flip is how a baseline lies. Reporting only.".format(
                summary["layout"], prov["layout"]))
    elif prov.get("recorded") and not prov.get("layout"):
        lines.append(
            "STALE: the baseline carries no layout, so it predates the "
            "0.26.0 flip. Re-record; reporting only.")
        stale_layout = True

    for name, (label, higher_better) in METRICS.items():
        if name not in summary:
            continue
        value = float(summary[name])
        entry = metrics.get(name)
        state, delta = verdict(name, value, entry)
        base_txt = "—" if entry is None or entry.get("value") is None else "{:g}".format(float(entry["value"]))
        tol_txt = "—" if entry is None or entry.get("tolerance") is None else "±{:g}".format(float(entry["tolerance"]))
        delta_txt = "—" if delta is None else "{:+.2f}".format(delta)
        # How far out this run is in the baseline's own units. The gate fires at
        # 3.3 sd, which is ~14 pp of `/json` here, so a run at 2 sd is both
        # inside the gate and worth seeing: a streak of those is what a
        # sensitivity rule would act on, and printing it is what makes such a
        # rule measurable before it is written.
        sd = None if entry is None else entry.get("sd")
        sd_txt = "—"
        if delta is not None and sd:
            sd_txt = "{:+.2f}sd".format(delta / float(sd))
        lines.append("  {:<24} {:>8.2f}  base {:>8}  tol {:>7}  delta {:>7} {:>8}  {}".format(
            label, value, base_txt, tol_txt, delta_txt, sd_txt, state))
        if state == REGRESSED:
            (regressions if name not in warn_only else ungated).append((name, label, value, delta))
        elif state == NO_BASELINE:
            ungated.append((name, label, value, delta))
        # The streak: this run and the previous one both on the wrong side of
        # STREAK_SD. One run there is ordinary host noise — 1 in 72 metric-runs
        # of the recording set — and two in a row is 0.05% per pair, which is
        # how a 9 pp regression becomes visible without narrowing the band that
        # a single run is judged against.
        if prev and name in prev and name not in warn_only:
            now_sd = deviation_sd(name, value, entry)
            prev_sd = deviation_sd(name, float(prev[name]), entry)
            if now_sd is not None and prev_sd is not None \
                    and now_sd < -STREAK_SD and prev_sd < -STREAK_SD:
                streaks.append((name, label, now_sd, prev_sd))

    for name, label, value, delta in ungated:
        if name in warn_only and delta is not None:
            lines.append("WARN: {} moved {:+.2f} (warn-only metric)".format(label, delta))

    if not metrics or all(m.get("tolerance") is None for m in metrics.values()):
        lines.append("")
        if baseline.get("missing_path"):
            lines.append("There is no baseline file at {} — this platform has not "
                         "recorded one yet.".format(baseline["missing_path"]))
        lines.append("No baseline with a measured tolerance, so nothing here can gate. Record one "
                     "from N green runs on the same runner class:")
        lines.append("  bench/perf_compare.py --record --out bench/baseline/perf_smoke.json \\")
        lines.append("      --runner <label> --commit <sha> bench/log/*/summary.json")
        return "\n".join(lines), 0

    if regressions:
        lines.append("")
        if stale_layout:
            lines.append("The differences below are across a layout change, not a regression:")
        elif stale_runner:
            lines.append("The differences below are across runner classes, not a regression:")
        for name, label, value, delta in regressions:
            entry = metrics[name]
            lines.append("FAIL: {} is {:.2f} against a baseline of {:g} — {:+.2f}, outside ±{:g}".format(
                label, value, float(entry["value"]), delta, float(entry["tolerance"])))
        return "\n".join(lines), (1 if gate and not stale_layout and not stale_runner
                     and not stale_protocol else 0)

    if streaks:
        lines.append("")
        for name, label, now_sd, prev_sd in streaks:
            lines.append(
                "FAIL: {} has been on the wrong side of {:g} sd for two runs in a row "
                "({:+.2f} sd now, {:+.2f} sd before) — inside the single-run gate, "
                "confirmed across runs".format(label, STREAK_SD, now_sd, prev_sd))
        lines.append("A single excursion past {:g} sd happened once in 72 metric-runs of the "
                     "recording set and never twice in a row, so this is a regression rather "
                     "than a slow hour on the runner pool.".format(STREAK_SD))
        return "\n".join(lines), (1 if gate and not stale_layout and not stale_runner
                     and not stale_protocol else 0)

    lines.append("")
    lines.append("PASS — every gated metric is within tolerance of the baseline"
                 + (", and no metric is two runs deep on the wrong side of "
                    "{:g} sd".format(STREAK_SD) if prev else ""))
    return "\n".join(lines), 0


def record(summaries, runner, commit, recorded, warn_only=()):
    """Median per metric, with a tolerance of TARGET_SD standard deviations.

    Floored per metric, so a freakishly quiet recording session cannot produce a
    gate nothing can pass. With fewer than 3 runs there is no spread to speak
    of, so the tolerance is left null and the baseline reports instead of
    gating.

    The rule was `max(half the observed range, 1.5 x IQR)` until 2026-09-13, and
    a baseline recorded that way **cannot be gated on at any sample size**. Both
    terms are proportional to the spread, so the gate sits a fixed number of
    standard deviations out however many runs go in — measured over normal
    samples, 400 draws each: 2.32 sd at n=10, 2.28 at 23, 2.29 at 40, 2.51 at
    100, 3.04 at 500, 3.24 at 1000. That is 1.0% to 0.06% false reds per metric
    per run, and the 23-run baseline this repo shipped read 2.12-2.62 sd across
    its gated metrics, i.e. 2.7% combined: one red every 37 runs. "Record more
    green runs and then turn gating on" was the plan carried for a year, and it
    needed about 1200 of them against a 30-day artifact retention.

    So the tolerance is stated in the unit the false-alarm rate is computed in.
    At 3.3 sd it is 0.048% per metric, 0.145% across the three gated ones — one
    false red per ~690 runs — and on the 2026-09-13 recording the gates land at
    `pct_json` 86.1 (the fixed floor is 65), `rss_x` 1.196 (floor 1.25) and
    `pause_p50_ms` 0.98 ms (floor 2.5), so two of the three are tighter than the
    floor they were meant to tighten and none of them is a coin toss.

    What this cannot do is catch a small regression: 3.3 sd on this runner class
    is ~14 pp of `/json` throughput, and anything under that is invisible to a
    single run. Sensitivity at a fixed false-alarm rate needs confirmation
    across runs rather than a narrower tolerance, and that needs state CI does
    not keep yet.
    """
    layouts = {s.get("layout") for s in summaries if s.get("layout")}
    if len(layouts) > 1:
        raise SystemExit("refusing to record a baseline from mixed layouts: "
                         + ", ".join(sorted(layouts)))
    unknown = set(warn_only) - set(METRICS)
    if unknown:
        raise SystemExit("--warn-only names no metric: " + ", ".join(sorted(unknown)))
    floors = {"pct_json": 2.0, "pct_root": 2.0, "rss_x": 0.05, "pause_p50_ms": 0.2}
    metrics = {}
    for name in METRICS:
        values = [float(s[name]) for s in summaries if name in s]
        if not values:
            continue
        entry = {"value": round(statistics.median(values), 4), "runs": len(values)}
        if len(values) >= 3:
            sd = statistics.stdev(values)
            entry["observed_range"] = [round(min(values), 4), round(max(values), 4)]
            entry["sd"] = round(sd, 4)
            entry["tolerance"] = round(max(TARGET_SD * sd, floors[name]), 4)
            entry["sd_out"] = round(entry["tolerance"] / sd, 2) if sd > 0 else None
        else:
            entry["tolerance"] = None
            entry["note"] = "fewer than 3 runs: no spread measured, so this metric reports only"
        if name in warn_only:
            entry["warn_only"] = True
        metrics[name] = entry
    # The sampling the samples were taken under, refused if mixed for the same
    # reason a mixed layout is: the tolerance below describes one distribution
    # or it describes nothing. Absent in summaries written before 2026-09-22,
    # which record as null and compare as "unknown, do not judge".
    protocol = {}
    for key in ("wrk_duration_s", "wrk_connections", "bench_runs"):
        seen = {s[key] for s in summaries if s.get(key) is not None}
        # Untagged beside tagged is mixed too: an untagged summary predates the
        # tag, and every one of those on either runner was sampled differently
        # (5 s, 3 runs). Ignoring them here let a recording of 10 old + 16 new
        # macOS summaries through as one protocol.
        if seen and any(s.get(key) is None for s in summaries):
            raise SystemExit("refusing to record from mixed sampling: {} is {} in some "
                             "summaries and absent in others".format(
                                 key, ", ".join(str(v) for v in sorted(seen))))
        if len(seen) > 1:
            raise SystemExit("refusing to record from mixed sampling: {} is {}".format(
                key, ", ".join(str(v) for v in sorted(seen))))
        protocol[key] = seen.pop() if seen else None
    return {
        "provenance": {
            "runner": runner,
            "layout": (layouts.pop() if layouts else None),
            "commit": commit,
            "runs": len(summaries),
            "recorded": recorded,
            "wrk_duration_s": protocol["wrk_duration_s"],
            "wrk_connections": protocol["wrk_connections"],
            "bench_runs": protocol["bench_runs"],
            "note": "Ratios only. Absolute RPS is not comparable across hosts; these are "
                    "same-host, same-run ratios against Boehm.",
        },
        "metrics": metrics,
    }


def selftest():
    """Fixtures, including both directions of every verdict."""
    base = {
        "provenance": {"runner": "test", "layout": "headerless", "commit": "0" * 40,
                        "runs": 5, "recorded": "1970-01-01"},
        "metrics": {
            "pct_json": {"value": 85.0, "tolerance": 3.0, "sd": 1.0},
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
        summary = dict(summary, layout="headerless")
        text, code = compare(base, summary, gate=True)
        if code != want_code or want_word not in text:
            failures.append("{}: exit {} (want {}), text missing {!r}".format(
                label, code, want_code, want_word))

    # A regression across a layout change is not a regression. The baseline
    # that shipped through 0.25.0 was recorded on the header layout and read
    # every headerless run as an RSS regression; gating on that would have
    # blocked every PR. Report the difference, name it, exit 0.
    text, code = compare(base, {"pct_json": 70.0, "rss_x": 0.95, "layout": "block_headers"}, gate=True)
    if code != 0 or "STALE" not in text or "across a layout change" not in text:
        failures.append("cross-layout baseline gated (exit {})".format(code))

    # And a regression against a baseline from another runner class is not one
    # either, for the same reason one collected on another layout is not: the
    # ratios are same-host but their *spread* is the runner's, and a tolerance
    # is a statement about spread. Before 2026-09-22 this printed a NOTE and
    # gated anyway, which is what a macOS perf step would have run into on its
    # first green run.
    text, code = compare(base, {"pct_json": 70.0, "rss_x": 0.95, "layout": "headerless",
                                "runner": "macos-latest"}, gate=True)
    if code != 0 or "STALE" not in text or "across runner classes" not in text:
        failures.append("cross-runner baseline gated (exit {})".format(code))
    # A run sampled differently from the baseline reports rather than gates,
    # and the matching one still gates.
    proto_base = dict(base)
    proto_base["provenance"] = dict(base["provenance"], bench_runs=3, wrk_duration_s=5)
    text, code = compare(proto_base, {"pct_json": 70.0, "rss_x": 0.95, "layout": "headerless",
                                      "runner": "test", "bench_runs": 7, "wrk_duration_s": 10}, gate=True)
    if code != 0 or "different measurements" not in text:
        failures.append("cross-protocol baseline gated (exit {})".format(code))
    text, code = compare(proto_base, {"pct_json": 70.0, "rss_x": 0.95, "layout": "headerless",
                                      "runner": "test", "bench_runs": 3, "wrk_duration_s": 5}, gate=True)
    if code != 1:
        failures.append("same-protocol regression did not gate (exit {})".format(code))
    # And a recording from mixed sampling is refused outright.
    try:
        record([{"pct_json": 90.0, "layout": "headerless", "bench_runs": 3},
                {"pct_json": 91.0, "layout": "headerless", "bench_runs": 7}],
               "test", "0" * 40, "1970-01-01")
        failures.append("recording from mixed sampling was allowed")
    except SystemExit:
        pass
    try:
        record([{"pct_json": 90.0, "layout": "headerless"},
                {"pct_json": 91.0, "layout": "headerless", "bench_runs": 7}],
               "test", "0" * 40, "1970-01-01")
        failures.append("recording from untagged beside tagged sampling was allowed")
    except SystemExit:
        pass

    # A metric the baseline marks warn-only reports its regression and takes no
    # part in the verdict, while the others still gate — the macOS baseline's
    # shape, where `/json` throughput's spread is too wide to gate on. The
    # recording writes the mark, and refuses a name that is not a metric.
    warned = record([{"pct_json": v, "rss_x": 0.8, "pause_p50_ms": 0.6, "layout": "headerless"}
                     for v in (84.0, 85.0, 86.0)], "test", "0" * 40, "1970-01-01",
                    warn_only=["pct_json"])
    if not warned["metrics"]["pct_json"].get("warn_only") or warned["metrics"]["rss_x"].get("warn_only"):
        failures.append("--warn-only did not mark exactly the named metric")
    text, code = compare(warned, {"pct_json": 50.0, "rss_x": 0.8, "pause_p50_ms": 0.6,
                                  "layout": "headerless", "runner": "test"}, gate=True)
    if code != 0 or "warn-only" not in text:
        failures.append("warn-only metric gated (exit {})".format(code))
    text, code = compare(warned, {"pct_json": 85.0, "rss_x": 1.2, "pause_p50_ms": 0.6,
                                  "layout": "headerless", "runner": "test"}, gate=True)
    if code != 1:
        failures.append("metric beside a warn-only one did not gate (exit {})".format(code))
    try:
        record([{"pct_json": 90.0}], "test", "0" * 40, "1970-01-01", warn_only=["pct_jsn"])
        failures.append("--warn-only accepted a name that is not a metric")
    except SystemExit:
        pass

    # A baseline path that does not exist reports instead of raising: a
    # platform gets its perf step before it can record one, and the first
    # Darwin run died on a traceback in the version of this that shipped for
    # ten minutes on 2026-09-22.
    missing = {"provenance": {}, "metrics": {}, "missing_path": "/nonexistent/perf.json"}
    text, code = compare(missing, {"pct_json": 98.0, "layout": "headerless",
                                   "runner": "macos-latest"}, gate=True)
    if code != 0 or "no baseline file" not in text.lower():
        failures.append("missing baseline file did not report (exit {})".format(code))

    # The same runner class still gates, or the rule above would disable the
    # gate everywhere by accident.
    text, code = compare(base, {"pct_json": 70.0, "rss_x": 0.95, "layout": "headerless",
                                "runner": "test"}, gate=True)
    if code != 1:
        failures.append("same-runner regression did not gate (exit {})".format(code))

    # A baseline with no layout at all predates the field, so it cannot be
    # shown to describe this run either. Same treatment.
    no_layout = {
        "provenance": {"runner": "test", "commit": "0" * 40, "runs": 5, "recorded": "1970-01-01"},
        "metrics": {"pct_json": {"value": 85.0, "tolerance": 3.0}},
    }
    text, code = compare(no_layout, {"pct_json": 40.0, "layout": "headerless"}, gate=True)
    if code != 0 or "predates" not in text:
        failures.append("layout-less baseline gated (exit {})".format(code))

    # Recording must refuse to average two layouts into one number.
    try:
        record([{"pct_json": 100.0, "layout": "headerless"},
                {"pct_json": 80.0, "layout": "block_headers"},
                {"pct_json": 90.0, "layout": "headerless"}], "test", "0" * 40, "1970-01-01")
        failures.append("recording accepted mixed layouts")
    except SystemExit:
        pass

    # A regression must NOT fail the run when --gate is off: the report is
    # useful before anyone is willing to block a PR on it.
    _, code = compare(base, {"pct_json": 70.0, "layout": "headerless"}, gate=False)
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

    # And the converse, which no fixture covered until a baseline was finally
    # recorded on the shipped layout: a fresh, matching baseline must not also
    # announce that none exists. "none recorded yet" was the fall-through of the
    # staleness chain, so it printed under every comparison that was *not*
    # stale — and every baseline this repo had shipped was stale, which is why
    # a report contradicting itself went unseen.
    text, _ = compare(base, {"pct_json": 85.0, "layout": "headerless"}, gate=True)
    if "none recorded yet" in text:
        failures.append("a recorded baseline also reported 'none recorded yet'")

    # The two-runs-in-a-row check. `base` has sd on every metric, so a run at
    # 2.5 sd is inside the single-run gate (3.3 sd) and confirmed only if the
    # run before it was out too — which is the whole point: sensitivity without
    # narrowing the band a single run is judged against.
    sd_json = base["metrics"]["pct_json"]["sd"]
    bad = {"pct_json": 85.0 - 2.5 * sd_json, "layout": "headerless"}
    ok_run = {"pct_json": 85.0, "layout": "headerless"}
    text, code = compare(base, bad, gate=True, prev=bad)
    if code != 1 or "two runs in a row" not in text:
        failures.append("a confirmed two-run excursion did not fail (exit {})".format(code))
    text, code = compare(base, bad, gate=True, prev=ok_run)
    if code != 0:
        failures.append("a single excursion with a clean previous run failed (exit {})".format(code))
    text, code = compare(base, bad, gate=False, prev=bad)
    if code != 0:
        failures.append("a confirmed excursion failed with --gate off (exit {})".format(code))
    text, code = compare(base, bad, gate=True, prev={"layout": "headerless"})
    if code != 0:
        failures.append("a previous run missing the metric was not treated as no data")

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
    # And stated in standard deviations, which is the unit the false-alarm rate
    # is computed in. The rule this replaced — half-range or 1.5x IQR — sits at
    # about 2.3 sd for any sample size, so a baseline recorded under it can never
    # be gated on; a revert to it would pass every other fixture here silently.
    sd = statistics.stdev([84.0, 85.0, 86.0, 82.0, 88.0])
    if tol < 3.0 * sd:
        failures.append("recorded tolerance {} is {:.2f} sd, under the 3 sd a gate needs"
                        .format(tol, tol / sd))
    if rec["metrics"]["pct_json"].get("sd_out") is None:
        failures.append("recording did not report how many sd the tolerance is")
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
          "tolerance-less, empty, unrecorded and self-denying baselines, a "
          "cross-layout, a cross-runner, a cross-protocol, a missing and a layout-less baseline, a per-baseline warn-only metric, mixed-layout and mixed-sampling recording, and "
          "both recording paths".format(len(cases)))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline")
    ap.add_argument("--summary")
    ap.add_argument("--prev", help="the previous run's summary.json, for the "
                                   "two-runs-in-a-row check (missing or unreadable is fine: "
                                   "the check simply does not run)")
    ap.add_argument("--gate", action="store_true",
                    help="exit 1 on a regression (default: report only)")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--runner", default="unknown")
    ap.add_argument("--commit", default="unknown")
    ap.add_argument("--warn-only", action="append", default=[], metavar="METRIC",
                    help="with --record: mark METRIC as reporting only in this baseline "
                         "(repeatable), for a runner class whose spread on it is too wide to gate")
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
        baseline = record(summaries, args.runner, args.commit, args.recorded, args.warn_only)
        with open(args.out, "w") as f:
            f.write(json.dumps(baseline, indent=2) + "\n")
        print(json.dumps(baseline, indent=2))
        return 0

    if not args.baseline or not args.summary:
        ap.error("need --baseline and --summary (or --record / --selftest)")
    # A baseline path that does not exist is an *unrecorded* baseline, not an
    # error: a platform gets its perf step before it has enough green runs to
    # record from, and the first Darwin run would otherwise die on a traceback
    # rather than print what it measured. Gate mode included — there is nothing
    # to gate against.
    if os.path.exists(args.baseline):
        baseline = json.load(open(args.baseline))
    else:
        baseline = {"provenance": {}, "metrics": {},
                    "missing_path": args.baseline}
    summary = json.load(open(args.summary))
    prev = None
    if args.prev:
        try:
            prev = json.load(open(args.prev))
        except Exception:
            prev = None
    text, code = compare(baseline, summary, args.gate, prev=prev)
    print(text)
    return code


if __name__ == "__main__":
    sys.exit(main())
