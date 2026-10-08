"""Process-fresh, arm-shuffled A/B of crystal-metric on Windows: Boehm vs gcry.

Every (trial, bench) runs each arm once, as a fresh process, in a random order.
Per run it records the bench's own wall time (parsed from its output), total CPU
(user + kernel, GetProcessTimes) and PeakWorkingSetSize (GetProcessMemoryInfo),
both read from the process handle after the process exited, so nothing is polled.

usage: python ab_win.py --out DIR [--trials 11] [--benches A,B] [--arms boehm,gcry,...]
                        [--gcry-exe PATH] [--boehm-exe PATH] [--seed N]
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import json
import os
import random
import re
import statistics
import subprocess
import sys
import time

REPO = r"C:\gcry-eval\gcry"
BENCHES = ["Primes", "JsonParsePure", "JsonParseSerializable", "JsonParsePull", "JsonGenerate",
           "Binarytrees", "RegexDna", "Revcomp", "Knuckeotide", "Brainfuck", "Brainfuck2",
           "Matmul", "Threadring"]
LINE = re.compile(r"^(\w+):\s+(ok|err).*?\bin\s+([0-9.]+)s", re.M)


class PMC(ctypes.Structure):
    _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]


psapi = ctypes.WinDLL("psapi", use_last_error=True)
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi.GetProcessMemoryInfo.argtypes = [wt.HANDLE, ctypes.POINTER(PMC), wt.DWORD]
k32.GetProcessTimes.argtypes = [wt.HANDLE] + [ctypes.POINTER(wt.FILETIME)] * 4


def ft(f):
    return ((f.dwHighDateTime << 32) | f.dwLowDateTime) / 1e7


def run_one(exe, bench, env_extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GCRY_")}
    env.update(env_extra)
    t0 = time.perf_counter()
    p = subprocess.Popen([exe, bench], cwd=REPO, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    out, _ = p.communicate()
    outer = time.perf_counter() - t0
    h = wt.HANDLE(int(p._handle))  # still open after exit: counters stay readable
    pmc = PMC()
    pmc.cb = ctypes.sizeof(PMC)
    if not psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), pmc.cb):
        raise OSError(ctypes.get_last_error())
    c, e, kt, ut = wt.FILETIME(), wt.FILETIME(), wt.FILETIME(), wt.FILETIME()
    if not k32.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e), ctypes.byref(kt), ctypes.byref(ut)):
        raise OSError(ctypes.get_last_error())
    text = out.decode("utf-8", "replace")
    m = LINE.search(text)
    # The computed result: "ok", or the wrong value an `err` line prints. A
    # run's timing counts only if its result matches every other arm's (see
    # summarize): several benches print `err` on Windows under Boehm too.
    sig = None
    if m:
        sig = "ok" if m.group(2) == "ok" else (re.search(r"err result=(.*?), but expected", text) or [None, "?"])[1]
    return {
        "rc": p.returncode,
        "status": m.group(2) if m else None,
        "result_sig": sig,
        "wall": float(m.group(3)) if m else None,
        "outer_wall": outer,
        "cpu": ft(ut) + ft(kt),
        "user": ft(ut), "kernel": ft(kt),
        "peak_wset": pmc.PeakWorkingSetSize,
        "peak_commit": pmc.PeakPagefileUsage,
        "page_faults": pmc.PageFaultCount,
        "output": text if (not m or m.group(2) != "ok") else text[-400:],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--trials", type=int, default=11)
    ap.add_argument("--benches", default=",".join(BENCHES))
    ap.add_argument("--arms", default="boehm,gcry,gcry_serial,gcry_nopace")
    ap.add_argument("--boehm-exe", default=os.path.join(REPO, "bin", "cm-boehm.exe"))
    ap.add_argument("--gcry-exe", default=os.path.join(REPO, "bin", "cm-gcry.exe"))
    ap.add_argument("--seed", type=int, default=None)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rnd = random.Random(a.seed)
    all_arms = {
        "boehm": (a.boehm_exe, {}),
        "gcry": (a.gcry_exe, {}),
        "gcry_serial": (a.gcry_exe, {"GCRY_PARALLEL_MARK": "1"}),
        "gcry_nopace": (a.gcry_exe, {"GCRY_THRESHOLD_PACE": "100"}),
    }
    arms = a.arms.split(",")
    benches = a.benches.split(",")
    meta = {"argv": sys.argv, "arms": {k: all_arms[k] for k in arms}, "benches": benches,
            "trials": a.trials, "seed": a.seed, "started": time.strftime("%Y-%m-%d %H:%M:%S")}
    # Warm-up (discarded): Defender scans a fresh image on its first launch.
    for exe in sorted({all_arms[k][0] for k in arms}):
        run_one(exe, "Primes", {})
    rows = []
    raw_path = os.path.join(a.out, "raw.jsonl")
    with open(raw_path, "w") as raw:
        for t in range(a.trials):
            for b in benches:
                order = arms[:]
                rnd.shuffle(order)
                for arm in order:
                    exe, env = all_arms[arm]
                    r = run_one(exe, b, env)
                    r.update(trial=t, bench=b, arm=arm)
                    rows.append(r)
                    raw.write(json.dumps(r) + "\n")
                    raw.flush()
                    if r["wall"] is None:
                        print(f"!! trial {t} {b} {arm}: rc={r['rc']} no result line\n{r['output']}",
                              file=sys.stderr, flush=True)
            print(f"trial {t + 1}/{a.trials} done", file=sys.stderr, flush=True)
    meta["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    with open(os.path.join(a.out, "meta.json"), "w") as f:
        json.dump(meta, f, indent=1)
    summary = summarize(rows, benches, arms)
    with open(os.path.join(a.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(summary)
    print(summary)


def summarize(rows, benches, arms):
    med = statistics.median
    out = ["| bench | result | arm | n | median wall s | min–max s | median CPU s | median peak WS MiB | speed vs Boehm | peak WS × Boehm |",
           "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for b in benches:
        # A run is valid when it computed what most runs of this bench computed:
        # every arm then did the same work, whether or not that matches the
        # suite's Linux-derived `expected`.
        sigs = [r["result_sig"] for r in rows if r["bench"] == b and r["wall"] is not None]
        ref = max(set(sigs), key=sigs.count) if sigs else None
        valid = lambda r: r["wall"] is not None and r["result_sig"] == ref
        res = "ok" if ref == "ok" else "err (same in every arm)"
        base = [r for r in rows if r["bench"] == b and r["arm"] == "boehm" and valid(r)]
        bw = med([r["wall"] for r in base]) if base else None
        bm = med([r["peak_wset"] for r in base]) if base else None
        for arm in arms:
            rs = [r for r in rows if r["bench"] == b and r["arm"] == arm]
            ok = [r for r in rs if valid(r)]
            if not ok:
                out.append(f"| {b} | {res} | {arm} | 0/{len(rs)} | — | — | — | — | — | — |")
                continue
            w = [r["wall"] for r in ok]
            mw = med(w)
            pk = med([r["peak_wset"] for r in ok])
            speed = f"{100 * bw / mw:.0f}%" if bw else "—"
            mem = f"{pk / bm:.2f}×" if bm else "—"
            n = f"{len(ok)}" if len(ok) == len(rs) else f"{len(ok)}/{len(rs)}"
            out.append(f"| {b} | {res} | {arm} | {n} | {mw:.3f} | {min(w):.3f}–{max(w):.3f} | "
                       f"{med([r['cpu'] for r in ok]):.2f} | {pk / 2**20:.1f} | {speed} | {mem} |")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    main()
