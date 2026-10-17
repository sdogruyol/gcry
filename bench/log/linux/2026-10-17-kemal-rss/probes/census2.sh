#!/usr/bin/env bash
P=3112
fuser -k $P/tcp >/dev/null 2>&1; sleep 0.3
PORT=$P taskset -c 0-2 $1 >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:$P/ && break; sleep 0.1; done
c() { curl -s http://127.0.0.1:$P/large-census | awk -F'\t' -v l="$1" 'NR>1{n++; m+=$1; r+=$5} END{print l, "large n="n, "mapped="m, "resident="r}'; }
c idle
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null; c after-wrk1
curl -s http://127.0.0.1:$P/gc-collect >/dev/null; curl -s http://127.0.0.1:$P/gc-collect >/dev/null; c after-2-collects
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null; c after-wrk2
curl -s http://127.0.0.1:$P/gc-collect >/dev/null; curl -s http://127.0.0.1:$P/gc-collect >/dev/null; c after-2-collects
for i in 1 2 3 4 5; do curl -s http://127.0.0.1:$P/gc-collect >/dev/null; done; c after-7-collects
sleep 6; c after-6s-idle
kill $pid
