#!/usr/bin/env bash
# acikturkiye live-set attribution probe (docs/STACK_MAPS.md §A).
# wrk → dual collect → /gc-live-attr + /gc-stats.
#
# Usage (gcry root):
#   bash bench/acik_live_attr.sh
#   SKIP_BUILD=1 BIN_VARIANT=exclusive WRK_DURATION=30 bash bench/acik_live_attr.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"
CUS="${CRYSTAL_PROBE:-$ROOT/../crystal/bin/crystal}"
TRIALS="${TRIALS:-1}"
DURATION="${WRK_DURATION:-15}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
PORT_BASE="${ACIK_PORT_BASE:-3800}"
OUT="${ACIK_LIVE_ATTR_OUT:-$ROOT/bench/log/linux/$(date +%Y-%m-%d)-acik-live-attr}"
BIN_VARIANT="${BIN_VARIANT:-exclusive}" # exclusive|base|sys — binary name
# Runtime precise mode (independent of binary name when maps present):
#   unset|0 = conservative stacks, 1 = hybrid, 2 = exclusive
PRECISE_MODE="${PRECISE_MODE:-}" # empty → derive from BIN_VARIANT
SKIP_BUILD="${SKIP_BUILD:-0}"
REQUIRE_2XX="${REQUIRE_2XX:-1}"
# After wrk+dual-collect sample: idle then re-sample (A/B/C for 32 KiB atomics).
# 0 = skip. Typical: IDLE_DRAIN_SEC=60
IDLE_DRAIN_SEC="${IDLE_DRAIN_SEC:-0}"

[[ -f "$AT/.env.demo" ]] || { echo "missing $AT/.env.demo"; exit 1; }
command -v wrk >/dev/null || { echo "wrk not found"; exit 1; }

mkdir -p "$OUT" "$AT/bin"
set -a; source "$AT/.env.demo"; set +a
AUTH=(-H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}")
EC_FLAGS=(-Dpreview_mt -Dexecution_context)

echo "OUT=$OUT bin=$BIN_VARIANT trials=$TRIALS d=${DURATION}s"

# Prefer AT/bin; if root-owned/unwritable, fall back to gcry/.tmp/acik-bin.
BIN_DIR="${ACIK_BIN_DIR:-$AT/bin}"
if [[ ! -w "$BIN_DIR" ]] || { [[ -e "$BIN_DIR/acikturkiye-$BIN_VARIANT" ]] && [[ ! -w "$BIN_DIR/acikturkiye-$BIN_VARIANT" ]]; }; then
  BIN_DIR="$ROOT/.tmp/acik-bin"
  mkdir -p "$BIN_DIR"
  echo "  note: AT/bin not writable → BIN_DIR=$BIN_DIR"
fi

build_exclusive() {
  [[ -x "$CUS" ]] || { echo "missing probe crystal: $CUS"; exit 1; }
  local outbin="$BIN_DIR/acikturkiye-exclusive"
  echo -n "  build exclusive → $outbin ... "
  (
    cd "$AT"
    ACIKTURKIYE_ENV=demo \
      CRYSTAL_EMIT_STACKMAP=1 CRYSTAL_STACKMAP_PER_FUN=0 \
      "$CUS" build -Dgc_none --release "${EC_FLAGS[@]}" --frame-pointers=always \
      -o "$outbin" src/acikturkiye.cr
  ) >"$OUT/build-exclusive.log" 2>&1 || {
    echo "FAIL"; tail -30 "$OUT/build-exclusive.log"; exit 1
  }
  echo ok
  readelf -S "$outbin" 2>/dev/null | grep -q llvm_stackmaps \
    && echo "  .llvm_stackmaps: yes" || echo "  .llvm_stackmaps: NO"
}

build_base() {
  local cry="${CRYSTAL_SYS:-crystal}"
  local outbin="$BIN_DIR/acikturkiye-base"
  echo -n "  build base → $outbin ... "
  (
    cd "$AT"
    ACIKTURKIYE_ENV=demo \
      "$cry" build -Dgc_none --release "${EC_FLAGS[@]}" \
      -o "$outbin" src/acikturkiye.cr
  ) >"$OUT/build-base.log" 2>&1 || {
    echo "FAIL"; tail -30 "$OUT/build-base.log"; exit 1
  }
  echo ok
}

