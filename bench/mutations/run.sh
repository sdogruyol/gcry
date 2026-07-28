#!/usr/bin/env bash
# Apply hand-crafted mutants, run a short kill suite, restore sources.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SCORE="$ROOT/bench/mutations/SCORE.log"
mkdir -p "$(dirname "$SCORE")"
: >"$SCORE"

kill_suite() {
  # Include invariant-enabled specs + dump/trace so related mutants die.
  GCRY_DEBUG_INVARIANTS=1 crystal spec \
    spec/heap_spec.cr spec/collect_spec.cr spec/invariant_spec.cr spec/trace_dump_spec.cr \
    --error-trace >/tmp/mut-out.txt 2>&1
}

apply_sed() {
  local expr="$1" src="$2" dst="$3"
  sed -e "$expr" "$src" >"$dst"
}

run_one() {
  local id="$1"
  local file="$2"
  local expr="$3"
  local desc="$4"
  local target="$ROOT/$file"
  local bak="${target}.mutbak"

  cp "$target" "$bak"
  apply_sed "$expr" "$bak" "$target"

  # Detect no-op sed (file unchanged) → treat as harness error / SURVIVED.
  if cmp -s "$bak" "$target"; then
    echo "$id NOOP $file :: sed did not match — $desc" | tee -a "$SCORE"
    mv "$bak" "$target"
    return
  fi

  local status="SURVIVED"
  set +e
  kill_suite
  local ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    status="KILLED"
  fi
  echo "$id $status $file :: $desc" | tee -a "$SCORE"
  mv "$bak" "$target"
}

filter="${1:-}"

while IFS='|' read -r id file expr desc; do
  [[ -z "${id:-}" || "$id" =~ ^# ]] && continue
  if [[ -n "$filter" && "$id" != "$filter" ]]; then
    continue
  fi
  echo "== mutant $id: $desc =="
  run_one "$id" "$file" "$expr" "$desc"
done <<'EOF'
01|src/gcry/heap.cr|s/@live_objects -= 1 if @live_objects > 0/# MUT01 skip live_objects dec/|skip live_objects decrement on free
02|src/gcry/heap.cr|s/raise ArgumentError.new("double free") if BlockHeader.free?(header)/# MUT02 allow double free/|disable double-free check
03|src/gcry/invariant.cr|s/return if actual == reported/return if actual != reported/|invert live_objects equality check
04|src/gcry/heap_dump.cr|s/count += 1/count += 0/g|heap dump undercounts all objects
05|src/gcry/trace.cr|s/@@enabled = true/@@enabled = false # MUT05/|Trace.enable is a no-op
06|src/gcry/size_classes.cr|s/when  1 then 32_u32/when  1 then 24_u32/|corrupt size-class index 1 payload
07|src/gcry/block.cr|s/FREE   = 1_u32/FREE   = 0_u32/|FREE flag bit cleared
08|src/gcry/collect.cr|s/@collections += 1/@collections += 0/g|collections counter never increments
09|src/gcry/roots.cr|s/word = sizeof(Void\*).to_u64/word = 1_u64/|root scan stride is 1 byte
10|src/gcry/heap.cr|s/raise OutOfMemoryError.new("mmap failed") if Gcry.mmap_failed?(ptr)/# MUT10 ignore mmap fail/|ignore mmap failure
EOF

killed=$(grep -c ' KILLED ' "$SCORE" || true)
noop=$(grep -c ' NOOP ' "$SCORE" || true)
survived=$(grep -c ' SURVIVED ' "$SCORE" || true)
total=$((killed + survived + noop))
echo
echo "kill_rate=${killed}/${total} (survived=${survived} noop=${noop}) — see $SCORE"
test "$total" -gt 0
