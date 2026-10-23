#!/usr/bin/env python3
# Exposure of the Darwin `TLAB+nursery sampler` step (`test (darwin native)`
# job of ci.yml) since the step was added (db000414, 2026-09-22): every ci.yml
# run's darwin-native job, the step's conclusion and duration.
# Writes sampler_jobs.json; run from this directory after `gh run list -w ci.yml
# -L 4000 --json databaseId,headSha,createdAt,event,conclusion,headBranch,status > runs.json`.
import json, subprocess, concurrent.futures as cf

runs = [x for x in json.load(open('runs.json')) if x['createdAt'] >= '2026-09-22']

def jobs(r):
    q = ('.jobs[] | select(.name=="test (darwin native)") | {id,name,conclusion,started_at,completed_at,'
         'steps:[.steps[]|{name,conclusion,started_at,completed_at}]} | tojson')
    for attempt in range(4):  # the jobs API answers "Server Error" now and then
        p = subprocess.run(['gh', 'api', f"repos/sdogruyol/gcry/actions/runs/{r['databaseId']}/jobs?per_page=100&filter=all",
                            '--paginate', '-q', q], capture_output=True, text=True, timeout=180)
        if p.returncode == 0:
            break
    else:
        print('failed', r['databaseId'], p.stderr[:120])
    res = []
    for line in p.stdout.splitlines():
        try:
            res.append(json.loads(line))
        except Exception:
            print('bad', r['databaseId'], line[:80])
    return r, res


res = []
with cf.ThreadPoolExecutor(8) as ex:
    for r, js in ex.map(jobs, runs):
        for j in js:
            res.append({'run': r['databaseId'], 'sha': r['headSha'], 'created': r['createdAt'],
                        'event': r['event'], 'branch': r['headBranch'], **j})
json.dump(res, open('sampler_jobs.json', 'w'))
print(len(res))
