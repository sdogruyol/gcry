#!/bin/sh
# Interleaved batch: GCRY_THREAD_LIST_TRIPWIRE on/off, same binary, same load.
# One iteration = 2 on-arm + 2 off-arm children running concurrently.
set -u
BIN=bin/dfr_tlw
OUT=bench/log/linux/2026-08-27-thread-list-tripwire/raw
ITER=${1:-80}
mkdir -p "$OUT"
i=0
while [ "$i" -lt "$ITER" ]; do
  for spec in on:a on:b off:a off:b; do
    arm=${spec%%:*}; tag=${spec##*:}
    (
      f="$OUT/$arm-$i-$tag.log"
      if [ "$arm" = on ]; then tlw=1; else tlw=0; fi
      GCRY_MOSTLY_EMPTY=1 GCRY_UNMAP_GUARD=1 GCRY_SEGV_REPORT=1 \
      GCRY_THREAD_LIST_TRIPWIRE=$tlw \
        timeout 120 "$BIN" --child >"$f" 2>&1
      echo "exit=$?" >>"$f"
    ) &
  done
  wait
  i=$((i + 1))
done
echo done