if [[ "$SKIP_BUILD" != "1" ]]; then
  case "$BIN_VARIANT" in
    exclusive) build_exclusive ;;
    base) build_base ;;
    sys) : ;; # expect existing
    *) echo "unknown BIN_VARIANT=$BIN_VARIANT"; exit 1 ;;
  esac
fi

BIN="$BIN_DIR/acikturkiye-$BIN_VARIANT"
[[ -x "$BIN" ]] || BIN="$AT/bin/acikturkiye-$BIN_VARIANT"
[[ -x "$BIN" ]] || { echo "missing $BIN_DIR/acikturkiye-$BIN_VARIANT"; exit 1; }

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

precise_env() {
  local mode="$PRECISE_MODE"
  if [[ -z "$mode" ]]; then
    case "$BIN_VARIANT" in
      exclusive) mode=2 ;;
      hybrid) mode=1 ;;
      *) mode=0 ;;
    esac
  fi
  case "$mode" in
    2) export GCRY_PRECISE_STACK=2 ;;
    1) export GCRY_PRECISE_STACK=1 ;;
    0|"") unset GCRY_PRECISE_STACK 2>/dev/null || true ;;
    *) echo "bad PRECISE_MODE=$mode" >&2; return 1 ;;
  esac
  echo "  precise_mode=$mode"
}

summarize() {
  local attr="$1" stats="$2"
  python3 - "$attr" "$stats" <<'PY'
import json, sys
attr=json.load(open(sys.argv[1]))
stats=json.load(open(sys.argv[2]))
def mib(x): return x/1024/1024
tb=attr["total_bytes"]
print(f"live_objects={attr['total_objects']} total_MiB={mib(tb):.1f} typed_MiB={mib(attr['typed_bytes']):.1f} collision_MiB={mib(attr.get('collision_bytes',0)):.1f} raw_MiB={mib(attr['raw_bytes']):.1f} large_MiB={mib(attr['large_bytes']):.1f}")
print(f"gcstats size_class_live_MiB={mib(stats.get('size_class_live_bytes',0)):.1f} live_objects={stats.get('live_objects')}")
print(f"stack_maps_loaded={stats.get('stack_maps_loaded')} records={stats.get('stack_maps_records')} hits={stats.get('stack_maps_hits')} precise_marked={stats.get('precise_stack_roots_marked')}")
if attr.get("live_attr_roots"):
    print("first_mark MiB: mutator={:.1f} parked={:.1f} static={:.1f} thread={:.1f} precise={:.1f} heap={:.1f}".format(
        mib(attr.get("first_mark_stack_bytes",0)), mib(attr.get("first_mark_parked_bytes",0)),
        mib(attr.get("first_mark_static_bytes",0)), mib(attr.get("first_mark_thread_bytes",0)),
        mib(attr.get("first_mark_precise_bytes",0)), mib(attr.get("first_mark_heap_bytes",0))))
    print("first_mark ATOMIC MiB: mutator={:.1f} parked={:.1f} precise={:.1f} heap={:.1f}".format(
        mib(attr.get("first_mark_stack_atomic_bytes",0)), mib(attr.get("first_mark_parked_atomic_bytes",0)),
        mib(attr.get("first_mark_precise_atomic_bytes",0)), mib(attr.get("first_mark_heap_atomic_bytes",0))))
print("top size_classes (payload → MiB / count):")
for c in attr["size_classes"][:12]:
    print(f"  {c['payload']:5d}  {mib(c['bytes']):7.1f} MiB  n={c['count']}")
mx=attr.get("max_size_class") or {}
if mx:
    print("max_size_class 32768 breakdown MiB:")
    print(f"  typed={mib(mx.get('typed_bytes',0)):.1f} collision={mib(mx.get('collision_bytes',0)):.1f} raw={mib(mx.get('raw_bytes',0)):.1f}")
    print(f"  atomic={mib(mx.get('atomic_bytes',0)):.1f} ptrish={mib(mx.get('ptrish_bytes',0)):.1f} byteish={mib(mx.get('byteish_bytes',0)):.1f}")
print("top typed type_ids:")
for t in attr["top_type_ids"][:12]:
    print(f"  {t['type_id']:6d}  {mib(t['bytes']):7.1f} MiB  n={t['count']}")
print("top collision type_ids (false typed on big blocks):")
for t in (attr.get("top_collision_type_ids") or [])[:12]:
    print(f"  {t['type_id']:6d}  {mib(t['bytes']):7.1f} MiB  n={t['count']}")
PY
}

