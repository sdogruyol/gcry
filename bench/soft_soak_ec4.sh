#!/usr/bin/env bash
# EC4 Kemal soft soak — Parallel TLAB-off + lazy correctness gate.
#
# Campaign bar: soft+hard == 0 over N trials (`wrk -c100 -d8 /json`).
# Soft: mark-miss / realloc class (`pointer is not a gcry allocation`, …).
# Hard: SEGV / abort / server dead mid-trial.
#
# Usage:
#   ./bench/soft_soak_ec4.sh              # N=40 local gate
#   SOFT_SOAK_N=5 ./bench/soft_soak_ec4.sh   # CI smoke
#   make soft-soak-ec4
#   make soft-soak-ec4-smoke
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
KEMAL="$ROOT/bench/kemal"
N="${SOFT_SOAK_N:-40}"
DURATION="${SOFT_SOAK_DURATION:-8}"
CONNECTIONS="${WRK_CONNECTIONS:-100}"
PORT_BASE="${SOFT_SOAK_PORT:-3230}"
EC="${EC_PARALLELISM:-4}"
OUT="${SOFT_SOAK_OUT:-/tmp/gcry-soft-soak-ec4}"

command -v wrk >/dev/null || { echo "ERROR: wrk not found"; exit 1; }
command -v curl >/dev/null || { echo "ERROR: curl not found"; exit 1; }

if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
  echo "SOFT_SOAK_N must be a positive integer (got: $N)" >&2
  exit 1
fi

mkdir -p "$BIN" "$OUT"
rm -f "$OUT/trials.tsv" "$OUT/summary.txt"

cd "$KEMAL"
shards install --production 2>/dev/null || shards install
echo "Building kemal-gcry (EC${EC} soft soak)..."
crystal build -Dgc_none --release src/server.cr -o "$BIN/kemal-gcry-soft-soak"

echo -e "n\tresult\treq_s\tsoft\thard\talive\tnote" >"$OUT/trials.tsv"

ok=0
fail=0
soft_total=0
hard_total=0

classify_log() {
  local log="$1"
  soft=0
  hard=0
  note=""
  if grep -qE 'Segmentation fault|SIGSEGV|Invalid memory access|Aborted|Aborted \(core dumped\)' "$log" 2>/dev/null; then
    hard=1
    note="SEGV"
  fi
  if grep -qE 'pointer is not a gcry allocation|not a gcry allocation|Invalid memory access|MARK_MISS' "$log" 2>/dev/null; then
    # Count as soft unless already hard SEGV.
    if [[ "$hard" -eq 0 ]]; then
      soft=1
      note="MARK_MISS"
    fi
  fi
}

for i in $(seq 1 "$N"); do
  port=$((PORT_BASE + (i % 50)))
  srv_log="$OUT/run-${i}.log"
  wrk_log="$OUT/wrk-${i}.txt"
  rm -f "$srv_log" "$wrk_log"

  EC_PARALLELISM="$EC" PORT="$port" "$BIN/kemal-gcry-soft-soak" >"$srv_log" 2>&1 &
  spid=$!
  alive=1
  result="OK"
  req_s="0"
  soft=0
  hard=0
  note=""

  ready=0
  for _ in $(seq 1 80); do
    if curl -sf -o /dev/null "http://127.0.0.1:${port}/"; then
      ready=1
      break
    fi
    if ! kill -0 "$spid" 2>/dev/null; then
      break
    fi
    sleep 0.25
  done

  if [[ "$ready" -ne 1 ]]; then
    alive=0
    hard=1
    result="FAIL"
    note="boot"
    classify_log "$srv_log"
    [[ "$hard" -eq 0 ]] && hard=1
  else
    set +e
    wrk -c "$CONNECTIONS" -d "$DURATION" "http://127.0.0.1:${port}/json" >"$wrk_log" 2>&1
    wrk_rc=$?
    set -e
    req_s=$(awk '/Requests\/sec:/ {print $2}' "$wrk_log" | tail -1)
    req_s=${req_s:-0}

    if ! kill -0 "$spid" 2>/dev/null; then
      alive=0
      hard=1
      result="FAIL"
      note="dead"
    fi
    classify_log "$srv_log"
    if [[ "$wrk_rc" -ne 0 && "$hard" -eq 0 && "$soft" -eq 0 ]]; then
      # wrk fail with live server often means server died mid-run
      if ! kill -0 "$spid" 2>/dev/null; then
        alive=0
        hard=1
        result="FAIL"
        note="dead"
      fi
    fi
    if [[ "$soft" -ne 0 || "$hard" -ne 0 ]]; then
      result="FAIL"
    fi
    # Empty / near-zero thr with soft errors
    if awk -v r="$req_s" 'BEGIN { exit !(r+0 < 1000) }'; then
      if [[ "$result" == "OK" ]]; then
        result="FAIL"
        soft=1
        note="thr_cliff"
      fi
    fi
  fi

  kill "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  # free port
  sleep 0.1

  soft_total=$((soft_total + soft))
  hard_total=$((hard_total + hard))
  if [[ "$result" == "OK" ]]; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$i" "$result" "$req_s" "$soft" "$hard" "$alive" "$note" >>"$OUT/trials.tsv"
  echo "  trial $i/$N $result req/s=$req_s soft=$soft hard=$hard alive=$alive $note"
done

{
  echo "process OK ${ok}/${N} fail=${fail} soft=${soft_total} hard=${hard_total}"
  if [[ "$ok" -gt 0 ]]; then
    awk -F'\t' 'NR>1 && $2=="OK" {print $3}' "$OUT/trials.tsv" \
      | sort -n \
      | awk -v n="$ok" '
          { a[NR]=$1 }
          END {
            if (NR==0) exit
            mid = int((NR+1)/2)
            if (NR%2==0) m=(a[mid]+a[mid+1])/2; else m=a[mid]
            printf "OK thr med=%.2f (n=%d)\n", m, NR
          }'
  fi
} | tee "$OUT/summary.txt"

if [[ "$soft_total" -ne 0 || "$hard_total" -ne 0 || "$fail" -ne 0 ]]; then
  echo "FAIL: soft-soak EC${EC} soft=${soft_total} hard=${hard_total} fail=${fail}" >&2
  exit 1
fi

echo "PASS: soft-soak EC${EC} ${ok}/${N} soft=0 hard=0"
exit 0
