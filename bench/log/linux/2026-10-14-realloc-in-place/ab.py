#!/usr/bin/env python3
"""Interleaved A/B for crystal-metric rows: /usr/bin/time -v per run.

usage: ab.py OUT.json TRIALS BENCH[,BENCH] ARM=BIN[:ENV=V;ENV=V] ...
Each run: bench-reported seconds, wall, user/sys, max RSS (KiB), minor faults,
and VmPeak (KiB), the largest address space, printed at exit by vmpeak.so:
  gcc -O2 -shared -fPIC vmpeak.c -o vmpeak.so   (next to this script)
Arm order rotates per trial.
"""
import json, os, re, statistics, subprocess, sys

out_path, trials, benches = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(",")
arms = []
for spec in sys.argv[4:]:
    name, rest = spec.split("=", 1)
    binp, _, envs = rest.partition(":")
    env = dict(e.split("=", 1) for e in envs.split(";") if e)
    arms.append((name, binp, env))

line_re = re.compile(r"^(\w+):\s+(ok|err|FAIL).*?\bin\s+([0-9.]+)s", re.M)
fields = {
    "rss_kib": (re.compile(r"Maximum resident set size \(kbytes\):\s+(\d+)"), int),
    "minflt": (re.compile(r"Minor \(reclaiming a frame\) page faults:\s+(\d+)"), int),
    "wall": (re.compile(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\):\s+([0-9:.]+)"), None),
    "user": (re.compile(r"User time \(seconds\):\s+([0-9.]+)"), float),
    "sys": (re.compile(r"System time \(seconds\):\s+([0-9.]+)"), float),
}


def wall_s(v):
    s = 0.0
    for p in v.split(":"):
        s = s * 60 + float(p)
    return s


VMPEAK_SO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vmpeak.so")
vmpeak_re = re.compile(r"^VMPEAK (\d+) VMHWM (\d+)$", re.M)


def run(binp, env, bench):
    e = dict(os.environ)
    e.update(env)
    # `env` execs the benchmark, so only it carries the preload, which prints
    # VmPeak (the process's largest address space) from a libc destructor.
    p = subprocess.run(["/usr/bin/time", "-v", "env", f"LD_PRELOAD={VMPEAK_SO}", binp, bench],
                       capture_output=True, env=e, text=True)
    out, err = p.stdout, p.stderr
    m = line_re.search(out)
    v = vmpeak_re.search(err)
    r = {"bench_s": float(m.group(3)) if m else None, "status": m.group(2) if m else "none",
         "vm_peak_kib": int(v.group(1)) if v else None}
    for k, (rx, conv) in fields.items():
        mm = rx.search(err)
        r[k] = None if not mm else (wall_s(mm.group(1)) if conv is None else conv(mm.group(1)))
    return r


results = {a[0]: {b: [] for b in benches} for a in arms}
for t in range(trials):
    for bench in benches:
        k = t % len(arms)
        for name, binp, env in arms[k:] + arms[:k]:
            r = run(binp, env, bench)
            results[name][bench].append(r)
            print(f"t{t+1} {bench:22s} {name:14s} bench={r['bench_s']} wall={r['wall']} user={r['user']} "
                  f"sys={r['sys']} rss={r['rss_kib']} minflt={r['minflt']} vmpeak={r['vm_peak_kib']} {r['status']}",
                  flush=True)


def med(rs, key):
    xs = [r[key] for r in rs if r[key] is not None]
    return statistics.median(xs) if xs else None


summary = {}
for name, _, _ in arms:
    summary[name] = {}
    for bench in benches:
        rs = results[name][bench]
        s = {key: med(rs, key) for key in ("bench_s", "wall", "user", "sys", "rss_kib", "minflt", "vm_peak_kib")}
        bs = [r["bench_s"] for r in rs if r["bench_s"] is not None]
        s["range_bench_s"] = [min(bs), max(bs)] if bs else None
        summary[name][bench] = s

json.dump({"arms": [[a[0], a[1], a[2]] for a in arms], "results": results, "summary": summary},
          open(out_path, "w"), indent=1)
print()
print(f"{'bench':22s} {'arm':14s} {'bench s':>8s} {'(min-max)':>14s} {'wall s':>7s} {'user':>6s} {'sys':>6s} "
      f"{'RSS MiB':>8s} {'minflt':>8s} {'VmPeak MiB':>10s}")
for bench in benches:
    for name, _, _ in arms:
        s = summary[name][bench]
        lo, hi = s["range_bench_s"]
        print(f"{bench:22s} {name:14s} {s['bench_s']:8.4f} {f'({lo:.3f}-{hi:.3f})':>14s} {s['wall']:7.2f} "
              f"{s['user']:6.2f} {s['sys']:6.2f} {s['rss_kib']/1024:8.1f} {int(s['minflt']):8d} "
              f"{(s['vm_peak_kib'] or 0)/1024:10.1f}")
