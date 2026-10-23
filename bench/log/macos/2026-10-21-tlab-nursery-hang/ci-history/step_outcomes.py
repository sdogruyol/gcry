#!/usr/bin/env python3
# What each Darwin `TLAB+nursery sampler` step actually reported. The step is
# `continue-on-error: true`, so the jobs API calls a red step "success"; only
# the log says. For every job in sampler_jobs.json whose step ran, fetch the
# job log and keep the make target's summary line ("tlab-nursery-sample: 30
# tlab+nursery + 10 tlab-only runs, X failed, Y stalled, Z upstream ...") and
# any stall lines. Writes step_outcomes.json.
import json, subprocess, re, concurrent.futures as cf

J = json.load(open('sampler_jobs.json'))
seen, todo = set(), []
for j in J:
    if j['id'] in seen:
        continue
    seen.add(j['id'])
    st = [s for s in j['steps'] if s['name'] == 'TLAB+nursery sampler']
    if st and st[0]['conclusion'] in ('success', 'failure', 'cancelled'):
        todo.append((j, st[0]))

KEEP = re.compile(r'tlab-nursery-sample:|STALLED|STALL CLASSIFIED|STOP-THE-WORLD STALLED|operation was canceled|'
                  r'Run TLAB_NURSERY_RUNS|##\[error\]|tlab-nursery-samples-darwin successfully')


def fetch(item):
    j, st = item
    for attempt in range(4):
        p = subprocess.run(['gh', 'api', f"repos/sdogruyol/gcry/actions/jobs/{j['id']}/logs"],
                           capture_output=True, text=True, timeout=300)
        if p.returncode == 0:
            break
    lines = [l[:400] for l in p.stdout.splitlines() if KEEP.search(l)]
    return {'run': j['run'], 'job': j['id'], 'sha': j['sha'], 'created': j['created'], 'event': j['event'],
            'branch': j['branch'], 'job_conclusion': j['conclusion'], 'step_conclusion': st['conclusion'],
            'step_started': st['started_at'], 'step_completed': st['completed_at'],
            'log_ok': p.returncode == 0, 'lines': lines}


out = []
with cf.ThreadPoolExecutor(8) as ex:
    for r in ex.map(fetch, todo):
        out.append(r)
json.dump(out, open('step_outcomes.json', 'w'))
print(len(out), sum(1 for r in out if not r['log_ok']), 'logs missing')
