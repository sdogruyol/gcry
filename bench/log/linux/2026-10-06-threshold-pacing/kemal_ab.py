#!/usr/bin/env python3
"""kemal_ab.py OUT TRIALS DURATION PATH arm=bin[:ENV=V,...] ...
Server on CPUs 8-10, wrk on CPU 11; fresh process per (trial, arm), arm order
shuffled per trial. Records req/s, VmHWM (peak), VmRSS after /gc-collect."""
import sys, os, subprocess, random, re, time, json, statistics, urllib.request
out, trials, dur, path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
arms = []
for a in sys.argv[5:]:
    name, rest = a.split('=', 1)
    parts = rest.split(':', 1)
    env = {}
    if len(parts) > 1 and parts[1]:
        for kv in parts[1].split(','):
            k, v = kv.split('=', 1); env[k] = v
    arms.append((name, parts[0], env))
os.makedirs(out, exist_ok=True)
res = {}
port = 3301
def status(pid, key):
    s = open(f"/proc/{pid}/status").read()
    return int(re.search(key + r":\s+(\d+)", s)[1])
for t in range(trials):
    order = arms[:]; random.shuffle(order)
    for name, binp, env in order:
        port += 1
        e = dict(os.environ); e.update(env); e["PORT"] = str(port)
        p = subprocess.Popen(["taskset", "-c", "8-10", binp], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        url = f"http://127.0.0.1:{port}"
        for _ in range(100):
            try:
                urllib.request.urlopen(url + "/", timeout=1).read(); break
            except Exception:
                time.sleep(0.1)
        subprocess.run(["taskset", "-c", "11", "wrk", "-t1", "-c50", "-d2", url + path], capture_output=True)
        w = subprocess.run(["taskset", "-c", "11", "wrk", "-t1", "-c50", f"-d{dur}", url + path], capture_output=True, text=True).stdout
        rps = float(re.search(r"Requests/sec:\s+([0-9.]+)", w)[1])
        hwm = status(p.pid, "VmHWM")
        try:
            urllib.request.urlopen(url + "/gc-collect", timeout=5).read()
        except Exception:
            pass
        time.sleep(0.2)
        rss = status(p.pid, "VmRSS")
        p.terminate(); p.wait()
        res.setdefault(name, []).append((rps, hwm, rss))
    print(f"trial {t+1}/{trials}", file=sys.stderr, flush=True)
json.dump(res, open(os.path.join(out, "raw.json"), "w"), indent=1)
base = arms[0][0]
bq = statistics.median([x[0] for x in res[base]])
bh = statistics.median([x[1] for x in res[base]])
lines = [f"{'arm':10} {'req/s med':>10} {'min':>9} {'max':>9} {'% ' + base:>8} {'HWM MiB':>8} {'x':>5} {'postGC MiB':>10}"]
for name, _, _ in arms:
    xs = res[name]
    q = statistics.median([x[0] for x in xs]); h = statistics.median([x[1] for x in xs])
    lines.append(f"{name:10} {q:10.0f} {min(x[0] for x in xs):9.0f} {max(x[0] for x in xs):9.0f} {q/bq*100:7.1f}% {h/1024:8.1f} {h/bh:5.2f} {statistics.median([x[2] for x in xs])/1024:10.1f}")
s = "\n".join(lines)
open(os.path.join(out, "summary.txt"), "w").write(s + "\n")
print(s)