for trial in $(seq 1 "$TRIALS"); do
  port=$((PORT_BASE + trial))
  base="http://127.0.0.1:${port}"
  log="$OUT/run-t${trial}.log"
  wrklog="$OUT/wrk-t${trial}.txt"
  attr="$OUT/live-attr-t${trial}.json"
  stats="$OUT/gcstats-t${trial}.json"

  echo -n "  trial=$trial ... "
  clean_port "$port"
  (
    cd "$AT"
    set -a; source .env.demo; set +a
    # Preserve research fiber / miss-log flags across GCRY_* scrub.
    _fibers="${GCRY_PRECISE_FIBERS:-}"
    _leaf="${GCRY_PRECISE_FIBER_LEAF:-}"
    _nofill="${GCRY_DISABLE_FIBER_FP_FILL:-}"
    _missonly="${GCRY_FIBER_FP_FILL_MISS_ONLY:-}"
    _misslog="${GCRY_STACKMAP_MISS_LOG:-}"
    _neard="${GCRY_STACKMAP_NEAR_DELTA:-}"
    _watch="${GCRY_LIVE_ATTR_WATCH_TID:-}"
    _thresh="${GCRY_THRESHOLD:-}"
    while IFS= read -r _k; do [[ -n "$_k" ]] && unset "$_k" || true
    done < <(env | awk -F= '/^GCRY_/ {print $1}')
    precise_env
    [[ -n "$_fibers" ]] && export GCRY_PRECISE_FIBERS="$_fibers"
    [[ -n "$_leaf" ]] && export GCRY_PRECISE_FIBER_LEAF="$_leaf"
    [[ -n "$_nofill" ]] && export GCRY_DISABLE_FIBER_FP_FILL="$_nofill"
    [[ -n "$_missonly" ]] && export GCRY_FIBER_FP_FILL_MISS_ONLY="$_missonly"
    [[ -n "$_misslog" ]] && export GCRY_STACKMAP_MISS_LOG="$_misslog"
    [[ -n "$_neard" ]] && export GCRY_STACKMAP_NEAR_DELTA="$_neard"
    [[ -n "$_watch" ]] && export GCRY_LIVE_ATTR_WATCH_TID="$_watch"
    [[ -n "$_thresh" ]] && export GCRY_THRESHOLD="$_thresh"
    export GCRY_LIVE_ATTR=1
    export ACIKTURKIYE_ENV=demo ACIKTURKIYE_SERVER_PORT="$port"
    exec "$BIN" >>"$log" 2>&1
  ) &
  pid=$!
  if ! wait_2xx "$base"; then
    echo "FAIL ready"; kill "$pid" 2>/dev/null || true; continue
  fi

  wrk -t4 -c"$CONNECTIONS" -d"${DURATION}s" --latency \
    -H "X-API-KEY: ${API_KEY}" -H "X-API-SECRET: ${API_SECRET}" \
    "${base}/api/v1/" >"$wrklog" 2>&1 || true

  if [[ "$REQUIRE_2XX" == "1" ]] && grep -qE 'Non-2xx or timeout responses:\s*[1-9]' "$wrklog"; then
    echo "FAIL non2xx"; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    continue
  fi

  curl -sS "${base}/gc-collect" >/dev/null
  curl -sS "${base}/gc-collect" >/dev/null
  curl -sS "${base}/gc-live-attr" >"$attr"
  curl -sS "${base}/gc-stats" >"$stats"
  ss -tn "sport = :${port}" 2>/dev/null | tee "$OUT/ss-t${trial}-post.txt" >/dev/null || true
  estab=$(awk 'BEGIN{n=0} /ESTAB/{n++} END{print n+0}' "$OUT/ss-t${trial}-post.txt" 2>/dev/null || echo 0)
  echo "estab_post=$estab" | tee "$OUT/estab-t${trial}-post.txt"
  echo ok
  summarize "$attr" "$stats" | tee "$OUT/summary-t${trial}.txt"

  if [[ "$IDLE_DRAIN_SEC" -gt 0 ]]; then
    echo -n "  idle ${IDLE_DRAIN_SEC}s ... "
    sleep "$IDLE_DRAIN_SEC"
    curl -sS "${base}/gc-collect" >/dev/null
    curl -sS "${base}/gc-collect" >/dev/null
    curl -sS "${base}/gc-live-attr" >"$OUT/live-attr-t${trial}-idle.json"
    curl -sS "${base}/gc-stats" >"$OUT/gcstats-t${trial}-idle.json"
    ss -tn "sport = :${port}" 2>/dev/null | tee "$OUT/ss-t${trial}-idle.txt" >/dev/null || true
    estab_i=$(awk 'BEGIN{n=0} /ESTAB/{n++} END{print n+0}' "$OUT/ss-t${trial}-idle.txt" 2>/dev/null || echo 0)
    echo "estab_idle=$estab_i" | tee "$OUT/estab-t${trial}-idle.txt"
    python3 - "$attr" "$OUT/live-attr-t${trial}-idle.json" "$estab" "$estab_i" <<'PY' \
      | tee "$OUT/idle-drain-t${trial}.txt"
