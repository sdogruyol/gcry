import sys, statistics, collections
rows = collections.defaultdict(lambda: collections.defaultdict(list))
for l in open(sys.argv[1]):
    if not l.startswith("ROW "): continue
    _, t, b, arm, secs, kib, rc = l.split()
    if float(secs) > 0:
        rows[b][arm + "_s"].append(float(secs))
    rows[b][arm + "_kib"].append(int(kib))
print("| bench | Boehm s | gcry s | gcry speed % of Boehm | Boehm peak MiB | gcry peak MiB | peak × |")
print("|---|---:|---:|---:|---:|---:|---:|")
sp, rx = [], []
for b, d in rows.items():
    bs, gs = statistics.median(d["boehm_s"]), statistics.median(d["gcry_s"])
    bk, gk = statistics.median(d["boehm_kib"]), statistics.median(d["gcry_kib"])
    sp.append(bs / gs * 100); rx.append(gk / bk if bk else 0)
    print(f"| {b} | {bs:.3f} | {gs:.3f} | {bs/gs*100:.1f} | {bk/1024:.1f} | {gk/1024:.1f} | {gk/bk:.2f} |")
print(f"\nmedian speed % of Boehm {statistics.median(sp):.1f}; median peak × {statistics.median(rx):.2f}; n per cell {len(next(iter(rows.values()))['boehm_s'])}")
