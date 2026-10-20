#!/usr/bin/env bash
# Callgrind profile of one Kemal server binary under wrk load on one route:
# instructions (and simulated cache/branch events) per request, by function.
#
#   cg_kemal.sh BIN OUT [ROUTE] [SECONDS]
#
# Instrumentation starts off (--instr-atstart=no) and is switched on after a
# warm-up, so startup and the warm-up don't count; wrk's request count over the
# measured window divides the totals. GCRY_COLLECT_SCRUB=0 for every arm: the
# collector's below-SP scrub runs into valgrind's smaller main stack
# (../../2026-10-15-revcomp-attribution/). Run under the host's heavy lock.
set -euo pipefail
bin=$1 out=$2 route=${3:-/json} secs=${4:-30}
port=3177
PORT=$port GCRY_COLLECT_SCRUB=0 valgrind --tool=callgrind --instr-atstart=no --cache-sim=yes --branch-sim=yes \
  --callgrind-out-file="$out.cg" "$bin" > "$out.server.log" 2>&1 &
vg=$!
for _ in $(seq 600); do curl -sf "http://127.0.0.1:$port/" > /dev/null && break; sleep 0.2; done
wrk -t1 -c10 -d10s "http://127.0.0.1:$port$route" > /dev/null
callgrind_control -i on "$vg" > /dev/null
wrk -t1 -c10 -d"${secs}s" "http://127.0.0.1:$port$route" > "$out.wrk"
callgrind_control -i off "$vg" > /dev/null
kill -TERM "$vg"
wait "$vg" || true
grep -E "requests in|Requests/sec" "$out.wrk"
