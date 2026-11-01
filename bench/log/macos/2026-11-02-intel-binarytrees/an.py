#!/usr/bin/env python3
# an.py RUNS.JSON [REF=base]: per bench and arm, medians (time, wall, user,
# kernel, faults, Σ mark, collections, time − Σ mark) and each arm's paired
# per-rep ratio against REF and against var: median [IQR].
import json, sys, statistics as st

def q(v):
    v = sorted(v)
    if not v:
        return None
    qs = st.quantiles(v, n=4, method="inclusive") if len(v) > 1 else [v[0]] * 3
    return qs[1], qs[0], qs[2]

def fmt(t):
    return "—" if t is None else f"{t[0]*100:+.1f}% [{t[1]*100:+.1f}, {t[2]*100:+.1f}]"

def paired(runs, a, ref, key):
    xs = {r["rep"]: r for r in runs if r["arm"] == a}
    ys = {r["rep"]: r for r in runs if r["arm"] == ref}
    v = [key(xs[k]) / key(ys[k]) - 1 for k in xs if k in ys and key(ys[k])]
    return q(v)

d = json.load(open(sys.argv[1]))
ref = sys.argv[2] if len(sys.argv) > 2 else "base"
arms = list(d["arms"])
for b in d["benches"]:
    runs = [r for r in d["runs"] if r["bench"] == b and r.get("time") is not None and r["rc"] == 0]
    print(f"\n### {b}\n")
    print(f"| arm | time | user | kernel | faults | Σ mark ms | Σ pause ms | collections | time−gc | time vs {ref} | user vs {ref} | time−gc vs {ref} | time vs var |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    tm = lambda r: r["time"] - ((r["pause"] if r.get("pause") is not None else r["mark"]) or 0) / 1e3
    for a in arms:
        v = [r for r in runs if r["arm"] == a]
        if not v:
            continue
        m = lambda k: st.median([r[k] for r in v if r.get(k) is not None] or [0])
        print(f"| {a} | {m('time'):.3f} | {m('utime'):.3f} | {m('stime'):.3f} | {m('faults'):.0f} | {m('mark'):.1f} | {m('pause'):.1f} | {m('collections'):.0f} | {st.median(map(tm, v)):.3f} | "
              f"{fmt(paired(runs, a, ref, lambda r: r['time'])) if a != ref else '—'} | {fmt(paired(runs, a, ref, lambda r: r['utime'])) if a != ref else '—'} | "
              f"{fmt(paired(runs, a, ref, tm)) if a != ref else '—'} | {fmt(paired(runs, a, 'var', lambda r: r['time'])) if a != 'var' else '—'} |")
