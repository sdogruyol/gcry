# Poll /gc-stats during a wrk run; print per-interval deltas of the release counters.
import json, subprocess, sys, time, urllib.request
port = int(sys.argv[1]); secs = int(sys.argv[2])
def stats():
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/gc-stats", timeout=2) as r: return json.load(r)
keys = ["collections","heap_size","unmapped_bytes","released_chunk_bytes","fully_free_chunk_bytes","dormant_chunk_bytes","size_class_live_bytes","free_bytes","gc_threshold","empty_chunk_warm_retain","size_class_chunk_count","bitmap_dormant_revives"]
wrk = subprocess.Popen(["wrk","-t4","-c100",f"-d{secs}s",f"http://127.0.0.1:{port}/json"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
prev = stats(); t0 = time.time()
print("  t   cols  heapMB  unmapMB/s relMB/s ffreeMB  liveMB freeMB  thrMB warmMB chunks")
while wrk.poll() is None:
    time.sleep(1.0); cur = stats()
    d = lambda k: cur.get(k,0) - prev.get(k,0)
    M = 1/1048576
    print(f"{time.time()-t0:4.0f} {d('collections'):5} {cur['heap_size']*M:7.1f} {d('unmapped_bytes')*M:9.1f} {d('released_chunk_bytes')*M:7.1f} {cur['fully_free_chunk_bytes']*M:7.1f} {cur['size_class_live_bytes']*M:7.1f} {cur['free_bytes']*M:6.1f} {cur['gc_threshold']*M:6.1f} {cur['empty_chunk_warm_retain']*M:6.1f} {cur['size_class_chunk_count']:6}")
    prev = cur
