#!/usr/bin/env python3
# Per code phase over one probe-win-rows placement artifact (runs.json + syms/):
# each arm's timed-section median grouped by where its code lands mod 64, taken
# as `Revcomp#revcomp`'s address mod 64 from the arm's link map (a prepad moves
# all of the program's code by the same amount, so one function stands for the
# shift of everything after gcry's code). Prints, per bench, the 0.40 (var-code)
# and 0.39.0 (base-code) medians at each phase, and each tree's range.
import json, re, statistics as st, sys, pathlib

def phase(syms, arm):
    s = (syms / f"ab-{arm}.txt").read_text(errors='replace')
    m = re.search(r'\.2A\.Revcomp\.23\.revcomp\S*\s+([0-9a-f]{16})', s)
    return int(m.group(1), 16) % 64

def main(dirpath, key='time'):
    d = pathlib.Path(dirpath)
    j = json.load(open(d / 'runs.json'))
    runs = [x for x in j['runs'] if x.get(key) is not None]
    arms = [a for a in j['arms'] if a in ('var', 'base') or a.startswith(('prepad', 'baseprepad'))]
    ph = {a: phase(d / 'syms', a) for a in arms}
    print(f"{d.name}: " + ', '.join(f"{a} {ph[a]}" for a in arms))
    print(f"| bench | phase 0: 0.40 / 0.39.0 | 16 | 32 | 48 | 0.40 range | 0.39.0 range |")
    print("|---|---|---|---|---|---|---|")
    for b in j['benches']:
        med = {a: st.median(x[key] for x in runs if x['bench'] == b and x['arm'] == a) for a in arms}
        cells = []
        for p in (0, 16, 32, 48):
            v = [f"{med[a]:.3f}" for a in arms if ph[a] == p and not a.startswith('base')]
            bb = [f"{med[a]:.3f}" for a in arms if ph[a] == p and a.startswith('base')]
            cells.append(f"{', '.join(v) or '—'} / {', '.join(bb) or '—'}")
        vr = [med[a] for a in arms if not a.startswith('base')]
        br = [med[a] for a in arms if a.startswith('base')]
        print(f"| {b} | " + ' | '.join(cells) + f" | {min(vr):.3f}–{max(vr):.3f} | {min(br):.3f}–{max(br):.3f} |")
    print()

if __name__ == '__main__':
    key = 'wall' if '--wall' in sys.argv else 'time'
    for p in [a for a in sys.argv[1:] if not a.startswith('--')]:
        main(p, key)
