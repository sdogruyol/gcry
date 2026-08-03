#!/usr/bin/env bash
# acikturkiye A/B: Boehm vs gcry tip±stackmaps (docs/STACK_MAPS.md gate).
#
# Tip Crystal needs -Dpreview_mt -Dexecution_context. Stackmap emit needs
# CRYSTAL_EMIT_STACKMAP=1 and the probe compiler.
#
# Usage (from gcry root):
#   TRIALS=1 WRK_DURATION=15 bash bench/acik_stackmap_ab.sh          # smoke
#   TRIALS=3 WRK_DURATION=30 bash bench/acik_stackmap_ab.sh          # cut
#   SKIP_BOEHM=1 bash bench/acik_stackmap_ab.sh                      # gcry-only
#   VARIANTS="base hybrid" bash bench/acik_stackmap_ab.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"
CUS="${CRYSTAL_PROBE:-$ROOT/../crystal/bin/crystal}"
SYS_CRYSTAL="${CRYSTAL_SYS:-crystal}"
TRIALS="${TRIALS:-3}"
DURATION="${WRK_DURATION:-30}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
PORT_BASE="${ACIK_PORT_BASE:-3600}"
OUT="${ACIK_STACKMAP_OUT:-$ROOT/bench/log/linux/$(date +%Y-%m-%d-%H%M%S)-acik-stackmap}"
# space-separated: boehm base hybrid exclusive sys tipec
# sys = system Crystal + gcry (-Dgc_none); tipec = tip Crystal + EC + gcry
VARIANTS="${VARIANTS:-boehm base hybrid}"
SKIP_BOEHM="${SKIP_BOEHM:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
# Fail trial if wrk reports Non-2xx (broken demo DB / exception path).
REQUIRE_2XX="${REQUIRE_2XX:-1}"

[[ -f "$AT/.env.demo" ]] || { echo "missing $AT/.env.demo"; exit 1; }
[[ -x "$CUS" ]] || { echo "missing probe crystal: $CUS"; exit 1; }
command -v wrk >/dev/null || { echo "wrk not found"; exit 1; }

mkdir -p "$OUT" "$AT/bin"
set -a; source "$AT/.env.demo"; set +a
AUTH=(-H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}")

EC_FLAGS=(-Dpreview_mt -Dexecution_context)
TIP_FLAGS=(--release "${EC_FLAGS[@]}")

echo "OUT=$OUT"
echo "probe=$CUS"
echo "variants=$VARIANTS trials=$TRIALS duration=${DURATION}s"

build_one() {
  local name="$1"; shift
  local outbin="$AT/bin/acikturkiye-$name"
  echo -n "  build $name ... "
  (
    cd "$AT"
    ACIKTURKIYE_ENV=demo "$@" -o "$outbin" src/acikturkiye.cr
  ) >"$OUT/build-$name.log" 2>&1 || {
    echo "FAIL"
    tail -20 "$OUT/build-$name.log" | sed 's/^/    /'
    return 1
  }
  echo "ok ($(basename "$outbin"))"
  if [[ "$name" == sm-* ]] || [[ "$name" == *stackmap* ]] || [[ "$name" == hybrid ]] || [[ "$name" == exclusive ]]; then
    readelf -S "$outbin" 2>/dev/null | grep -q llvm_stackmaps && echo "    .llvm_stackmaps: yes" || echo "    .llvm_stackmaps: NO"
  fi
}

echo "=== Build ==="
if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "  SKIP_BUILD=1 — using existing $AT/bin/acikturkiye-*"
else
  for v in $VARIANTS; do
    case "$v" in
      boehm)
        [[ "$SKIP_BOEHM" == "1" ]] && continue
        rm -f "$AT/bin/acikturkiye-boehm"
        build_one boehm "$SYS_CRYSTAL" build --release
        ;;
      sys)
        rm -f "$AT/bin/acikturkiye-sys"
        build_one sys "$SYS_CRYSTAL" build -Dgc_none --release
        ;;
      base|tipec)
        rm -f "$AT/bin/acikturkiye-$v"
        build_one "$v" "$CUS" build -Dgc_none "${TIP_FLAGS[@]}"
        ;;
      hybrid|exclusive)
        rm -f "$AT/bin/acikturkiye-$v"
        # Frame pointers required for exclusive FP walk under --release; hybrid
        # benefits too. Raise map density (default PER_FUN=2 is too sparse for
        # exclusive — missing frames have no conservative fallback).
        CRYSTAL_EMIT_STACKMAP=1 CRYSTAL_STACKMAP_PER_FUN="${CRYSTAL_STACKMAP_PER_FUN:-256}" \
          build_one "$v" "$CUS" build -Dgc_none "${TIP_FLAGS[@]}" --frame-pointers=always
        ;;
      *)
        echo "unknown variant: $v" >&2
        exit 1
        ;;
    esac
  done
fi

clean_port() {
  fuser -k "${1}/tcp" 2>/dev/null || true
  sleep 0.3
}

wait_auth() {
  local base="$1" i code
  for i in $(seq 1 600); do
    # Do not `|| echo 000` — curl already prints 000 on connect fail; appending
    # made [[ != "000" ]] succeed spuriously.
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 \
      "${AUTH[@]}" "${base}/api/v1/" 2>/dev/null || true)
    if [[ "$REQUIRE_2XX" == "1" ]]; then
      [[ "$code" =~ ^2[0-9][0-9]$ ]] && return 0
    else
      [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && return 0
    fi
    sleep 0.1
  done
  return 1
}

TSV="$OUT/acik-stackmap.tsv"
printf "variant\ttrial\trps\trss_kib\tmarked\trecords\tnon2xx\n" >"$TSV"

