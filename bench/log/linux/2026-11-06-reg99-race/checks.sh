#!/usr/bin/env bash
cd /home/naruto/playground/.scratch/Reg99Race/wt
L=/home/naruto/playground/.scratch/heavy.lock
rm -rf lib/ameba bin/ameba
/home/naruto/playground/.scratch/verify.sh .
run() { echo "=== $*"; flock "$L" "$@" 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"; }
run make windows-typecheck
run make darwin-typecheck
run make alloc-entry-frame
C=$HOME/.local/share/mise/installs/crystal/1.22.2/bin
run env PATH="$C:$PATH" crystal spec -Dgc_none process_spec
echo CHECKS-DONE
