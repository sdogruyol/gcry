import json, os, statistics as st, sys
# rnpool.py ARTIFACT_DIR: a perf-ab run (bench/runner_ab/ab.py runs.json + syms/) with prepad arms of
# both sides. Per bench: each arm's median wall and timed section, paired % against `base`, and the
# start of GC::malloc_atomic mod 64 in its binary; then the per-rep ratio of the mean over every
# placement of `var` (var, prepadN) to the mean over every placement of `base` (base, baseprepadN).
d = sys.argv[1]
j = json.load(open(os.path.join(d, "runs.json")))
rows = j["runs"]
tree = lambda a: "base" if a.startswith("base") else "var" if a == "var" or a.startswith("prepad") else None


def phase(a):
    p = os.path.join(d, "syms", f"ab-{a}.txt")
    if not os.path.exists(p):
        return "-"
    for l in open(p):
        f = l.split(" ", 2)
        if len(f) == 3 and f[2].startswith("*GC::malloc_atomic<UInt64>"):
            return str(int(f[0], 16) % 64)
    return "?"


for b in j["benches"]:
    rs = [r for r in rows if r["bench"] == b and r.get("time")]
    arms = sorted({r["arm"] for r in rs}, key=lambda a: st.median(r["wall"] for r in rs if r["arm"] == a))
    by = {(r["arm"], r["rep"]): r for r in rs}
    reps = sorted({r["rep"] for r in rs})
    print(f"## {b} ({j['platform']}, {len(reps)} reps)")
    print(f"{'arm':18s} {'wall':>6s} {'timed':>6s}  {'wall vs base':>22s}  mod64")
    for a in arms:
        d_ = [100 * (by[(a, r)]["wall"] / by[("base", r)]["wall"] - 1) for r in reps if (a, r) in by and ("base", r) in by]
        q = st.quantiles(d_, n=4) if len(d_) > 1 else [0, 0, 0]
        print(f"{a:18s} {st.median(r['wall'] for r in rs if r['arm'] == a):6.3f} {st.median(r['time'] for r in rs if r['arm'] == a):6.3f}"
              f"  {st.median(d_):+5.1f}% [{q[0]:+5.1f}, {q[2]:+5.1f}]  {phase(a)}")
    for name, f in (("wall", lambda r: r["wall"]), ("timed", lambda r: r["time"])):
        ratios = []
        for rep in reps:
            m = {}
            for t in ("base", "var"):
                xs = [f(r) for r in rs if r["rep"] == rep and tree(r["arm"]) == t]
                m[t] = st.mean(xs) if xs else None
            if m["base"] and m["var"]:
                ratios.append(100 * (m["var"] / m["base"] - 1))
        q = st.quantiles(ratios, n=4)
        meds = {t: sorted(st.median(f(r) for r in rs if r["arm"] == a) for a in arms if tree(a) == t) for t in ("base", "var")}
        print(f"pooled {name:5s} var vs base: {st.median(ratios):+.2f}% [{q[0]:+.2f}, {q[2]:+.2f}] (min {min(ratios):+.2f}, max {max(ratios):+.2f});"
              f" arm medians base {meds['base'][0]:.3f}-{meds['base'][-1]:.3f} mean {st.mean(meds['base']):.4f},"
              f" var {meds['var'][0]:.3f}-{meds['var'][-1]:.3f} mean {st.mean(meds['var']):.4f}")
    print()
