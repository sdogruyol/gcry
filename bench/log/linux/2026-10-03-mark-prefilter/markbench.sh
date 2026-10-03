#!/bin/bash
# $1 = binary; prints min over 3 runs of total mark ms and wall s, per bench
bin=$1
for b in Primes JsonParsePure Binarytrees; do
  best_mark=999999; best_wall=999
  for i in 1 2 3; do
    GCRY_TRACE=1 GCRY_TRACE_ALLOC_SAMPLE=0 GCRY_TRACE_FILE=/tmp/mb.ndjson $bin $b > /tmp/mb.out 2>&1
    m=$(python3 -c "
import json
print(sum(json.loads(l)['mark_ns'] for l in open('/tmp/mb.ndjson') if 'collect_end' in l)//1000000)")
    w=$(grep -oE "in [0-9.]+s" /tmp/mb.out | tail -1 | grep -oE "[0-9.]+")
    [ "$m" -lt "$best_mark" ] && best_mark=$m
    best_wall=$(python3 -c "print(min($best_wall, $w))")
  done
  echo "$b mark_ms=$best_mark wall_s=$best_wall"
done
