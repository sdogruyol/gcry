import json,re
cand=json.load(open('cand_jobs.json'))
runs={r['databaseId']:r for r in json.load(open('runs.json'))}
rows=[]
for rid,jid,name,steps in cand:
    t=open(f'joblogs/{jid}.log',errors='replace').read()
    lines=t.splitlines()
    strip=lambda l: re.sub(r'^\S+Z ','',l)
    L=[strip(l) for l in lines]
    failed_target=None
    for l in L:
        m=re.search(r'make(?:\[\d+\])?: \*\*\* \[(?:Makefile:\d+: )?([\w-]+)\] Error (\d+)',l)
        if m: failed_target=(m.group(1),m.group(2))
    if not failed_target or failed_target[0]!='nursery-tlab-smoke':
        rows.append((rid,jid,name,'other:'+str(failed_target)));continue
    # find smoke section
    i=max(k for k,l in enumerate(L) if l.startswith('GCRY_BITMAP_ALLOC=0 bin/nursery_tlab_smoke'))
    sect=L[i:i+40]
    addr=next((re.search(r'at address (0x[0-9a-f]+)',l).group(1) for l in sect if 'at address' in l),None)
    frames=[re.sub(r'^\[0x[0-9a-f]+\] ','',l).split(' in /')[0] for l in sect if re.match(r'\[0x',l)]
    last=[l for l in sect if l.strip().startswith(('PASS','claim_probe','  PASS','FAIL'))]
    r=runs.get(rid,{})
    rows.append((rid,jid,name,r.get('createdAt'),r.get('headSha','')[:8],r.get('headBranch'),r.get('event'),addr,frames[2:8] if len(frames)>2 else frames,[s.strip() for s in sect if s.strip()][:12]))
for row in rows:
    print(json.dumps(row))
