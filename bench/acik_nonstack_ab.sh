#!/usr/bin/env bash
# Non-stack retention A/B on acikturkiye (docs/ACIKTURKIYE.md gate).
# Uses existing exclusive/base/boehm bins; passes through GCRY_* knobs.
#
# Usage (gcry root):
#   SKIP_BUILD=1 KNObs="control auto_layouts scan_caps floor" \
#     bash bench/acik_nonsstack_ab.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"
TRIALS="${TRIALS:-1}"
DURATION="${WRK_DURATION:-15}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
PORT_BASE="${ACIK_PORT_BASE:-3700}"
OUT="${ACIK_NONSTACK_OUT:-$ROOT/bench/log/linux/$(date +%Y-%m-%d-%H%M%S)-acik-nonstack}"
BIN_VARIANT="${BIN_VARIANT:-exclusive}" # exclusive|base
KNOBS="${KNOBS:-control auto_layouts scan_caps floor disable_layout}"

[[ -f "$AT/.env.demo" ]] || { echo "missing $AT/.env.demo"; exit 1; }
[[ -x "$AT/bin/acikturkiye-$BIN_VARIANT" ]] || { echo "missing bin acikturkiye-$BIN_VARIANT"; exit 1; }
[[ -x "$AT/bin/acikturkiye-boehm" ]] || { echo "missing boehm bin"; exit 1; }
command -v wrk >/dev/null || { echo "wrk not found"; exit 1; }

mkdir -p "$OUT"
set -a; source "$AT/.env.demo"; set +a
AUTH=(-H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}")

echo "OUT=$OUT bin=$BIN_VARIANT knobs=$KNOBS trials=$TRIALS d=${DURATION}s"

clean_port() { fuser -k "${1}/tcp" 2>/dev/null || true; sleep 0.3; }

wait_2xx() {
  local base="$1" i code
  for i in $(seq 1 600); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 \
      "${AUTH[@]}" "${base}/api/v1/" 2>/dev/null || true)
    [[ "$code" =~ ^2[0-9][0-9]$ ]] && return 0
    sleep 0.1
  done
  return 1
}

apply_knob() {
  case "$1" in
    control) : ;;
    auto_layouts) export GCRY_AUTO_LAYOUTS=1 ;;
    scan_caps) export GCRY_SCAN_CAPS=1 ;;
    floor)
      export GCRY_LARGE_CACHE=1048576
      export GCRY_EMPTY_CHUNK_RETAIN=0
      ;;
    disable_layout) export GCRY_DISABLE_LAYOUT=1 ;;
    auto_scan)
      export GCRY_AUTO_LAYOUTS=1
      export GCRY_SCAN_CAPS=1
      ;;
    *) echo "unknown knob $1" >&2; return 1 ;;
  esac
}

# Precise stack for exclusive bin
precise_env() {
  case "$BIN_VARIANT" in
    exclusive) export GCRY_PRECISE_STACK=2 ;;
    base) unset GCRY_PRECISE_STACK 2>/dev/null || true ;;
    *) ;;
  esac
}

TSV="$OUT/nonstack.tsv"
printf "knob\ttrial\trps\trss_kib\tlive_bytes\tprecise\tconservative\tentries\tge75\tlarge_free\tfree_chunks\n" >"$TSV"

