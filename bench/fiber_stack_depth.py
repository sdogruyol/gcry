#!/usr/bin/env python3
"""Which fiber stacks are deeply used, and by what code?

`GCRY_SOUND=1` scans every parked fiber from its low-water mark — the deepest
page ever faulted — so its pause tracks how much stack was *ever touched*, and
its distribution is wide (ROADMAP: "Which fibers are deeply used, and why").
This answers it from outside the process, with no collector change:

  1. launch the server as this script's own child (Yama `ptrace_scope=1`
     lets a parent read a child's `/proc/<pid>/mem`), drive it with wrk;
  2. find every 8 MiB anonymous read-write mapping (fiber stacks and pthread
     stacks — the census names which is which by each task's SP);
  3. from `/proc/<pid>/pagemap`, a stack's touched depth is its top minus its
     lowest page with the present or swapped bit — the collector's own
     low-water predicate;
  4. read the deepest 64 KiB that was touched, keep the words that point into
     the executable's text, and symbolize them with `addr2line`: the frames
     that were live when the stack was at its deepest.

Stale words count, so the symbols are "code that ran this deep", not a
backtrace. A stack's depth is a high-water mark over its whole life, and
Crystal's stack pool hands a released stack to the next fiber without
clearing it, so the code named may belong to an earlier owner.

  python3 bench/fiber_stack_depth.py bin/kemal-gcry-mt \\
      --env EC_PARALLELISM=4 --env GCRY_SOUND=1 --wrk "-c100 -d15s"

Measured 2026-09-26 (Kemal /json, EC4, gcry and Boehm alike): ~105 stacks,
touched depth p50 = p99 = 20 KiB, deepest frames Crystal's exception unwinder
under `HTTP::Server#handle_client`. No fiber is deeply used; the stack that was
read whole was SYSMON's pthread stack, by the collector
(`bench/log/linux/2026-09-26-sysmon-guard-scan/FINDINGS.md`).

Linux only.
"""
import argparse
import collections
import os
import shlex
import struct
import subprocess
import sys
import time
import urllib.request

PAGE = os.sysconf("SC_PAGE_SIZE")
STACK_SIZE = 8 * 1024 * 1024
DEEP_WINDOW = 64 * 1024
PM_PRESENT = 1 << 63
PM_SWAPPED = 1 << 62
TOUCHED_IDX = []


def maps(pid):
    out = []
    with open(f"/proc/{pid}/maps") as f:
        for line in f:
            parts = line.split(None, 5)
            lo, hi = (int(x, 16) for x in parts[0].split("-"))
            path = parts[5].strip() if len(parts) > 5 else ""
            out.append((lo, hi, parts[1], int(parts[2], 16), path))
    return out


