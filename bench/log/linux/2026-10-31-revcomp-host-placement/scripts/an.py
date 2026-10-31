import json, sys, statistics as st
# an.py SESSDIR [BASE]: per arm, paired % vs BASE (median [q1,q3]) of whole-process wall,
# of the bench's own timed section (`timed`) and of the rest (`setup` = wall - timed), plus
# median/min wall and median peak RSS.
rows = json.load(open(sys.argv[1] + "/runs.json"))
arms = list(dict.fromkeys(r["arm"] for r in rows))
base = sys.argv[2] if len(sys.argv) > 2 else arms[0]


def pair(by, reps, a, f):
    d = [100 * (f(by[(a, r)]) / f(by[(base, r)]) - 1) for r in reps if (a, r) in by and (base, r) in by and f(by[(a, r)]) and f(by[(base, r)])]
    if not d:
        return "      -          "
    q = st.quantiles(d, n=4) if len(d) > 1 else [d[0]] * 3
    return f"{st.median(d):+5.1f}% [{q[0]:+5.1f},{q[2]:+5.1f}]"


for b in dict.fromkeys(r["bench"] for r in rows):
    by = {(r["arm"], r["rep"]): r for r in rows if r["bench"] == b}
    reps = sorted({r["rep"] for r in rows if r["bench"] == b})
    print(f"## {b}: n={len(reps)}, paired vs {base}")
    print(f"{'arm':14s} {'wall med':>8s} {'min':>6s}  {'wall':19s} {'timed':19s} {'setup':19s} {'timed med/min':>13s}  rss MB")
    for a in arms:
        ws = [by[(a, r)]["wall"] for r in reps if (a, r) in by]
        ts = [by[(a, r)]["timed"] for r in reps if (a, r) in by and by[(a, r)].get("timed")]
        tx = f"{st.median(ts):.3f}/{min(ts):.3f}" if ts else "-"
        rss = st.median(by[(a, r)]["rss_kb"] for r in reps if (a, r) in by) / 1024
        print(f"{a:14s} {st.median(ws):8.3f} {min(ws):6.3f}  {pair(by, reps, a, lambda x: x['wall'])} "
              f"{pair(by, reps, a, lambda x: x.get('timed'))} "
              f"{pair(by, reps, a, lambda x: x['wall'] - x['timed'] if x.get('timed') else None)} {tx:>13s}  {rss:.1f}")
