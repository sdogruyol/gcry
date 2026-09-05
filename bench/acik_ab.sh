#!/usr/bin/env bash
# gcry vs Boehm on acikturkiye — paired and order-rotated.
#
# Each trial runs both arms back-to-back and the order alternates between
# trials, and the figure reported is the **median of the per-trial ratios**, not
# the ratio of the medians. That is the difference between a number and a
# coin-flip on a machine that is doing anything else: a fixed arm order charges
# all of the within-trial drift to whichever arm runs second. Measured
# 2026-08-23 — fixed order at n=3 gave 77.8% with a Boehm column falling
# 1114 → 1018 → 845 monotonically; rotated at n=6 gave 87.1% with the per-trial
# ratios inside 85.6–89.7% while the host load doubled underneath.
#
# `docs/ACIKTURKIYE.md` records the same n=3 failure on this app from another
# host, and says not to cite such a median. This script exists so the next
# person does not have to rediscover it.
#
# Needs: ../acikturkiye with .env.demo and a reachable Postgres, `wrk`, and both
# binaries (built here unless SKIP_BUILD=1).
#
#   bash bench/acik_ab.sh
#   AB_TRIALS=10 AB_DUR=30 AB_PATH=/api/v1/cities bash bench/acik_ab.sh
set -uo pipefail
export LC_ALL=C   # printf %f with a comma decimal separator is a runtime error

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"
OUT="${ACIK_AB_OUT:-$ROOT/bench/log/linux/$(date +%Y-%m-%d)-acik-ab}"
WRK="${WRK_BIN:-wrk}"
P="${AB_PATH:-/api/v1/}"
TRIALS="${AB_TRIALS:-6}"
DUR="${AB_DUR:-20}"
CONN="${AB_CONN:-100}"
PORT="${AB_PORT:-3000}"
SKIP_BUILD="${SKIP_BUILD:-0}"

command -v "$WRK" >/dev/null || { echo "wrk not found (WRK_BIN=/path/to/wrk)" >&2; exit 1; }
[ -d "$AT" ] || { echo "acikturkiye not at $AT (set ACIKTURKIYE_ROOT)" >&2; exit 1; }
mkdir -p "$OUT" "$AT/bin"

cd "$AT"
set -a; . ./.env.demo; set +a
export ACIKTURKIYE_ENV=demo

if [ "$SKIP_BUILD" != "1" ]; then
  echo "=== build both arms (--release) ==="
  "$ROOT/bench/assert_gcry_lib.sh" "$AT/lib/gcry" "$ROOT"
  crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry
  crystal build --release src/acikturkiye.cr -o bin/acikturkiye-boehm
fi

