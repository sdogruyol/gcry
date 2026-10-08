"""Kemal A/B on Windows: Boehm vs gcry req/s, interleaved, server and load generator
pinned to disjoint cores. Each (trial, endpoint, arm) starts a fresh server.

usage: python kemal_ab.py --out DIR [--trials 7] [--duration 10s] [--conns 100]
"""
import argparse
import json
import os
import random
import socket
import statistics
import subprocess
import sys
import time

import psutil

sys.path.insert(0, os.path.dirname(__file__))
from ab_win import PMC, psapi  # noqa: E402  (GetProcessMemoryInfo wrapper)
import ctypes  # noqa: E402
import ctypes.wintypes as wt  # noqa: E402

KW = r"C:\gcry-eval\kemal-win"
OHA = r"C:\Users\dogru\AppData\Local\Microsoft\WinGet\Packages\hatoo.oha_Microsoft.Winget.Source_8wekyb3d8bbwe\oha.exe"
ARMS = {"boehm": os.path.join(KW, "kemal-boehm.exe"), "gcry": os.path.join(KW, "kemal-gcry.exe")}
SERVER_CPUS = list(range(0, 6))
LOAD_CPUS = list(range(6, 12))


def wait_port(port, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def oha(url, duration, conns):
    p = subprocess.Popen([OHA, "--no-tui", "--output-format", "json", "-z", duration, "-c", str(conns), url],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    psutil.Process(p.pid).cpu_affinity(LOAD_CPUS)
    out, err = p.communicate()
    if p.returncode != 0:
        raise RuntimeError(f"oha failed: {err.decode(errors='replace')}")
    return json.loads(out)


def peak_wset(handle):
    pmc = PMC()
    pmc.cb = ctypes.sizeof(PMC)
    psapi.GetProcessMemoryInfo(wt.HANDLE(int(handle)), ctypes.byref(pmc), pmc.cb)
    return pmc.PeakWorkingSetSize, pmc.WorkingSetSize


def one(arm, path, duration, conns, port):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GCRY_")}
    env["PORT"] = str(port)
    srv = subprocess.Popen([ARMS[arm]], cwd=KW, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        psutil.Process(srv.pid).cpu_affinity(SERVER_CPUS)
        if not wait_port(port):
            raise RuntimeError(f"{arm} did not listen")
        url = f"http://127.0.0.1:{port}{path}"
        oha(url, "2s", conns)  # warm-up, discarded
        r = oha(url, duration, conns)
        peak, ws = peak_wset(srv._handle)
        s = r["summary"]
        codes = r.get("statusCodeDistribution", {})
        return {"rps": s["requestsPerSec"], "success": s["successRate"], "codes": codes,
                "p50_ms": r["latencyPercentiles"]["p50"] * 1e3, "p99_ms": r["latencyPercentiles"]["p99"] * 1e3,
                "peak_wset": peak, "wset_end": ws, "alive": srv.poll() is None}
    finally:
        srv.kill()
        _, err = srv.communicate()
        if err:
            sys.stderr.write(f"[{arm} stderr] {err.decode(errors='replace')[-2000:]}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--trials", type=int, default=7)
    ap.add_argument("--duration", default="10s")
    ap.add_argument("--conns", type=int, default=100)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rnd = random.Random(a.seed)
    rows = []
    port = 3101
    with open(os.path.join(a.out, "raw.jsonl"), "w") as raw:
        for t in range(a.trials):
            for path in ["/json", "/"]:
                order = list(ARMS)
                rnd.shuffle(order)
                for arm in order:
                    port += 1
                    r = one(arm, path, a.duration, a.conns, port)
                    r.update(trial=t, path=path, arm=arm)
                    rows.append(r)
                    raw.write(json.dumps(r) + "\n")
                    raw.flush()
                    print(f"trial {t} {path} {arm}: {r['rps']:.0f} req/s success={r['success']} "
                          f"peak={r['peak_wset'] / 2**20:.1f}MiB alive={r['alive']}", file=sys.stderr, flush=True)
    med = statistics.median
    lines = ["| endpoint | arm | n | median req/s | min–max req/s | median p99 ms | median peak WS MiB | gcry ÷ Boehm |",
             "|---|---|---:|---:|---:|---:|---:|---:|"]
    for path in ["/json", "/"]:
        b = med([r["rps"] for r in rows if r["path"] == path and r["arm"] == "boehm"])
        for arm in ARMS:
            rs = [r for r in rows if r["path"] == path and r["arm"] == arm]
            v = [r["rps"] for r in rs]
            lines.append(f"| {path} | {arm} | {len(rs)} | {med(v):.0f} | {min(v):.0f}–{max(v):.0f} | "
                         f"{med([r['p99_ms'] for r in rs]):.2f} | {med([r['peak_wset'] for r in rs]) / 2**20:.1f} | "
                         f"{100 * med(v) / b:.1f}% |")
    summary = "\n".join(lines) + "\n"
    with open(os.path.join(a.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(summary)
    print(summary)


if __name__ == "__main__":
    main()
