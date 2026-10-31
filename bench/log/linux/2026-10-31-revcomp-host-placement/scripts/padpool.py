import json, sys, statistics as st
# padpool.py SESSDIR BENCH A B: per rep, the mean over every placement arm of tree A (arms named A, Ap<N>)
# against tree B's; prints the per-rep ratio B/A (median, IQR, min, max) for wall, timed and setup,
# and each tree's arm medians (the placement spread).
d, bench, A, B = sys.argv[1:5]
rows = [r for r in json.load(open(d + "/runs.json")) if r["bench"] == bench]
tree = lambda a: A if a == A or a.startswith(A + "p") else B if a == B or a.startswith(B + "p") else None
reps = sorted({r["rep"] for r in rows})
has_t = all(r.get("timed") for r in rows)
for name, f in (("wall", lambda r: r["wall"]), ("timed", lambda r: r["timed"]), ("setup", lambda r: r["wall"] - r["timed"])):
    if name != "wall" and not has_t: continue
    ratios = []
    for rep in reps:
        m = {t: st.mean(f(r) for r in rows if r["rep"] == rep and tree(r["arm"]) == t) for t in (A, B)}
        ratios.append(100 * (m[B] / m[A] - 1))
    q = st.quantiles(ratios, n=4)
    meds = {t: sorted(st.median(f(r) for r in rows if r["arm"] == a) for a in {r["arm"] for r in rows} if tree(a) == t) for t in (A, B)}
    print(f"{name:5s} {B} vs {A}, per-rep pooled-arm ratio: median {st.median(ratios):+.2f}% [{q[0]:+.2f}, {q[2]:+.2f}] min {min(ratios):+.2f} max {max(ratios):+.2f}"
          f" | arm medians {A} {meds[A][0]:.3f}-{meds[A][-1]:.3f} mean {st.mean(meds[A]):.4f}, {B} {meds[B][0]:.3f}-{meds[B][-1]:.3f} mean {st.mean(meds[B]):.4f}")
