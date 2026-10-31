#!/usr/bin/env bash
# stats.sh OUT N BENCH BIN...: N runs of each counter binary, GCSTATS line + rusage (minflt, maxrss, user, sys).
S=/home/naruto/playground/.scratch/RevcompHost
out=$1 n=$2 bench=$3; shift 3
flock /home/naruto/playground/.scratch/heavy.lock bash -c '
out=$1 n=$2 bench=$3; shift 3
for i in $(seq $n); do for b in "$@"; do
  line=$(/usr/bin/time -f "TIME wall=%e user=%U sys=%S minflt=%R majflt=%F maxrss=%M ctxv=%w ctxi=%c" "'$S'/bins/$b" $bench 2>&1 | grep -E "^($bench:|GCSTATS|TIME)" | tr "\n" " ")
  echo "$b $i $line"
done; done' _ "$out" "$n" "$bench" "$@" >> "$S/$out"
