#!/usr/bin/env bash
# run_all.sh — Run all gcry benchmarks with structured logging to bench/log/.
#
# Usage:  bash bench/run_all.sh [kemal|acik|all]
#         TRIALS=3 WRK_DURATION=30 WRK_CONNECTIONS=100 bash bench/run_all.sh
#         COUNT=5 bash bench/run_all.sh kemal   # repeat full suite 5×
#         GC=gcry bash bench/run_all.sh kemal  # only gcry (boehm|gcry|both)
#         GCRY_FLAGS="GCRY_NURSERY=1 GCRY_INCREMENTAL=1" GC=gcry bash bench/run_all.sh kemal
#         CRYSTAL_FLAGS="--release --debug --error-trace" bash bench/run_all.sh kemal  # SEGV symbols
#
# GCRY_FLAGS — space-separated KEY=VALUE applied only to gcry server processes
# (boehm runs stay clean). Ambient GCRY_* in the shell are also inherited by
# gcry; GCRY_FLAGS wins on duplicate keys. Recorded in metadata.yaml.
#
# CRYSTAL_FLAGS — space-separated `crystal build` flags (overrides DEBUG presets).
#   default / unset + DEBUG=0  — --release   (PERF.md methodology)
#   DEBUG=1                    — --debug --error-trace
#   CRYSTAL_FLAGS="--release --debug --error-trace"  — release + SEGV file:line
#
#   DEBUG=1 bash bench/run_all.sh kemal
#   CRYSTAL_FLAGS="--release --debug --error-trace" bash bench/run_all.sh kemal
#   DEBUG=1 TRIALS=1 WRK_DURATION=10 bash bench/run_all.sh kemal
#   COUNT=3 TRIALS=1 WRK_DURATION=15 bash bench/run_all.sh kemal
#   GC=gcry COUNT=5 bash bench/run_all.sh kemal
#
# Output in bench/log/ (auto-detected platform):
#   linux/       — `uname -s` = Linux
#   macos/       — `uname -s` = Darwin
#     YYYY-MM-DD-HHMMSS/
#       run-01/
#         metadata.yaml
#         kemal-median.tsv / kemal-summary.md / kemal-gcry-gcstats-*.json
#         acik-* (if available)
#       run-02/
#         ...
#
# Requires: wrk, curl, python3, git
# Requires sibling ../acikturkiye for acikturkiye benchmarks.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WRK_CONNECTIONS="${WRK_CONNECTIONS:-100}"
WRK_DURATION="${WRK_DURATION:-30}"
TRIALS="${TRIALS:-3}"
COUNT="${COUNT:-1}"
GC="${GC:-both}"
# Space-separated KEY=VALUE for gcry servers only, e.g.:
#   GCRY_FLAGS="GCRY_NURSERY=1 GCRY_THRESHOLD=33554432"
GCRY_FLAGS="${GCRY_FLAGS:-}"
KEMAL_PORT_BASE="${KEMAL_PORT_BASE:-3200}"
ACIK_PORT_BASE="${ACIK_PORT_BASE:-3500}"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "COUNT must be a positive integer (got: $COUNT)" >&2
  exit 1
fi

case "$GC" in
  both|all)
    GC_TAGS=(boehm gcry)
    ;;
  gcry|boehm)
    GC_TAGS=("$GC")
    ;;
  *)
    echo "GC must be boehm, gcry, or both (got: $GC)" >&2
    exit 1
    ;;
esac
gc_wants() {
  local want="$1" t
  for t in "${GC_TAGS[@]}"; do
    [[ "$t" == "$want" ]] && return 0
  done
  return 1
}

# Parsed GCRY_FLAGS → env KEY=VAL args for `env` / export.
GCRY_ENV_ARGS=()
if [[ -n "$GCRY_FLAGS" ]]; then
  # shellcheck disable=SC2086
  for tok in $GCRY_FLAGS; do
    if [[ "$tok" != GCRY_*=* ]]; then
      echo "GCRY_FLAGS entries must be GCRY_KEY=value (got: $tok)" >&2
      exit 1
    fi
    GCRY_ENV_ARGS+=("$tok")
  done
