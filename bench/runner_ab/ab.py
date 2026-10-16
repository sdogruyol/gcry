import json, os, random, re, statistics, subprocess, sys, tempfile

reps = int(sys.argv[1])
benches = sys.argv[2:]
arms = {"base": "bin/ab-base", "var": "bin/ab-var"}
trace = os.path.join(tempfile.gettempdir(), "ab-trace.ndjson")
res, results = {}, {}
for rep in range(reps):
    for b in benches:
        order = list(arms)
        random.shuffle(order)
        for a in order:
            env = {**os.environ, "GCRY_TRACE": "1", "GCRY_TRACE_ALLOC_SAMPLE": "0", "GCRY_TRACE_FILE": trace}
            p = subprocess.run([arms[a], b], env=env, capture_output=True, text=True)
            # Exit 1 with `err result=` is the suite's checksum disagreeing with
            # its expected value, which a compiler bump alone causes (Crystal
            # 1.22 under Boehm fails five of these). What gcry must keep is
            # base and var agreeing, checked below. Anything else is a crash:
            # say which arm, and stop.
            got = re.search(r"err result=(.*?), but expected", p.stdout)
            if p.returncode != 0 and not (p.returncode == 1 and got):
                sys.exit(f"AB {b}: {a} exited {p.returncode} on rep {rep}\n{p.stdout[-2000:]}{p.stderr[-2000:]}")
            results.setdefault((b, a), set()).add(got.group(1)[:200] if got else "expected")
            w = float(re.findall(rf"{b}:.*? in ([0-9.]+)s", p.stdout)[-1])
            m = sum(json.loads(l)["mark_ns"] for l in open(trace) if '"collect_end"' in l) / 1e6
            res.setdefault((b, a), []).append((m, w))
for b in benches:
    bm, bw = (statistics.median(x[i] for x in res[(b, "base")]) for i in (0, 1))
    vm, vw = (statistics.median(x[i] for x in res[(b, "var")]) for i in (0, 1))
    print(f"AB {b}: mark {bm:.0f} -> {vm:.0f} ms ({vm / bm - 1:+.1%}); time {bw:.3f} -> {vw:.3f} s ({vw / bw - 1:+.1%})")
differ = [b for b in benches if results[(b, "base")] != results[(b, "var")]]
for b in differ:
    print(f"AB {b}: results differ: base {sorted(results[(b, 'base')])} var {sorted(results[(b, 'var')])}")
# Every rep's samples, for bench/runner_ab/report.py: rep i of base and var
# ran back to back, so the pairs are paired.
if path := os.environ.get("AB_JSON"):
    out = {
        "runner": os.environ.get("AB_RUNNER", ""),
        "base": os.environ.get("AB_BASE_REV", ""),
        "var": os.environ.get("AB_VAR_REV", ""),
        "reps": reps,
        "benches": {
            b: {
                a: {
                    "mark_ms": [x[0] for x in res[(b, a)]],
                    "time_s": [x[1] for x in res[(b, a)]],
                    "results": sorted(results[(b, a)]),
                }
                for a in arms
            }
            for b in benches
        },
    }
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
sys.exit(1 if differ else 0)
