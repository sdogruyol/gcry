#!/usr/bin/env python3
# Per-arm table of one bench from the sessions/ files (trimmed runs.json of the
# probe-winbt artifacts): timed-section, wall and user medians, Σ pause, Σ
# stacks phase and Σ mark (ms, from GCRY_TRACE), collections, and the timed
# section against `var` and against `base`, paired per rep (median
# [interquartile range]).
#
#   python3 tab.py sessions/41437353530-w2.json [bench]
import json, sys, statistics as st

def q(xs):
    qs = st.quantiles(xs, n=4, method='inclusive') if len(xs) > 1 else [xs[0]] * 3
    return qs[0], st.median(xs), qs[2]

for path in sys.argv[1:2]:
    j = json.load(open(path))
    bench = sys.argv[2] if len(sys.argv) > 2 else 'Binarytrees'
    cols = j['columns']
    rows = [dict(zip(cols, r)) for r in j['runs']]
    rows = [r for r in rows if r['bench'] == bench and r['time'] is not None]
    print(f"run {j['run']} session {j['session']} ({j['cpu']}), {bench}, {j['reps']} reps")
    print(f"{'arm':18s} {'time':>6s} {'wall':>6s} {'user':>6s} {'pause':>6s} {'stacks':>6s} {'mark':>6s} {'coll':>4s}  {'vs var':24s} vs base")
    by = {}
    for r in rows:
        by.setdefault(r['arm'], {})[r['rep']] = r
    for a in j['arms']:
        ar = by.get(a)
        if not ar:
            continue
        def m(k):
            xs = [v[k] for v in ar.values() if v.get(k) is not None]
            return st.median(xs) if xs else float('nan')
        cells = []
        for ref in ('var', 'base'):
            pr = by.get(ref, {})
            xs = [ar[i]['time'] / pr[i]['time'] - 1 for i in ar if i in pr]
            lo, md, hi = q(xs)
            cells.append('—' if a == ref else f"{md*100:+5.1f}% [{lo*100:+5.1f}, {hi*100:+5.1f}]")
        print(f"{a:18s} {m('time'):6.3f} {m('wall'):6.3f} {m('utime'):6.3f} {m('pause_ms'):6.1f} {m('stacks_ms'):6.2f} {m('mark_ms'):6.1f} {m('collections'):4.0f}  {cells[0]:24s} {cells[1]}")
