#!/usr/bin/env bash
# run_all.sh — Run all gcry benchmarks with structured logging to bench/log/.
#
# Usage:  bash bench/run_all.sh
#         TRIALS=3 WRK_DURATION=30 WRK_CONNECTIONS=100 bash bench/run_all.sh
#
# Output in bench/log/:
#   YYYY-MM-DD-HHMMSS/
#     metadata.yaml           — platform info
#     kemal-median.tsv        — raw trials
#     kemal-summary.md        — median-of-3 table
#     kemal-gcry-gcstats-*.json
#     acik-median.tsv         — raw trials (if available)
#     acik-summary.md         — median-of-3 table
#     acik-*-gcstats-*.json
#
# Requires: wrk, curl, python3, git
# Requires sibling ../acikturkiye for acikturkiye benchmarks.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30}"
TRIALS="${TRIALS:-3}"
KEMAL_PORT_BASE="${KEMAL_PORT_BASE:-3200}"
ACIK_PORT_BASE="${ACIK_PORT_BASE:-3500}"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"

HAS_ACIK="no"
[[ -d "$AT" && -f "$AT/.env.demo" ]] && HAS_ACIK="yes"

TIMESTAMP="$(date -u +%Y-%m-%d-%H%M%S)"
LOG="$ROOT/bench/log/$TIMESTAMP"
mkdir -p "$LOG"
echo "=== Logging to $LOG ==="

###############################################################################
# Metadata
###############################################################################
collect_metadata() {
  local cv cc gh gt
  cv="$(crystal --version 2>/dev/null | head -1 | awk '{print $2}')" || cv="unknown"
  cc="$(crystal --version 2>/dev/null | grep -i commit | awk '{print $4}')" || cc="unknown"
  gh="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  gt="$(cd "$ROOT" && git describe --tags --always 2>/dev/null || echo "none")"

  cat <<EOF >"$LOG/metadata.yaml"
timestamp_utc: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hostname: "$(hostname -s 2>/dev/null || uname -n)"
os: "$(uname -s)"
os_release: "$(uname -r)"
os_version: "$(uname -v)"
arch: "$(uname -m)"
cpu: "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu 2>/dev/null | grep 'Model name' | head -1 | sed 's/.*:\s*//' || echo 'unknown')"
cpu_cores: "$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)"
crystal_version: "$cv"
crystal_commit: "$cc"
gcry_version: "$(grep 'VERSION\s*=' src/gcry.cr 2>/dev/null | sed 's/.*"\(.*\)".*/\1/' || echo 'unknown')"
git_commit: "$gh"
git_tag: "$gt"
wrk_connections: $WRK_CONNECTIONS
wrk_duration_seconds: $WRK_DURATION
trials: $TRIALS
EOF
  echo "  metadata.yaml written"
}
collect_metadata

###############################################################################
# Build
###############################################################################
build_kemal() {
  echo "=== Build kemal binaries ==="
  cd "$ROOT/bench/kemal"
  shards install --production 2>/dev/null || shards install
  echo -n "  kemal-gcry "; crystal build -Dgc_none --release src/server.cr -o "$ROOT/bin/kemal-gcry" 2>&1 | tail -1
  if [[ -f "$ROOT/bin/kemal-boehm" ]]; then
    echo "  kemal-boehm (cached)"
  else
    echo -n "  kemal-boehm "; crystal build --release src/server.cr -o "$ROOT/bin/kemal-boehm" 2>&1 | tail -1
  fi
  cd "$ROOT"
}

build_acik() {
  echo "=== Build acikturkiye binaries ==="
  cd "$AT"
  mkdir -p bin
  echo -n "  acik-gcry "; ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry 2>&1 | tail -1 || return 1
  if [[ -f "bin/acikturkiye-boehm" ]]; then
    echo "  acik-boehm (cached)"
  else
    echo -n "  acik-boehm "; ACIKTURKIYE_ENV=demo crystal build --release src/acikturkiye.cr -o bin/acikturkiye-boehm 2>&1 | tail -1 || return 1
  fi
  cd "$ROOT"
}

