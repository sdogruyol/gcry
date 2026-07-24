#!/usr/bin/env bash
# Median-of-3 Kemal wrk: gcry (-Dgc_none) vs Boehm, both paths, post-GC RSS.
# Usage: ./bench/median_kemal_boehm.sh
# Env: PORT WRK_CONNECTIONS WRK_DURATION LABEL
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="${PORT:-3001}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30}"
BASE="http://127.0.0.1:${PORT}"
LABEL="${LABEL:-unreleased}"
TRIALS="${TRIALS:-3}"
OUT="/tmp/gcry-median-kemal-${LABEL}.tsv"

command -v wrk >/dev/null || { echo "wrk not found" >&2; exit 1; }

mkdir -p bin
fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
sleep 0.3

echo "=== build kemal-gcry + kemal-boehm ==="
(
  cd bench/kemal
  shards install >/dev/null
  crystal build -Dgc_none --release src/server.cr -o ../../bin/kemal-gcry
  crystal build --release src/server.cr -o ../../bin/kemal-boehm
)

rss_kib() {
  local pid=$1
  # Prefer the binary process if $pid is a wrapper shell.
  local p
  p=$(pgrep -P "$pid" -n 2>/dev/null || true)
  if [[ -n "$p" ]]; then pid=$p; fi
  ps -o rss= -p "$pid" 2>/dev/null | tr -d ' '
}

wait_ready() {
  local i
  for i in $(seq 1 80); do
    if curl -sf -o /dev/null "${BASE}/"; then return 0; fi
    sleep 0.15
  done
  return 1
}

run_one() {
  local bin=$1 path=$2 trial=$3 tag=$4
  fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  sleep 0.4
  PORT="$PORT" "$bin" >"/tmp/kemal-${tag}-t${trial}.log" 2>&1 &
  local pid=$!
  if ! wait_ready; then
    echo "FAIL ready ${tag} ${path} t${trial}" >&2
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  # Resolve crystal pid for RSS
  local cpid
  cpid=$(pgrep -f "$(basename "$bin")" | head -1)
  [[ -z "$cpid" ]] && cpid=$pid

  wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "${BASE}${path}" >"/tmp/wrk-${tag}-${path//\//_}-t${trial}.txt" 2>&1
  local rps
  rps=$(awk '/Requests\/sec:/ {print $2}' "/tmp/wrk-${tag}-${path//\//_}-t${trial}.txt")

  curl -sf -o /dev/null "${BASE}/gc-collect" || true
  sleep 0.4
  local rss
  rss=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ')
  [[ -z "$rss" ]] && rss=$(rss_kib "$pid")

  kill "$cpid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  sleep 0.3

  echo -e "${tag}\t${path}\t${trial}\t${rps}\t${rss}"
  echo -e "${tag}\t${path}\t${trial}\t${rps}\t${rss}" >>"$OUT"
}

: >"$OUT"
echo "tag	path	trial	rps	rss_kib" >>"$OUT"

for trial in $(seq 1 "$TRIALS"); do
  for path in / /json; do
    echo "=== trial $trial path $path Boehm ==="
    run_one ./bin/kemal-boehm "$path" "$trial" boehm
    echo "=== trial $trial path $path gcry ==="
    run_one ./bin/kemal-gcry "$path" "$trial" gcry
  done
done

python3 - <<'PY' "$OUT" "$LABEL"
import sys, statistics
path = sys.argv[1]
label = sys.argv[2]
rows = []
with open(path) as f:
    next(f)
    for line in f:
        tag, pth, trial, rps, rss = line.strip().split("\t")
        rows.append((tag, pth, int(trial), float(rps), int(rss)))

print(f"\n=== median-of-3 summary ({label}) ===")
print("| Path | Boehm req/s (med) | gcry req/s (med) | % Boehm | post-GC RSS × |")
print("|------|------------------:|-----------------:|-------:|--------------:|")
for pth in ("/", "/json"):
    b_rps = sorted(r[3] for r in rows if r[0]=="boehm" and r[1]==pth)
    g_rps = sorted(r[3] for r in rows if r[0]=="gcry" and r[1]==pth)
    b_rss = sorted(r[4] for r in rows if r[0]=="boehm" and r[1]==pth)
    g_rss = sorted(r[4] for r in rows if r[0]=="gcry" and r[1]==pth)
    bm, gm = statistics.median(b_rps), statistics.median(g_rps)
    br, gr = statistics.median(b_rss), statistics.median(g_rss)
    pct = 100.0 * gm / bm if bm else 0
    rx = gr / br if br else 0
    print(f"| `{pth}` | {bm:.0f} | {gm:.0f} | **{pct:.1f}%** | **{rx:.2f}×** |")
    print(f"  trials boehm rps={b_rps} rss={b_rss}", file=sys.stderr)
    print(f"  trials gcry  rps={g_rps} rss={g_rss}", file=sys.stderr)
print(f"\nraw: {path}")
PY
