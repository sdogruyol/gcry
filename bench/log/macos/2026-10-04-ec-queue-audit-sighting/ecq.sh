#!/bin/bash
set -u
mkdir -p bin
crystal build -Dgc_none bench/ec_queue_audit.cr -o bin/ec_queue_audit --error-trace || exit 1
fails=0
for i in $(seq 400); do
  GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1 bin/ec_queue_audit > /tmp/ecq.log 2>&1 &
  pid=$!; t=0
  while kill -0 $pid 2>/dev/null && [ $t -lt 240 ]; do sleep 1; t=$((t + 1)); done
  if kill -0 $pid 2>/dev/null; then kill -9 $pid; echo "ECQ run $i HUNG"; fails=$((fails + 1)); continue; fi
  wait $pid; rc=$?
  if [ $rc -ne 0 ]; then
    fails=$((fails + 1)); echo "ECQ run $i rc=$rc"
    grep -E "Thread|type_id|SIGSEGV|Invalid memory|FAIL|thread list|poison" /tmp/ecq.log | head -25 | sed 's/^/ECQ   /'
  fi
done
echo "ECQ summary: 400 runs, $fails failed"
