import json, os, re, statistics as st, sys
# phase.py SESSDIR [BENCH]: per arm, median timed/wall and GC::malloc_atomic's start address mod 64,
# then timed medians grouped by that phase.
rows0 = [r for r in json.load(open(sys.argv[1] + "/runs.json")) if r["bench"] == (sys.argv[2] if len(sys.argv) > 2 else "Revcomp")]
rows = [dict(r, timed=r.get("timed") or r["wall"]) for r in rows0]
arms = sorted({r["arm"] for r in rows}, key=lambda a: st.median(r["timed"] for r in rows if r["arm"] == a))
def addr(a):
    # An env arm (v039nowipe) runs its tree's binary.
    a = a if os.path.exists(f"syms/{a}.txt") else re.match(r"v03[89](p\d+)?|c\d+", a).group(0)
    for l in open(f"syms/{a}.txt"):
        p = l.split(" ", 2)
        if len(p) == 3 and p[2].startswith("*GC::malloc_atomic<UInt64>"): return int(p[0], 16)
by = {}
for a in arms:
    t = st.median(r["timed"] for r in rows if r["arm"] == a); w = st.median(r["wall"] for r in rows if r["arm"] == a)
    ph = addr(a) % 64; by.setdefault(ph, []).append((t, a))
    print(f"{a:10s} timed {t:.3f} wall {w:.3f}  GC::malloc_atomic @{addr(a):x} mod64={ph}")
for ph in sorted(by): print(f"mod64={ph:2d}: " + ", ".join(f"{a} {t:.3f}" for t, a in sorted(by[ph])))