def touched(pm, lo, hi):
    """(lowest touched page or None, number of touched pages) in [lo, hi):
    touched = present or swapped, the collector's low-water predicate."""
    n = (hi - lo) // PAGE
    pm.seek((lo // PAGE) * 8)
    data = pm.read(n * 8)
    low = None
    count = 0
    TOUCHED_IDX.clear()
    for i in range(n):
        (e,) = struct.unpack_from("<Q", data, i * 8)
        if e & (PM_PRESENT | PM_SWAPPED):
            count += 1
            TOUCHED_IDX.append(i)
            if low is None:
                low = lo + i * PAGE
    return low, count


def task_sps(pid):
    """Each task's saved user SP (field 29 of stat, readable by the parent)."""
    sps = {}
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            with open(f"/proc/{pid}/task/{tid}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            with open(f"/proc/{pid}/task/{tid}/comm") as f:
                sps[int(fields[26])] = f.read().strip()
        except (OSError, IndexError, ValueError):
            pass
    return sps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("server")
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--port", default="3031")
    ap.add_argument("--path", default="/json")
    ap.add_argument("--wrk", default="-c100 -d15s")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--wait", type=float, default=0.0, help="seconds to sleep after load (or instead of it)")
    a = ap.parse_args()

    env = dict(os.environ, PORT=a.port)
    for kv in a.env:
        k, v = kv.split("=", 1)
        env[k] = v
    server = subprocess.Popen([a.server], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f"http://127.0.0.1:{a.port}"
    try:
        for _ in range(200):
            try:
                urllib.request.urlopen(base + "/", timeout=1).read()
                break
            except OSError:
                time.sleep(0.05)
        if a.wrk:
            subprocess.run(["wrk", *shlex.split(a.wrk), base + a.path], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(a.wait)
        try:
            stats = urllib.request.urlopen(base + "/gc-stats", timeout=5).read().decode()
        except OSError:
            stats = ""
        census(server.pid, a.server, a.top, stats)
    finally:
        server.kill()
        server.wait()


def census(pid, exe_path, top, stats):
    mp = maps(pid)
    exe = os.path.realpath(exe_path)
    text = [(lo, hi, off) for lo, hi, perm, off, path in mp if path == exe and "x" in perm]
    base = min(lo for lo, hi, perm, off, path in mp if path == exe)
    sps = task_sps(pid)

    stacks = []
    # `/proc/<pid>/mem` through an unbuffered fd and exact-range `pread`s only.
    # A buffered reader over-reads past the range asked for, and these reads
    # use FOLL_FORCE, which goes straight through the next stack's PROT_NONE
    # guard page (it keeps VM_MAYREAD) and maps the zero page under it. The
    # first version of this census did exactly that and reported ~100 KiB
    # "touched" at the bottom of 102 of 107 stacks — its own reads, measured
    # by pagemap on the next pass (0 bands before any read, 102 after).
    mem = os.open(f"/proc/{pid}/mem", os.O_RDONLY)
    with open(f"/proc/{pid}/pagemap", "rb", buffering=0) as pm:
        for lo, hi, perm, off, path in mp:
            # 8 MiB, or 8 MiB less the guard page `mprotect` split off it
            # (Crystal's fiber stacks and glibc's thread stacks both).
            if path or perm[:2] != "rw" or hi - lo not in (STACK_SIZE, STACK_SIZE - PAGE):
                continue
            low, pages = touched(pm, lo, hi)
            if low is None:
                continue
            owner = next((name for sp, name in sps.items() if lo <= sp < hi), None)
            depth = hi - low
            words = []
            try:
                buf = os.pread(mem, min(DEEP_WINDOW, depth), low)
            except OSError:
                buf = b""
            for i in range(0, len(buf) - 7, 8):
                (w,) = struct.unpack_from("<Q", buf, i)
                if any(tlo <= w < thi for tlo, thi, _ in text):
                    words.append(w - base)
            if pages * PAGE < depth // 4:
                idx = TOUCHED_IDX
                owner = f"pages {idx[:6]}..{idx[-4:]} of {(hi - lo) // PAGE}"
            stacks.append((depth, lo, owner, words, pages))
    os.close(mem)

    stacks.sort(reverse=True)
    # A stack is used contiguously from its top down, so its touched pages
    # fill most of its depth. A mapping touched at its low end and barely
    # anywhere else is an 8 MiB *buffer* that happens to be stack-sized — it
    # was once reported here as a stack 8188 KiB deep. Reported apart.
    sparse = [s for s in stacks if s[4] * PAGE < s[0] // 4]
    stacks = [s for s in stacks if s[4] * PAGE >= s[0] // 4]
    for depth, lo, owner, ws, pages in sparse:
        print(f"not a stack's use: {hex(lo)} touched {pages} page(s) but its lowest "
              f"touched page is {depth // 1024} KiB below the top ({owner or 'no task on it'})")
    depths = sorted(d for d, *_ in stacks)
    kib = lambda b: b / 1024
    print(f"stacks: {len(stacks)} touched 8 MiB mappings "
          f"({sum(1 for s in stacks if s[2])} are a live task's current stack)")
    if depths:
        q = lambda p: depths[min(len(depths) - 1, int(p * len(depths)))]
        print(f"touched depth KiB: min {kib(depths[0]):.0f}  p50 {kib(q(0.5)):.0f}  "
              f"p90 {kib(q(0.9)):.0f}  p99 {kib(q(0.99)):.0f}  max {kib(depths[-1]):.0f}  "
              f"total {kib(sum(depths)) / 1024:.1f} MiB")
        hist = collections.Counter()
        for d in depths:
            b = 4
            while b * 1024 < d:
                b *= 2
            hist[b] += 1
        print("histogram (depth <= KiB: stacks): " +
              "  ".join(f"{b}: {hist[b]}" for b in sorted(hist)))

    # Symbolize the deepest windows of the deepest stacks, then say which
    # functions appear there and on how many stacks.
    deep = stacks[:top]
    uniq = sorted({w for *_, ws, _pages in deep for w in ws})
    names = {}
    if uniq:
        out = subprocess.run(["addr2line", "-f", "-C", "-e", exe] + [hex(w) for w in uniq],
                             capture_output=True, text=True).stdout.splitlines()
        for i, w in enumerate(uniq):
            fn = out[2 * i] if 2 * i < len(out) else "??"
            loc = out[2 * i + 1] if 2 * i + 1 < len(out) else ""
            names[w] = (fn, loc.split("/src/")[-1] if "/src/" in loc else loc)
    per_fn = collections.Counter()
    for *_, ws, _pages in deep:
        for fn in {names[w][0] for w in ws if w in names}:
            per_fn[fn] += 1
    print(f"\nfunctions in the deepest 64 KiB of the {len(deep)} deepest stacks "
          f"(stacks naming each):")
    for fn, n in per_fn.most_common(40):
        loc = next((names[w][1] for w in names if names[w][0] == fn), "")
        print(f"  {n:3d}  {fn[:90]}  {loc}")
    print("\ndeepest stacks:")
    for depth, lo, owner, ws, _pages in deep[:10]:
        innermost = [names[w][0] for w in ws[:6] if w in names]
        print(f"  {kib(depth):7.0f} KiB  {hex(lo)}  {owner or 'parked/pooled'}  "
              f"{' <- '.join(f[:40] for f in innermost)}")
    if stats:
        import json
        try:
            s = json.loads(stats)
            print(f"\n/gc-stats: collections {s.get('collections')}  "
                  f"low_water_skipped_bytes {s.get('low_water_skipped_bytes')}")
        except ValueError:
            pass


if __name__ == "__main__":
    sys.exit(main())
