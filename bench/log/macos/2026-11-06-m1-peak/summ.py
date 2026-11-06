#!/usr/bin/env python3
# summ.py runs.json [bench] [ARM...]: per arm collections, peak, time, and the
# median schedule per major (scanned MiB, next threshold MiB, pace %, cycle ms,
# mutator ms, allocated MiB).
import json, statistics as st, sys, collections
runs = json.load(open(sys.argv[1]))
bench = sys.argv[2] if len(sys.argv) > 2 else 'JsonParsePure'
want = sys.argv[3:]
arms = []
for r in runs:
    if r['arm'] not in arms:
        arms.append(r['arm'])
detail = bool(want)
for a in (want or arms):
    v = [r for r in runs if r['bench'] == bench and r['arm'] == a]
    if not v:
        continue
    c = collections.Counter(len(r['ends']) for r in v)
    pk = [r['rss'] / 2**20 for r in v if r['rss']]
    ts = [r['time'] for r in v if r['time']]
    print(f"{a:8} n={len(v)} coll={dict(sorted(c.items()))} peak={st.median(pk):.0f} [{min(pk):.0f},{max(pk):.0f}] time={st.median(ts):.3f}")
    if not detail:
        continue
    for k in sorted(c):
        g = [r for r in v if len(r['ends']) == k]
        print(f"  {k} collections, {len(g)} runs, peak {st.median([r['rss']/2**20 for r in g]):.0f}")
        for i in range(k):
            row = []
            for r in g:
                e = r['ends'][i]
                prev = r['ends'][i - 1]['end_ns'] if i else None
                cyc = (e['end_ns'] - e['start_ns']) / 1e6 if e.get('start_ns') else 0
                mut = (e['start_ns'] - prev) / 1e6 if prev and e.get('start_ns') else 0
                row.append((e['scanned_bytes'] / 2**20, e['threshold'] / 2**20, e['threshold_pace_pct'], cyc, mut,
                            (e['bytes_before_gc'] or 0) / 2**20, e['mark_ns'] / 1e6, e['heap_size'] / 2**20))
            m = [st.median(x) for x in zip(*row)]
            print("    #%2d scan %6.1f thr %6.1f pace %3.0f cyc %6.1f mut %6.1f alloc %6.1f mark %6.1f heap %6.1f" % (i + 1, *m))
