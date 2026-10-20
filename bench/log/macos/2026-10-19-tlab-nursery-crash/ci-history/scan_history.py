import json, subprocess, concurrent.futures as cf, re, os
runs = [int(x) for x in open('failed_runs.txt').read().split()]
STEPS = ('Process-GC nursery+TLAB minor smoke', 'Linux gates on Darwin')
def jobs(rid):
    try:
        out = subprocess.run(['gh','api',f'repos/sdogruyol/gcry/actions/runs/{rid}/jobs?per_page=100&filter=all','--paginate','-q','.jobs[] | {id, name, conclusion, steps: [.steps[] | select(.conclusion=="failure") | .name]}'],capture_output=True,text=True,timeout=120).stdout
    except Exception as e:
        return rid, []
    res=[]
    for line in out.splitlines():
        j=json.loads(line)
        if j['conclusion']=='failure' and any(s.startswith(STEPS) for s in j['steps']):
            res.append((j['id'], j['name'], j['steps']))
    return rid, res
cand=[]
with cf.ThreadPoolExecutor(8) as ex:
    for rid,res in ex.map(jobs, runs):
        for r in res: cand.append((rid,)+r)
json.dump(cand, open('cand_jobs.json','w'))
print(len(cand))
os.makedirs('joblogs', exist_ok=True)
def fetch(c):
    rid,jid,name,steps=c
    p=f'joblogs/{jid}.log'
    if not os.path.exists(p):
        subprocess.run(['gh','api',f'repos/sdogruyol/gcry/actions/jobs/{jid}/logs'],stdout=open(p,'w'),stderr=subprocess.DEVNULL,timeout=180)
    txt=open(p,errors='replace').read()
    hit = 'nursery_tlab_smoke' in txt and re.search(r'nursery_tlab_smoke\n|make: \*\*\* \[nursery-tlab-smoke\]|nursery-tlab-smoke\] Error|Makefile:\d+: nursery-tlab-smoke', txt)
    return c, bool(hit)
with cf.ThreadPoolExecutor(6) as ex:
    for c,hit in ex.map(fetch,cand):
        if hit: print('HIT', c)
