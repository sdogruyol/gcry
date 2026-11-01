#!/usr/bin/env python3
# Same-session placement bands over one probe-win-rows artifact (runs.json):
# per bench, each arm's median timed section, wall, Σ mark and collections,
# grouped by tree (var-code: var, prepadN; base-code: base, baseprepadN;
# rev-code: rev, revpN), each group's range, and whether the groups overlap.
# `--equal` adds the medians at each collection count (Primes' step).
import json, sys, statistics as st
from collections import Counter

def tree(a):
    if a == 'var' or a.startswith('prepad'): return 'var'
    if a == 'base' or a.startswith('baseprepad'): return 'base'
    if a == 'rev' or a.startswith('revp'): return 'rev'
    return a

def main(path, equal=False):
    d = json.load(open(path))
    runs = [x for x in d['runs'] if x.get('time') is not None]
    arms = list(d['arms'])
    for b in d['benches']:
        print(f"## {b}")
        print("| arm | tree | time | wall | Σ mark ms | collections | n |")
        print("|---|---|---:|---:|---:|---|---:|")
        groups = {}
        for a in arms:
            rs = [x for x in runs if x['bench'] == b and x['arm'] == a]
            if not rs: continue
            t = st.median(x['time'] for x in rs)
            w = st.median(x['wall'] for x in rs)
            m = st.median(x['mark'] for x in rs) if rs[0].get('mark') is not None else float('nan')
            c = Counter(x.get('collections') for x in rs)
            cs = ', '.join(f"{n}×{k}" for k, n in sorted(c.items(), key=lambda kv: -kv[1]))
            groups.setdefault(tree(a), []).append((a, t, w))
            print(f"| {a} | {tree(a)} | {t:.3f} | {w:.3f} | {m:.1f} | {cs} | {len(rs)} |")
        print()
        for g, xs in groups.items():
            ts = [t for _, t, _ in xs]; ws = [w for _, _, w in xs]
            print(f"- {g}: time {min(ts):.3f}–{max(ts):.3f}, wall {min(ws):.3f}–{max(ws):.3f}")
        if 'var' in groups and 'base' in groups:
            vmin = min(t for _, t, _ in groups['var']); bmax = max(t for _, t, _ in groups['base'])
            print(f"- var-code min {vmin:.3f} {'<=' if vmin <= bmax else '>'} base-code max {bmax:.3f}: "
                  f"{'bands overlap' if vmin <= bmax else 'VAR BAND ABOVE BASE BAND'}")
        if 'rev' in groups and 'var' in groups:
            rmax = max(t for _, t, _ in groups['rev']); vmin = min(t for _, t, _ in groups['var'])
            rmin = min(t for _, t, _ in groups['rev']); vmax = max(t for _, t, _ in groups['var'])
            print(f"- rev-code {rmin:.3f}–{rmax:.3f} against var-code {vmin:.3f}–{vmax:.3f}: "
                  f"{'overlap' if rmin <= vmax and vmin <= rmax else ('REV BELOW' if rmax < vmin else 'REV ABOVE')}")
        if equal:
            counts = sorted({x.get('collections') for x in runs if x['bench'] == b} - {None})
            for c in counts:
                row = []
                for a in arms:
                    ts = [x['time'] for x in runs if x['bench'] == b and x['arm'] == a and x.get('collections') == c]
                    if ts: row.append(f"{a} {st.median(ts):.3f} ({len(ts)})")
                print(f"- at {c} collections: " + '; '.join(row))
        print()

if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    for p in args: main(p, '--equal' in sys.argv)
