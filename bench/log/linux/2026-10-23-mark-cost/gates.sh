#!/usr/bin/env bash
# gates.sh <tree> <outdir>: the gates, one per hold of the heavy lock, each
# through bench/run_bounded.sh; "exit N" appended to each log.
set -u
tree=$1 out=$2
mkdir -p "$out"
L=/home/naruto/playground/.scratch/heavy.lock
cd "$tree" || exit 1
mkdir -p bin
run() {
  local n=$1 limit=$2; shift 2
  flock "$L" bench/run_bounded.sh "$limit" "$out/$n.txt" -- "$@" >> "$out/$n.txt" 2>&1
  echo "exit $?" >> "$out/$n.txt"
  echo "$n $(tail -1 "$out/$n.txt")"
}
run format 600 crystal tool format --check src spec process_spec bench samples
run lint 1200 make lint
run spec 3000 crystal spec -Dgc_none spec/all_specs.cr
run spec-headers 3000 crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr
run process 3600 crystal spec -Dgc_none process_spec
run process-headers 3600 crystal spec -Dgc_none -Dgcry_block_headers process_spec
run process-headers-freelist 3600 env GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
run alloc-entry-frame 1800 make alloc-entry-frame
run windows-typecheck 1200 make windows-typecheck
run darwin-typecheck 1200 crystal build --no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin samples/hello.cr -o "$out/hello-darwin"
run mark-audit 1200 make mark-audit
run parallel-mark-termination 1800 make parallel-mark-termination
run parallel-mark-stress 2400 make parallel-mark-stress
run parallel-mark-process 1800 make parallel-mark-process
run chunk-list-drift 2400 make chunk-list-drift
