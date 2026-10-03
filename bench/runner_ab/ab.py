import json, os, random, re, statistics, subprocess, sys, tempfile

reps = int(sys.argv[1])
benches = sys.argv[2:]
arms = {"base": "bin/ab-base", "var": "bin/ab-var"}
trace = os.path.join(tempfile.gettempdir(), "ab-trace.ndjson")
res = {}
for rep in range(reps):
    for b in benches:
        order = list(arms)
        random.shuffle(order)
        for a in order:
            env = {**os.environ, "GCRY_TRACE": "1", "GCRY_TRACE_ALLOC_SAMPLE": "0", "GCRY_TRACE_FILE": trace}
            out = subprocess.run([arms[a], b], env=env, capture_output=True, text=True).stdout
            w = float(re.findall(rf"{b}:.*? in ([0-9.]+)s", out)[-1])
            m = sum(json.loads(l)["mark_ns"] for l in open(trace) if '"collect_end"' in l) / 1e6
            res.setdefault((b, a), []).append((m, w))
for b in benches:
    bm, bw = (statistics.median(x[i] for x in res[(b, "base")]) for i in (0, 1))
    vm, vw = (statistics.median(x[i] for x in res[(b, "var")]) for i in (0, 1))
    print(f"AB {b}: mark {bm:.0f} -> {vm:.0f} ms ({vm / bm - 1:+.1%}); time {bw:.3f} -> {vw:.3f} s ({vw / bw - 1:+.1%})")
