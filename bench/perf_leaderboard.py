#!/usr/bin/env python3
"""Per-release perf leaderboard from CI's own perf-smoke summaries.

Every CI push run on master uploads `summary.json` (gcry as % of Boehm on Kemal
`/` and `/json`, peak RSS ratio, pause p50) from the perf smoke job. One run is
noisy — a hosted runner's `/json` ratio moves by several points between
identical commits, macOS by ~15 — so a release is not scored by its tag run.
It is scored by every run in its development window: the commits after the
previous tag up to and including its own, which is the code converging on it.
Median and interquartile range, with n, so a thin window reads as thin.

    bench/perf_leaderboard.py                     # writes bench/leaderboard.md
    bench/perf_leaderboard.py --out /dev/stdout

Summaries are cached by run id (`--cache`); a rerun only downloads new runs.
Artifacts expire after 90 days, so the cache is also what keeps old windows.
"""
import argparse, io, json, os, statistics, subprocess, sys, zipfile

REPO = "sdogruyol/gcry"
ARTIFACTS = {"linux": "perf-smoke-report", "macos": "perf-smoke-report-macos"}


def gh(*args, binary=False):
    out = subprocess.run(["gh", *args], check=True, capture_output=True)
    return out.stdout if binary else out.stdout.decode()


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def master_runs():
    runs = []
    page = 1
    while True:
        data = json.loads(gh("api", f"repos/{REPO}/actions/workflows/ci.yml/runs"
                                    f"?branch=master&event=push&per_page=100&page={page}"))
        batch = data["workflow_runs"]
        if not batch:
            return runs
        runs += [(r["id"], r["head_sha"]) for r in batch]
        page += 1


def summary(cache, run_id, platform):
    path = os.path.join(cache, f"{run_id}-{platform}.json")
    if os.path.exists(path):
        text = open(path).read()
        return json.loads(text) if text else None
    found = None
    arts = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run_id}/artifacts"))["artifacts"]
    for a in arts:
        if a["name"] == ARTIFACTS[platform] and not a["expired"]:
            blob = gh("api", f"repos/{REPO}/actions/artifacts/{a['id']}/zip", binary=True)
            with zipfile.ZipFile(io.BytesIO(blob)) as z:
                if "summary.json" in z.namelist():
                    found = json.loads(z.read("summary.json"))
            break
    # Cache a miss too once the run has uploaded anything: a finished run
    # without this artifact never grows one. A run still in flight has none.
    if found is not None or arts:
        open(path, "w").write(json.dumps(found) if found else "")
    return found


def windows():
    """sha -> release name; commits after the last tag map to 'unreleased'."""
    tags = git("tag", "--sort=creatordate").split()
    owner = {}
    prev = None
    for tag in tags:
        rng = f"{prev}..{tag}" if prev else tag
        for sha in git("rev-list", rng).split():
            owner.setdefault(sha, tag)
        prev = tag
    for sha in git("rev-list", f"{prev}..origin/master").split():
        owner.setdefault(sha, "unreleased")
    dates = {t: git("log", "-1", "--format=%as", t).strip() for t in tags}
    return tags, owner, dates


def q(values):
    s = sorted(values)
    if len(s) < 4:
        return statistics.median(s), None
    qs = statistics.quantiles(s, n=4)
    return statistics.median(s), (qs[0], qs[2])


def cell(values, fmt):
    if not values:
        return "—"
    med, iqr = q(values)
    if iqr is None:
        return fmt.format(med)
    return f"{fmt.format(med)} [{fmt.format(iqr[0])}–{fmt.format(iqr[1])}]"


def table(rows_by_release, order, dates, platform):
    lines = [f"### {platform}", "",
             "| release | date | runs | `/json` % of Boehm | `/` % of Boehm | peak RSS × Boehm | pause p50 ms | layout |",
             "|---|---|---|---|---|---|---|---|"]
    for rel in order:
        rows = rows_by_release.get(rel, [])
        if not rows:
            continue
        layouts = sorted({r.get("layout", "?") for r in rows})
        lines.append("| {} | {} | {} | {} | {} | {} | {} | {} |".format(
            rel, dates.get(rel, ""), len(rows),
            cell([r["pct_json"] for r in rows if "pct_json" in r], "{:.1f}"),
            cell([r["pct_root"] for r in rows if "pct_root" in r], "{:.1f}"),
            cell([r["rss_x"] for r in rows if "rss_x" in r], "{:.2f}"),
            cell([r["pause_p50_ms"] for r in rows if "pause_p50_ms" in r], "{:.2f}"),
            ", ".join(layouts)))
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="bench/leaderboard.md")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/gcry-leaderboard"))
    args = ap.parse_args()
    os.makedirs(args.cache, exist_ok=True)

    tags, owner, dates = windows()
    runs = master_runs()
    by_platform = {p: {} for p in ARTIFACTS}
    unmapped = 0
    for run_id, sha in runs:
        rel = owner.get(sha)
        if rel is None:
            unmapped += 1
            continue
        for platform in ARTIFACTS:
            s = summary(args.cache, run_id, platform)
            if s:
                by_platform[platform].setdefault(rel, []).append(s)

    order = ["unreleased"] + list(reversed(tags))
    out = ["# Performance by release", "",
           "Generated by `bench/perf_leaderboard.py` from the perf smoke job's `summary.json`",
           "on every CI push run to master. A release is scored over its **development",
           "window** — every run on a commit after the previous tag up to and including",
           "its own — as a median with the interquartile range in brackets (shown from",
           "four runs up). Hosted runners are noisy, so read the ranges, not the medians",
           "alone; the controlled numbers are the paired A/Bs under `bench/log/`.",
           "", "Kemal, `wrk` 5 s × 50 connections, 3 runs per arm, gcry and Boehm on the same",
           "runner in the same job. `unreleased` is master since the last tag.", ""]
    for platform in ARTIFACTS:
        out += table(by_platform[platform], order, dates, platform) + [""]
    out.append(f"{len(runs)} runs listed, {unmapped} on commits no longer on master.")
    text = "\n".join(out) + "\n"
    if args.out == "/dev/stdout":
        sys.stdout.write(text)
    else:
        open(args.out, "w").write(text)
        print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
