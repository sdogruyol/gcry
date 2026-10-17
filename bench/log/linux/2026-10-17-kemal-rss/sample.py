#!/usr/bin/env python3
"""Resident-memory attribution for a running Kemal server under wrk.

Usage: sample.py OUT.json BIN PATH [ENV=VAL ...]

Starts BIN on CPUs 0-2 (PORT 3111), warms it with `wrk -t4 -c50 -d3s` on CPUs
3-11, then runs `wrk -t4 -c50 -d10s` while reading /proc/<pid>/smaps every
100 ms. Every sample is the Rss of each mapping, grouped into categories:

  gcry-*            gcry's own mappings, named by the probe build (os_map)
  fiber-stack       Crystal fiber stacks, named by vma_names.cr
  thread-stack      anonymous mappings holding a thread's SP
                    (/proc/<pid>/task/<tid>/syscall; threads in a syscall)
  libc-heap         [heap] (brk) and glibc arenas (anon, 64 MiB-aligned)
  binary            file mappings of BIN (text, rodata, data)
  bss               the anonymous mapping right after BIN's last file mapping
  libs              other file-backed mappings
  main-stack        [stack]
  anon-other        any other anonymous mapping (Boehm's heap lands here)

and, on gcry builds, /gc-stats once a second (heap counters over time). The
sample with the largest total Rss is the peak breakdown; VmHWM is read at the
end. Then /gc-collect and one more breakdown (post-collect).
"""
import json, os, re, subprocess, sys, time, urllib.request

PORT = 3111
out, binary, path = sys.argv[1], sys.argv[2], sys.argv[3]
extra_env = dict(a.split("=", 1) for a in sys.argv[4:])
STATS_KEYS = ["collections", "gc_threshold", "heap_size", "free_bytes", "bytes_since_gc",
              "small_mapped_bytes", "small_free_bytes", "large_mapped_bytes", "large_free_bytes",
              "size_class_live_bytes", "empty_chunk_warm_retain", "fully_free_chunk_bytes",
              "size_class_chunk_count", "parallel_mark_workers", "parallel_mark_runs",
              "large_cache_retain", "finalizer_entries", "live_objects"]

HDR = re.compile(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) (\S+) (\S+) (\S+)\s*(.*)$")


def read_smaps(pid):
    maps = []
    cur = None
    with open(f"/proc/{pid}/smaps") as f:
        for line in f:
            m = HDR.match(line)
            if m:
                cur = {"lo": int(m.group(1), 16), "hi": int(m.group(2), 16), "perm": m.group(3),
                       "inode": m.group(6), "name": m.group(7).strip(), "rss": 0}
                maps.append(cur)
            elif line.startswith("Rss:"):
                cur["rss"] = int(line.split()[1])
    return maps


def thread_sps(pid):
    sps = []
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            parts = open(f"/proc/{pid}/task/{tid}/syscall").read().split()
        except OSError:
            continue
        if len(parts) >= 9:
            sps.append(int(parts[-2], 16))
    return sps


def classify(maps, sps, binpath):
    cats = {}
    last_bin = -1
    for i, m in enumerate(maps):
        if m["name"] == binpath:
            last_bin = i
    for i, m in enumerate(maps):
        name = m["name"]
        if name.startswith("[anon:"):
            cat = name[6:-1]
        elif name == "[heap]":
            cat = "libc-heap"
        elif name == "[stack]":
            cat = "main-stack"
        elif name == binpath:
            cat = "binary"
        elif name.startswith("/"):
            cat = "libs"
        elif name.startswith("["):
            cat = "kernel"
        elif i == last_bin + 1 and m["lo"] == maps[last_bin]["hi"]:
            cat = "bss"
        elif any(m["lo"] <= sp < m["hi"] for sp in sps):
            cat = "thread-stack"
        elif m["lo"] % (64 << 20) == 0 and m["perm"].startswith("rw"):
            cat = "libc-heap"
        else:
            cat = "anon-other"
        cats[cat] = cats.get(cat, 0) + m["rss"]
    return cats


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=2) as r:
            return r.read().decode()
    except Exception:
        return None


