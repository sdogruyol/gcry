#!/usr/bin/env bash
# loop.sh with every CPU busy: one spinning shell per CPU, each under a
# timeout so none can outlive the run, all killed when the loop ends.
# usage: loaded.sh <runs> <outfile> <loop.sh specs>...
set -u
here=$(dirname "$0")
hogs=()
for ((c = 0; c < $(nproc); c++)); do
  timeout 900 bash -c 'while :; do :; done' &
  hogs+=($!)
done
"$here/loop.sh" "$@"
kill "${hogs[@]}" 2>/dev/null
wait "${hogs[@]}" 2>/dev/null
true
