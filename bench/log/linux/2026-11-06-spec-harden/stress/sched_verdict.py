#!/usr/bin/env python3
"""Per sched log: the threads' shape from the first gdb backtrace pass.

A log is the crystal-lang/crystal#17486 resume shape when >= 2 threads are in
`Parallel::Scheduler#resume` (parallel/scheduler.cr) and no thread has a gcry
frame other than a service thread's idle wait: gcry-mark parked in
`wait_on_mark_word`, gc-idle sleeping in `loop_forever`, the Monitor's
`run_loop` wrapper (monitor_gate.cr) sleeping. Anything else under src/gcry/
is printed as a gcry frame.
"""
import re
import sys

IDLE = {
    "parallel_mark.cr": {"wait_on_mark_word", "mark_wait", "wait_for_mark_epoch", "mark_worker_loop",
                         "run_mark_worker", "gcry_mark_worker_main", "->"},
    "idle_release.cr": {"loop_forever", "->"},
    "monitor_gate.cr": {"run_loop"},
}
FRAME = re.compile(r"^#\d+\s+(?:0x[0-9a-f]+ in )?(\S+) \(.*\) at (\S+?):(\d+)")


def threads(text):
    # The first full backtrace pass ends where the per-frame locals pass starts.
    text = text.split("--- innermost frames", 1)[0]
    cur = None
    out = {}
    for line in text.splitlines():
        m = re.match(r'^Thread \d+ \(Thread \S+ \(LWP (\d+)\) "([^"]*)"\):', line)
        if m:
            cur = f"{m.group(2)}/{m.group(1)}"
            out[cur] = []
            continue
        if cur and line.startswith("#"):
            f = FRAME.match(line)
            if f:
                out[cur].append((f.group(1), f.group(2), int(f.group(3))))
    return out


def verdict(path):
    text = open(path, errors="replace").read()
    ts = threads(text)
    resume = [t for t, fr in ts.items() if any(fn == "resume" and "parallel/scheduler.cr" in p for fn, p, _ in fr)]
    gcry = []
    for t, fr in ts.items():
        for fn, p, ln in fr:
            if "/src/gcry/" not in p:
                continue
            base = p.rsplit("/", 1)[1]
            if fn in IDLE.get(base, ()):
                continue
            gcry.append(f"{t}: {fn} {base}:{ln}")
    classified = "STALL CLASSIFIED" in text
    shape = len(resume) >= 2 and not gcry
    return shape, classified, resume, gcry, len(ts)


bad = 0
for path in sys.argv[1:]:
    shape, classified, resume, gcry, n = verdict(path)
    name = path.rsplit("/", 1)[1]
    tag = "17486-shape" if shape else "NOT-17486"
    bad += not shape
    print(f"{name}: {tag} threads={n} resume={len(resume)} ({' '.join(resume)}) classified={classified}"
          + (f" GCRY FRAMES: {'; '.join(gcry)}" if gcry else " gcry-frames=none"))
print(f"{len(sys.argv) - 1} logs, {bad} not the 17486 shape")
