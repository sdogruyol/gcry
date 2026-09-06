#!/usr/bin/env bash
# Interleaved Kemal /json A/B with a paired design.
#
#   run_kemal_ab.sh <rounds> <out.jsonl> <name>=<binary>[:<ENV=v,ENV=v>] ...
#
# Every round runs every arm once, the arm order rotated by one position per
# round so each arm sees every position equally. One trial line per arm per
# round, JSON: round, arm, position, req/s, requests, peak RSS (VmHWM kB),
# minor faults and CPU ms from /proc/<pid>/stat over the wrk window, and the
# load average at the start of the trial. Analyse with analyze_ab.py.
set -u
rounds=$1; out=$2; shift 2
arms=("$@"); n=${#arms[@]}
port=4400
: > "$out"
echo "# $(date -Is) host=$(hostname) load=$(cut -d' ' -f1-3 /proc/loadavg) arms=${arms[*]}" >&2
for ((r=0; r<rounds; r++)); do
  for ((k=0; k<n; k++)); do
    j=$(( (k + r) % n ))
    spec="${arms[$j]}"; name="${spec%%=*}"; rest="${spec#*=}"; bin="${rest%%:*}"
    envs=""; [[ "$rest" == *:* ]] && envs="${rest#*:}"; envs="${envs//,/ }"
    port=$((port + 1)); [ $port -gt 4499 ] && port=4401
    load=$(cut -d' ' -f1 /proc/loadavg)
    env $envs PORT=$port "$bin" >/dev/null 2>&1 & pid=$!
    ok=0; for _ in $(seq 1 100); do curl -sf -m 2 -o /dev/null "http://127.0.0.1:$port/json" && { ok=1; break; }; sleep 0.1; done
    if [ $ok -eq 0 ]; then echo "{\"round\":$r,\"arm\":\"$name\",\"position\":$k,\"error\":\"no response\"}" >> "$out"; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; continue; fi
    s0=$(awk '{print $10, $14, $15}' /proc/$pid/stat)
    wrk_out=$(timeout 40 wrk -t4 -c100 -d15s --timeout 5s "http://127.0.0.1:$port/json" 2>/dev/null)
    s1=$(awk '{print $10, $14, $15}' /proc/$pid/stat)
    reqs=$(echo "$wrk_out" | awk '/requests in/{print $1}'); rps=$(echo "$wrk_out" | awk '/Requests\/sec/{print $2}')
    hwm=$(awk '/VmHWM/{print $2}' /proc/$pid/status); rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status)
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
    read m0 u0 t0 <<<"$s0"; read m1 u1 t1 <<<"$s1"
    echo "{\"round\":$r,\"arm\":\"$name\",\"position\":$k,\"rps\":${rps:-0},\"requests\":${reqs:-0},\"hwm_kb\":${hwm:-0},\"rss_kb\":${rss:-0},\"minflt\":$((m1-m0)),\"cpu_ticks\":$(( (u1-u0)+(t1-t0) )),\"load1\":$load}" >> "$out"
  done
done
echo "# $(date -Is) done load=$(cut -d' ' -f1-3 /proc/loadavg)" >&2
