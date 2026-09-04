import json, math, statistics as st
from scipy import stats
rows=[json.loads(l) for l in open("/tmp/claude-1000/-home-steve-projects-scratch-gcry/7e41c2fd-f0a1-4087-b6f5-d7abf89777ca/scratchpad/results.jsonl") if l.strip()]
rows=[r for r in rows if r.get('arm')!='warmup']
def paired(path,A,B):
    seq=[r for r in rows if r['path']==path and r['arm'] in (A,B)]
    out=[];i=0
    while i+1<len(seq):
        a,b=seq[i],seq[i+1]
        if a['arm']!=b['arm']:
            out.append((a if a['arm']==A else b, b if b['arm']==B else a)); i+=2
        else: i+=1
    return out
def get(r,k):
    return r['pre'].get(k) if k in ('phase_mark_ns','heap_size','live_objects','small_mapped_bytes','size_class_live_bytes','bytes_since_gc') else r.get(k)
for path in ['/json','/']:
    for (A,B,tag) in [('default','radix','RADIX'),('nullA','nullB','NULL ')]:
        ps=paired(path,A,B)
        print(f"\n--- {tag} {path}  n={len(ps)}")
        for k in ['phase_mark_ns','rps','heap_size','live_objects','size_class_live_bytes']:
            d=[get(b,k)-get(a,k) for a,b in ps if get(a,k) is not None and get(b,k) is not None]
            if not d: continue
            base=st.mean([get(a,k) for a,b in ps])
            pos=sum(1 for x in d if x>0); neg=sum(1 for x in d if x<0); n=pos+neg
            sign_p=stats.binomtest(pos,n,0.5).pvalue if n else float('nan')
            w=stats.wilcoxon(d) if len(d)>5 else None
            med=st.median(d)
            print(f"  {k:24} mean%={st.mean(d)/base*100:+7.2f}  median%={med/base*100:+7.2f}  "
                  f"faster/lower in B: {neg}/{n}  sign p={sign_p:.4g}  wilcoxon p={w.pvalue:.4g}" if w else
                  f"  {k:24} mean%={st.mean(d)/base*100:+7.2f}")
