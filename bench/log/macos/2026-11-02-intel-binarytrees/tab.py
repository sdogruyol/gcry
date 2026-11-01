#!/usr/bin/env python3
# tab.py RUN...: Binarytrees' timed section per arm against base and var,
# median of per-rep paired ratios [IQR], one column per session; plus Nbody's
# var against base. A RUN is a `gh run download` directory (one session per
# subdirectory) or a run id whose sessions are runs/<id>-s<N>.json here.
import json, glob, os, statistics as st, sys
def q(v):
    v = sorted(v); a = st.quantiles(v, n=4, method="inclusive"); return a[1], a[0], a[2]
def pr(runs, a, ref, bench):
    xs = {r["rep"]: r["time"] for r in runs if r["arm"] == a and r["bench"] == bench and r.get("time")}
    ys = {r["rep"]: r["time"] for r in runs if r["arm"] == ref and r["bench"] == bench and r.get("time")}
    return q([xs[k] / ys[k] - 1 for k in xs if k in ys])
for root in sys.argv[1:]:
    sess = sorted(glob.glob(os.path.join(root, "*", "runs.json"))) or \
        sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "runs", f"{root}-s*.json")))
    ds = [json.load(open(s)) for s in sess]
    rid = os.path.basename(root.rstrip("/")).split("-")[-1]
    print(f"\n{rid}: Binarytrees, timed section, against base / against var\n")
    print("| arm | " + " | ".join(f"session {i+1}" for i in range(len(ds))) + " |")
    print("|---|" + "---|" * len(ds))
    for a in ds[0]["arms"]:
        cells = []
        for d in ds:
            b = pr(d["runs"], a, "base", "Binarytrees") if a != "base" else None
            v = pr(d["runs"], a, "var", "Binarytrees") if a != "var" else None
            f = lambda t: "—" if t is None else f"{t[0]*100:+.1f}% [{t[1]*100:+.1f}, {t[2]*100:+.1f}]"
            cells.append(f"{f(b)} / {f(v) if v is None else f'{v[0]*100:+.1f}%'}")
        print(f"| {a} | " + " | ".join(cells) + " |")
    if "Nbody" in ds[0]["benches"]:
        print("\nNbody var against base: " + ", ".join(f"{(t:=pr(d['runs'],'var','base','Nbody'))[0]*100:+.1f}% [{t[1]*100:+.1f}, {t[2]*100:+.1f}]" for d in ds))
