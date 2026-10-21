#!/usr/bin/env python3
"""dormant_flush_race children from several builds side by side, under load.

usage: repro.py PAR BATCHES OUT_TSV [ARMS]
ARMS is a comma list of bin/df_<arm> binaries (default old,new). Each batch
holds the heavy lock once and starts PAR copies of each arm's `--child` at
once, with the environment the harness parent gives its queued arm plus
GCRY_TRACE_LARGE=1, every child bounded by bench/run_bounded.sh.
"""
import fcntl, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = "/home/naruto/playground/.scratch/heavy.lock"
BOUNDED = f"{HERE}/wt/bench/run_bounded.sh"
ENV = dict(os.environ, GCRY_MOSTLY_EMPTY="1", GCRY_UNMAP_GUARD="1", GCRY_SEGV_REPORT="1",
           GCRY_STW_WATCHDOG_MS="5000", GCRY_TRACE_LARGE="1", GCRY_ANY_PTRACER="1")
par, batches, out_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ARMS = (sys.argv[4] if len(sys.argv) > 4 else "old,new").split(",")
BINS = {arm: f"{HERE}/bin/df_{arm}" for arm in ARMS}
os.makedirs(f"{HERE}/logs", exist_ok=True)
out = open(out_path, "a", buffering=1)

def one(args):
    label, b, k = args
    log = f"{HERE}/logs/{label}-{b}-{k}.log"
    t0 = time.time()
    rc = subprocess.run([BOUNDED, "300", log, "--", BINS[label], "--child"], env=ENV).returncode
    dur = time.time() - t0
    summary = ""
    if rc == 0:
        with open(log, errors="replace") as f:
            for line in f:
                if line.startswith("child:"):
                    summary = line.strip()[:400]
                    break
        os.remove(log)
    return label, b, k, rc, dur, summary


for b in range(batches):
    with open(LOCK) as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        jobs = [(label, b, k) for k in range(par) for label in ARMS]
        with ThreadPoolExecutor(len(jobs)) as ex:
            for label, bb, k, rc, dur, summary in ex.map(one, jobs):
                out.write(f"{int(time.time())}\t{label}\t{bb}\t{k}\t{rc}\t{dur:.1f}\t{summary}\n")
    print(f"batch {b} done", flush=True)
