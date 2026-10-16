"""Markdown verdict for one or more `AB_JSON` files from bench/runner_ab/ab.py.

    python3 bench/runner_ab/report.py ab-ubuntu-latest.json ab-arm.json > report.md
    python3 bench/runner_ab/report.py --self-test

Per bench and metric: the ratio of the var and base medians, with a 95%
bootstrap interval that resamples whole reps (a rep's base and var ran back to
back, so they stay together). A row is a regression or an improvement only when
the whole interval is past the threshold; anything else is noise at this sample
size, however large the point estimate. Timings never fail a build; base
and var computing different results is reported with ❌ (ab.py exits 1 on it).
"""

import json, random, re, statistics, sys

MARKER = "<!-- gcry-perf-pr -->"
THRESHOLDS = {"time_s": 0.03, "mark_ms": 0.10}
# Below this base median a ratio is not a finding: Revcomp's Σ mark going
# 2 → 3 ms read as a 🔴 +22% in the positive-control run.
FLOORS = {"time_s": 0.0, "mark_ms": 10.0}
BOOT = 2000


def ratio_ci(base, var, rng, floor=0.0):
    """Ratio of medians and its 95% paired-bootstrap interval, or None when
    the base median is at or under *floor* (a bench that barely collects)."""
    if statistics.median(base) <= floor:
        return None
    n = len(base)
    rs = []
    for _ in range(BOOT):
        idx = [rng.randrange(n) for _ in range(n)]
        b = statistics.median(base[i] for i in idx)
        if b > 0:
            rs.append(statistics.median(var[i] for i in idx) / b)
    rs.sort()
    return statistics.median(var) / statistics.median(base) - 1, rs[int(0.025 * len(rs))] - 1, rs[int(0.975 * len(rs)) - 1] - 1


def verdict(ci, threshold):
    if ci is None:
        return "⚪"
    _, lo, hi = ci
    return "🔴" if lo > threshold else "🟢" if hi < -threshold else "⚪"


def judge(arms, rng):
    """{metric: (ci, verdict)} for one bench's {"base": {...}, "var": {...}}."""
    return {m: (ci := ratio_ci(arms["base"][m], arms["var"][m], rng, FLOORS[m]), verdict(ci, t)) for m, t in THRESHOLDS.items()}


def fmt(ci):
    return "—" if ci is None else f"{ci[0]:+.1%} [{ci[1]:+.1%}, {ci[2]:+.1%}]"


def safe(x):
    """A name from the JSON, as it may appear in a comment. The JSON was
    written by PR code (perf-pr-comment.yml posts it), so no markdown."""
    return re.sub(r"[^A-Za-z0-9._-]", "", str(x))[:40]


def clean(run):
    """*run* with every name sanitized and every sample a float."""
    return {
        "runner": safe(run["runner"]), "base": safe(run["base"]), "var": safe(run["var"]), "reps": int(run["reps"]),
        "benches": {
            safe(b): {
                a: {**{m: [float(x) for x in arms[a][m]] for m in THRESHOLDS}, "results": [str(r) for r in arms[a].get("results", ["expected"])]}
                for a in ("base", "var")
            }
            for b, arms in run["benches"].items()
        },
    }


def render(runs):
    runs = [clean(r) for r in runs]
    rng = random.Random(0)
    rows, flags, drift = [], {"🔴": [], "🟢": [], "❌": []}, set()
    for run in runs:
        for bench, arms in run["benches"].items():
            j = judge(arms, rng)
            for v in {j["time_s"][1], j["mark_ms"][1]} & flags.keys():
                flags[v].append(f"{bench} ({run['runner']})")
            res = {a: arms[a].get("results", ["expected"]) for a in arms}
            if res["base"] != res["var"]:
                flags["❌"].append(f"{bench} ({run['runner']})")
            elif res["base"] != ["expected"]:
                drift.add(bench)
            med = {a: {m: statistics.median(arms[a][m]) for m in THRESHOLDS} for a in arms}
            rows.append(
                f"| {'❌ ' if res['base'] != res['var'] else ''}{bench} | {run['runner']} "
                f"| {med['base']['time_s']:.3f} → {med['var']['time_s']:.3f} s | {j['time_s'][1]} {fmt(j['time_s'][0])} "
                f"| {med['base']['mark_ms']:.0f} → {med['var']['mark_ms']:.0f} ms | {j['mark_ms'][1]} {fmt(j['mark_ms'][0])} |"
            )
    revs = sorted({(r["base"], r["var"], r["reps"]) for r in runs})
    head = "; ".join(f"`{b}` → `{v}`, {n} reps" for b, v, n in revs)
    if flags["❌"]:
        summary = "❌ **PR and base compute different results:** " + ", ".join(flags["❌"]) + "\n\n"
    else:
        summary = ""
    if flags["🔴"]:
        summary += "🔴 **Possible regression:** " + ", ".join(flags["🔴"])
    else:
        summary += "No regression past the noise."
    if flags["🟢"]:
        summary += "  🟢 Faster: " + ", ".join(flags["🟢"])
    return "\n".join([
        MARKER,
        "### Performance against the base branch",
        "",
        summary,
        "",
        "| Bench | Runner | Wall time | Δ time [95% CI] | Σ mark | Δ mark [95% CI] |",
        "|---|---|---:|---:|---:|---:|",
        *rows,
        "",
        f"<sub>{head}. crystal-metric, base and PR built on the same runner and run "
        f"interleaved in random order, a fresh process per run. Δ is the ratio of medians; "
        f"🔴/🟢 only when the whole interval is past ±{THRESHOLDS['time_s']:.0%} (time) or "
        f"±{THRESHOLDS['mark_ms']:.0%} (mark, judged from {FLOORS['mark_ms']:.0f} ms up). Timings never fail the build; ❌ (PR and base computing different results) does. "
        f"Reproduce with `bench/runner_ab/ab.sh`.</sub>",
        *([f"<sub>{', '.join(sorted(drift))}: the checksum differs from the suite's expected value "
           f"identically in both arms, which is the toolchain, not this PR.</sub>"] if drift else []),
    ])


def self_test():
    """The verdict rule on synthetic runs shaped like the runners' (2% spread on
    time, 10 reps): how often it cries wolf on A/A, and how often it sees a
    real 10% slowdown."""
    rng = random.Random(1)

    def run(shift, n=10, sd=0.02):
        draw = lambda k: [1.0 * k * rng.gauss(1, sd) for _ in range(n)]
        return {"base": {"time_s": draw(1), "mark_ms": draw(1)}, "var": {"time_s": draw(1 + shift), "mark_ms": draw(1 + shift)}}

    trials = 300
    false_red = sum(judge(run(0.0), rng)["time_s"][1] != "⚪" for _ in range(trials)) / trials
    seen = sum(judge(run(0.10), rng)["time_s"][1] == "🔴" for _ in range(trials)) / trials
    faster = sum(judge(run(-0.10), rng)["time_s"][1] == "🟢" for _ in range(trials)) / trials
    print(f"A/A flagged {false_red:.1%}; +10% seen {seen:.1%}; -10% seen {faster:.1%} ({trials} trials each)")
    assert false_red <= 0.02, false_red
    assert seen >= 0.95 and faster >= 0.95, (seen, faster)
    assert verdict(None, 0.03) == "⚪"
    print(render([{"runner": "synthetic", "base": "aaaaaaa", "var": "bbbbbbb", "reps": 10, "benches": {"AA": run(0.0), "Slow": run(0.10)}}]))


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        print(render([json.load(open(p)) for p in sys.argv[1:]]))
