#!/usr/bin/env bash
# rates.sh OUTDIR N WORKERS BIN...  — interleaved runs of the DORMANT_ALL arm
# (2026-11-03-parked-seed/rates.sh, plus the thread count and the live MB the
# last collect measured, and the whole output, stderr too, of any run that
# fails or seeds more than 64 KiB as parked).
set -u
out=$1; n=$2; workers=$3; shift 3
mkdir -p "$out"
worker() {
  local w=$1; shift
  local i=$w
  while [ "$i" -lt "$n" ]; do
    for b in "$@"; do
      name=$(basename "$b")
      o=$(GCRY_PARALLEL_DORMANT_ALL=1 timeout 120 "$b" --ordinary --expect-dormant 2>&1); rc=$?
      parked=$(printf '%s\n' "$o" | grep -o 'parked [0-9]* KiB' | tail -1 | grep -o '[0-9]*')
      threads=$(printf '%s\n' "$o" | grep -o 'threads=[0-9]*' | tail -1 | grep -o '[0-9]*')
      echo "$name $i $rc ${parked:-NA} ${threads:-NA}" >> "$out/w$w.tsv"
      if [ "$rc" != 0 ] || [ "${parked:-0}" -gt 64 ] || printf '%s\n' "$o" | grep -q 'DBG big'; then
        printf '%s\n' "$o" > "$out/fail_${name}_$i.txt"
      fi
    done
    i=$((i + workers))
  done
}
for w in $(seq 0 $((workers - 1))); do worker "$w" "$@" & done
wait
cat "$out"/w*.tsv | awk '{runs[$1]++; if ($3!=0) fail[$1]++; if ($4!="NA" && $4>64) big[$1]++} END {for (b in runs) printf "%s runs=%d fail=%d parked>64KiB=%d\n", b, runs[b], fail[b]+0, big[b]+0}' | sort > "$out/summary.txt"
cat "$out/summary.txt"
