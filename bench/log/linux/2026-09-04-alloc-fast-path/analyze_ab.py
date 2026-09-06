#!/usr/bin/env python3
"""Paired analysis of run_kemal_ab.sh trials.

    analyze_ab.py trials.jsonl [reference-arm]

Every round has one trial per arm, so arms are compared pairwise by round:
d_r = x_arm,r / x_ref,r. Reported per arm: mean req/s, mean of the per-round
ratio to the reference (as %), the paired t of the differences, a 95% CI on
the mean difference (t distribution), peak RSS × reference, faults per 1k
requests and CPU ms per 10k requests. A second reference-like arm (e.g. a
second Boehm binary) is the null control: its row is what "no difference"
looks like on this box in this run.
"""
import json, sys, math, statistics as st
path = sys.argv[1]; ref = sys.argv[2] if len(sys.argv) > 2 else "boehm"
rows = [json.loads(l) for l in open(path) if l.startswith("{")]
rows = [r for r in rows if "rps" in r and r["rps"] > 0]
by = {}
for r in rows: by.setdefault(r["arm"], {})[r["round"]] = r
arms = list(by)
refr = by[ref]
# t critical values (two-sided 95%) for df 1..40, then 1.96
TCRIT = {1:12.71,2:4.303,3:3.182,4:2.776,5:2.571,6:2.447,7:2.365,8:2.306,9:2.262,10:2.228,11:2.201,12:2.179,13:2.160,14:2.145,15:2.131,16:2.120,17:2.110,18:2.101,19:2.093,20:2.086,24:2.064,29:2.045,39:2.023}
def tcrit(df):
    for k in sorted(TCRIT):
        if df <= k: return TCRIT[k]
    return 1.96
print(f"{'arm':28}{'n':>3}{'req/s':>9}{'vs ref':>8}{'paired t':>10}{'95% CI of ratio':>18}{'RSS×ref':>9}{'flt/1k':>8}{'cpu ms/10k':>11}")
for a in arms:
    common = sorted(set(by[a]) & set(refr))
    xs = [by[a][r]["rps"] for r in common]; ys = [refr[r]["rps"] for r in common]
    ratios = [x / y for x, y in zip(xs, ys)]
    diffs = [x - y for x, y in zip(xs, ys)]
    n = len(common)
    mean_ratio = st.mean(ratios) * 100
    if a == ref or n < 2:
        t = 0.0; lo = hi = mean_ratio
    else:
        sd = st.stdev(diffs); t = st.mean(diffs) / (sd / math.sqrt(n)) if sd > 0 else float("inf")
        sdr = st.stdev(ratios); h = tcrit(n - 1) * sdr / math.sqrt(n); lo, hi = (st.mean(ratios) - h) * 100, (st.mean(ratios) + h) * 100
    rss = st.mean([by[a][r]["hwm_kb"] for r in common]) / st.mean([refr[r]["hwm_kb"] for r in common])
    flt = st.mean([by[a][r]["minflt"] / by[a][r]["requests"] * 1000 for r in common])
    cpu = st.mean([by[a][r]["cpu_ticks"] * 10 / by[a][r]["requests"] * 10000 for r in common])
    print(f"{a:28}{n:>3}{st.mean(xs):>9.0f}{mean_ratio:>7.1f}%{t:>10.2f}{'[%.1f, %.1f]' % (lo, hi):>18}{rss:>9.2f}{flt:>8.1f}{cpu:>11.0f}")
loads = [r["load1"] for r in rows]
print(f"load average during trials: min {min(loads):.2f} max {max(loads):.2f}")
