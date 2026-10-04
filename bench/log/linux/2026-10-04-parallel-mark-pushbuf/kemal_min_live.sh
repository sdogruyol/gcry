#!/bin/bash
set -u
mkdir -p bin
for round in 1 2; do
  for arm in "pm1:GCRY_PARALLEL_MARK=1" "pm4:GCRY_PARALLEL_MARK=4" "pm4min:GCRY_PARALLEL_MARK=4 GCRY_PARALLEL_MARK_MIN_LIVE=33554432"; do
    name=${arm%%:*}; envs=${arm#*:}
    echo "=== round $round $name"
    env $envs PORT=3011 WRK_DURATION=5 WRK_CONNECTIONS=50 BENCH_RUNS=5 \
      MIN_PCT=0 MAX_RSS_X=100 MAX_PAUSE_P50_MS=1000 RUNNER_LABEL=probe PERF_GATE_BASELINE=0 \
      ./bench/perf_smoke.sh 2>&1 | grep -E "^\s+/json thr, %|^\s+/ thr, %|pause p50, ms" | tail -3
  done
done
