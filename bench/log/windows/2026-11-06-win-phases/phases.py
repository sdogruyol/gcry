#!/usr/bin/env python3
# Per code phase over one probe-win-phases session: an artifact directory
# (runs.json + syms/ + cpu.txt) or its trimmed copy in sessions/ (`--save
# FILE` writes one). Each arm's phase is `Revcomp#revcomp`'s address mod 64 in
# its link map (a prepad moves all of a tree's code by the same amount), as in
# ../2026-11-02-0.40-win-rows/phases.py. Arms are grouped by tree: 0.40 (var,
# prepadN), 0.39.0 (base, baseprepadN) and each AB_REVS checkpoint or
# AB_PATCHES arm (its name less the `p`/`_p` pad suffix). Per bench: each
# tree's median at each phase and its range, then each tree against 0.39.0 at
# the same phase, paired per rep (median [interquartile range] of the ratio's
# percent). `--wall` reads wall time.
#
#   python3 phases.py [--wall] <artifact dir or sessions/*.json>...
#   python3 phases.py --save sessions/<run>-<session>.json <artifact dir>
import json, re, statistics as st, sys, pathlib

COLS = ('arm', 'bench', 'rep', 'time', 'wall', 'utime', 'stime', 'faults', 'peak',
        'collections', 'mark', 'pause')

def phase(syms, arm):
    s = (syms / f"ab-{arm}.txt").read_text(errors='replace')
    m = re.search(r'\.2A\.Revcomp\.23\.revcomp\S*\s+([0-9a-f]{16})', s)
    return int(m.group(1), 16) % 64

def tree(a):
    if a == 'var' or a.startswith('prepad'): return '0.40'
    if a == 'base' or a.startswith('baseprepad'): return '0.39.0'
    return re.sub(r'_?p\d+$', '', a)

def q(xs):
    qs = st.quantiles(xs, n=4, method='inclusive') if len(xs) > 1 else [xs[0]] * 3
    return qs[0], st.median(xs), qs[2]

def load(path):
    d = pathlib.Path(path)
    if d.is_file():
        s = json.load(open(d))
        runs = [dict(zip(s['columns'], r)) for r in s['runs']]
        return s['name'], s['cpu'], s['arms'], s['benches'], s['phase'], runs
    j = json.load(open(d / 'runs.json'))
    cpu = (d / 'cpu.txt').read_text(errors='replace').strip() if (d / 'cpu.txt').exists() else '?'
    arms = [a for a in j['arms'] if a != 'boehm']
    return d.name, cpu, arms, j['benches'], {a: phase(d / 'syms', a) for a in arms}, j['runs']

def save(src, dst):
    _, cpu, arms, benches, ph, runs = load(src)
    out = dict(name=pathlib.Path(dst).stem, cpu=cpu, arms=arms, benches=benches, phase=ph, columns=COLS,
               runs=[[x.get(k) for k in COLS] for x in runs if x['arm'] in arms])
    pathlib.Path(dst).write_text(json.dumps(out, separators=(',', ':')) + '\n')

def main(path, key):
    name, cpu, arms, benches, ph, runs = load(path)
    runs = [x for x in runs if x.get(key) is not None]
    trees = list(dict.fromkeys(tree(a) for a in arms))
    print(f"## {name} ({cpu}), {key}")
    print("arms: " + ', '.join(f"{a} {ph[a]}" for a in arms))
    print()
    for b in benches:
        by = {a: {x['rep']: x for x in runs if x['bench'] == b and x['arm'] == a} for a in arms}
        med = {a: st.median(x[key] for x in by[a].values()) for a in arms if by[a]}
        col = {a: st.median(x['collections'] for x in by[a].values() if x.get('collections') is not None)
               for a in arms if by[a]}
        print(f"### {b}")
        print("| tree | phase 0 | 16 | 32 | 48 | range | phase mean | collections |")
        print("|---|---|---|---|---|---|---|---|")
        for t in trees:
            ta = [a for a in arms if tree(a) == t and a in med]
            cells = [', '.join(f"{med[a]:.3f}" for a in ta if ph[a] == p) or '—' for p in (0, 16, 32, 48)]
            vs = [med[a] for a in ta]
            # each phase the tree reaches counts once (two arms at one phase: their mean)
            pm = st.mean(st.mean(med[a] for a in ta if ph[a] == p) for p in sorted({ph[a] for a in ta}))
            cs = sorted({col[a] for a in ta})
            print(f"| {t} | " + ' | '.join(cells) + f" | {min(vs):.3f}–{max(vs):.3f} | {pm:.3f} | {', '.join(f'{c:g}' for c in cs)} |")
        print()
        base = [a for a in arms if tree(a) == '0.39.0']
        for t in trees:
            if t == '0.39.0': continue
            out = []
            for p in (0, 16, 32, 48):
                xs = []
                for a in (a for a in arms if tree(a) == t and ph[a] == p):
                    for r in (r for r in base if ph[r] == p):
                        xs += [by[a][i][key] / by[r][i][key] - 1 for i in by[a] if i in by[r]]
                if xs:
                    lo, md, hi = q(xs)
                    out.append(f"{p}: {md*100:+.1f}% [{lo*100:+.1f}, {hi*100:+.1f}]")
            allx = []
            for a in (a for a in arms if tree(a) == t):
                for r in (r for r in base if ph[r] == ph[a]):
                    allx += [by[a][i][key] / by[r][i][key] - 1 for i in by[a] if i in by[r]]
            lo, md, hi = q(allx) if allx else (float('nan'),) * 3
            print(f"- {t} vs 0.39.0 at the same phase: " + '; '.join(out) + f"; pooled {md*100:+.1f}% [{lo*100:+.1f}, {hi*100:+.1f}]")
        print()

if __name__ == '__main__':
    if '--save' in sys.argv:
        i = sys.argv.index('--save')
        save(sys.argv[i + 2], sys.argv[i + 1])
        sys.exit()
    key = 'wall' if '--wall' in sys.argv else 'time'
    for p in [a for a in sys.argv[1:] if not a.startswith('--')]:
        main(p, key)
