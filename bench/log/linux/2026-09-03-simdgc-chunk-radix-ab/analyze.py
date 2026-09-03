import json, sys, math, statistics as st
from scipy import stats

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if 'error' not in r and r.get('arm') != 'warmup']

def mean_or_none(v):
    v = [x for x in v if x is not None]
    return st.mean(v) if v else None

def metric(r, name):
    pre, post = r.get('pre', {}), r.get('post', {})
    if name == 'rps':          return r['rps']
    if name == 'rss_kib':      return r['rss_kib']
    if name == 'pause_p50':    return post.get('pause_p50_ns')
    if name == 'inload_mark':  return pre.get('phase_mark_ns')
    if name == 'inload_sweep': return pre.get('phase_sweep_ns')
    if name == 'inload_stacks':return pre.get('phase_stacks_ns')
    if name == 'inload_roots': return pre.get('phase_roots_ns')
    if name == 'inload_clear': return pre.get('phase_clear_ns')
    if name == 'idle_mark':
        v = [post.get('phase_mark_ns')] + (r.get('idle_marks') or [])
        return mean_or_none(v)
    if name == 'idle_sweep':
        v = [post.get('phase_sweep_ns')] + (r.get('idle_sweeps') or [])
        return mean_or_none(v)
    if name == 'idle_stacks':
        v = [post.get('phase_stacks_ns')] + (r.get('idle_stacks') or [])
        return mean_or_none(v)
    if name == 'mean_pause_inload':
        c, t = pre.get('pause_count'), pre.get('pause_total_ns')
        return t / c if c else None
    if name == 'collections':  return pre.get('collections')
    raise KeyError(name)

def paired(rows, path, armA, armB):
    seq = [r for r in rows if r['path'] == path and r['arm'] in (armA, armB)]
    pairs, i = [], 0
    while i + 1 < len(seq):
        a, b = seq[i], seq[i+1]
        if a['arm'] != b['arm']:
            pairs.append((a, b)); i += 2
        else:
            i += 1
    return pairs

def report(pairs, armA, armB, label, key='rps', unit='', scale=1.0, quiet=False):
    d, basev = [], []
    for a, b in pairs:
        A = a if a['arm'] == armA else b
        B = b if b['arm'] == armB else a
        va, vb = metric(A, key), metric(B, key)
        if va is None or vb is None: continue
        d.append((vb - va) / scale); basev.append(va / scale)
    n = len(d)
    if n < 2:
        print(f"{label}: n={n}, too few"); return None
    mean = st.mean(d); sd = st.stdev(d); se = sd / math.sqrt(n)
    t = mean / se if se else float('nan')
    tcrit = stats.t.ppf(0.975, n-1)
    lo, hi = mean - tcrit*se, mean + tcrit*se
    baseA = st.mean(basev)
    wins = sum(1 for x in d if x > 0)
    pval = 2*(1 - stats.t.cdf(abs(t), n-1))
    # min detectable effect at 80% power, two-sided 0.05
    mde = (stats.t.ppf(0.975, n-1) + stats.t.ppf(0.80, n-1)) * se
    print(f"\n{label}   (n={n} pairs)")
    print(f"  mean {armA}: {baseA:,.3f}{unit}    mean {armB}: {baseA+mean:,.3f}{unit}")
    print(f"  paired mean diff ({armB} - {armA}): {mean:+,.3f}{unit}  ({mean/baseA*100:+.2f}%)")
    print(f"  t = {t:+.3f}   p = {pval:.4f}   sd(d) = {sd:,.3f}{unit}")
    print(f"  95% CI: [{lo:+,.3f}, {hi:+,.3f}]{unit}  = [{lo/baseA*100:+.2f}%, {hi/baseA*100:+.2f}%]")
    print(f"  wins: {wins}/{n}   CI half-width: +/-{(hi-lo)/2/baseA*100:.2f}%   MDE@80% = {mde/baseA*100:.2f}%")
    print(f"  -> {'SPANS ZERO: unmeasurable' if lo < 0 < hi else 'EXCLUDES ZERO: measurable effect'}")
    return dict(n=n, mean=mean, pct=mean/baseA*100, t=t, p=pval,
                lo_pct=lo/baseA*100, hi_pct=hi/baseA*100, wins=wins,
                base=baseA, mde_pct=mde/baseA*100)

