#!/usr/bin/env python3
"""Summarise kn_probe's `ev` rows: per collection Start/End, RSS and gcry
heap counters (MiB), and where VmHWM was set.

Usage: events.py probe-stderr.txt [--all]

Columns (gcry only after `|`): collections, heap_size, large_mapped_bytes,
large_free_bytes, size_class_live_bytes, dormant_chunk_bytes, gc_threshold,
fully_free_chunk_bytes, released_chunk_bytes (the last three as of the last
sweep), bytes_since_gc, chunks_mapped (count), threshold_pace_pct.
"""
import gzip
import sys

KIND = {0: "start", 1: "end", 2: "ph:start", 3: "ph:init", 4: "ph:collect", 5: "ph:run", 6: "ph:end"}
rows = []
for line in (gzip.open if sys.argv[1].endswith(".gz") else open)(sys.argv[1], "rt", errors="replace"):
    if line.startswith("ev\t"):
        rows.append([int(x) for x in line.split("\t")[1:]])
M = 1024 * 1024
show_all = "--all" in sys.argv
hwm_prev = 0
print("kind        t_ms   rss_MB  hwm_MB  anon_MB | coll heap  large lfree sclive dormant thr  ffree rel   since mapped pace")
for r in rows:
    kind, t, rss, hwm, anon, file_ = r[:6]
    gc = r[6:]
    jump = hwm > hwm_prev
    if show_all or jump or kind >= 2:
        g = ""
        if any(gc):
            coll, heap, large, lfree, sclive, dormant, thr, ffree, rel, unm = gc[:10]
            since, mapped, pace = (gc[10:13] + [0, 0, 0])[:3]
            g = (f"{coll:4d} {heap/M:5.1f} {large/M:5.1f} {lfree/M:5.1f} {sclive/M:6.1f} {dormant/M:6.1f} {thr/M:5.1f} {ffree/M:5.1f} {rel/M:5.1f}"
                 f" {since/M:6.1f} {mapped:5d} {pace:4d}")
        print(f"{KIND.get(kind, kind):10s} {t/1e6:7.1f} {rss/1024:7.1f} {hwm/1024:7.1f} {anon/1024:7.1f} | {g}{'  <-- hwm' if jump else ''}")
    hwm_prev = max(hwm_prev, hwm)
print(f"collections: {sum(1 for r in rows if r[0] == 0)}  final VmHWM {hwm_prev/1024:.1f} MB")
