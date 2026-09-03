import json, os, sys, time

KEYS = ["collections","major_collections","minor_collections","pause_count",
        "pause_total_ns","pause_p50_ns","pause_p99_ns","pause_max_ns","pause_last_ns",
        "phase_clear_ns","phase_scrub_ns","phase_roots_ns","phase_static_ns",
        "phase_stacks_ns","phase_mark_ns","phase_sweep_ns","phase_flush_ns",
        "phase_stw_stop_ns","phase_stw_start_ns","heap_size","live_objects",
        "small_mapped_bytes","size_class_live_bytes"]

def parse(s):
    try:
        d = json.loads(s)
    except Exception:
        return {}
    return {k: d.get(k) for k in KEYS if k in d}

pre  = parse(os.environ.get("PRE","{}"))
post = parse(os.environ.get("POST","{}"))
idles = [parse(l) for l in os.environ.get("IDLES","").splitlines() if l.strip()]

rec = {
    "arm": os.environ["ARM"],
    "path": os.environ["PATHV"],
    "rps": float(os.environ.get("RPS") or 0),
    "lat_avg": os.environ.get("LAT",""),
    "rss_kib": int(os.environ.get("RSS") or 0),
    "sock_errors": os.environ.get("ERRS",""),
    "ts": int(time.time()),
    "pre": pre,
    "post": post,
    "idle_marks": [d.get("phase_mark_ns") for d in idles],
    "idle_sweeps": [d.get("phase_sweep_ns") for d in idles],
    "idle_stacks": [d.get("phase_stacks_ns") for d in idles],
}
with open(os.environ["OUT"], "a") as f:
    f.write(json.dumps(rec) + "\n")
print("  [%s %s] rps=%.0f rss=%sKiB colls=%s inload_mark=%sns idle_marks=%s" % (
    rec["arm"], rec["path"], rec["rps"], rec["rss_kib"],
    pre.get("collections"), pre.get("phase_mark_ns"), rec["idle_marks"]))