def order_effect(rows, path, arms):
    """Second-position effect: mean(second) - mean(first) within pairs."""
    seq = [r for r in rows if r['path'] == path and r['arm'] in arms]
    d, base = [], []
    i = 0
    while i + 1 < len(seq):
        a, b = seq[i], seq[i+1]
        if a['arm'] != b['arm']:
            d.append(b['rps'] - a['rps']); base.append(a['rps']); i += 2
        else: i += 1
    if len(d) < 2: return
    m = st.mean(d); se = st.stdev(d)/math.sqrt(len(d))
    tc = stats.t.ppf(0.975, len(d)-1)
    print(f"  order effect (2nd - 1st) {path} {arms}: {m/st.mean(base)*100:+.2f}%  "
          f"CI [{(m-tc*se)/st.mean(base)*100:+.2f}%, {(m+tc*se)/st.mean(base)*100:+.2f}%]")

def block_ordered(rows, path, armA, armB):
    a = [r['rps'] for r in rows if r['path']==path and r['arm']==armA]
    b = [r['rps'] for r in rows if r['path']==path and r['arm']==armB]
    if a and b:
        print(f"  naive unpaired mean ratio {armB}/{armA} {path}: {st.mean(b)/st.mean(a):.4f}")

MET = [('rps','rps',' rps',1.0),
       ('inload_mark','phase_mark (in-load, last collection under wrk)',' us',1000.0),
       ('idle_mark','phase_mark (idle, mean of 5 forced collects)',' us',1000.0),
       ('inload_sweep','phase_sweep (in-load)',' us',1000.0),
       ('idle_sweep','phase_sweep (idle, mean of 5)',' us',1000.0),
       ('inload_stacks','phase_stacks (in-load)',' us',1000.0),
       ('inload_roots','phase_roots (in-load)',' us',1000.0),
       ('inload_clear','phase_clear (in-load)',' us',1000.0),
       ('mean_pause_inload','mean pause over the load (pause_total/pause_count)',' us',1000.0),
       ('pause_p50','pause p50 (post-GC snapshot)',' us',1000.0),
       ('rss_kib','post-GC VmRSS',' KiB',1.0),
       ('collections','collections during load','',1.0)]

for p in ['/json', '/']:
    print("\n" + "="*78)
    print(f"### PATH {p}  —  RADIX vs DEFAULT")
    print("="*78)
    for key, lbl, unit, sc in MET:
        report(paired(rows,p,'default','radix'),'default','radix',f"{lbl}  {p}",key,unit,sc)

for p in ['/json', '/']:
    print("\n" + "="*78)
    print(f"### PATH {p}  —  NULL CONTROL (default vs default, same binary, same env)")
    print("="*78)
    for key, lbl, unit, sc in MET:
        report(paired(rows,p,'nullA','nullB'),'nullA','nullB',f"NULL {lbl}  {p}",key,unit,sc)

print("\n" + "="*78)
print("### ORDERING DIAGNOSTICS")
print("="*78)
for p in ['/json','/']:
    order_effect(rows, p, ('default','radix'))
    order_effect(rows, p, ('nullA','nullB'))
    block_ordered(rows, p, 'default', 'radix')
    block_ordered(rows, p, 'nullA', 'nullB')

print("\n" + "="*78)
print("### RAW PER-ARM SUMMARIES")
print("="*78)
for p in ['/json','/']:
    for arm in ['default','radix','nullA','nullB']:
        sub = [r for r in rows if r['path']==p and r['arm']==arm]
        if not sub: continue
        def s(k):
            v=[metric(r,k) for r in sub]; v=[x for x in v if x is not None]
            return (st.mean(v), st.median(v), min(v), max(v)) if v else (0,0,0,0)
        rp=s('rps'); rs=s('rss_kib'); pm=s('idle_mark'); im=s('inload_mark'); pp=s('pause_p50')
        print(f"{p:6} {arm:8} n={len(sub):3}  rps mean={rp[0]:9,.0f} med={rp[1]:9,.0f}  "
              f"RSS mean={rs[0]:7,.0f} med={rs[1]:7,.0f}  idle_mark={pm[0]/1000:7.2f}us  "
              f"inload_mark={im[0]/1000:7.2f}us  p50={pp[0]/1e6:.3f}ms")

errs = [r for r in rows if 'timeout' in (r.get('sock_errors') or '') and 'timeout 0' not in r.get('sock_errors','')]
print(f"\ntrials with wrk socket timeouts: {len(errs)}/{len(rows)}")
from collections import Counter
print(Counter((r['arm'],r['path']) for r in errs))
