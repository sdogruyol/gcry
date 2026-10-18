#!/usr/bin/env bash
# gates.sh <tag>: every gate this change can affect, on the worktree's
# checkout, each under the heavy lock and `taskset -c 0-3` (as in
# ../2026-10-15-mark-cost/). Output: logs/g-<tag>-<gate>.txt, ending in the
# exit status.
S=/home/naruto/playground/.scratch/ParallelMarkBatch
LOCK=/home/naruto/playground/.scratch/heavy.lock
tag=$1
cd $S/wt
run() {
  local n=$1; shift
  flock $LOCK taskset -c 0-3 env "$@" > ../logs/g-$tag-$n.txt 2>&1
  echo "exit $?" >> ../logs/g-$tag-$n.txt
  echo "$n $(tail -1 ../logs/g-$tag-$n.txt)"
}
run spec crystal spec -Dgc_none spec/all_specs.cr
run spec-headers crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr
run process crystal spec -Dgc_none process_spec
run process-headers-freelist GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
run parallel-mark-termination make parallel-mark-termination
run parallel-mark-process make parallel-mark-process
run mark-audit make mark-audit
run lint make lint
run windows-typecheck make windows-typecheck
run darwin-typecheck crystal build --no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin samples/hello.cr
