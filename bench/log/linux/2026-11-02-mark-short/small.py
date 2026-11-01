#!/usr/bin/env python3
"""small.py TRIALS N EVICT_MIB VARIANT...: interleaved runs of `main_mark small N EVICT`, Σ mark_ns and
median mark_ns per explicit collection from GCRY_TRACE, per variant."""
import sys, os, subprocess, json, random, statistics
S = os.environ.get('MS_SCRATCH', '.') + '/micro'
trials, n, ev, vs = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4:]
res = {v: [] for v in vs}
for t in range(trials):
    order = vs[:]; random.shuffle(order)
    for v in order:
        tf = f'{S}/tr-small.ndjson'
        if os.path.exists(tf): os.unlink(tf)
        env = dict(os.environ, GCRY_TRACE='1', GCRY_TRACE_FILE=tf, GCRY_TRACE_ALLOC_SAMPLE='0')
        subprocess.run(['taskset', '-c', '0-3', f'{S}/mm-{v}', 'small', n, ev], env=env, stdout=subprocess.DEVNULL, check=True)
        rs = [json.loads(l) for l in open(tf) if '"collect_end"' in l][-int(n):]
        res[v].append((sum(d['mark_ns'] for d in rs) / 1e6, statistics.median(d['mark_ns'] for d in rs) / 1e3,
                       statistics.median(d['scanned_bytes'] for d in rs)))
for v in vs:
    s = [x[0] for x in res[v]]; m = [x[1] for x in res[v]]
    print(f'{v:6} Σmark {statistics.median(s):7.3f} ms ({min(s):.3f}-{max(s):.3f})  per collection {statistics.median(m):6.2f} us ({min(m):.2f}-{max(m):.2f})  scanned {res[v][0][2]/1024:.0f} KiB')
