import json, sys, math
from collections import defaultdict
import numpy as np
from scipy import stats

path = sys.argv[1]
rows = [json.loads(l) for l in open(path) if l.strip()]

# derived metrics
for r in rows:
    r["pause_per_gc_us"] = r["pause_total_ms"] * 1000.0 / r["collections"]
    r["mallocs_per_s"] = r["allocs"] / (r["wall_ms"] / 1000.0) / 1e6  # M/s

METRICS = ["ns_per_alloc", "gc_duty_cycle", "phase_mark_us", "rss_kb",
           "pause_per_gc_us", "mallocs_per_s"]
# lower is better for all except mallocs_per_s
LOWER_BETTER = {m: True for m in METRICS}
LOWER_BETTER["mallocs_per_s"] = False

# index[(survival, arm, round)] = row
idx = {}
for r in rows:
    idx[(r["survival"], r["arm"], r["round"])] = r

survivals = sorted({r["survival"] for r in rows})
rounds = sorted({r["round"] for r in rows})
arms = sorted({r["arm"] for r in rows})

print(f"rows={len(rows)} rounds={len(rounds)} arms={arms} survivals={survivals}")

# position balance audit
pos = defaultdict(lambda: defaultdict(int))
for r in rows:
    if r["survival"] == survivals[0]:
        pos[r["arm"]][r["pos"]] += 1
print("\n=== position balance (runs per arm per absolute slot) ===")
for a in arms:
    print(f"  {a:3s} " + " ".join(f"p{p}={pos[a][p]}" for p in sorted(pos[a])))

def paired(surv, treat, ctrl, metric):
    d, tv, cv = [], [], []
    for rd in rounds:
        a = idx.get((surv, treat, rd)); b = idx.get((surv, ctrl, rd))
        if a is None or b is None: continue
        tv.append(a[metric]); cv.append(b[metric]); d.append(a[metric] - b[metric])
    d = np.array(d); tv = np.array(tv); cv = np.array(cv)
    n = len(d)
    m = d.mean(); sd = d.std(ddof=1); se = sd / math.sqrt(n)
    tcrit = stats.t.ppf(0.975, n - 1)
    t = m / se if se > 0 else float("nan")
    p = 2 * (1 - stats.t.cdf(abs(t), n - 1)) if se > 0 else float("nan")
    lo, hi = m - tcrit * se, m + tcrit * se
    better = (d < 0) if LOWER_BETTER[metric] else (d > 0)
    wins = int(better.sum())
    base = cv.mean()
    # MDE at 80% power, two-sided alpha=0.05
    mde = (tcrit + stats.t.ppf(0.80, n - 1)) * se
    return dict(n=n, mean=m, pct=100*m/base if base else float("nan"), sd=sd, se=se,
                t=t, p=p, lo=lo, hi=hi, wins=wins, treat_mean=tv.mean(),
                ctrl_mean=base, mde=mde, mde_pct=100*mde/base if base else float("nan"))

COMPARISONS = [
    ("Q1  RADIX vs OFF",        "R",  "O1"),
    ("Q1b RADIX vs OFF(twin)",  "R",  "O2"),
    ("Q2  RADIX+THP vs RADIX",  "T",  "R"),
    ("NULL OFF vs OFF",         "O2", "O1"),
]

for surv in survivals:
    print(f"\n{'='*100}\nsurvival = {surv}   (duty cycle ~"
          f"{np.mean([r['gc_duty_cycle'] for r in rows if r['survival']==surv]):.1f}%)\n{'='*100}")
    for label, tr, ct in COMPARISONS:
        print(f"\n--- {label} ---")
        print(f"{'metric':<17}{'ctrl':>11}{'treat':>11}{'diff':>11}{'%':>9}"
              f"{'t':>8}{'p':>8}{'95% CI':>26}{'wins':>7}{'MDE':>11}{'MDE%':>8}")
        for m in METRICS:
            s = paired(surv, tr, ct, m)
            ci = f"[{s['lo']:+.3f}, {s['hi']:+.3f}]"
            print(f"{m:<17}{s['ctrl_mean']:>11.3f}{s['treat_mean']:>11.3f}"
                  f"{s['mean']:>+11.3f}{s['pct']:>+9.2f}{s['t']:>8.2f}{s['p']:>8.3f}"
                  f"{ci:>26}{s['wins']:>4}/{s['n']:<2}{s['mde']:>11.3f}{s['mde_pct']:>7.2f}%")

# radix hit-rate sanity
print(f"\n{'='*100}\nradix counters (mean per run)\n{'='*100}")
for surv in survivals:
    for a in arms:
        v = [r for r in rows if r["survival"] == surv and r["arm"] == a]
        f = np.mean([x["radix_fast"] for x in v]); s = np.mean([x["radix_slow"] for x in v])
        tot = f + s
        print(f"  surv={surv} arm={a:3s} fast={f:>14,.0f} slow={s:>10,.0f} "
              f"fast_frac={(f/tot if tot else 0):.6f}")
