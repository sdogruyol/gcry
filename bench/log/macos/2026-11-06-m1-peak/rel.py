#!/usr/bin/env python3
# rel.py runs.json [bench]: per arm, the collection that ends the setup (the GC.collect
# _run calls before the timed section): its scanned MiB and the heap it leaves, medians
# and ranges, against the run's peak.
import json, sys, statistics as st, collections
runs = json.load(open(sys.argv[1])); bench = sys.argv[2] if len(sys.argv) > 2 else 'JsonParsePure'
order = ['v039', 'pre', 'band421', 'hit', 'r86', 'band', 'refin', 'whole', 'drain', 'pth', 'tip', 'tipnog']
print('| arm | runs | collections | setup-end collection scanned MiB | heap after it MiB | peak MiB |')
print('|---|---:|---|---:|---:|---:|')
for a in order:
    v = [r for r in runs if r['bench'] == bench and r['arm'] == a]
    if not v: continue
    sc, hp = [], []
    for r in v:
        e = r['ends']
        mut = [(x['start_ns'] - e[i - 1]['end_ns']) / 1e6 if i and x.get('start_ns') else 0 for i, x in enumerate(e)]
        k = next(i for i, m in enumerate(mut) if m > 200)
        if k + 1 < len(e) and mut[k + 1] < 50: k += 1
        sc.append(e[k]['scanned_bytes'] / 2**20); hp.append(e[k]['heap_size'] / 2**20)
    c = collections.Counter(len(r['ends']) for r in v)
    pk = [r['rss'] / 2**20 for r in v]
    f = lambda xs: f"{st.median(xs):.1f} [{min(xs):.1f}, {max(xs):.1f}]"
    print(f"| {a} | {len(v)} | {', '.join(f'{k}: {n}' for k, n in sorted(c.items()))} | {f(sc)} | {f(hp)} | {st.median(pk):.0f} [{min(pk):.0f}, {max(pk):.0f}] |")
