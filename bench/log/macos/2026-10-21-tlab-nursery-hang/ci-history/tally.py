#!/usr/bin/env python3
# Tally step_outcomes.json: runs per era of the Darwin `TLAB+nursery sampler`
# step, and every run that failed, stalled or was classified upstream. Eras by
# what the job's tree contains — master's history was rewritten on 2026-10-15
# (233b3ad6), so ancestry does not cross it: the pthread list-lock fix
# (9c19480 resolved every port and bound before the first suspend, through
# `reserve_stop_entries` in darwin_stw.cr) and the scan_stack: false fix
# (a00f5c47, `other_stacks_are_roots?` in collect.cr). Run inside a gcry clone
# with the PR heads fetched.
import json, re, subprocess, sys, collections

O = sorted(json.load(open(sys.argv[1] if len(sys.argv) > 1 else 'step_outcomes.json')), key=lambda r: r['created'])
new = re.compile(r'tlab-nursery-sample: (\d+) tlab\+nursery \+ (\d+) tlab-only runs, (\d+) failed(?:, (\d+) stalled, (\d+) upstream[^,]*)?, (\d+) without')
old = re.compile(r'tlab-nursery-sample: (\d+) runs, (\d+) crashed, (\d+) without')
MARKERS = {'pthread': ('src/gcry/platform/darwin_stw.cr', 'reserve_stop_entries'),
           'scan_stack': ('src/gcry/collect.cr', 'other_stacks_are_roots?')}


def has(fix, sha):
    path, marker = MARKERS[fix]
    p = subprocess.run(['git', 'show', f'{sha}:{path}'], capture_output=True, text=True)
    return None if p.returncode else marker in p.stdout  # None: sha not fetched


tot = collections.defaultdict(collections.Counter)
events = []
for r in O:
    m = n = None
    for l in r['lines']:
        m = new.search(l) or m
        n = old.search(l) or n
    era = 'pre-pthread-fix'
    a = has('pthread', r['sha'])
    if a is None:
        era = 'unknown'
    elif a:
        era = 'post-scan_stack-fix' if has('scan_stack', r['sha']) else 'pthread-fix..v0.37'
    t = tot[era]
    if m:
        a_, b_, f, st, up, un = m.groups()
        runs = int(a_) + int(b_)
        t['steps'] += 1; t['runs'] += runs; t['failed'] += int(f); t['unengaged'] += int(un)
        if st is not None:
            t['bounded_runs'] += runs; t['stalled'] += int(st); t['upstream'] += int(up)
        if int(f) or (st and int(st)) or (up and int(up)) or int(un):
            events.append((r['created'][:16], r['run'], r['job'], r['sha'][:8], era, f'failed={f} stalled={st} upstream={up}'))
    elif n:
        runs, f, un = map(int, n.groups())
        t['steps'] += 1; t['runs'] += runs; t['failed'] += int(f)
        if f:
            events.append((r['created'][:16], r['run'], r['job'], r['sha'][:8], era, f'crashed={f}'))
    else:
        dur = r['step_started'] + '..' + r['step_completed']
        events.append((r['created'][:16], r['run'], r['job'], r['sha'][:8], era, f"no summary: job {r['job_conclusion']}, step {r['step_conclusion']} {dur}"))
        t['no_summary'] += 1

for era in ('pre-pthread-fix', 'pthread-fix..v0.37', 'post-scan_stack-fix', 'unknown'):
    if era in tot:
        print(f'{era:22s}', dict(tot[era]))
print('events:')
for e in events:
    print(' ', *e)
