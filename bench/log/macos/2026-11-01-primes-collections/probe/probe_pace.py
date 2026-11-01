#!/usr/bin/env python3
# Probe only: probe_pace.py OUT REPS "BENCH..." NAME=BIN... — each rep runs
# every bench under every arm in random order, traced; writes OUT/runs.json
# (wall, the collect_end lines' fields) and prints a summary.
import collections, json, os, random, re, statistics, subprocess, sys

out, reps, benches = sys.argv[1], int(sys.argv[2]), sys.argv[3].split()
arms = dict(a.split('=', 1) for a in sys.argv[4:])
# An arm `NAME=BIN|K=V` runs BIN with K=V set.
extra = {}
for k, v in list(arms.items()):
    if '|' in v:
        arms[k], kv = v.split('|', 1)
        extra[k] = dict([kv.split('=', 1)])
os.makedirs(out, exist_ok=True)
KEYS = ('collections', 'threshold', 'threshold_pace_pct', 'scanned_bytes', 'size_class_live_bytes',
        'pause_ns', 'mark_ns', 'sweep_ns', 'flush_ns')
runs = []
for rep in range(reps):
    for b in benches:
        order = list(arms)
        random.shuffle(order)
        for a in order:
            tf = os.path.join(out, 'trace.ndjson')
            env = dict(os.environ, GCRY_TRACE='1', GCRY_TRACE_ALLOC_SAMPLE='0', GCRY_TRACE_FILE=tf, **extra.get(a, {}))
            p = subprocess.run([arms[a], b], env=env, capture_output=True, text=True)
            m = re.search(r'in ([\d.]+)s', p.stdout + p.stderr)
            ends, starts = [], []
            with open(tf) as f:
                for line in f:
                    try:
                        e = json.loads(line)
                    except ValueError:
                        continue
                    if e.get('event') == 'collect_start':
                        starts.append(e['ts_ns'])
                    elif e.get('event') == 'collect_end':
                        ends.append(dict({k: e.get(k) for k in KEYS}, end_ns=e['ts_ns']))
            for i, e in enumerate(ends):
                e['start_ns'] = starts[i] if i < len(starts) else None
            runs.append({'rep': rep, 'bench': b, 'arm': a, 'rc': p.returncode,
                         'time': float(m.group(1)) if m else None, 'ends': ends})
with open(os.path.join(out, 'runs.json'), 'w') as f:
    json.dump(runs, f)
for b in benches:
    for a in arms:
        v = [r for r in runs if r['bench'] == b and r['arm'] == a]
        c = collections.Counter(len(r['ends']) for r in v)
        t = statistics.median(r['time'] for r in v if r['time'] is not None)
        print(f'{b} {a}: time {t:.3f} collections {dict(sorted(c.items()))}')
        for r in v[:6]:
            print('   ', len(r['ends']), r['time'], [e['threshold_pace_pct'] for e in r['ends']])
