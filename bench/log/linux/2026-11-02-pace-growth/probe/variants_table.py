import json,sys,statistics as st,pathlib
root=pathlib.Path(sys.argv[1]); arms=['tip','g1','g2','g3','g1f16','g1f64','g3f64']
def stats(runs,b,a):
    base={r['rep']:r for r in runs if r['bench']==b and r['arm']=='tip'}
    v=[r for r in runs if r['bench']==b and r['arm']==a]
    t=st.median([r['time']/base[r['rep']]['time']-1 for r in v]) if a!='tip' else None
    p=[r['rss']/base[r['rep']]['rss']-1 for r in v if r['rss']]
    p=st.median(p) if p and a!='tip' else None
    ten=sum(1 for r in v if len(r['ends'])>=10)
    return t,p,ten,len(v)
for metric in ['primes10','knuck_peak','jpp_time','jpp_peak','jps_peak','jpl_peak','jg_time']:
    print(f'\n{metric}\n| runner | '+' | '.join(arms)+' |\n|---|'+'---:|'*len(arms))
    for d in sorted(root.glob('probe-*')):
        runs=json.load(open(d/'runs.json')); cells=[]
        for a in arms:
            if metric=='primes10':
                t,p,ten,n=stats(runs,'Primes',a); cells.append(f'{ten}/{n}')
            else:
                b={'knuck':'Knuckeotide','jpp':'JsonParsePure','jps':'JsonParseSerializable','jpl':'JsonParsePull','jg':'JsonGenerate'}[metric.split('_')[0]]
                t,p,ten,n=stats(runs,b,a); x=t if metric.endswith('time') else p
                cells.append('—' if x is None else f'{x*100:+.1f}%')
        print(f'| {d.name[6:]} | '+' | '.join(cells)+' |')