def stats(gcry):
    """/gc-stats counters (gcry) plus GC.prof_stats (/gc-prof, probe build, both GCs)."""
    out = {}
    if gcry:
        s = get(f"http://127.0.0.1:{PORT}/gc-stats")
        if s:
            d = json.loads(s)
            out.update({k: d.get(k) for k in STATS_KEYS})
    s = get(f"http://127.0.0.1:{PORT}/gc-prof")
    if s and s.startswith("{"):
        out.update({"prof_" + k: v for k, v in json.loads(s).items()})
    return out or None


env = dict(os.environ, PORT=str(PORT), **extra_env)
subprocess.run(["fuser", "-k", f"{PORT}/tcp"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
time.sleep(0.3)
srv = subprocess.Popen(["taskset", "-c", "0-2", binary], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
binpath = os.path.realpath(binary)
for _ in range(100):
    if get(f"http://127.0.0.1:{PORT}/"):
        break
    time.sleep(0.1)
gcry = get(f"http://127.0.0.1:{PORT}/gc-stats") is not None
idle = classify(read_smaps(srv.pid), thread_sps(srv.pid), binpath)
url = f"http://127.0.0.1:{PORT}{path}"
subprocess.run(["taskset", "-c", "3-11", "wrk", "-t4", "-c50", "-d3s", url], capture_output=True)
w = subprocess.Popen(["taskset", "-c", "3-11", "wrk", "-t4", "-c50", "-d10s", url],
                     stdout=subprocess.PIPE, text=True)
samples, gstats = [], []
t0 = time.time()
next_stats = t0
while w.poll() is None:
    now = time.time()
    try:
        cats = classify(read_smaps(srv.pid), thread_sps(srv.pid), binpath)
    except (OSError, AttributeError):
        continue
    samples.append({"t": round(now - t0, 2), "cats": cats, "total": sum(cats.values())})
    if now >= next_stats:
        st = stats(gcry)
        if st:
            gstats.append({"t": round(now - t0, 2), **st})
        next_stats = now + 1.0
    time.sleep(0.1)
wrk_out = w.stdout.read()
reqs = float(re.search(r"Requests/sec:\s+([\d.]+)", wrk_out).group(1))
status = open(f"/proc/{srv.pid}/status").read()
hwm = int(re.search(r"VmHWM:\s+(\d+)", status).group(1))
end_stats = stats(gcry)
end_cats = classify(read_smaps(srv.pid), thread_sps(srv.pid), binpath)
get(f"http://127.0.0.1:{PORT}/gc-collect")
time.sleep(0.5)
post = classify(read_smaps(srv.pid), thread_sps(srv.pid), binpath)
post_stats = stats(gcry)
thread_names = sorted(open(f"/proc/{srv.pid}/task/{t}/comm").read().strip()
                      for t in os.listdir(f"/proc/{srv.pid}/task"))
threads = len(thread_names)
srv.kill()
srv.wait()
peak = max(samples, key=lambda s: s["total"])
res = {"binary": binary, "path": path, "env": extra_env, "reqs": reqs, "vmhwm_kb": hwm,
       "threads": threads, "thread_names": thread_names, "idle": idle, "peak": peak, "end": end_cats, "end_stats": end_stats,
       "post_collect": post, "post_stats": post_stats, "samples": samples, "gc_stats": gstats}
json.dump(res, open(out, "w"), indent=1)
cats = sorted(set(peak["cats"]) | set(post))
print(f"{binary} {path} {extra_env} req/s {reqs:.0f} VmHWM {hwm} kB threads {threads} {thread_names}")
print(f"{'category':22s} {'idle':>7s} {'peak':>7s} {'max':>7s} {'post':>7s}  (kB)")
for c in sorted(cats, key=lambda c: -peak["cats"].get(c, 0)):
    mx = max(s["cats"].get(c, 0) for s in samples)
    print(f"{c:22s} {idle.get(c, 0):7d} {peak['cats'].get(c, 0):7d} {mx:7d} {post.get(c, 0):7d}")
print(f"{'total':22s} {sum(idle.values()):7d} {peak['total']:7d} {'':7s} {sum(post.values()):7d}")
if end_stats:
    print("end stats:", end_stats)
