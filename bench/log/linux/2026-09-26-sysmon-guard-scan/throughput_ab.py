import os, re, subprocess, sys, time, urllib.request, statistics, json
G=os.path.expanduser("~/playground/gcry/bin")
WRK=os.path.expanduser("~/.cache/wrkdeb/bin/wrk")
arms={"fix":f"{G}/kemal-gcry-mt","master":f"{G}/kemal-master-mt","boehm":f"{G}/kemal-boehm-mt"}
rounds=int(sys.argv[1]) if len(sys.argv)>1 else 8
dur=sys.argv[2] if len(sys.argv)>2 else "10s"
res={k:[] for k in arms}
keys=list(arms)
for r in range(rounds):
    order=keys[r%3:]+keys[:r%3]
    for k in order:
        env=dict(os.environ, PORT="3060", EC_PARALLELISM="4")
        p=subprocess.Popen([arms[k]],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for _ in range(100):
            try: urllib.request.urlopen("http://127.0.0.1:3060/",timeout=1).read(); break
            except OSError: time.sleep(0.05)
        subprocess.run([WRK,"-t4","-c100","-d2s","http://127.0.0.1:3060/json"],capture_output=True)  # warm-up
        out=subprocess.run([WRK,"-t4","-c100","-d"+dur,"http://127.0.0.1:3060/json"],capture_output=True,text=True).stdout
        m=re.search(r"Requests/sec:\s+([\d.]+)",out); res[k].append(float(m.group(1)) if m else 0.0)
        p.kill(); p.wait(); time.sleep(0.3)
b=statistics.median(res["boehm"])
for k in keys:
    v=res[k]; print(f"{k:7s} median {statistics.median(v):9.0f} req/s  ({100*statistics.median(v)/b:5.1f}% of boehm)  runs {[round(x) for x in v]}")
# paired fix/master ratio per round
ratios=[f/m for f,m in zip(res["fix"],res["master"]) if m]
print(f"fix/master per round: median {statistics.median(ratios):.3f}  {[round(x,3) for x in ratios]}")
json.dump(res, open(os.path.expanduser("~/.cache/thr_ec4.json"),"w"))