run_one() {
  local knob="$1" trial="$2" is_boehm="${3:-0}"
  local name="$knob"
  local bin="$AT/bin/acikturkiye-$BIN_VARIANT"
  [[ "$is_boehm" == "1" ]] && bin="$AT/bin/acikturkiye-boehm" && name="boehm"

  local port=$((PORT_BASE + trial * 20 + ${#name}))
  local base="http://127.0.0.1:${port}"
  local log="$OUT/run-${name}-t${trial}.log"
  local wrklog="$OUT/wrk-${name}-t${trial}.txt"
  local stats="$OUT/gcstats-${name}-t${trial}.json"

  echo -n "  $name trial=$trial ... "
  clean_port "$port"

  (
    cd "$AT"
    set -a; source .env.demo; set +a
    # Drop ambient GCRY_ then apply knob
    while IFS= read -r _k; do [[ -n "$_k" ]] && unset "$_k" || true
    done < <(env | awk -F= '/^GCRY_/ {print $1}')
    if [[ "$is_boehm" != "1" ]]; then
      precise_env
      apply_knob "$knob"
    fi
    export ACIKTURKIYE_ENV=demo ACIKTURKIYE_SERVER_PORT="$port"
    exec "$bin"
  ) >"$log" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true

  if ! wait_2xx "$base"; then
    echo "FAIL (server)"
    kill -9 "$pid" 2>/dev/null || true
    printf "%s\t%d\t0\t0\t0\t0\t0\t0\t0\t0\t0\n" "$name" "$trial" >>"$TSV"
    return 0
  fi

  wrk -c "$CONNECTIONS" -d "$DURATION" "${AUTH[@]}" "${base}/api/v1/" >"$wrklog" 2>&1 || true
  local rps non2xx
  rps=$(awk '/Requests\/sec:/ {print $2}' "$wrklog") || rps=0
  rps=${rps:-0}
  non2xx=$(awk '/Non-2xx or 3xx responses:/ {print $NF}' "$wrklog") || non2xx=0
  non2xx=${non2xx:-0}
  if [[ "$non2xx" != "0" ]]; then
    echo "FAIL (Non-2xx=$non2xx)"
    kill -9 "$pid" 2>/dev/null || true
    printf "%s\t%d\t%s\t0\t0\t0\t0\t0\t0\t0\t0\n" "$name" "$trial" "$rps" >>"$TSV"
    return 0
  fi

  curl -sf -o /dev/null "${base}/gc-collect" || true
  sleep 0.5
  curl -sf "${base}/gc-stats" >"$stats" 2>/dev/null || true

  local cpid rss live prec cons ent ge75 lfree fch
  cpid=$(pgrep -n -f "acikturkiye-(boehm|$BIN_VARIANT)" 2>/dev/null || echo "$pid")
  rss=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ') || rss=0
  rss=${rss:-0}

  live=0; prec=0; cons=0; ent=0; ge75=0; lfree=0; fch=0
  if [[ -s "$stats" ]]; then
    eval "$(python3 - "$stats" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
def g(k,default=0):
    v=d.get(k,default)
    return int(v) if v is not None else 0
print(f"live={g('size_class_live_bytes')}")
print(f"prec={g('layout_precise_scans')}")
print(f"cons={g('layout_conservative_scans')}")
print(f"ent={g('layout_entries')}")
print(f"ge75={g('chunk_fill_ge75')}")
print(f"lfree={g('large_free_bytes')}")
print(f"fch={g('fully_free_chunk_bytes')}")
PY
)"
  fi

  kill -9 "$cpid" "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  printf "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$name" "$trial" "$rps" "$rss" "$live" "$prec" "$cons" "$ent" "$ge75" "$lfree" "$fch" >>"$TSV"
  echo "${rps} req/s rss=${rss}KiB live=$((live/1024/1024))MiB prec/cons=${prec}/${cons} entries=${ent}"
}

echo "=== Run ==="
# Boehm once as reference
run_one control 1 1

for trial in $(seq 1 "$TRIALS"); do
  for k in $KNOBS; do
    run_one "$k" "$trial" 0
  done
done

python3 - "$TSV" "$OUT/summary.md" <<'PY'
import sys
tsv, out = sys.argv[1], sys.argv[2]
rows=[]
with open(tsv) as f:
    next(f)
    for line in f:
        p=line.strip().split("\t")
        if len(p)<11: continue
        rows.append(p)
boehm=[r for r in rows if r[0]=="boehm"]
brss=float(boehm[0][3]) if boehm and float(boehm[0][3])>0 else None
lines=["# acik non-stack A/B", "",
       "| knob | thr | RSS KiB | × Boehm | live MiB | prec/cons | layouts |",
       "|------|----:|--------:|--------:|---------:|----------:|--------:|"]
for r in rows:
    name,t,rps,rss,live,prec,cons,ent,ge75,lfree,fch=r
    rss_f=float(rss); live_m=float(live)/1024/1024
    rx=f"{rss_f/brss:.2f}×" if brss and rss_f else "—"
    lines.append(f"| {name} | {float(rps):.1f} | {rss_f:.0f} | {rx} | {live_m:.0f} | {prec}/{cons} | {ent} |")
lines += ["", f"Source: `{tsv}`", f"Bin variant ambient precise-stack per script.", ""]
text="\n".join(lines)
open(out,"w").write(text)
print(text)
PY

echo "Done → $OUT"
