import sys,re,glob,os
run=sys.argv[1]
def cell(c):
    m=re.match(r'\s*([+-]?[\d.]+)% \[([+-]?[\d.]+)%, ([+-]?[\d.]+)%\]',c)
    return tuple(map(float,m.groups())) if m else None
for d in sorted(glob.glob(run+'/perf-ab-*')):
    r=os.path.basename(d)[8:]
    s=open(d+'/summary.md').read()
    i=s.index('`var` against `base`')
    rows=[l for l in s[i:].split('\n')[4:] if l.startswith('| ')][:9]
    print('==',r)
    # boehm table
    j=s.index('| bench | boehm');bt=[l for l in s[j:].split('\n')[2:] if l.startswith('| ')][:9]
    bmap={l.split('|')[1].strip():l for l in bt}
    for l in rows:
        c=l.split('|'); b=c[1].strip()
        w=cell(c[3]); pk=cell(c[7]); fl=cell(c[6]); col=cell(c[9]); sc=cell(c[10])
        flag=[]
        if w and w[1]>0: flag.append('SLOWER')
        if w and w[2]<0: flag.append('faster')
        if pk and pk[1]>0: flag.append('PEAK+')
        if pk and pk[2]<0: flag.append('peak-')
        bc=bmap.get(b,'').split('|')
        bb=(bc[3].strip()+' -> '+bc[4].strip()) if len(bc)>4 else ''
        print(f"{b:22s} wall {c[3].strip():24s} peak {c[7].strip():24s} faults {c[6].strip():22s} coll {c[9].strip():22s} {' '.join(flag):14s} | {bb}")
