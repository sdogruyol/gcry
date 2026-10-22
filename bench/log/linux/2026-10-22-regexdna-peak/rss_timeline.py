#!/usr/bin/env python3
"""rss_timeline.py BIN OUTPREFIX [ENV=V ...]

Runs `BIN RegexDna` with GCRY_TRACE=1 (collect_end lines to OUTPREFIX.ndjson)
and GCRY_TRACE_LARGE=1 (large maps on stderr -> OUTPREFIX.large), polls
/proc/<pid>/status VmRSS every ~0.5 ms (CLOCK_MONOTONIC, the trace's clock),
and writes OUTPREFIX.rss (ts_ns rss_kb). Prints the peak and the collections
around it.
"""
import json, os, subprocess, sys, time

binp, pref = sys.argv[1], sys.argv[2]
env = dict(os.environ)
env.update(GCRY_TRACE="1", GCRY_TRACE_ALLOC_SAMPLE="0", GCRY_TRACE_FILE=pref + ".ndjson", GCRY_TRACE_LARGE="1")
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    env[k] = v
bench = env.pop("BENCH", "RegexDna")
err = open(pref + ".large", "w")
p = subprocess.Popen([binp, bench], env=env, stdout=subprocess.DEVNULL, stderr=err)
samples = []
path = f"/proc/{p.pid}/status"
while p.poll() is None:
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    samples.append((time.monotonic_ns(), int(line.split()[1])))
                    break
    except (FileNotFoundError, ProcessLookupError):
        break
    time.sleep(0.0005)
with open(pref + ".rss", "w") as f:
    for t, r in samples:
        f.write(f"{t} {r}\n")
colls = [json.loads(l) for l in open(pref + ".ndjson") if '"collect_end"' in l]
t0 = samples[0][0]
pt, pr = max(samples, key=lambda s: s[1])
print(f"peak {pr/1024:.1f} MiB at {(pt-t0)/1e6:.1f} ms; {len(samples)} samples")
before = [c for c in colls if c["ts_ns"] <= pt]
after = [c for c in colls if c["ts_ns"] > pt]
if before:
    print(f"  last collection before: c={before[-1]['collections']} at {(before[-1]['ts_ns']-t0)/1e6:.1f} ms heap={before[-1]['heap_size']/2**20:.1f}M")
if after:
    print(f"  first collection after: c={after[0]['collections']} at {(after[0]['ts_ns']-t0)/1e6:.1f} ms heap={after[0]['heap_size']/2**20:.1f}M")
