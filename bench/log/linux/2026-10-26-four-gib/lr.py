#!/usr/bin/env python3
"""lr.py N BIN ARM=ENV[,ENV]... : interleaved JsonGenerate reps of a counters
build (bench/runner_ab/gc_counters.cr in front of crystal-metric's main.cr).
One line per run: arm, rep, peak MiB (ru_maxrss), four_gib_fences,
four_gib_remaps, heap_size at exit (MiB)."""
import os, re, subprocess, sys, resource

n, binp = int(sys.argv[1]), sys.argv[2]
arms = []
for spec in sys.argv[3:]:
    name, _, envs = spec.partition("=")
    env = dict(os.environ, SILENT="1")
    for kv in filter(None, envs.split(",")):
        k, v = kv.split(":", 1)
        env[k] = v
    arms.append((name, env))
for i in range(n):
    for name, env in arms:
        pid = os.posix_spawn(binp, [binp, "JsonGenerate"], env,
                             file_actions=[(os.POSIX_SPAWN_OPEN, 1, "/dev/null", os.O_WRONLY, 0),
                                           (os.POSIX_SPAWN_OPEN, 2, "/tmp/lr-%d.err" % os.getpid(), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)])
        _, status, ru = os.wait4(pid, 0)
        err = open("/tmp/lr-%d.err" % os.getpid()).read()
        f = re.search(r"four_gib_fences=(\d+)", err)
        r = re.search(r"four_gib_remaps=(\d+)", err)
        h = re.search(r"heap_size=(\d+)", err)
        print(name, i, round(ru.ru_maxrss / 1024), f and f.group(1), r and r.group(1),
              h and round(int(h.group(1)) / 2**20), flush=True)
