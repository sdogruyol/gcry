#!/usr/bin/env bash
# pausecost.sh BIN [ENV...]: GC pause share of a 10 s /json run
P=3113
fuser -k $P/tcp >/dev/null 2>&1; sleep 0.3
env PORT=$P "${@:2}" taskset -c 0-2 $1 >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:$P/ && break; sleep 0.1; done
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null
s0=$(curl -s http://127.0.0.1:$P/gc-stats); c0=$(awk '{print $14+$15}' /proc/$pid/stat)
r=$(taskset -c 3-11 wrk -t4 -c50 -d10s http://127.0.0.1:$P/json | awk '/Requests\/sec/{print $2}')
s1=$(curl -s http://127.0.0.1:$P/gc-stats); c1=$(awk '{print $14+$15}' /proc/$pid/stat)
python3 -c "
import json,sys
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
n=b['collections']-a['collections']; p=b['pause_total_ns']-a['pause_total_ns']
cpu=(int(sys.argv[4])-int(sys.argv[3]))/100
print(f'{sys.argv[5]} req/s={sys.argv[6]} collections={n} ({n/10:.0f}/s) pause_total={p/1e6:.1f} ms mean={p/max(n,1)/1e3:.0f} us share_of_wall={p/1e8:.2f}% server_cpu={cpu:.1f}s p50={b[\"pause_p50_ns\"]/1e3:.0f}us p99={b[\"pause_p99_ns\"]/1e3:.0f}us')
" "$s0" "$s1" $c0 $c1 "${*:2}" $r
kill $pid
