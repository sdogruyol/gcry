import subprocess, json, re, statistics, random, sys
reps = int(sys.argv[1])
res = {}
def rec(k, v): res.setdefault(k, []).append(v)
for r in range(reps):
    arms = ['base', 'new']; random.shuffle(arms)
    for a in arms:
        o = subprocess.run(['./gc_phases-'+a, '--seconds=2', '--live=200000', '--survival=0.1'], capture_output=True, text=True).stdout.splitlines()
        d = json.loads(o[1]); rec((a,'gcph200k ns/alloc'), d['ns_per_alloc']); rec((a,'gcph200k mark_us/gc'), d['phase_mark_us']); rec((a,'gcph200k rss_kb'), d['rss_kb'])
        o = subprocess.run(['./gc_phases-'+a, '--seconds=2', '--live=20000', '--survival=0.5', '--fanout=6'], capture_output=True, text=True).stdout.splitlines()
        d = json.loads(o[1]); rec((a,'gcph20k-f6 ns/alloc'), d['ns_per_alloc']); rec((a,'gcph20k-f6 mark_us/gc'), d['phase_mark_us']); rec((a,'gcph20k-f6 rss_kb'), d['rss_kb'])
        o = subprocess.run(['./alloc_ns-'+a, '1', '20000000', '48'], capture_output=True, text=True).stdout
        rec((a,'alloc_ns 48B'), json.loads(o.strip().splitlines()[-1])['ns_per_alloc'])
        p = subprocess.run(['/usr/bin/time', '-f', 'W %e %M', './json_churn-'+a, '300000'], capture_output=True, text=True)
        m = re.search(r'W ([0-9.]+) (\d+)', p.stderr); rec((a,'json_churn wall_s'), float(m.group(1))); rec((a,'json_churn rss_kb'), int(m.group(2)))
        m = re.search(r'p50_us=(\d+) p99_us=(\d+)', p.stdout); rec((a,'json_churn p50_us'), int(m.group(1))); rec((a,'json_churn p99_us'), int(m.group(2)))
keys = sorted({k for _, k in res})
print(f"{'metric':24} {'base med':>10} {'new med':>10} {'Δ':>7}   base[min,max]  new[min,max]")
for k in keys:
    b = res[('base',k)]; n = res[('new',k)]
    mb, mn = statistics.median(b), statistics.median(n)
    print(f"{k:24} {mb:10.2f} {mn:10.2f} {(mn/mb-1)*100:+6.1f}%   [{min(b):.4g},{max(b):.4g}] [{min(n):.4g},{max(n):.4g}]")
