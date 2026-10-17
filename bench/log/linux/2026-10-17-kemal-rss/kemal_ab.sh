#!/usr/bin/env bash
# Kemal interleaved A/B: arms = name=binary pairs. Per trial and path, every arm
# in random order: start server on CPUs 0-2, warm 3 s, wrk 10 s on CPUs 3-11,
# record req/s and the server's VmHWM. Each (arm, path) run holds the shared
# heavy lock, so no other job runs during a measurement.
# Usage: kemal_ab.sh OUTDIR TRIALS name=bin ...
set -u
out=$1 trials=$2; shift 2
mkdir -p "$out"
LOCK=/home/naruto/playground/.scratch/heavy.lock
PORT=3121
res="$out/results.tsv"
echo -e "trial\tpath\tarm\treqs\thwm_kb" > "$res"
one() {
  local name=$1 bin=$2 path=$3 trial=$4
  fuser -k ${PORT}/tcp >/dev/null 2>&1; sleep 0.3
  PORT=$PORT taskset -c 0-2 "$bin" >"$out/server-$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
  taskset -c 3-11 wrk -t4 -c50 -d3s "http://127.0.0.1:$PORT$path" >/dev/null 2>&1
  local r
  r=$(taskset -c 3-11 wrk -t4 -c50 -d10s "http://127.0.0.1:$PORT$path" 2>/dev/null | awk '/Requests\/sec/{print $2}')
  local hwm
  hwm=$(awk '/VmHWM/{print $2}' /proc/$pid/status)
  kill $pid; wait $pid 2>/dev/null
  echo -e "$trial\t$path\t$name\t$r\t$hwm" >> "$res"
}
for t in $(seq 1 "$trials"); do
  for path in /json /; do
    for spec in $(printf '%s\n' "$@" | shuf); do
      flock "$LOCK" bash -c "$(declare -f one); PORT=$PORT out=$out res=$res; one ${spec%%=*} ${spec#*=} $path $t"
    done
  done
  echo "trial $t done" >&2
done
python3 - "$res" <<'PY'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
arms = list(dict.fromkeys(r["arm"] for r in rows))
for path in ["/json", "/"]:
    print(f"## {path}")
    base = None
    for a in arms:
        rs = [float(r["reqs"]) for r in rows if r["arm"] == a and r["path"] == path and r["reqs"]]
        hw = [int(r["hwm_kb"]) for r in rows if r["arm"] == a and r["path"] == path and r["hwm_kb"]]
        m = statistics.median(rs); h = statistics.median(hw)
        base = base or (m, h)
        print(f"{a:8s} req/s median {m:9.0f} (min {min(rs):.0f} max {max(rs):.0f}, n={len(rs)})  "
              f"{100*m/base[0]:5.1f}% of first arm  peak RSS {h/1024:6.1f} MB ({h/base[1]:.2f}x)")
PY
