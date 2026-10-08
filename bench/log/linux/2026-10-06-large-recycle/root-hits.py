import sys,re
for f in sys.argv[1:]:
    txt=open(f).read()
    rss=re.search(r"RSS (\d+)",txt).group(1)
    seen={}
    for m in re.finditer(r"DBG root src=(\d+) val=([0-9a-f]+) chunk=([0-9a-f]+) mapped=(\d+) alloc=(\d) coll=(\d+)",txt):
        s,v,c,mp,a,co=m.groups(); vv=int(v,16)
        if (vv & 0xffffffff) < 0x100000:
            k=(mp,); seen.setdefault(k,set()).add(int(co))
    print(f, int(rss)//1024, {k[0]:(min(v),max(v),len(v)) for k,v in seen.items()})
