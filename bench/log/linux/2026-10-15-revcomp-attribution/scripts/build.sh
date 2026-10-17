#!/usr/bin/env bash
set -euo pipefail
S=/home/naruto/playground/.scratch/RevcompCounters
export CRYSTAL_CACHE_DIR=$S/cache
for c in "$@"; do
  cd $S/builds/$c
  echo "== $c $(date +%T)"
  crystal build -Dgc_none --release main.cr -o $S/bin/cm-$c
done
echo DONE