import json,sys
a0=json.load(open(sys.argv[1])); a1=json.load(open(sys.argv[2]))
e0,e1=int(sys.argv[3]),int(sys.argv[4])
def mib(x): return x/1024/1024
def mx(a):
  m=a.get("max_size_class") or {}
  return mib(m.get("atomic_bytes",0)), m.get("atomic_objects",0) or m.get("count",0), mib(a["total_bytes"])
at0,n0,t0=mx(a0); at1,n1,t1=mx(a1)
print(f"idle-drain: estab {e0}→{e1}  max_atomic {at0:.1f}→{at1:.1f} MiB  live {t0:.1f}→{t1:.1f} MiB")
if e1 <= 2 and at1 > 40:
  print("verdict: B-leaning (sockets drained, atomics remain → false roots / unreclaimed graph)")
elif at1 <= max(8.0, 0.15*at0) and e1 <= e0:
  print("verdict: A/C-leaning (atomics fell with drain → true live IO / pool)")
else:
  print("verdict: mixed — inspect top_type_ids + PG pool")
def watch(a,tag):
  tid=a.get("live_attr_watch_tid") or 0
  if not tid: return
  keys=["stack","parked","static","thread","precise","heap"]
  parts=[f"{k}={a.get('first_mark_watch_'+k,0)}" for k in keys]
  print(f"watch_tid={tid} [{tag}]: "+", ".join(parts))
watch(a0,"post"); watch(a1,"idle")
print("top typed post→idle (type_id MiB):")
def tops(a):
  return {t["type_id"]:(t["bytes"],t["count"]) for t in (a.get("top_type_ids") or [])[:8]}
tpost,tidle=tops(a0),tops(a1)
for tid in sorted(set(tpost)|set(tidle), key=lambda i: -(tidle.get(i,tpost.get(i,(0,0)))[0])):
  b0,c0=tpost.get(tid,(0,0)); b1,c1=tidle.get(tid,(0,0))
  print(f"  {tid:6d}  {mib(b0):5.1f}→{mib(b1):5.1f} MiB  n={c0}→{c1}")
PY
    echo ok
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  clean_port "$port"
done

echo "done OUT=$OUT"
