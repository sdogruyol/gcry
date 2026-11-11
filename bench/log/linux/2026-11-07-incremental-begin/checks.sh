#!/usr/bin/env bash
# The branch's checks, one heavy step at a time under the shared lock.
cd /home/naruto/playground/.scratch/IncBegin/wt
L=/home/naruto/playground/.scratch/heavy.lock
rm -rf lib/ameba bin/ameba
/home/naruto/playground/.scratch/verify.sh .
run() { echo "=== $*"; flock "$L" "$@" 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"; }
run make windows-typecheck
run make darwin-typecheck
run make alloc-entry-frame
C=$HOME/.local/share/mise/installs/crystal/1.22.2/bin
run env PATH="$C:$PATH" crystal spec -Dgc_none process_spec
echo "=== stress loops, scale 0.5"
flock "$L" bench/stress_overnight.sh --only='pattern-fuzz-(nursery|incremental)-mprotect|claim-stress.*' \
  . ../stress-out 0.5 2>&1 | tail -30
echo "exit=${PIPESTATUS[0]}"
echo CHECKS-DONE
