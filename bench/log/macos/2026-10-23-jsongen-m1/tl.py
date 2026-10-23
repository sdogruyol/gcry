#!/usr/bin/env python3
"""tl.py BIN OUTDIR N [ENV=V ...]: run JsonGenerate N times with GCRY_TRACE=1,
GCRY_TRACE_LARGE=1 and VmRSS polled every ~0.5 ms; keeps every run's files as
OUTDIR/<i>.{ndjson,large,rss}; prints peak, faults, peak time and the
collections around it. Kills its child on exit; each child capped at 60 s."""
import json, os, signal, sys, time

binp, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.makedirs(out, exist_ok=True)
extra = dict(kv.split("=", 1) for kv in sys.argv[4:])
bench = extra.pop("BENCH", "JsonGenerate")
child = None

def bye(*_):
    if child:
        try: os.kill(child, signal.SIGKILL)
        except ProcessLookupError: pass
    sys.exit(1)

for s in (signal.SIGTERM, signal.SIGINT):
    signal.signal(s, bye)
for i in range(n):
    pref = f"{out}/{i}"
    env = dict(os.environ, SILENT="1", GCRY_TRACE="1", GCRY_TRACE_ALLOC_SAMPLE="0",
               GCRY_TRACE_FILE=pref + ".ndjson", GCRY_TRACE_LARGE="1", **extra)
    errfd = os.open(pref + ".large", os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    nul = os.open(pref + ".out", os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    child = os.posix_spawn(binp, [binp, bench], env,
                           file_actions=[(os.POSIX_SPAWN_DUP2, nul, 1), (os.POSIX_SPAWN_DUP2, errfd, 2)])
    os.close(errfd); os.close(nul)
    t_start = time.monotonic()
    samples = []
    path = f"/proc/{child}/status"
    while True:
        r = os.wait4(child, os.WNOHANG)
        if r[0] != 0:
            _, status, ru = r
            break
        if time.monotonic() - t_start > 60:
            os.kill(child, signal.SIGKILL)
        try:
            with open(path) as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        samples.append((time.monotonic_ns(), int(line.split()[1])))
                        break
        except (FileNotFoundError, ProcessLookupError):
            pass
        time.sleep(0.0005)
    child = None
    with open(pref + ".rss", "w") as f:
        for t, r_ in samples:
            f.write(f"{t} {r_}\n")
    try:
        colls = [json.loads(l) for l in open(pref + ".ndjson") if '"collect_end"' in l]
    except Exception:
        colls = []
    pt, pr = max(samples, key=lambda s: s[1]) if samples else (0, 0)
    t0 = samples[0][0] if samples else 0
    before = [c for c in colls if c["ts_ns"] <= pt]
    after = [c for c in colls if c["ts_ns"] > pt]
    b = before[-1]["collections"] if before else None
    a = after[0]["collections"] if after else None
    print(i, status, round(ru.ru_maxrss / 1024), ru.ru_minflt, f"polled {pr/1024:.0f} at {(pt-t0)/1e6:.0f}ms between c{b} c{a}", len(colls), flush=True)
