#!/usr/bin/env python3
"""Overnight varied-seed campaign with stall capture.

Lanes pull (job, seed) pairs round-robin until the deadline. A run that
outlives its timeout is not just killed: every thread's name/state/wchan is
recorded and gdb takes a backtrace of all threads through a live one (the
leader can be a zombie while other threads run on), then it is killed.
"""
import ctypes, itertools, os, subprocess, sys, threading, time

C = os.path.dirname(os.path.abspath(__file__))
SOUND = {"GCRY_SOUND": "1"}
HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
LANES = int(sys.argv[2]) if len(sys.argv) > 2 else 5
OUT = sys.argv[3] if len(sys.argv) > 3 else "results-night.tsv"
DEADLINE = time.time() + HOURS * 3600
DIAG = {"GCRY_POISON_FREED": "1", "GCRY_SEGV_REPORT": "1", "GCRY_STW_WATCHDOG_MS": "10000"}
CHURN = {"GCRY_UNMAP_GUARD": "1", "GCRY_SEGV_REPORT": "1", "GCRY_POISON_HOLDERS": "1",
         "GCRY_STW_WATCHDOG_MS": "10000"}

JOBS = [
    ("stw_mt", lambda s: [f"{C}/stw_mt", f"--seed={s}", "--iterations=200", "--workers=2,4,8"], {}, 300),
    ("stw_mt+diag", lambda s: [f"{C}/stw_mt", f"--seed={s}", "--iterations=200", "--workers=2,4,8"], DIAG, 300),
    ("stw_mt+diag", lambda s: [f"{C}/stw_mt", f"--seed={s + 100000}", "--iterations=200", "--workers=2,4,8"], DIAG, 300),
    ("stw_mt_hdr_tlab", lambda s: [f"{C}/stw_mt_hdr", "--tlab", f"--seed={s}", "--iterations=200", "--workers=2,4"],
     {"GCRY_BITMAP_ALLOC": "0"}, 300),
    ("stw_mt_hdr_tlab_nursery", lambda s: [f"{C}/stw_mt_hdr", "--tlab", "--nursery", f"--seed={s}", "--iterations=200", "--workers=2,4"],
     {"GCRY_BITMAP_ALLOC": "0", **DIAG}, 300),
    ("pattern_fuzz+diag", lambda s: [f"{C}/pattern_fuzz", f"--seed={s}", "--phases=200", "--objects-per-phase=5000"], DIAG, 900),
    ("churn", lambda s: [f"{C}/churn", "--child"], CHURN, 300),
    ("churn_hdr", lambda s: [f"{C}/churn_hdr", "--child"], CHURN, 300),
    ("index_grow", lambda s: [f"{C}/index_grow", "--child"],
     {"GCRY_INDEX_GROW_TEST_STALL_MS": "50", "GCRY_POISON_FREED": "1", "GCRY_SEGV_REPORT": "1"}, 300),
    ("thread_storm", lambda s: [f"{C}/thread_storm", "--iterations=1000", "--workers=10"], {}, 300),
]

# yama ptrace_scope=1: only a declared tracer may attach, so every child
# declares "any" before exec; the stall capture's gdb is a sibling.
_libc = ctypes.CDLL(None, use_errno=True)


def _allow_ptrace():
    _libc.prctl(0x59616d61, ctypes.c_ulong(0xffffffffffffffff), 0, 0, 0)


lock = threading.Lock()
queue = ((job, seed) for seed in itertools.count(20000) for job in JOBS)
out = open(f"{C}/{OUT}", "a", buffering=1)
os.makedirs(f"{C}/night", exist_ok=True)


def capture_stall(pid, f):
    f.write("\n--- STALL CAPTURE\n")
    live = None
    try:
        for tid in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
            base = f"/proc/{pid}/task/{tid}"
            try:
                comm = open(f"{base}/comm").read().strip()
                state = open(f"{base}/stat").read().split(")")[-1].split()[0]
                wchan = open(f"{base}/wchan").read().strip()
            except OSError:
                continue
            f.write(f"task {tid} {comm} state={state} wchan={wchan}\n")
            if live is None and state != "Z":
                live = tid
    except OSError as e:
        f.write(f"no task list: {e}\n")
    if live:
        f.flush()
        r = subprocess.run(["gdb", "-q", "-batch", "-p", live, "-ex", "set pagination off",
                            "-ex", "info threads", "-ex", "thread apply all bt 40"],
                           capture_output=True, text=True, timeout=120)
        f.write(r.stdout[-200000:])
        f.write(r.stderr[-4000:])


def lane(n):
    while time.time() < DEADLINE:
        with lock:
            (name, argv, env, timeout), seed = next(queue)
        start = time.time()
        log = f"{C}/night/{name}-{seed}-{n}.log"
        with open(log, "w") as f:
            p = subprocess.Popen(argv(seed), env={**os.environ, **env, **SOUND}, stdout=f, stderr=subprocess.STDOUT,
                                 preexec_fn=_allow_ptrace)
            try:
                rc = p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                capture_stall(p.pid, f)
                p.kill()
                p.wait()
                rc = "TIMEOUT"
        dur = time.time() - start
        with lock:
            out.write(f"{int(start)}\t{name}\t{seed}\t{rc}\t{dur:.1f}\n")
        if rc == 0:
            os.remove(log)


threads = [threading.Thread(target=lane, args=(i,)) for i in range(LANES)]
for t in threads:
    t.start()
for t in threads:
    t.join()
print("campaign done")
