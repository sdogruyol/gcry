#!/usr/bin/env python3
# export.py RUNID DIR BENCH... > schedules.ndjson: one run per line, each major as
# [collection number, scanned MiB, next threshold MiB, pace %, cycle ms, mutator ms,
# mark ms]; Knuckeotide only its majors at 0.5 MiB scanned or more (`n` counts all).
import json, sys, pathlib
run, root, benches = sys.argv[1], pathlib.Path(sys.argv[2]), set(sys.argv[3:])
for d in sorted(root.glob('probe-*')):
    for r in json.load(open(d / 'runs.json')):
        if r['bench'] not in benches:
            continue
        cs, prev = [], None
        for e in r['ends']:
            cyc = (e['end_ns'] - e['start_ns']) / 1e6 if e.get('start_ns') else None
            mut = (e['start_ns'] - prev) / 1e6 if prev and e.get('start_ns') else None
            if r['bench'] != 'Knuckeotide' or e['scanned_bytes'] >= 2**19:
                cs.append([e['collections'], round(e['scanned_bytes'] / 2**20, 2), round(e['threshold'] / 2**20, 1),
                           e['threshold_pace_pct'], cyc and round(cyc, 2), mut and round(mut, 2),
                           round(e['mark_ns'] / 1e6, 2)])
            prev = e['end_ns']
        print(json.dumps({'run': run, 'runner': d.name[6:], 'bench': r['bench'], 'arm': r['arm'], 'rep': r['rep'],
                          'time': r['time'], 'peak_mib': r['rss'] and round(r['rss'] / 2**20, 1),
                          'n': len(r['ends']), 'collections': cs}, separators=(',', ':')))
