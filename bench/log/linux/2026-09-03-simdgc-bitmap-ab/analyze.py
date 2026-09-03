import json, sys, math, statistics as st
from scipy import stats

path_in = sys.argv[1]
rows = [json.loads(l) for l in open(path_in) if l.strip()]
rows = [r for r in rows if 'error' not in r]

def paired(rows, path, armA, armB):
    """Pair up armA/armB trials on `path` in file order: each consecutive
    (A,B) or (B,A) adjacency within a round forms one pair."""
    seq = [r for r in rows if r['path'] == path and r['arm'] in (armA, armB)]
    pairs = []
    i = 0
    while i + 1 < len(seq):
        a, b = seq[i], seq[i+1]
        if a['arm'] != b['arm']:
            pairs.append((a, b))
            i += 2
        else:
            i += 1
    return pairs

def report(pairs, armA, armB, label, key='rps'):
    # difference is always (armB - armA) i.e. treatment - control
    d = []
    for a, b in pairs:
        A = a if a['arm'] == armA else b
        B = b if b['arm'] == armB else a
        d.append(B[key] - A[key])
    n = len(d)
    if n < 2:
        print(f"{label}: n={n}, too few"); return
    mean = st.mean(d); sd = st.stdev(d); se = sd / math.sqrt(n)
    t = mean / se if se else float('nan')
    tcrit = stats.t.ppf(0.975, n-1)
    lo, hi = mean - tcrit*se, mean + tcrit*se
    baseA = st.mean([(a if a['arm']==armA else b)[key] for a,b in pairs])
    wins = sum(1 for x in d if x > 0)
    pval = 2*(1 - stats.t.cdf(abs(t), n-1))
    print(f"\n{label}  (n={n} pairs)")
    print(f"  mean {armA}: {baseA:,.0f}   mean {armB}: {baseA+mean:,.0f}")
    print(f"  paired mean diff ({armB} - {armA}): {mean:+,.1f} rps  ({mean/baseA*100:+.2f}%)")
    print(f"  t = {t:+.3f}   p = {pval:.3f}   sd(d) = {sd:,.0f}")
    print(f"  95% CI: [{lo:+,.0f}, {hi:+,.0f}] rps  = [{lo/baseA*100:+.2f}%, {hi/baseA*100:+.2f}%]")
    print(f"  wins: {wins}/{n}   CI half-width: +/-{(hi-lo)/2/baseA*100:.2f}%")
    print(f"  spans zero: {'YES -> unmeasurable' if lo < 0 < hi else 'NO -> real effect'}")
    return mean/baseA*100, lo/baseA*100, hi/baseA*100

def summarize(rows, arm, path, key):
    v = [r[key] for r in rows if r['arm']==arm and r['path']==path and r.get(key)]
    if not v: return None
    return st.mean(v), st.median(v), min(v), max(v), len(v)

for p in ['/json', '/']:
    print("="*72)
    print(f"PATH {p}")
    print("="*72)
    report(paired(rows, p, 'default', 'bitmap'), 'default', 'bitmap', f"BITMAP vs DEFAULT  {p}")
    report(paired(rows, p, 'nullA', 'nullB'), 'nullA', 'nullB', f"NULL CONTROL (default vs default)  {p}")

print("\n" + "="*72)
print("RSS (post-GC VmRSS KiB) and pause p50")
print("="*72)
for p in ['/json', '/']:
    for arm in ['default','bitmap','nullA','nullB','boehm_start','boehm_end']:
        s = summarize(rows, arm, p, 'rss_kib')
        q = summarize(rows, arm, p, 'pause_p50_ns')
        if s:
            qs = f"  pause_p50 mean={q[0]/1e6:.3f}ms median={q[1]/1e6:.3f}ms" if q else "  pause_p50 n/a"
            print(f"{p:6} {arm:12} RSS mean={s[0]:8,.0f} median={s[1]:8,.0f} [{s[2]:,.0f}-{s[3]:,.0f}] n={s[4]}{qs}")

print("\n" + "="*72)
print("Throughput vs Boehm reference")
print("="*72)
for p in ['/json','/']:
    bs = [r['rps'] for r in rows if r['arm'] in ('boehm_start','boehm_end') and r['path']==p]
    if not bs: continue
    bref = st.mean(bs)
    for arm in ['default','bitmap']:
        v = [r['rps'] for r in rows if r['arm']==arm and r['path']==p]
        if v: print(f"{p:6} {arm:8} {st.mean(v):,.0f} rps = {st.mean(v)/bref*100:.1f}% of Boehm ({bref:,.0f} rps, n_boehm={len(bs)}: {['%.0f'%x for x in bs]})")

# paired RSS
print("\n" + "="*72)
print("Paired RSS difference (bitmap - default)")
print("="*72)
for p in ['/json','/']:
    report(paired(rows, p, 'default', 'bitmap'), 'default', 'bitmap', f"RSS {p}", key='rss_kib')