###############################################################################
# Helpers
###############################################################################
clean_port() {
  local port="$1"
  fuser -k "${port}/tcp" 2>/dev/null || true
  lsof -ti tcp:"$port" 2>/dev/null | xargs kill -9 2>/dev/null || true
  sleep 0.3
}

wait_http() {
  local base="$1" timeout="${2:-60}" i
  for i in $(seq 1 $((timeout * 10))); do
    if curl -sf -o /dev/null "$base/" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

wait_http_auth() {
  local base="$1" timeout="${2:-60}" i
  for i in $(seq 1 $((timeout * 10))); do
    if curl -sf -o /dev/null "${AUTH[@]}" "${base}/api/v1/" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

get_crystal_pid() {
  local bin_name="$1" fallback_pid="$2"
  local pid
  pid="$(pgrep -n -f "$bin_name" 2>/dev/null || true)"
  echo "${pid:-$fallback_pid}"
}

kill_both() {
  for p in "$@"; do
    kill -9 "$p" 2>/dev/null || true
  done
  wait "$1" 2>/dev/null || true
}

###############################################################################
# Kemal median
###############################################################################
run_kemal() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║           Kemal median-of-${TRIALS}            ║"
  echo "╚══════════════════════════════════════════════╝"

  local out="$LOG/kemal-median.tsv"
  printf "tag\tpath\ttrial\trps\trss_kib\n" >"$out"

  for trial in $(seq 1 "$TRIALS"); do
    for path in / /json; do
      for tag in boehm gcry; do
        local bin="$ROOT/bin/kemal-${tag}"
        local port=$((KEMAL_PORT_BASE + trial * 5 + ($(echo "$tag" | wc -c) % 5) * 2))
        local base="http://127.0.0.1:${port}"
        local slug="${path//\//_}"

        echo -n "  kemal trial=$trial path=$path tag=$tag ... "

        clean_port "$port"
        PORT="$port" "$bin" >"/tmp/kemal-${tag}-t${trial}.log" 2>&1 &
        local pid=$!
        if ! wait_http "$base" 40; then
          echo "FAIL (server)"
          kill_both "$pid" || true
          continue
        fi

        wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "${base}${path}" \
          >"/tmp/wrk-kemal-${tag}-${slug}-t${trial}.txt" 2>&1 || true
        local rps
        rps=$(awk '/Requests\/sec:/ {print $2}' "/tmp/wrk-kemal-${tag}-${slug}-t${trial}.txt")

        curl -sf -o /dev/null "${base}/gc-collect" || true
        sleep 0.3

        local cpid
        cpid=$(get_crystal_pid "$(basename "$bin")" "$pid")
        local rss
        rss=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ')
        rss=${rss:-0}

        if [[ "$tag" == "gcry" ]]; then
          curl -sf "${base}/gc-stats" >"$LOG/kemal-gcry-gcstats-${slug}-t${trial}.json" 2>/dev/null || true
        fi

        kill_both "$cpid" "$pid" || true
        clean_port "$port"

        printf "%s\t%s\t%d\t%s\t%s\n" "$tag" "$path" "$trial" "$rps" "$rss" >>"$out"
        echo "$rps req/s"
      done
    done
  done

  # Summarize
  python3 "$ROOT/bench/summarize_kemal.py" "$out" "$LOG/kemal-summary.md"
  cat "$LOG/kemal-summary.md"
}

###############################################################################
# Acikturkiye median
###############################################################################
run_acik() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║    acikturkiye median-of-${TRIALS}             ║"
  echo "╚══════════════════════════════════════════════╝"

  set -a; source "$AT/.env.demo"; set +a
  AUTH=(-H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}")

  local out="$LOG/acik-median.tsv"
  printf "tag\ttrial\trps\trss_kib\n" >"$out"

  for trial in $(seq 1 "$TRIALS"); do
    for tag in boehm gcry; do
      local bin="$AT/bin/acikturkiye-${tag}"
      local port trial_id="${tag}-t${trial}"
      port=$((ACIK_PORT_BASE + trial * 2 + ($(echo "$tag" | wc -c) % 5) * 3))
      local base="http://127.0.0.1:${port}"

      echo -n "  acik trial=$trial tag=$tag ... "

      clean_port "$port"
      (
        cd "$AT"
        set -a; source .env.demo; set +a
        unset GCRY_CLEAR_STACK GCRY_SCRUB_FIBERS GCRY_CLEAR_STACK_EVERY GCRY_PARALLEL_MARK || true
        export ACIKTURKIYE_ENV=demo ACIKTURKIYE_SERVER_PORT="$port"
        exec "$bin"
      ) >"/tmp/acik-${trial_id}.log" 2>&1 &
      local pid=$!

      if ! wait_http_auth "$base" 60; then
        echo "FAIL (server)"
        tail -10 "/tmp/acik-${trial_id}.log" 2>&1 | sed 's/^/    /' || true
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        printf "%s\t%d\t%s\t%s\n" "$tag" "$trial" "0" "0" >>"$out"
        echo "0 req/s"
        continue
      fi

      wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "${AUTH[@]}" "${base}/api/v1/" \
        >"/tmp/wrk-acik-${trial_id}.txt" 2>&1 || true

      # If server crashed (process gone), dump its log
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "  CRASHED — last 20 lines:"
        tail -20 "/tmp/acik-${trial_id}.log" 2>/dev/null | sed 's/^/    /'
      fi

      local rps
      rps=$(awk '/Requests\/sec:/ {print $2}' "/tmp/wrk-acik-${trial_id}.txt") || rps=0

      curl -sf -o /dev/null "${base}/gc-collect" || true
      sleep 0.5

      if [[ "$tag" == "gcry" ]]; then
        curl -sf "${base}/gc-stats" >"$LOG/acik-gcry-gcstats-t${trial}.json" 2>/dev/null || true
      fi

      local cpid
      cpid=$(get_crystal_pid "$(basename "$bin")" "$pid")
      local rss
      rss=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ') || rss=0
      rss=${rss:-0}

      kill -9 "$cpid" 2>/dev/null || true
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true

      printf "%s\t%d\t%s\t%s\n" "$tag" "$trial" "$rps" "$rss" >>"$out"
      echo "$rps req/s"
    done
  done

  # Summarize
  python3 "$ROOT/bench/summarize_acik.py" "$out" "$LOG/acik-summary.md" || true
  cat "$LOG/acik-summary.md" 2>/dev/null || true
}

###############################################################################
# Main dispatch
###############################################################################
cmd="${1:-all}"

case "$cmd" in
  kemal)
    build_kemal
    run_kemal
    ;;
  acik)
    if [[ "$HAS_ACIK" == "yes" ]]; then
      if build_acik; then
        run_acik
      else
        echo "  SKIP acikturkiye (build failed)"
      fi
    else
      echo ""
      echo "=== SKIP acikturkiye (not found at $AT/.env.demo) ==="
    fi
    ;;
  all|"")
    build_kemal
    run_kemal
    if [[ "$HAS_ACIK" == "yes" ]]; then
      if build_acik; then
        run_acik
      else
        echo "  SKIP acikturkiye (build failed)"
      fi
    else
      echo ""
      echo "=== SKIP acikturkiye (not found at $AT/.env.demo) ==="
    fi
    ;;
  *)
    echo "Usage: bash bench/run_all.sh [kemal|acik|all]"
    exit 1
    ;;
esac

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║              ALL DONE                        ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Logs: $LOG/"
echo "  Metadata: $LOG/metadata.yaml"
ls -lh "$LOG/"