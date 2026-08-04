#!/usr/bin/env bash
# A/B live-attr: one stackmap exclusive bin × PRECISE_MODE=0|1|2.
# Shows who first-marks atomic slabs (mutator vs parked vs heap).
#
# Usage (gcry root):
#   bash bench/acik_live_attr_ab.sh
#   MODES="0 2" WRK_DURATION=15 bash bench/acik_live_attr_ab.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AT="${ACIKTURKIYE_ROOT:-$ROOT/../acikturkiye}"
CUS="${CRYSTAL_PROBE:-$ROOT/../crystal/bin/crystal}"
MODES="${MODES:-0 1 2}"
DURATION="${WRK_DURATION:-15}"
BASE_OUT="${ACIK_LIVE_ATTR_AB_OUT:-$ROOT/bench/log/linux/$(date +%Y-%m-%d)-acik-live-attr-ab}"
SKIP_BUILD="${SKIP_BUILD:-0}"
mkdir -p "$BASE_OUT" "$AT/bin"

BIN="$AT/bin/acikturkiye-exclusive"
if [[ ! -w "$(dirname "$BIN")" ]] || { [[ -e "$BIN" ]] && [[ ! -w "$BIN" ]]; }; then
  mkdir -p "$ROOT/.tmp/acik-bin"
  BIN="$ROOT/.tmp/acik-bin/acikturkiye-exclusive"
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "=== build exclusive → $BIN ==="
  (
    cd "$AT"
    ACIKTURKIYE_ENV=demo \
      CRYSTAL_EMIT_STACKMAP=1 CRYSTAL_STACKMAP_PER_FUN=0 \
      "$CUS" build -Dgc_none --release -Dpreview_mt -Dexecution_context --frame-pointers=always \
      -o "$BIN" src/acikturkiye.cr
  ) >"$BASE_OUT/build-exclusive.log" 2>&1 || {
    echo FAIL; tail -30 "$BASE_OUT/build-exclusive.log"; exit 1
  }
  readelf -S "$BIN" | grep -q llvm_stackmaps && echo "  .llvm_stackmaps: yes" || echo "  .llvm_stackmaps: NO"
fi
[[ -x "$BIN" ]] || { echo "missing $BIN"; exit 1; }

printf "mode\tmax_atomic_MiB\tcollision_MiB\tmutator_atomic\tparked_atomic\tprecise_atomic\theap_atomic\tlive_MiB\n" \
  >"$BASE_OUT/ab.tsv"

for mode in $MODES; do
  echo "=== PRECISE_MODE=$mode ==="
  out="$BASE_OUT/mode-$mode"
  mkdir -p "$out"
  ACIK_BIN_DIR="$(dirname "$BIN")" \
  ACIK_LIVE_ATTR_OUT="$out" BIN_VARIANT=exclusive SKIP_BUILD=1 \
    PRECISE_MODE="$mode" TRIALS=1 WRK_DURATION="$DURATION" REQUIRE_2XX=1 \
    bash "$ROOT/bench/acik_live_attr.sh" 2>&1 | tee "$out/harness.log" | tail -40

  attr="$out/live-attr-t1.json"
  [[ -f "$attr" ]] || { echo "missing $attr"; continue; }
  python3 - "$attr" "$mode" "$BASE_OUT/ab.tsv" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); mode=sys.argv[2]; tsv=sys.argv[3]
def mib(x): return x/1024/1024
mx=a.get("max_size_class") or {}
row=[
  mode,
  f"{mib(mx.get('atomic_bytes',0)):.1f}",
  f"{mib(a.get('collision_bytes',0)):.1f}",
  f"{mib(a.get('first_mark_stack_atomic_bytes',0)):.1f}",
  f"{mib(a.get('first_mark_parked_atomic_bytes',0)):.1f}",
  f"{mib(a.get('first_mark_precise_atomic_bytes',0)):.1f}",
  f"{mib(a.get('first_mark_heap_atomic_bytes',0)):.1f}",
  f"{mib(a['total_bytes']):.1f}",
]
open(tsv,"a").write("\t".join(row)+"\n")
print("ROW", "\t".join(row))
PY
done

echo "=== A/B table ==="
column -t -s $'\t' "$BASE_OUT/ab.tsv" 2>/dev/null || cat "$BASE_OUT/ab.tsv"
echo "OUT=$BASE_OUT"
