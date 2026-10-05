import sys,json,re
for f in sys.argv[1:]:
    txt=open(f).read()
    w=re.search(r"in ([0-9.]+)s",txt).group(1)
    out=[]
    prev=None
    for l in txt.splitlines():
        if '"collect_start"' in l: st=json.loads(l)["ts_ns"]
        if '"collect_end"' in l:
            e=json.loads(l)
            out.append(f'{e["collections"]}:p{e["threshold_pace_pct"]} th{e["threshold"]>>20} cyc{(e["ts_ns"]-st)/1e6:.1f} fl{e.get("flush_ns",0)/1e6:.1f}')
    print(f, w, " | ".join(out[1:7]))
