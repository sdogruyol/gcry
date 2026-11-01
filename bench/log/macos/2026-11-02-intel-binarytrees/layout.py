#!/usr/bin/env python3
# layout.py ARTIFACT_DIR...: per arm, Binarytrees' timed section against
# `base` (median of per-rep paired ratios) in each session, next to where the
# hot path's functions landed in that arm's binary (`syms/`, `nm -n`): the
# address mod 64 and mod 4096, and the distances TreeNode::new → GC::malloc
# and GC::malloc → tlab_alloc_small. An ARTIFACT_DIR holds one session per
# subdirectory (`runs.json`, `syms/`), as `gh run download` leaves them.
import glob, json, os, re, statistics as st, sys

HOT = [
    ("new", "_*Binarytrees::TreeNode::new<Int32, Int32>:Binarytrees::TreeNode"),
    ("check", "_*Binarytrees::TreeNode#check:Int32"),
    ("malloc", "_*GC::malloc<UInt64>:Pointer(Void)"),
    ("tlab", "_*Gcry::Heap#tlab_alloc_small<UInt32, UInt32, Int32, Bool, UInt64>:Pointer(Void)"),
    ("refill", "_*Gcry::Heap#tlab_refill_once<Int32, UInt32, Bool>:Pointer(Void)"),
]


def addresses(path):
    d = {}
    for line in open(path):
        parts = line.rstrip("\n").split(" ", 2)
        if len(parts) == 3 and re.fullmatch(r"[0-9a-f]{16}", parts[0]):
            d[parts[2]] = int(parts[0], 16)
    return d


def paired(runs, arm, ref):
    xs = {r["rep"]: r["time"] for r in runs if r["arm"] == arm}
    ys = {r["rep"]: r["time"] for r in runs if r["arm"] == ref}
    return st.median([xs[k] / ys[k] - 1 for k in xs if k in ys])


cells, syms = {}, {}
for root in sys.argv[1:]:
    for sess in sorted(glob.glob(os.path.join(root, "*", "runs.json"))):
        d = json.load(open(sess))
        runs = [r for r in d["runs"] if r["bench"] == "Binarytrees" and r.get("time")]
        for arm in d["arms"]:
            cells.setdefault(arm, []).append(paired(runs, arm, "base") * 100)
            binary = os.path.basename(d["arms"][arm])
            sym = os.path.join(os.path.dirname(sess), "syms", binary + ".txt")
            if arm not in syms and os.path.exists(sym):
                syms[arm] = addresses(sym)

print("| arm | sessions (time vs base, %) | mean | mod 64 (new check malloc tlab refill) | mod 4096 | new→malloc | malloc→tlab |")
print("|---|---|---:|---|---|---:|---:|")
for arm in sorted(cells, key=lambda a: st.mean(cells[a])):
    s = syms.get(arm)
    if s is None:
        continue
    a = [s[n] for _, n in HOT]
    print(f"| {arm} | {' '.join(f'{x:+.1f}' for x in cells[arm])} | {st.mean(cells[arm]):+.1f} | "
          f"{' '.join(str(x % 64) for x in a)} | {' '.join(str(x % 4096) for x in a)} | {a[2] - a[0]:+d} | {a[3] - a[2]:+d} |")
