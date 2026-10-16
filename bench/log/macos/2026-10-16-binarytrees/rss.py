"""The macOS RSS-budget candidates, one table per runner: rss.py DIR_A DIR_B

DIR_A is the `perf-ab-<runner>` artifact of the pacing run (probe-rss-a:
`base` = the tip, Darwin pace max 300; `var` = pace max 100; `var_env` =
`GCRY_THRESHOLD_PACE=200` on `var`), DIR_B of the floor run (probe-rss-b:
`var` = 8 MiB Darwin floor; `var_env` = 8 MiB floor and pace 100). Cells:
speed as % of Boehm (whole-process wall, Boehm / arm) and peak resident size
× Boehm, medians of per-rep paired ratios, and every arm's wall against its
own run's `base` [IQR]. Boehm and `base` are in both runs; the table uses
run A's.
"""
import json, os, statistics, sys

med = statistics.median


def quart(xs):
    q = statistics.quantiles(xs, n=4, method="inclusive") if len(xs) > 1 else [xs[0]] * 3
    return q[0], med(xs), q[2]


def load(d):
    runs = json.load(open(os.path.join(d, "runs.json")))
    by = {}
    for r in runs["runs"]:
        by.setdefault((r["bench"], r["arm"]), {})[r["rep"]] = r
    return runs["benches"], by


arms = [("A", "base", "pace 300 (tip)"), ("A", "var_env", "pace 200"), ("A", "var", "pace 100"),
        ("B", "var", "floor 8, pace 300"), ("B", "var_env", "floor 8, pace 100")]
data = {"A": load(sys.argv[1]), "B": load(sys.argv[2])}
benches = data["A"][0]
print("| bench | Boehm | " + " | ".join(a[2] for a in arms) + " |")
print("|---|---:|" + "---:|" * len(arms))
worst = {a[2]: 0.0 for a in arms}
for b in benches:
    bo = data["A"][1][(b, "boehm")]
    cells = [f"{med(r['wall'] for r in bo.values()):.2f} s, {med(r['peak'] for r in bo.values()) / 2**20:.0f} MiB"]
    for run, arm, label in arms:
        by = data[run][1]
        rb, ra, rbase = by[(b, "boehm")], by[(b, arm)], by[(b, "base")]
        reps = sorted(set(rb) & set(ra) & set(rbase))
        sp = med([100 * rb[i]["wall"] / ra[i]["wall"] for i in reps])
        pk = med([ra[i]["peak"] / rb[i]["peak"] for i in reps])
        worst[label] = max(worst[label], pk)
        vb = quart([ra[i]["wall"] / rbase[i]["wall"] - 1 for i in reps])
        vs = "" if arm == "base" else f", {vb[1]:+.1%} [{vb[0]:+.1%}, {vb[2]:+.1%}]"
        cells.append(f"{sp:.0f}% / {pk:.2f}×{vs}")
    print(f"| {b} | " + " | ".join(cells) + " |")
print("| worst peak × Boehm | | " + " | ".join(f"{worst[a[2]]:.2f}×" for a in arms) + " |")
for run, d in (("A", sys.argv[1]), ("B", sys.argv[2])):
    p = os.path.join(d, "kemal-summary.md")
    if os.path.exists(p):
        print(f"\nKemal, run {run} (`base` = tip, `var` = {'pace 100' if run == 'A' else 'floor 8 MiB'}):\n")
        print(open(p).read().strip())