run_one() {
  local variant="$1" trial="$2"
  local bin="$AT/bin/acikturkiye-$variant"
  local port=$((PORT_BASE + trial * 10 + ${#variant}))
  local base="http://127.0.0.1:${port}"
  local log="$OUT/run-${variant}-t${trial}.log"
  local wrklog="$OUT/wrk-${variant}-t${trial}.txt"

  echo -n "  $variant trial=$trial ... "
  clean_port "$port"

  (
    cd "$AT"
    set -a; source .env.demo; set +a
    while IFS= read -r _k; do [[ -n "$_k" ]] && unset "$_k" || true
    done < <(env | awk -F= '/^GCRY_/ {print $1}')
    case "$variant" in
      hybrid) export GCRY_PRECISE_STACK=1 ;;
      exclusive) export GCRY_PRECISE_STACK=2 ;;
    esac
    export ACIKTURKIYE_ENV=demo ACIKTURKIYE_SERVER_PORT="$port"
    exec "$bin"
  ) >"$log" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true

  if ! wait_auth "$base"; then
    echo "FAIL (server / not 2xx — check demo DB migrate+seed)"
    tail -15 "$log" | sed 's/^/    /' || true
    kill -9 "$pid" 2>/dev/null || true
    printf "%s\t%d\t0\t0\t0\t0\t-1\n" "$variant" "$trial" >>"$TSV"
    return 0
  fi

  wrk -c "$CONNECTIONS" -d "$DURATION" "${AUTH[@]}" "${base}/api/v1/" >"$wrklog" 2>&1 || true
  local rps non2xx
  rps=$(awk '/Requests\/sec:/ {print $2}' "$wrklog") || rps=0
  rps=${rps:-0}
  non2xx=$(awk '/Non-2xx or 3xx responses:/ {print $NF}' "$wrklog") || non2xx=0
  non2xx=${non2xx:-0}

  if [[ "$REQUIRE_2XX" == "1" && "$non2xx" != "0" ]]; then
    echo "FAIL (Non-2xx=${non2xx} — invalid for RSS gate)"
    kill -9 "$pid" 2>/dev/null || true
    printf "%s\t%d\t%s\t0\t0\t0\t%s\n" "$variant" "$trial" "$rps" "$non2xx" >>"$TSV"
    return 0
  fi

  curl -sf -o /dev/null "${base}/gc-collect" || true
  sleep 0.5
  local stats="$OUT/gcstats-${variant}-t${trial}.json"
  curl -sf "${base}/gc-stats" >"$stats" 2>/dev/null || true

  local marked=0 records=0
  if [[ -s "$stats" ]]; then
    marked=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('precise_stack_roots_marked',0))" "$stats" 2>/dev/null || echo 0)
    records=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('stack_maps_records', d.get('stackmap_records',0)))" "$stats" 2>/dev/null || echo 0)
  fi

  local cpid
  cpid=$(pgrep -n -f "acikturkiye-$variant" 2>/dev/null || echo "$pid")
  local rss
  rss=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ') || rss=0
  rss=${rss:-0}

  kill -9 "$cpid" "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\n" "$variant" "$trial" "$rps" "$rss" "$marked" "$records" "$non2xx" >>"$TSV"
  echo "${rps} req/s rss=${rss}KiB marked=${marked} non2xx=${non2xx}"
}

echo "=== Run ==="
for trial in $(seq 1 "$TRIALS"); do
  for v in $VARIANTS; do
    [[ "$v" == "boehm" && "$SKIP_BOEHM" == "1" ]] && continue
    run_one "$v" "$trial"
  done
done

python3 - "$TSV" "$OUT/summary.md" <<'PY'
import sys, statistics as stats
from collections import defaultdict
tsv, out = sys.argv[1], sys.argv[2]
rows = []
with open(tsv) as f:
    next(f)
    for line in f:
        parts = line.strip().split("\t")
        v, t, rps, rss, marked, rec = parts[:6]
        non2xx = int(float(parts[6])) if len(parts) > 6 else 0
        rows.append((v, float(rps), int(float(rss)), int(float(marked)), non2xx))
by = defaultdict(list)
for v, rps, rss, marked, non2xx in rows:
    by[v].append((rps, rss, marked, non2xx))

def med(xs):
    return stats.median(xs) if xs else 0

lines = ["# acikturkiye stackmap A/B", "", "| variant | thr med | RSS KiB med | marked med | non2xx |", "|---------|--------:|------------:|-----------:|-------:|"]
boehm_rps = med([r for r,_,_,_ in by.get("boehm", []) if r > 0]) or None
boehm_rss = med([s for _,s,_,n in by.get("boehm", []) if s > 0 and n == 0]) or None
for v in sorted(by.keys()):
    rps = med([r for r,_,_,_ in by[v]])
    rss = med([s for _,s,_,n in by[v] if n == 0] or [s for _,s,_,_ in by[v]])
    mk = med([m for _, _, m, _ in by[v]])
    n2 = med([n for _, _, _, n in by[v]])
    thr = f"{100*rps/boehm_rps:.1f}% Boehm" if boehm_rps and rps else "—"
    rx = f"{rss/boehm_rss:.2f}×" if boehm_rss and rss else "—"
    lines.append(f"| {v} | {rps:.1f} ({thr}) | {rss:.0f} ({rx}) | {mk:.0f} | {n2:.0f} |")
lines += ["", f"Source: `{tsv}`", ""]
text = "\n".join(lines)
open(out, "w").write(text)
print(text)
PY

echo "Done → $OUT"
