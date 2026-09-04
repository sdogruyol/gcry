import json, math, statistics as st
import numpy as np
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

def ci(m,se,df):
    tc=stats.t.ppf(0.975,df); return m-tc*se, m+tc*se

for path in ['/json','/']:
  for (A,B,tag) in [('default','radix','RADIX'),('nullA','nullB','NULL')]:
    ps=paired(path,A,B)
    dm=np.array([b['pre']['phase_mark_ns']-a['pre']['phase_mark_ns'] for a,b in ps],float)
    dl=np.array([b['pre']['live_objects']-a['pre']['live_objects'] for a,b in ps],float)
    base=st.mean([a['pre']['phase_mark_ns'] for a,b in ps])
    # ANCOVA on paired differences: d_mark = intercept + slope * d_live
    X=np.column_stack([np.ones(len(dl)),dl])
    beta,_,_,_=np.linalg.lstsq(X,dm,rcond=None)
    resid=dm-X@beta; dof=len(dm)-2
    s2=resid@resid/dof
    cov=s2*np.linalg.inv(X.T@X)
    se0=math.sqrt(cov[0,0]); t0=beta[0]/se0
    lo,hi=ci(beta[0],se0,dof)
    p0=2*(1-stats.t.cdf(abs(t0),dof))
    r=np.corrcoef(dl,dm)[0,1]
    # unadjusted
    mu=dm.mean(); seu=dm.std(ddof=1)/math.sqrt(len(dm))
    ul,uh=ci(mu,seu,len(dm)-1)
    # per-live-object normalisation
    pn=[b['pre']['phase_mark_ns']/max(b['pre']['live_objects'],1)-a['pre']['phase_mark_ns']/max(a['pre']['live_objects'],1) for a,b in ps]
    bn=st.mean([a['pre']['phase_mark_ns']/max(a['pre']['live_objects'],1) for a,b in ps])
    tn=st.mean(pn)/(st.stdev(pn)/math.sqrt(len(pn)))
    nl,nh=ci(st.mean(pn), st.stdev(pn)/math.sqrt(len(pn)), len(pn)-1)
    print(f"\n=== {tag} {path}  n={len(ps)}   corr(d_live, d_mark) = {r:+.3f}")
    print(f"  unadjusted   d_mark = {mu/1000:+7.2f} us ({mu/base*100:+6.2f}%)  CI [{ul/base*100:+.2f}%, {uh/base*100:+.2f}%]")
    print(f"  ANCOVA-adj   d_mark = {beta[0]/1000:+7.2f} us ({beta[0]/base*100:+6.2f}%)  CI [{lo/base*100:+.2f}%, {hi/base*100:+.2f}%]  t={t0:+.2f} p={p0:.4g}")
    print(f"  per-live-obj d      = {st.mean(pn)/bn*100:+6.2f}%  CI [{nl/bn*100:+.2f}%, {nh/bn*100:+.2f}%]  t={tn:+.2f}")
