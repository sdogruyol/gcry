#!/bin/bash
set -u
mkdir -p bin
for round in 1 2; do
  for pm in 1 4; do
    echo "=== round $round GCRY_PARALLEL_MARK=$pm"
    GCRY_PARALLEL_MARK=$pm PORT=3011 WRK_DURATION=5 WRK_CONNECTIONS=50 BENCH_RUNS=5 \
      MIN_PCT=0 MAX_RSS_X=100 MAX_PAUSE_P50_MS=1000 RUNNER_LABEL=probe PERF_GATE_BASELINE=0 \
      ./bench/perf_smoke.sh 2>&1 | grep -iE "% of boehm|thr|rss|pause|median" | grep -v "^\s*#" | tail -12
  done
done
