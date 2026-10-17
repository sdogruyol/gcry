"""Summarize one probe.sh artifact directory: analyze.py DIR

Prints, per arm: the timed A/B against Boehm and against `tip` (paired per
rep, median [IQR]); bt.cr's build/walk split and gcry counters (medians);
rusage (macOS `time -l` / Linux `time -v`); the per-collection schedule from
the traces; Boehm's collection count from GC_PRINT_STATS.
"""
import glob, json, os, re, statistics, sys

d = sys.argv[1]
med = statistics.median


def quart(xs):
    if len(xs) < 2:
        return xs[0], xs[0], xs[0]
    q = statistics.quantiles(xs, n=4, method="inclusive")
    return q[0], med(xs), q[2]


def fmt(q, pct=False, digits=1):
    if pct:
        return f"{q[1]:+.{digits}%} [{q[0]:+.{digits}%}, {q[2]:+.{digits}%}]"
    return f"{q[1]:.{digits}f} [{q[0]:.{digits}f}, {q[2]:.{digits}f}]"


runs = json.load(open(os.path.join(d, "runs.json")))
rows = runs["runs"]
arms = list(runs["arms"])
by = {}
for r in rows:
    by.setdefault((r["bench"], r["arm"]), {})[r["rep"]] = r
print(f"## timed A/B ({runs['reps']} reps, env {runs['arm_env']})\n")
print("| arm | wall s | % of Boehm | wall vs tip | peak MiB | peak × Boehm | collections | Σ mark ms |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for b in runs["benches"]:
    bo, tp = by[(b, "boehm")], by[(b, "tip")]
    for a in arms:
        ar = by[(b, a)]
        reps = sorted(set(ar) & set(bo) & set(tp))
        wall = med(ar[i]["wall"] for i in reps)
        sp = quart([100 * bo[i]["wall"] / ar[i]["wall"] for i in reps])
        vt = quart([ar[i]["wall"] / tp[i]["wall"] - 1 for i in reps])
        pk = med(ar[i]["peak"] for i in reps) / 2**20
        pm = quart([ar[i]["peak"] / bo[i]["peak"] for i in reps])
        col = [ar[i]["collections"] for i in reps if ar[i]["collections"] is not None]
        mk = [ar[i]["mark"] for i in reps if ar[i]["mark"] is not None]
        res = sorted({str(ar[i]["result"]) for i in reps})
        print(f"| {b} {a} | {wall:.3f} | {fmt(sp, digits=0)} | {fmt(vt, True)} | {pk:.0f} | {fmt(pm, digits=2)} | "
              f"{med(col) if col else '-'} | {med(mk) if mk else '-'} |" + ("" if res == ["ok"] else f" results {res}"))

bt = {}
for line in open(os.path.join(d, "bt.txt")):
    m = re.match(r"ARM (\S+) rep (\d+) BT (\S+) (.*)", line)
    if not m:
        continue
    kv = dict(x.split("=", 1) for x in m.group(4).split())
    bt.setdefault(m.group(1), []).append(kv)
print("\n## bt.cr (medians of reps)\n")
keys = ["total_ms", "build_ms", "walk_ms", "majors", "gc_no", "pause_ms", "max_pause_ms", "threshold", "refills",
        "word_adv", "miss_coll", "miss_refill", "miss_thr", "chunk_adv", "revives", "heap_size", "small_mapped", "dormant", "hits", "locked"]
for a, xs in bt.items():
    cells = []
    for k in keys:
        v = [float(x[k]) for x in xs if k in x]
        if v:
            cells.append(f"{k}={med(v):.6g}")
    print(f"- {a} (n={len(xs)}): " + " ".join(cells))

print("\n## rusage (medians)\n")
ru, cur = {}, None
pats = {
    "real": r"([0-9.]+) real", "user": r"([0-9.]+) user", "sys": r"([0-9.]+) sys",
    "maxrss": r"(\d+)\s+maximum resident set size", "minflt": r"(\d+)\s+page reclaims",
    "majflt": r"(\d+)\s+page faults", "ivcsw": r"(\d+)\s+involuntary context switches",
    "instr": r"(\d+)\s+instructions retired", "cycles": r"(\d+)\s+cycles elapsed",
    "footprint": r"(\d+)\s+peak memory footprint",
    "l_user": r"User time \(seconds\): ([0-9.]+)", "l_sys": r"System time \(seconds\): ([0-9.]+)",
    "l_maxrss_kb": r"Maximum resident set size \(kbytes\): (\d+)", "l_minflt": r"Minor \(reclaiming a frame\) page faults: (\d+)",
    "l_ivcsw": r"Involuntary context switches: (\d+)", "l_wall": r"Elapsed \(wall clock\) time .*: ([0-9:.]+)",
}
for line in open(os.path.join(d, "rusage.txt")):
    m = re.match(r"ARM (\S+) rep", line)
    if m:
        cur = ru.setdefault(m.group(1), [])
        cur.append({})
        continue
    if cur is None:
        continue
    for k, p in pats.items():
        mm = re.search(p, line)
        if mm and k not in cur[-1]:
            v = mm.group(1)
            if ":" in v:
                mins, secs = v.rsplit(":", 1)
                v = float(mins) * 60 + float(secs)
            cur[-1][k] = float(v)
for a, xs in ru.items():
    ks = sorted({k for x in xs for k in x})
    print(f"- {a}: " + " ".join(f"{k}={med([x[k] for x in xs if k in x]):.6g}" for k in ks))

print("\n## per-collection schedule (one traced run)\n")
for p in sorted(glob.glob(os.path.join(d, "trace-*.ndjson"))):
    a = os.path.basename(p)[len("trace-"):-len(".ndjson")]
    ends = [json.loads(l) for l in open(p) if '"collect_end"' in l]
    if not ends:
        continue
    thr = [e["threshold"] / 2**20 for e in ends]
    pace = [e.get("threshold_pace_pct", 0) for e in ends]
    live = [e.get("size_class_live_bytes", 0) / 2**20 for e in ends]
    tot = lambda k: sum(e[k] for e in ends) / 1e6
    print(f"- {a}: {len(ends)} collections, Σ pause {tot('pause_ns'):.1f} ms (mark {tot('mark_ns'):.1f}, sweep {tot('sweep_ns'):.1f}, "
          f"stacks {tot('stacks_ns'):.1f}, roots {tot('roots_ns'):.1f}, static {tot('static_ns'):.1f}, flush {tot('flush_ns'):.1f}, "
          f"stop {tot('stw_stop_ns'):.1f}); threshold MiB median {med(thr):.1f} [min {min(thr):.1f}, max {max(thr):.1f}]; "
          f"pace % median {med(pace)} [{min(pace)}, {max(pace)}]; live MiB median {med(live):.1f} max {max(live):.1f}; "
          f"median pause {med(e['pause_ns'] for e in ends) / 1e6:.2f} ms")

p = os.path.join(d, "boehm-stats.txt")
if os.path.exists(p):
    t = open(p, errors="replace").read()
    gcs = re.findall(r"GC #(\d+) freed", t) or re.findall(r"Collection (\d+) ", t)
    marks = [int(x) for x in re.findall(r"World-stopped marking took (\d+) ms", t)]
    print(f"\n## Boehm GC_PRINT_STATS: {len(gcs)} collections, Σ world-stopped marking {sum(marks)} ms "
          f"(median {med(marks) if marks else '-'} ms)")
    hs = re.findall(r"heap (\d+) KiB", t)
    if hs:
        print(f"   heap KiB last {hs[-1]}, max {max(int(x) for x in hs)}")

for p in sorted(glob.glob(os.path.join(d, "calls-*.txt"))):
    a = os.path.basename(p)[len("calls-"):-len(".txt")]
    print(f"\n## calls from the allocation entry points, {a}\n")
    print(open(p).read().rstrip())
