#!/usr/bin/env python3
# Keep rule over a perf-ab run dir: rows whose paired timed section or wall (var vs base) is
# slower beyond its interquartile range, and for each the same-session placement band: the
# medians of the var-code arms (var, prepadN) against those of the base-code arms (base,
# baseprepadN). Excused when a var-code median falls inside the base-code range.
import json, sys, statistics as st, pathlib

def paired(r, b, a, key):
    xs = {x['rep']: x[key] for x in r if x['bench'] == b and x['arm'] == a}
    ys = {x['rep']: x[key] for x in r if x['bench'] == b and x['arm'] == 'base'}
    ratios = sorted(xs[k] / ys[k] - 1 for k in xs if k in ys)
    qs = st.quantiles(ratios, n=4, method='inclusive')
    return st.median(ratios), qs[0], qs[2]

for run in sys.argv[1:]:
    for osdir in sorted(pathlib.Path(run).glob('perf-ab-*')):
        d = json.load(open(osdir / 'runs.json'))
        r = [x for x in d['runs'] if x.get('time') is not None]
        varc = [a for a in d['arms'] if a == 'var' or a.startswith('prepad')]
        basec = [a for a in d['arms'] if a == 'base' or a.startswith('baseprepad')]
        for b in d['benches']:
            flags = []
            for key in ('time', 'wall'):
                m, lo, hi = paired(r, b, 'var', key)
                if lo > 0:
                    flags.append(f"{key} {m*100:+.1f}% [{lo*100:+.1f}, {hi*100:+.1f}]")
            med = lambda a, key='time': st.median(x[key] for x in r if x['bench'] == b and x['arm'] == a)
            vm = {a: med(a) for a in varc}
            bm = {a: med(a) for a in basec}
            lo_b, hi_b = min(bm.values()), max(bm.values())
            inside = [a for a, v in vm.items() if lo_b <= v <= hi_b or v < lo_b]
            status = 'ok' if not flags else ('placement' if inside else 'UNEXCUSED')
            fmt = lambda m: ' '.join(f"{a}={v:.3f}" for a, v in m.items())
            m, lo, hi = paired(r, b, 'var', 'peak')
            peak = f"  PEAK {m*100:+.1f}% [{lo*100:+.1f}, {hi*100:+.1f}]" if lo > 0 else ''
            print(f"{osdir.name[8:]:17s} {b:22s} {status:9s} {'; '.join(flags):45s} var-code {fmt(vm)} | base-code {fmt(bm)}{peak}")
