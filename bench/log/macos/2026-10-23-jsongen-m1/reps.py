#!/usr/bin/env python3
"""reps.py OUTDIR N ARM=BIN[:ENV=V,...] ...

Interleaved reps of one crystal-metric bench (BENCH, default JsonGenerate),
one child at a time, each killed after 120 s. Per run: the child's stdout
(the probe build's HOLDPROBE / FALSEWORD lines) in OUTDIR/<arm>-<i>.out, and
one summary line: arm, rep, exit status, peak MiB (ru_maxrss: bytes on
Darwin, KiB on Linux), minor faults, wall, and the root-sourced (src != 3)
HOLDPROBE hits on large blocks: collection, source, word, block size, slot
offset from the collection's entry SP.
"""
import os, re, signal, sys, time

out, n = sys.argv[1], int(sys.argv[2])
os.makedirs(out, exist_ok=True)
arms = []
for spec in sys.argv[3:]:
    name, rest = spec.split("=", 1)
    binp, _, envs = rest.partition(":")
    env = dict(os.environ, SILENT="1")
    for kv in filter(None, envs.split(",")):
        k, v = kv.split("=", 1)
        env[k] = v
    arms.append((name, binp, env))
bench = os.environ.get("BENCH", "JsonGenerate")
scale = 1 if sys.platform == "darwin" else 1024
child = None


def bye(*_):
    if child:
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
    sys.exit(1)


for s in (signal.SIGTERM, signal.SIGINT, signal.SIGALRM):
    signal.signal(s, bye)
pat = re.compile(r"HOLDPROBE coll=(\d+) src=(\d+) cand=(0x[0-9a-f]+) user=\S+ size=(\d+) slot=\S+ slot-entry=(-?\d+)")
for i in range(n):
    for name, binp, env in arms:
        path = "%s/%s-%d.out" % (out, name, i)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        t = time.time()
        child = os.posix_spawn(binp, [binp, bench], env, file_actions=[(os.POSIX_SPAWN_DUP2, fd, 1)])
        os.close(fd)
        signal.alarm(120)
        _, status, ru = os.wait4(child, 0)
        signal.alarm(0)
        child = None
        hits = []
        for m in pat.finditer(open(path, errors="replace").read()):
            if m.group(2) != "3":
                hits.append("c%s/src%s/%s/%dM/%s" % (m.group(1), m.group(2), m.group(3), int(m.group(4)) >> 20, m.group(5)))
        print(name, i, status, round(ru.ru_maxrss * scale / 2**20), ru.ru_minflt, round(time.time() - t, 2), " ".join(hits), flush=True)