# Kill by pid from /proc, never `pkill -f`: the pattern matches this script's
# own command line, which kills the run instead of the server.
stop_stragglers() {
  for p in $(ls -l /proc/*/exe 2>/dev/null | grep -E 'acikturkiye-(gcry|boehm)' \
             | sed 's|/proc/\([0-9]*\)/exe.*|\1|'); do kill "$p" 2>/dev/null; done
}
stop_stragglers

# $1 = binary, $2 = a label that makes the log unique.
#
# The log is per-run and never overwritten. The first version of this wrote one
# log per *arm*, so when a server died in trial 7 of 8 the next trial had
# already overwritten the only record of it — an instrument that loses the event
# it exists to catch.
run_one() {
  local bin="$1" tag="$2" pid rps rss stats alive n=0
  local log="$OUT/$tag.log"
  "$bin" >"$log" 2>&1 & pid=$!
  until curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/gc-collect" || [ $n -gt 40 ]; do
    sleep 1; n=$((n+1))
  done
  "$WRK" -c 20 -d 5 -H "X-API-KEY: $API_KEY" -H "X-API-SECRET: $API_SECRET" \
    "http://127.0.0.1:$PORT$P" >/dev/null 2>&1
  rps=$("$WRK" -c "$CONN" -d "$DUR" -H "X-API-KEY: $API_KEY" -H "X-API-SECRET: $API_SECRET" \
    "http://127.0.0.1:$PORT$P" 2>/dev/null | awk '/Requests\/sec/{print $2}')
  # Dual collect: the second one reclaims what the first one's finalizers freed.
  curl -s --max-time 20 -o /dev/null "http://127.0.0.1:$PORT/gc-collect"
  curl -s --max-time 20 -o /dev/null "http://127.0.0.1:$PORT/gc-collect"
  # Did it survive its own measurement? A dead server reads as 0 RSS and a low
  # throughput, which looks like a bad trial rather than the crash it is.
  if kill -0 "$pid" 2>/dev/null; then alive=yes; else alive=no; fi
  rss=$(awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null)
  stats=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/gc-stats" 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('col=%d heap=%dK' % (d['collections'], d['heap_size']//1024))" 2>/dev/null)
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if [ "$alive" = "no" ]; then
    echo "  !! $tag DIED during its own run — last 12 lines of $log:" >&2
    tail -12 "$log" | sed 's/^/     /' >&2
  fi
  echo "${rps:-0}|${rss:-0}|${stats:-}|$alive"
}

echo "=== acikturkiye A/B (paired, order-rotated) — $P, wrk -c $CONN -d $DUR, $TRIALS trials ==="
echo "host load at start: $(cut -d' ' -f1-3 /proc/loadavg)"
ratios=(); rssratios=(); deaths=0
for i in $(seq 1 "$TRIALS"); do
  if [ $((i % 2)) -eq 1 ]; then order=(boehm gcry); else order=(gcry boehm); fi
  declare -A R=(); declare -A S=(); declare -A G=()
  died=0
  for arm in "${order[@]}"; do
    IFS='|' read -r r s g a <<<"$(run_one "$AT/bin/acikturkiye-$arm" "trial-$i-$arm")"
    R[$arm]=$r; S[$arm]=$s; G[$arm]=$g
    [ "$a" = "yes" ] || died=1
  done
  if [ "$died" = "1" ]; then
    printf "  trial %d [%s first]  DIED — excluded from the medians, see the log above\n" "$i" "${order[0]}"
    deaths=$((deaths+1))
    continue
  fi
  ratio=$(awk -v g="${R[gcry]}" -v b="${R[boehm]}" 'BEGIN{printf "%.4f", (b>0? g/b : 0)}')
  rr=$(awk -v g="${S[gcry]}" -v b="${S[boehm]}" 'BEGIN{printf "%.4f", (b>0? g/b : 0)}')
  ratios+=("$ratio"); rssratios+=("$rr")
  printf "  trial %d [%s first]  boehm %9s r/s %8s KiB | gcry %9s r/s %8s KiB  -> thr %.1f%% rss %.2fx  %s\n" \
    "$i" "${order[0]}" "${R[boehm]}" "${S[boehm]}" "${R[gcry]}" "${S[gcry]}" \
    "$(awk -v x="$ratio" 'BEGIN{print x*100}')" "$rr" "${G[gcry]}"
done

med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }
echo ""
echo "host load at end:   $(cut -d' ' -f1-3 /proc/loadavg)"
awk -v m="$(med "${ratios[@]}")" 'BEGIN{printf "  median of per-trial thr ratios: %.1f%% of Boehm\n", m*100}'
awk -v m="$(med "${rssratios[@]}")" 'BEGIN{printf "  median of per-trial RSS ratios: %.2fx Boehm\n", m}'
echo "  thr ratios: ${ratios[*]}"
echo "  rss ratios: ${rssratios[*]}"
echo "  trials used: ${#ratios[@]} of $TRIALS ($deaths died)"
[ "$deaths" -gt 0 ] && echo "  a death is a finding, not a bad trial — its log is kept per-run under $OUT"
echo ""
echo "A load average that moves during the run, or a spread wider than a few"
echo "points across trials, means this host cannot resolve the difference."
