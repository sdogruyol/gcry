import json, subprocess, concurrent.futures as cf, os
runs=[x for x in json.load(open('runs.json')) if x['createdAt']>='2026-09-30']
def jobs(r):
    out=subprocess.run(['gh','api',f"repos/sdogruyol/gcry/actions/runs/{r['databaseId']}/jobs?per_page=100&filter=all",'--paginate','-q','.jobs[] | select(.name|test("gates")) | {id,name,conclusion,started_at, steps:[.steps[]|{name,conclusion}]} | tojson'],capture_output=True,text=True,timeout=120).stdout
    res=[]
    for l in out.splitlines():
        try: res.append(json.loads(l))
        except Exception: print('bad', r['databaseId'], l[:80])
    return r,res
res=[]
with cf.ThreadPoolExecutor(8) as ex:
    for r,js in ex.map(jobs,runs):
        for j in js: res.append({'run':r['databaseId'],'sha':r['headSha'],'created':r['createdAt'],**j})
json.dump(res,open('gates_jobs.json','w'))
print(len(res))
