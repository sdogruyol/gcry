#!/usr/bin/env python3
"""Varied-seed stress campaign over gcry's randomized harnesses.

Lanes pull (job, seed) pairs round-robin until the deadline; every run is one
row in results.tsv; a failing run keeps its log under logs/.
"""
import itertools, os, subprocess, sys, threading, time

C = os.path.dirname(os.path.abspath(__file__))
HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0
LANES = int(sys.argv[2]) if len(sys.argv) > 2 else 3
DEADLINE = time.time() + HOURS * 3600
DIAG = {"GCRY_POISON_FREED": "1", "GCRY_SEGV_REPORT": "1"}

# name, argv builder (seed -> list), env, timeout seconds
JOBS = [
    ("stw_mt", lambda s: [f"{C}/stw_mt", f"--seed={s}", "--iterations=200", "--workers=2,4,8"], {}, 900),
    ("stw_mt+diag", lambda s: [f"{C}/stw_mt", f"--seed={s}", "--iterations=200", "--workers=2,4,8"], DIAG, 900),
    # Weighted x3 on the fixed tree: 2 of 62 lost live roots here before the
    # chunk-index growth fix, under this same load.
    ("stw_mt_hdr_tlab", lambda s: [f"{C}/stw_mt_hdr", "--tlab", f"--seed={s}", "--iterations=200", "--workers=2,4"],
     {"GCRY_BITMAP_ALLOC": "0"}, 900),
    ("stw_mt_hdr_tlab", lambda s: [f"{C}/stw_mt_hdr", "--tlab", f"--seed={s + 100000}", "--iterations=200", "--workers=2,4"],
     {"GCRY_BITMAP_ALLOC": "0"}, 900),
    ("stw_mt_hdr_tlab", lambda s: [f"{C}/stw_mt_hdr", "--tlab", f"--seed={s + 200000}", "--iterations=200", "--workers=2,4"],
     {"GCRY_BITMAP_ALLOC": "0"}, 900),
    ("stw_mt_hdr_tlab_nursery", lambda s: [f"{C}/stw_mt_hdr", "--tlab", "--nursery", f"--seed={s}", "--iterations=200", "--workers=2,4"],
     {"GCRY_BITMAP_ALLOC": "0", **DIAG}, 900),
    ("pattern_fuzz", lambda s: [f"{C}/pattern_fuzz", f"--seed={s}", "--phases=200", "--objects-per-phase=5000"], {}, 900),
    ("pattern_fuzz+diag", lambda s: [f"{C}/pattern_fuzz", f"--seed={s}", "--phases=200", "--objects-per-phase=5000"], DIAG, 900),
    ("mt_prop", lambda s: [f"{C}/mt_prop", f"--seed={s}", "--iterations=500", "--workers=2,4,8"], {}, 900),
    ("prop", lambda s: [f"{C}/prop", f"--seed={s}", "--iterations=100000"], {}, 900),
    ("layout_prop", lambda s: [f"{C}/layout_prop", f"--seed={s}", "--iterations=10000"], {}, 900),
    ("fuzz", lambda s: [f"{C}/fuzz", "--seconds=300", f"--seed={s}"], {}, 600),
    ("thread_storm", lambda s: [f"{C}/thread_storm", "--iterations=1000", "--workers=10"], {}, 900),
]

lock = threading.Lock()
queue = ((job, seed) for seed in itertools.count(1000) for job in JOBS)
out = open(f"{C}/results.tsv", "a", buffering=1)


def lane(n):
    while time.time() < DEADLINE:
        with lock:
            (name, argv, env, timeout), seed = next(queue)
        start = time.time()
        log = f"{C}/logs/{name}-{seed}-{n}.log"
        with open(log, "w") as f:
            try:
                rc = subprocess.run(argv(seed), env={**os.environ, **env}, stdout=f, stderr=subprocess.STDOUT,
                                    timeout=timeout).returncode
            except subprocess.TimeoutExpired:
                rc = "TIMEOUT"
        dur = time.time() - start
        ok = rc == 0
        with lock:
            out.write(f"{int(start)}\t{name}\t{seed}\t{rc}\t{dur:.1f}\n")
        if ok:
            os.remove(log)


threads = [threading.Thread(target=lane, args=(i,)) for i in range(LANES)]
for t in threads:
    t.start()
for t in threads:
    t.join()
print("campaign done")
