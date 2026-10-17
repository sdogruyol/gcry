#!/usr/bin/env python3
"""Interleaved crystal-metric A/B with rusage counters.

Usage: ab2.py OUT.json REPS BENCH[,BENCH...] ARM=bin ...
Each (rep, bench) runs every arm once in a random order. Per run: whole-process
wall, the bench's own "in X s" (run() only, Fasta setup excluded), user/sys CPU,
minor/major faults, voluntary/involuntary context switches, ru_maxrss.
"""
import json, os, random, re, sys, time

out, reps, benches = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(",")
arms = dict(s.split("=", 1) for s in sys.argv[4:])
inner_re = re.compile(r"in ([0-9.]+)s")
rows = []
random.seed(20261015)
for r in range(reps):
    for b in benches:
        order = list(arms)
        random.shuffle(order)
        for a in order:
            t0 = time.monotonic()
            pid = os.fork()
            if pid == 0:
                try:
                    fd = os.open(f"{out}.stdout", os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
                    os.dup2(fd, 1); os.dup2(fd, 2)
                    os.execv(arms[a], [arms[a], b])
                finally:
                    os._exit(127)
            _, status, ru = os.wait4(pid, 0)
            wall = time.monotonic() - t0
            text = open(f"{out}.stdout", errors="replace").read()
            m = inner_re.search(text)
            rows.append(dict(rep=r, bench=b, arm=a, wall=wall,
                             inner=float(m.group(1)) if m else None,
                             utime=ru.ru_utime, stime=ru.ru_stime,
                             minflt=ru.ru_minflt, majflt=ru.ru_majflt,
                             nvcsw=ru.ru_nvcsw, nivcsw=ru.ru_nivcsw,
                             rss_kb=ru.ru_maxrss,
                             exit=os.waitstatus_to_exitcode(status)))
        print(f"rep {r} {b} done", file=sys.stderr, flush=True)
    with open(out, "w") as f:
        json.dump(rows, f, indent=0)
