"""Which hot functions' placement explains the arms' speeds?

usage: phase_classes.py EFFECTS.json PHASES.json [--mod 64] [--ir TOP.tsv]

EFFECTS.json is effects.py's output (per run label, per arm, per-trial
effects); PHASES.json is fn_phases.py's (per function, per arm: address,
size, layout signature). For each function, arms are grouped by (layout
signature, address mod MOD): arms in one group lay that function out the same
way against cache lines. If the function's placement is what sets the speed,
arms in one group run at the same speed. Every function after a placement pad
moves with it, so functions fall into a few classes that group the arms the
same way; per class this prints the grouping, R² of the arms' median effects
explained by the grouping (and adjusted for the number of groups) in each
run, the largest spread inside one group, and its functions ranked by
instructions per request (`--ir`: name<TAB>Ir per request, from callgrind).
"""
import argparse, json, statistics


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("effects")
    ap.add_argument("phases")
    ap.add_argument("--mod", type=int, default=64)
    ap.add_argument("--ir", default=None)
    a = ap.parse_args()
    eff = json.load(open(a.effects))
    ph = json.load(open(a.phases))
    ir = {}
    if a.ir:
        for line in open(a.ir):
            n, v = line.rstrip("\n").rsplit("\t", 1)
            ir[n] = float(v)
    med = {r: {arm: statistics.median(xs) for arm, xs in e.items()} for r, e in eff.items()}
    arms = sorted(set.intersection(*(set(m) for m in med.values())))
    classes = {}
    for fn, per in ph.items():
        if not all(arm in per for arm in arms):
            continue
        g = {}
        for arm in arms:
            addr, _, sig = per[arm]
            g.setdefault((sig, addr % a.mod), []).append(arm)
        key = tuple(sorted(tuple(sorted(v)) for v in g.values()))
        classes.setdefault(key, []).append(fn)
    n = len(arms)
    for key, fns in sorted(classes.items(), key=lambda kv: -sum(ir.get(f, 0) for f in kv[1])):
        k = len(key)
        cells = []
        for r, m in med.items():
            v = [m[arm] for arm in arms]
            mu = statistics.mean(v)
            sst = sum((x - mu) ** 2 for x in v)
            ssw = sum(sum((m[x] - statistics.mean(m[y] for y in grp)) ** 2 for x in grp) for grp in key)
            r2 = 1 - ssw / sst
            adj = 1 - (1 - r2) * (n - 1) / (n - k) if n > k else float("nan")
            spread = max(max(m[x] for x in grp) - min(m[x] for x in grp) for grp in key)
            cells.append(f"{r}: R² {r2:.2f} (adj. {adj:.2f}), widest group {spread:.1f} pts")
        print(f"\n### {k} groups; {sum(ir.get(f, 0) for f in fns):.0f} Ir/request in its {len(fns)} hot functions")
        print("groups: " + "; ".join("{" + ", ".join(grp) + "}" for grp in key))
        for c in cells:
            print(f"- {c}")
        for f in sorted(fns, key=lambda f: -ir.get(f, 0))[:12]:
            print(f"  - {ir.get(f, 0):6.0f} `{f[:100]}`")


if __name__ == "__main__":
    main()
