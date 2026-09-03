#!/usr/bin/env bash
# Q1/Q2 batch. 4 arms per round, Latin square over 4 absolute positions,
# with within-pair order balanced 2/2 for every pair of interest.
set -u
SP="$1"; OUT="$2"; ROUNDS="${3:-32}"
BIN="$SP/gc_phases"
ARGS="--seconds=3 --live=200000 --survival=0.05,0.25"

env_for() {
  case "$1" in
    O1|O2) echo "" ;;
    R)     echo "GCRY_CHUNK_RADIX=1" ;;
    T)     echo "GCRY_CHUNK_RADIX=1 GCRY_RADIX_THP=1" ;;
  esac
}

# Latin square: each arm visits each position once per 4 rounds;
# every pair of interest is ordered 2/2 across the block.
SQ=("O1 R O2 T" "T O2 R O1" "R O1 T O2" "O2 T O1 R")

: > "$OUT"
for ((r=0; r<ROUNDS; r++)); do
  read -r -a slots <<< "${SQ[$((r % 4))]}"
  for ((p=0; p<4; p++)); do
    arm="${slots[$p]}"
    e="$(env_for "$arm")"
    # shellcheck disable=SC2086
    env $e "$BIN" $ARGS 2>/dev/null | \
      awk -v r="$r" -v p="$((p+1))" -v a="$arm" '/"survival"/{print "{\"round\":" r ",\"pos\":" p ",\"arm\":\"" a "\"," substr($0,2)}' >> "$OUT"
  done
  echo "round $r done ($(date +%H:%M:%S))" >&2
done
