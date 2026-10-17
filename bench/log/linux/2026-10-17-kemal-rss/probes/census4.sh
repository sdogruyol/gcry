#!/usr/bin/env bash
# census4.sh BIN [ENV...]: socket finalization after load and collects
P=3112
fuser -k $P/tcp >/dev/null 2>&1; sleep 0.3
env PORT=$P "${@:2}" taskset -c 0-2 $1 >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:$P/ && break; sleep 0.1; done
c() { echo "$1 finalized=$(curl -s http://127.0.0.1:$P/sockets-finalized)"; }
c idle
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null; c after-wrk1
for i in 1 2 3; do curl -s http://127.0.0.1:$P/gc-collect >/dev/null; done; c after-3-collects
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null; c after-wrk2
for i in 1 2 3; do curl -s http://127.0.0.1:$P/gc-collect >/dev/null; done; c after-3-collects
kill $pid
