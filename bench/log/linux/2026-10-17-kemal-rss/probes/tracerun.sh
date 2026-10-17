#!/usr/bin/env bash
# tracerun.sh BIN OUT [ENV...]: per-collection trace over warm-up + 10 s load
P=3114
fuser -k $P/tcp >/dev/null 2>&1; sleep 0.3
env PORT=$P GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE=$2 "${@:3}" taskset -c 0-2 $1 >/dev/null 2>&1 & pid=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null http://127.0.0.1:$P/ && break; sleep 0.1; done
taskset -c 3-11 wrk -t4 -c50 -d3s http://127.0.0.1:$P/json >/dev/null
taskset -c 3-11 wrk -t4 -c50 -d10s http://127.0.0.1:$P/json | grep Requests
grep VmHWM /proc/$pid/status
kill $pid
