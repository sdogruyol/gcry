import json, os, statistics as st, subprocess, sys, time, urllib.request

label, ec, port = sys.argv[1], sys.argv[2], sys.argv[3]
env = {k: v for k, v in os.environ.items() if not k.startswith("GCRY_") and k not in ("EC_PARALLELISM",)}
env.update({"PORT": port, "EC_PARALLELISM": ec, "GCRY_ROOT_PHASE_TIMING": "1"})
for kv in sys.argv[4:]:
    k, v = kv.split("=", 1); env[k] = v
srv = subprocess.Popen(["bin/kemal-gcry-ec4"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
base = f"http://127.0.0.1:{port}"
for _ in range(100):
    try: urllib.request.urlopen(base + "/json", timeout=1); break
    except Exception: time.sleep(0.1)
subprocess.run(["wrk", "-t4", "-c100", "-d3", base + "/json"], stdout=subprocess.DEVNULL)  # warmup
wrk = subprocess.Popen(["wrk", "-t4", "-c100", "-d15", base + "/json"], stdout=subprocess.PIPE, text=True)
samples = []
while wrk.poll() is None:
    try: samples.append(json.loads(urllib.request.urlopen(base + "/gc-stats", timeout=2).read()))
    except Exception: pass
    time.sleep(0.4)
out = wrk.stdout.read()
rps = [l for l in out.splitlines() if "Requests/sec" in l][0].split()[1]
srv.terminate(); srv.wait()
keys = ["phase_roots_ns", "roots_explicit_ns", "roots_cursors_ns", "roots_metadata_ns", "roots_fibers_ns", "roots_threads_ns",
        "phase_stacks_ns", "phase_static_ns", "phase_mark_ns", "phase_sweep_ns", "phase_clear_ns", "phase_scrub_ns", "pause_p50_ns", "pause_p99_ns"]
med = {k: st.median(s.get(k, 0) for s in samples) / 1e6 for k in keys}
last = samples[-1]
extra = {k: last.get(k) for k in ("collections", "fiber_count", "parked_fibers", "fibers_scanned", "low_water_skips", "low_water_skipped_bytes", "sp_clamp_hits", "thread_count", "threads_scanned", "stw_threads") if k in last}
print(f"{label}: rps={rps} samples={len(samples)} collections={last.get('collections')} " + " ".join(f"{k}={v:.2f}ms" for k, v in med.items()) + " " + json.dumps(extra))
