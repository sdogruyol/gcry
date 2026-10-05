#!/usr/bin/env python3
"""livediff.py BENCHES binA binB [ENV=V,...] — compare per-collection live_objects."""
import sys, os, subprocess, json
benches, a, b = sys.argv[1].split(','), sys.argv[2], sys.argv[3]
extra = dict(kv.split('=', 1) for kv in sys.argv[4].split(',')) if len(sys.argv) > 4 else {}
scratch = os.path.expanduser('~/.cache/gcry-work/MarkCost/ld')
os.makedirs(scratch, exist_ok=True)
def run(bin_, bench):
    tf = os.path.join(scratch, 'ld.ndjson')
    if os.path.exists(tf): os.unlink(tf)
    e = dict(os.environ); e.update(extra)
    e.update({"GCRY_TRACE": "1", "GCRY_TRACE_FILE": tf, "GCRY_TRACE_ALLOC_SAMPLE": "0"})
    subprocess.run([bin_, bench], capture_output=True, text=True, env=e)
    return [json.loads(l)["live_objects"] for l in open(tf) if '"collect_end"' in l]
for bench in benches:
    la, lb = run(a, bench), run(b, bench)
    diffs = [(i + 1, x, y) for i, (x, y) in enumerate(zip(la, lb)) if x != y]
    print(f"{bench:22} gcs {len(la)}/{len(lb)}  differing {len(diffs)}  " + " ".join(f"#{i}:{x}->{y}({y-x:+d})" for i, x, y in diffs[:6]))