fi

# Snapshot ambient GCRY_* (before any unset) for acik subshells + metadata.
AMBIENT_GCRY=()
while IFS= read -r line; do
  [[ -n "$line" ]] && AMBIENT_GCRY+=("$line")
done < <(env | awk -F= '/^GCRY_/ && $1 != "GCRY_FLAGS" {print}' | sort || true)

ambient_gcry_env() {
  if [[ ${#AMBIENT_GCRY[@]} -gt 0 ]]; then
    printf '%s\n' "${AMBIENT_GCRY[@]}"
  fi
}

# DEBUG=1 → --debug --error-trace (file:line + symbols for SEGV; no --release).
# Default → --release only (matches docs/PERF.md; thr gate).
# For release + symbolicated SEGV: CRYSTAL_FLAGS="--release --debug --error-trace"
# CRYSTAL_FLAGS overrides both presets and forces a rebuild (no bin cache).
CRYSTAL_FLAGS="${CRYSTAL_FLAGS:-}"
DEBUG="${DEBUG:-0}"
case "$DEBUG" in
  1|true|TRUE|yes|YES) DEBUG=1 ;;
  *) DEBUG=0 ;;
esac

FORCE_REBUILD=0
CRYSTAL_BUILD_FLAGS=()
if [[ -n "$CRYSTAL_FLAGS" ]]; then
  # shellcheck disable=SC2206
  CRYSTAL_BUILD_FLAGS=($CRYSTAL_FLAGS)
  BUILD_MODE="custom"
  FORCE_REBUILD=1
  if [[ "$DEBUG" == "1" ]]; then
    echo "note: CRYSTAL_FLAGS set — ignoring DEBUG=1 preset" >&2
  fi
elif [[ "$DEBUG" == "1" ]]; then
  BUILD_MODE="debug"
  CRYSTAL_BUILD_FLAGS=(--debug --error-trace)
  FORCE_REBUILD=1
else
  BUILD_MODE="release"
  CRYSTAL_BUILD_FLAGS=(--release)
fi

HAS_ACIK="no"
[[ -d "$AT" && -f "$AT/.env.demo" ]] && HAS_ACIK="yes"

# Detect platform: Linux → bench/log/linux/, Darwin → bench/log/macos/
OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Linux)
    PLATFORM_DIR="linux"
    ;;
  Darwin)
    PLATFORM_DIR="macos"
    ;;
  *)
    PLATFORM_DIR="other"
    ;;
esac

SESSION_TS="$(date -u +%Y-%m-%d-%H%M%S)"
LOG_ROOT="$ROOT/bench/log/$PLATFORM_DIR/$SESSION_TS"
mkdir -p "$LOG_ROOT"
RUN=1
LOG="$LOG_ROOT/run-$(printf '%02d' "$RUN")"

