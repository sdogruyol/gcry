#!/usr/bin/env bash
# One gcry probe binary under environment knobs, interleaved: peak RSS
# (VmHWM at exit, from the probe's last event row) and the number of
# collections, REPS times per arm in a fresh random order each rep.
#
#   knobs.sh BIN REPS OUT.tsv [ARM ...]
# ARM is "name:K=V K=V" (empty after the colon: no extra environment); the
# default list below is the first sweep's.
set -euo pipefail
bin=$1 reps=$2 out=$3
shift 3
if [ $# -gt 0 ]; then
  arms=("$@")
else
  arms=(
    "default:"
    "pace100:GCRY_THRESHOLD_PACE=100"
    "thr8:GCRY_THRESHOLD=8388608"
    "factor50:GCRY_THRESHOLD_FACTOR=50"
    "nolargecache:GCRY_LARGE_CACHE=0"
    "nooomreserve:GCRY_OOM_RESERVE_KB=0"
    "nowarm:GCRY_EMPTY_CHUNK_WARM_RETAIN=0"
    "noparallel:GCRY_DISABLE_PARALLEL_MARK=1"
    "noslack:GCRY_ATOMIC_SLACK=0"
    "pace100_noslack:GCRY_THRESHOLD_PACE=100 GCRY_ATOMIC_SLACK=0"
  )
fi
echo -e "rep\tarm\thwm_kb\tcollections\trun_s" >"$out"
for r in $(seq 1 "$reps"); do
  while IFS= read -r a; do
    name=${a%%:*} envs=${a#*:}
    log=$(mktemp -p "$(dirname "$out")")
    # shellcheck disable=SC2086 # envs is a space-separated K=V list
    env $envs "$bin" 2>"$log" >/dev/null || true
    hwm=$(grep '^ev' "$log" | tail -1 | cut -f5)
    coll=$(grep '^ev' "$log" | tail -1 | cut -f8)
    run=$(grep -o 'run_s=[0-9.]*' "$log" | cut -d= -f2)
    echo -e "$r\t$name\t$hwm\t$coll\t$run" >>"$out"
    rm -f "$log"
  done < <(printf '%s\n' "${arms[@]}" | shuf)
done
