#!/usr/bin/env bash
P=3112
fuser -k $P/tcp >/dev/null 2>&1; sleep 0.3
PORT=$P taskset -c 0-2 $1 >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:$P/ && break; sleep 0.1; done
echo "== idle"; curl -s http://127.0.0.1:$P/large-census
taskset -c 3-11 wrk -t4 -c50 -d5s http://127.0.0.1:$P/json >/dev/null
echo "== after load"; curl -s http://127.0.0.1:$P/large-census
kill $pid
