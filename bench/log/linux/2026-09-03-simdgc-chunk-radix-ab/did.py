import json, math, statistics as st
from scipy import stats
RES="/tmp/claude-1000/-home-steve-projects-scratch-gcry/7e41c2fd-f0a1-4087-b6f5-d7abf89777ca/scratchpad/results.jsonl"
rows=[json.loads(l) for l in open(RES) if l.strip()]
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
def val(r,k):
    if k=='rps': return r['rps']
    if k=='rss_kib': return r['rss_kib']
    if k=='pause_p50_ns': return r['post'].get('pause_p50_ns')
    return r['pre'].get(k)
def contrast(path,A,B,k):
    ps=paired(path,A,B)
    d=[val(b,k)-val(a,k) for a,b in ps if val(a,k) is not None and val(b,k) is not None]
    base=st.mean([val(a,k) for a,b in ps if val(a,k) is not None])
    return st.mean(d), st.stdev(d)/math.sqrt(len(d)), len(d), base

# DiD = (radix - default) - (nullA - nullB); the position artifact cancels
# because nullA carries it on '/' exactly as radix does, and nullB carries it
# on '/json' exactly as default does.
print("Difference-in-differences: treatment contrast minus null contrast.")
print("Cancels the position-in-round artifact that my schedule confounded with arm.\n")
for path in ['/json','/']:
    print(f"### {path}")
    for k,lbl,sc,unit in [('rps','throughput',1.0,' rps'),
                          ('phase_mark_ns','phase_mark',1000.0,' us'),
                          ('pause_p50_ns','pause p50',1000.0,' us'),
                          ('rss_kib','post-GC RSS',1.0,' KiB')]:
        mT,seT,nT,base=contrast(path,'default','radix',k)
        mN,seN,nN,_   =contrast(path,'nullA','nullB',k)
        did=mT-mN; se=math.sqrt(seT**2+seN**2)
        df=(seT**2+seN**2)**2/((seT**4)/(nT-1)+(seN**4)/(nN-1))
        tc=stats.t.ppf(0.975,df); t=did/se
        lo,hi=did-tc*se, did+tc*se
        p=2*(1-stats.t.cdf(abs(t),df))
        print(f"  {lbl:12} raw={mT/sc:+9.2f}{unit} ({mT/base*100:+6.2f}%)  null={mN/sc:+9.2f}{unit} ({mN/base*100:+6.2f}%)")
        print(f"  {'':12} DiD={did/sc:+9.2f}{unit} ({did/base*100:+6.2f}%)  95% CI [{lo/base*100:+.2f}%, {hi/base*100:+.2f}%]  t={t:+.2f}  p={p:.4g}  "
              f"-> {'SPANS ZERO' if lo<0<hi else 'EXCLUDES ZERO'}")
    print()
