#!/usr/bin/env python3
"""Resident-memory breakdown at a gcry probe run's peak (KN_PEAK=1 runs).

The peak row is the collection Start with the highest VmRSS: a collection
starts when the threshold's worth of garbage is in the heap, so that is when
the heap is fullest (VmHWM is never set between two Starts by more than the
sampling resolution; the script prints the run's VmHWM next to it).

Usage: peak.py probe-stderr.txt [...]
"""
import gzip
import sys

M = 1024 * 1024
SIZES = [16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896, 1024,
         1280, 1536, 1792, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192, 10240, 12288, 14336,
         16384, 20480, 24576, 28672, 32768]
for path in sys.argv[1:]:
    ev, cls = [], {}
    for line in (gzip.open if path.endswith(".gz") else open)(path, "rt", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if f[0] == "ev":
            ev.append([int(x) for x in f[1:]])
        elif f[0] == "cls":
            cls[int(f[1])] = [int(x) for x in f[2:]]
    starts = [i for i, r in enumerate(ev) if r[0] == 0]
    i = max(starts, key=lambda k: ev[k][2])
    r = ev[i]
    hwm = max(x[3] for x in ev)
    kind, t, rss, _, anon, file_ = r[:6]
    coll, heap, large, lfree, sclive, dormant, thr, ffree, rel, unm, since, mapped, pace, small_res, large_res = r[6:21]
    nonheap = anon * 1024 - small_res - large_res
    # Live at the last sweep: the End row before this Start.
    prev = next(ev[k] for k in range(i - 1, -1, -1) if ev[k][0] == 1)
    live_large = prev[8] - prev[9]
    print(f"== {path}: peak at collection {coll + 1} start, t={t/1e6:.0f} ms, VmRSS {rss/1024:.1f} MB (run VmHWM {hwm/1024:.1f})")
    print(f"  file-backed (binary, libc)      {file_/1024:6.1f} MB")
    print(f"  anon outside gcry chunks        {nonheap/M:6.1f} MB  (RssAnon minus mincore; RssAnon lags by up to ~2 MB)")
    print(f"  large chunks resident           {large_res/M:6.1f} MB  (large mapped {large/M:.1f}, on free list {lfree/M:.1f})")
    print(f"  size-class chunks resident      {small_res/M:6.1f} MB  (mapped {(heap-large)/M:.1f})")
    print(f"  live at the last sweep          {(sclive + live_large)/M:6.1f} MB  (small {sclive/M:.1f}, large {live_large/M:.1f})")
    print(f"  allocated since (small, large)  {since/M:6.1f} MB  (threshold {thr/M:.1f}, pace {pace}%)")
    print(f"  rest (free blocks, empties)     {(small_res + large_res - sclive - live_large - since)/M:6.1f} MB  (last sweep: fully free {ffree/M:.1f}, released {rel/M:.1f})")
    c = cls.get(i)
    if c:
        top = sorted(((c[k], k) for k in range(80) if c[k]), reverse=True)[:6]
        print("    by class: " + ", ".join(f"{SIZES[k // 2]}{'a' if k % 2 else ''} {kb/1024:.1f}" for kb, k in top) + "  (MB; a = atomic)")
