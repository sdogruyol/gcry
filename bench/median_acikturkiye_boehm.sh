#!/usr/bin/env bash
# Median-of-3 acikturkiye /api/v1/: gcry vs Boehm, post-GC RSS.
# Run from anywhere; uses sibling ../acikturkiye by default.
# Usage: ./bench/median_acikturkiye_boehm.sh
# Record Linux → docs/ACIKTURKIYE.md; Darwin → docs/ACIKTURKIYE-macos.md (never mix).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"
PATH_API="${API_PATH:-/api/v1/}"
WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30}"
LABEL="${LABEL:-unreleased-$(uname -s | tr '[:upper:]' '[:lower:]')}"
TRIALS="${TRIALS:-3}"
OUT="/tmp/gcry-median-acik-${LABEL}.tsv"

[[ -d "$AT" ]] || { echo "acikturkiye not found at $AT" >&2; exit 1; }
command -v wrk >/dev/null || { echo "wrk not found" >&2; exit 1; }

set -a
source "$AT/.env.demo"
set +a
[[ -n "${API_KEY:-}" && -n "${API_SECRET:-}" ]] || { echo "API_KEY/SECRET missing in .env.demo" >&2; exit 1; }

AUTH=(-H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}")

echo "=== build acikturkiye-gcry + acikturkiye-boehm ==="
(
  cd "$AT"
  mkdir -p bin
  ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry
  ACIKTURKIYE_ENV=demo crystal build --release src/acikturkiye.cr -o bin/acikturkiye-boehm
)

wait_ready() {
  local base=$1 timeout=${2:-60}
  local i
  for i in $(seq 1 $((timeout * 10))); do
    if curl -sf -o /dev/null "${AUTH[@]}" "${base}/api/v1/" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

run_one() {
  local bin=$1 trial=$2 tag=$3
  # Unique port per trial avoids TIME_WAIT conflicts and macOS fuser issues.
  local port trial_id="${tag}-t${trial}"
  port=$((3500 + trial * 2 + ($(echo "$tag" | wc -c) % 5) * 3))
  local base="http://127.0.0.1:${port}"

  (
    cd "$AT"
    set -a; source .env.demo; set +a
    unset GCRY_CLEAR_STACK GCRY_SCRUB_FIBERS GCRY_CLEAR_STACK_EVERY GCRY_PARALLEL_MARK || true
    export ACIKTURKIYE_ENV=demo ACIKTURKIYE_SERVER_PORT="$port"
    exec "$bin"
  ) >"/tmp/acik-${trial_id}.log" 2>&1 &
  local pid=$!

  if ! wait_ready "$base" 60; then
    echo "FAIL ready ${tag} t${trial} (port ${port})" >&2
    tail -10 "/tmp/acik-${trial_id}.log" >&2 || true
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "${AUTH[@]}" "${base}${PATH_API}" \
    >"/tmp/wrk-acik-${trial_id}.txt" 2>&1 || true
  local rps timeouts
  rps=$(awk '/Requests\/sec:/ {print $2}' "/tmp/wrk-acik-${trial_id}.txt")
  timeouts=$(awk '/Socket errors/ {for(i=1;i<=NF;i++) if($i~/timeout/) print $(i+1)}' "/tmp/wrk-acik-${trial_id}.txt")
  timeouts=${timeouts:-0}

  # Prefer /gc-collect; fall back to Observability if present
  curl -sf -o /dev/null "${base}/gc-collect" || curl -sf -X POST "${base}/gc-collect" -o /dev/null || true
  sleep 0.5

  local cpid
  cpid=$(pgrep -n -f "$(basename "$bin")" 2>/dev/null || true)
  [[ -z "$cpid" ]] && cpid=$pid
  local rss
  rss=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ')
  [[ -z "$rss" ]] && rss=0

  kill -9 "$cpid" 2>/dev/null || true
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  echo -e "${tag}\t${trial}\t${rps}\t${rss}\t${timeouts}"
  echo -e "${tag}\t${trial}\t${rps}\t${rss}\t${timeouts}" >>"$OUT"
}

: >"$OUT"
echo "tag	trial	rps	rss_kib	timeouts" >>"$OUT"

for trial in $(seq 1 "$TRIALS"); do
  echo "=== trial $trial Boehm ==="
  run_one "$AT/bin/acikturkiye-boehm" "$trial" boehm || echo "SKIP boehm t$trial"
  echo "=== trial $trial gcry ==="
  run_one "$AT/bin/acikturkiye-gcry" "$trial" gcry || echo "SKIP gcry t$trial"
done

python3 - <<'PY' "$OUT" "$LABEL"
import sys, statistics
path, label = sys.argv[1], sys.argv[2]
rows = []
with open(path) as f:
    next(f)
    for line in f:
        tag, trial, rps, rss, to = line.strip().split("\t")
        rows.append((tag, int(trial), float(rps), int(rss), int(float(to or 0))))

b = sorted(r for r in rows if r[0]=="boehm")
g = sorted(r for r in rows if r[0]=="gcry")
b_rps = sorted(r[2] for r in b); g_rps = sorted(r[2] for r in g)
b_rss = sorted(r[3] for r in b); g_rss = sorted(r[3] for r in g)
bm, gm = statistics.median(b_rps), statistics.median(g_rps)
br, gr = statistics.median(b_rss), statistics.median(g_rss)
pct = 100.0 * gm / bm if bm else 0
rx = gr / br if br else 0

print(f"\n=== acikturkiye median-of-3 ({label}) /api/v1/ ===")
print("| Trial | thr % Boehm | post-GC RSS × | gcry/Boehm req/s | timeouts gcry/Boehm |")
print("|------:|------------:|--------------:|-----------------:|--------------------:|")
for i in range(len(b)):
    bt, gt = b[i], g[i]
    tp = 100.0 * gt[2] / bt[2] if bt[2] else 0
    rr = gt[3] / bt[3] if bt[3] else 0
    print(f"| {i+1} | {tp:.1f}% | {rr:.2f}× | {gt[2]:.0f} / {bt[2]:.0f} | {gt[4]} / {bt[4]} |")
print(f"| **median** | **{pct:.1f}%** | **{rx:.2f}×** | — | — |")
print(f"  boehm rps={b_rps} rss_kib={b_rss}", file=sys.stderr)
print(f"  gcry  rps={g_rps} rss_kib={g_rss}", file=sys.stderr)
print(f"\nraw: {path}")
PY