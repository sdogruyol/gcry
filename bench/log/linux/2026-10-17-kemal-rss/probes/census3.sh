#!/usr/bin/env bash
# census3.sh BIN [ENV...]: live TCPSocket/buffer census after load + collects
P=3112
fuser -k $P/tcp >/dev/null 2>&1; sleep 0.3
env PORT=$P "${@:2}" taskset -c 0-2 $1 >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:$P/ && break; sleep 0.1; done
c() { curl -s http://127.0.0.1:$P/large-census | awk -F'\t' -v l="$1" 'NR>1{n++; m+=$1; r+=$5} END{printf "%s large n=%d mapped=%d resident=%d ", l, n, m, r}';
  curl -s http://127.0.0.1:$P/gc-stats | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k:v for k,v in d.items() if k.startswith("first_mark_watch") or k in ("finalizer_entries",) or (k.startswith("first_mark") and k.endswith("atomic_bytes"))})'; }
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null; c after-wrk
for i in 1 2 3; do curl -s http://127.0.0.1:$P/gc-collect >/dev/null; done; c after-3-collects
curl -s http://127.0.0.1:$P/live-attr | python3 -c '
import json,sys; d=json.load(sys.stdin)
print(json.dumps(d)[:1500])'
kill $pid