echo "=== Session $LOG_ROOT (COUNT=$COUNT GC=${GC_TAGS[*]}) ==="
echo "=== Build mode: $BUILD_MODE (${CRYSTAL_BUILD_FLAGS[*]}) ==="
if [[ ${#GCRY_ENV_ARGS[@]} -gt 0 ]]; then
  echo "=== GCRY_FLAGS: ${GCRY_ENV_ARGS[*]} ==="
fi
amb="$(ambient_gcry_env)"
if [[ -n "$amb" ]]; then
  echo "=== ambient GCRY_*: ==="
  echo "$amb" | sed 's/^/  /'
fi

###############################################################################
# Metadata
###############################################################################
collect_metadata() {
  local cv cc gh gt
  cv="$(crystal --version 2>/dev/null | head -1 | awk '{print $2}')" || cv="unknown"
  cc="$(crystal --version 2>/dev/null | grep -i commit | awk '{print $4}')" || cc="unknown"
  gh="$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  gt="$(cd "$ROOT" && git describe --tags --always 2>/dev/null || echo "none")"

  mkdir -p "$LOG"
  cat <<EOF >"$LOG/metadata.yaml"
timestamp_utc: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
session: "$SESSION_TS"
run: $RUN
count: $COUNT
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
gc: "${GC_TAGS[*]}"
gcry_flags: "${GCRY_FLAGS:-}"
ambient_gcry: |
$(ambient_gcry_env | sed 's/^/  /')
build_mode: "$BUILD_MODE"
crystal_flags: "${CRYSTAL_FLAGS:-}"
crystal_build_flags: "${CRYSTAL_BUILD_FLAGS[*]}"
EOF
  echo "  metadata.yaml written ($LOG)"
}

###############################################################################
# Build
###############################################################################
build_kemal() {
  echo "=== Build kemal binaries ($BUILD_MODE, GC=${GC_TAGS[*]}) ==="
  echo "  crystal build flags: ${CRYSTAL_BUILD_FLAGS[*]}"
  cd "$ROOT/bench/kemal"
  shards install --production 2>/dev/null || shards install
  mkdir -p "$ROOT/bin"
  # DEBUG / CRYSTAL_FLAGS always rebuild; default release may reuse cached boehm.
  if [[ "$FORCE_REBUILD" == "1" ]]; then
    rm -f "$ROOT/bin/kemal-gcry" "$ROOT/bin/kemal-boehm"
  fi
  if gc_wants gcry; then
    echo -n "  kemal-gcry "; crystal build -Dgc_none "${CRYSTAL_BUILD_FLAGS[@]}" src/server.cr -o "$ROOT/bin/kemal-gcry" 2>&1 | tail -1
  else
    echo "  kemal-gcry (skipped)"
  fi
  if gc_wants boehm; then
    if [[ "$FORCE_REBUILD" != "1" && -f "$ROOT/bin/kemal-boehm" ]]; then
      echo "  kemal-boehm (cached)"
    else
      echo -n "  kemal-boehm "; crystal build "${CRYSTAL_BUILD_FLAGS[@]}" src/server.cr -o "$ROOT/bin/kemal-boehm" 2>&1 | tail -1
    fi
  else
    echo "  kemal-boehm (skipped)"
  fi
  cd "$ROOT"
}

build_acik() {
  echo "=== Build acikturkiye binaries ($BUILD_MODE, GC=${GC_TAGS[*]}) ==="
  echo "  crystal build flags: ${CRYSTAL_BUILD_FLAGS[*]}"
  cd "$AT"
  mkdir -p bin
  if [[ "$FORCE_REBUILD" == "1" ]]; then
    rm -f bin/acikturkiye-gcry bin/acikturkiye-boehm
  fi
  if gc_wants gcry; then
    echo -n "  acik-gcry "; ACIKTURKIYE_ENV=demo crystal build -Dgc_none "${CRYSTAL_BUILD_FLAGS[@]}" src/acikturkiye.cr -o bin/acikturkiye-gcry 2>&1 | tail -1 || return 1
  else
    echo "  acik-gcry (skipped)"
  fi
  if gc_wants boehm; then
    if [[ "$FORCE_REBUILD" != "1" && -f "bin/acikturkiye-boehm" ]]; then
      echo "  acik-boehm (cached)"
    else
      echo -n "  acik-boehm "; ACIKTURKIYE_ENV=demo crystal build "${CRYSTAL_BUILD_FLAGS[@]}" src/acikturkiye.cr -o bin/acikturkiye-boehm 2>&1 | tail -1 || return 1
    fi
  else
    echo "  acik-boehm (skipped)"
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

# SIGKILL servers without bash "Killed" job noise (disown at start).
kill_quiet() {
  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    kill -9 "$p" 2>/dev/null || true
  done
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    wait "$p" 2>/dev/null || true
  done
}
kill_both() { kill_quiet "$@"; }

###############################################################################
# Kemal median
###############################################################################
run_kemal() {
  echo ""
  echo "╔══════════════════════════════════════════════╗"
  echo "║  Kemal median-of-${TRIALS}  (run ${RUN}/${COUNT})  ║"
  echo "╚══════════════════════════════════════════════╝"

  local out="$LOG/kemal-median.tsv"
  local run_tag
  run_tag="$(printf '%02d' "$RUN")"
  printf "tag\tpath\ttrial\trps\trss_kib\n" >"$out"

  for trial in $(seq 1 "$TRIALS"); do
    for path in / /json; do
      for tag in "${GC_TAGS[@]}"; do
        local bin="$ROOT/bin/kemal-${tag}"
        local port=$((KEMAL_PORT_BASE + RUN * 20 + trial * 5 + ($(echo "$tag" | wc -c) % 5) * 2))
        local base="http://127.0.0.1:${port}"
        local slug="${path//\//_}"
        local srv_log="/tmp/kemal-${tag}-r${run_tag}-t${trial}.log"
        local wrk_log="/tmp/wrk-kemal-${tag}-${slug}-r${run_tag}-t${trial}.txt"

        echo -n "  kemal run=$RUN trial=$trial path=$path tag=$tag ... "

        clean_port "$port"
        if [[ "$tag" == "gcry" && ${#GCRY_ENV_ARGS[@]} -gt 0 ]]; then
          env "${GCRY_ENV_ARGS[@]}" PORT="$port" "$bin" >"$srv_log" 2>&1 &
        else
          PORT="$port" "$bin" >"$srv_log" 2>&1 &
        fi
        local pid=$!
        disown "$pid" 2>/dev/null || true
        if ! wait_http "$base" 40; then
          echo "FAIL (server)"
          kill_quiet "$pid" || true
          continue
        fi

        wrk -c "$WRK_CONNECTIONS" -d "$WRK_DURATION" "${base}${path}" \
          >"$wrk_log" 2>&1 || true
        local rps
        rps=$(awk '/Requests\/sec:/ {print $2}' "$wrk_log")

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

        kill_quiet "$cpid" "$pid"
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
  echo "║  acikturkiye median-of-${TRIALS}  (run ${RUN}/${COUNT})  ║"
  echo "╚══════════════════════════════════════════════╝"

  set -a; source "$AT/.env.demo"; set +a
  AUTH=(-H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}")

  local out="$LOG/acik-median.tsv"
  local run_tag
  run_tag="$(printf '%02d' "$RUN")"
  printf "tag\ttrial\trps\trss_kib\n" >"$out"

  for trial in $(seq 1 "$TRIALS"); do
    for tag in "${GC_TAGS[@]}"; do
      local bin="$AT/bin/acikturkiye-${tag}"
      local port trial_id="r${run_tag}-${tag}-t${trial}"
      port=$((ACIK_PORT_BASE + RUN * 20 + trial * 2 + ($(echo "$tag" | wc -c) % 5) * 3))
      local base="http://127.0.0.1:${port}"

      echo -n "  acik run=$RUN trial=$trial tag=$tag ... "

      clean_port "$port"
      (
        cd "$AT"
        set -a; source .env.demo; set +a
        # Demo env may set GCRY_*; strip, then re-apply ambient + GCRY_FLAGS (flags win).
        while IFS= read -r _k; do
          [[ -n "$_k" ]] && unset "$_k" || true
        done < <(env | awk -F= '/^GCRY_/ {print $1}')
        if [[ "$tag" == "gcry" ]]; then
          for _kv in "${AMBIENT_GCRY[@]+"${AMBIENT_GCRY[@]}"}"; do
            export "${_kv?}"
          done
          for _kv in "${GCRY_ENV_ARGS[@]+"${GCRY_ENV_ARGS[@]}"}"; do
            export "${_kv?}"
          done
        fi
        export ACIKTURKIYE_ENV=demo ACIKTURKIYE_SERVER_PORT="$port"
        exec "$bin"
      ) >"/tmp/acik-${trial_id}.log" 2>&1 &
      local pid=$!
      disown "$pid" 2>/dev/null || true

      if ! wait_http_auth "$base" 60; then
        echo "FAIL (server)"
        tail -10 "/tmp/acik-${trial_id}.log" 2>&1 | sed 's/^/    /' || true
        kill_quiet "$pid" || true
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

      kill_quiet "$cpid" "$pid"

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
  kemal|acik|all|"") ;;
  *)
    echo "Usage: bash bench/run_all.sh [kemal|acik|all]"
    echo "  GC=boehm|gcry|both  — which collector(s) to build/run (default: both)"
    echo "  GCRY_FLAGS=\"GCRY_NURSERY=1 …\"  — env knobs for gcry servers only"
    echo "  CRYSTAL_FLAGS=\"--release --debug …\"  — crystal build flags (overrides DEBUG)"
    echo "  DEBUG=1             — --debug --error-trace (no --release); forces rebuild"
    echo "  COUNT=N             — repeat suite N times → log/.../run-01 .. run-NN"
    echo "  default             — --release (PERF.md); SEGV symbols: CRYSTAL_FLAGS=--release --debug --error-trace"
    exit 1
    ;;
esac

# Build once per session.
case "$cmd" in
  kemal|all|"")
    build_kemal
    ;;
esac
case "$cmd" in
  acik|all|"")
    if [[ "$HAS_ACIK" == "yes" ]]; then
      build_acik || echo "  SKIP acikturkiye (build failed)"
    elif [[ "$cmd" == "acik" ]]; then
      echo ""
      echo "=== SKIP acikturkiye (not found at $AT/.env.demo) ==="
    fi
    ;;
esac

acik_ready() {
  [[ "$HAS_ACIK" == "yes" ]] || return 1
  gc_wants gcry && [[ -x "$AT/bin/acikturkiye-gcry" ]] && return 0
  gc_wants boehm && [[ -x "$AT/bin/acikturkiye-boehm" ]] && return 0
  return 1
}

for RUN in $(seq 1 "$COUNT"); do
  LOG="$LOG_ROOT/run-$(printf '%02d' "$RUN")"
  mkdir -p "$LOG"
  echo ""
  echo "══════════════════════════════════════════════"
  echo "  RUN ${RUN}/${COUNT}  →  $LOG"
  echo "══════════════════════════════════════════════"
  collect_metadata

  case "$cmd" in
    kemal)
      run_kemal
      ;;
    acik)
      if acik_ready; then
        run_acik
      fi
      ;;
    all|"")
      run_kemal
      if [[ "$HAS_ACIK" == "yes" ]]; then
        if acik_ready; then
          run_acik
        else
          echo "  SKIP acikturkiye (no binary for GC=${GC_TAGS[*]})"
        fi
      else
        echo ""
        echo "=== SKIP acikturkiye (not found at $AT/.env.demo) ==="
      fi
      ;;
  esac
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║              ALL DONE                        ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Build: $BUILD_MODE (${CRYSTAL_BUILD_FLAGS[*]})"
echo "  GC: ${GC_TAGS[*]}"
[[ ${#GCRY_ENV_ARGS[@]} -gt 0 ]] && echo "  GCRY_FLAGS: ${GCRY_ENV_ARGS[*]}"
echo "  COUNT: $COUNT"
echo "  Session: $LOG_ROOT/"
ls -lh "$LOG_ROOT"/
for d in "$LOG_ROOT"/run-*; do
  [[ -d "$d" ]] || continue
  echo "  --- $(basename "$d") ---"
  ls -lh "$d/"
done
