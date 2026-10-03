import json, os, random, re, statistics, subprocess, sys
reps = int(sys.argv[1]); benches = sys.argv[2:]
arms = {"base": "bin/base", "var": "bin/var"}
res = {}
for rep in range(reps):
    for b in benches:
        order = list(arms); random.shuffle(order)
        for a in order:
            env = {**os.environ, "GCRY_TRACE": "1", "GCRY_TRACE_ALLOC_SAMPLE": "0", "GCRY_TRACE_FILE": "/tmp/ab.ndjson"}
            out = subprocess.run([arms[a], b], env=env, capture_output=True, text=True).stdout
            w = float(re.findall(rf"{b}:.*? in ([0-9.]+)s", out)[-1])
            m = sum(json.loads(l)["mark_ns"] for l in open("/tmp/ab.ndjson") if '"collect_end"' in l) / 1e6
            res.setdefault((b, a), []).append((m, w))
for b in benches:
    bm = statistics.median(x[0] for x in res[(b, "base")]); bw = statistics.median(x[1] for x in res[(b, "base")])
    vm = statistics.median(x[0] for x in res[(b, "var")]); vw = statistics.median(x[1] for x in res[(b, "var")])
    print(f"AB {b}: mark {bm:.0f} -> {vm:.0f} ms ({vm / bm - 1:+.1%}); time {bw:.3f} -> {vw:.3f} s ({vw / bw - 1:+.1%})")
