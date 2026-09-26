import os, re, subprocess, time, urllib.request, json
G=os.path.expanduser("~/playground/gcry/bin"); WRK=os.path.expanduser("~/.cache/wrkdeb/bin/wrk")
arms=[("ec1+t1 default",f"{G}/kemal-ec1-dorm",{"EXTRA_THREADS":"1"}),
      ("ec1+t1 DORMANT=1",f"{G}/kemal-ec1-dorm",{"EXTRA_THREADS":"1","GCRY_PARALLEL_DORMANT":"1"}),
      ("ec1+t1 DORMANT=1 RETAIN=0 (pre-fix)",f"{G}/kemal-ec1-dorm",{"EXTRA_THREADS":"1","GCRY_PARALLEL_DORMANT":"1","GCRY_EMPTY_CHUNK_RETAIN":"0"}),
      ("ec4 default",f"{G}/kemal-gcry-mt-fix",{"EC_PARALLELISM":"4"}),
      ("ec4 DORMANT=1",f"{G}/kemal-gcry-mt-fix",{"EC_PARALLELISM":"4","GCRY_PARALLEL_DORMANT":"1"}),
      ("ec4 DORMANT=1 RETAIN=0 (pre-fix)",f"{G}/kemal-gcry-mt-fix",{"EC_PARALLELISM":"4","GCRY_PARALLEL_DORMANT":"1","GCRY_EMPTY_CHUNK_RETAIN":"0"})]
for name,b,env in arms:
    p=subprocess.Popen([b],env=dict(os.environ, PORT="3085", **env),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for _ in range(100):
        try: urllib.request.urlopen("http://127.0.0.1:3085/",timeout=1).read(); break
        except OSError: time.sleep(0.05)
    subprocess.run([WRK,"-t4","-c100","-d6s","http://127.0.0.1:3085/json"],capture_output=True)
    for _ in range(2): urllib.request.urlopen("http://127.0.0.1:3085/gc-collect").read()
    time.sleep(0.3)
    s=json.loads(urllib.request.urlopen("http://127.0.0.1:3085/gc-stats").read())
    rss=int(re.search(r"VmRSS:\s+(\d+)",open(f"/proc/{p.pid}/status").read()).group(1))
    print(f"{name:30s} rss {rss/1024:6.1f} MB  dormant {s['dormant_chunk_bytes']>>20:4d} MB  fully_free {s['fully_free_chunk_bytes']>>20:4d} MB")
    p.kill(); p.wait(); time.sleep(0.3)
