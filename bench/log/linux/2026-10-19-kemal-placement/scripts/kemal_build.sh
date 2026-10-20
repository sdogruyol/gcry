#!/usr/bin/env bash
# kemal_build.sh REV OUT: the Kemal server as bench/runner_ab/ab.sh's `kbuild`
# builds it on the runners, with gcry's `src/` taken from REV, into OUT (and
# `nm -n` of it into OUT.nm). PAD=N puts N bytes of nops ahead of
# `server.cr`'s code (the runners' `padN` arm); HEAPPAD=1 applies probe
# 5a379e02 (a 472 KiB `StaticArray` back in the `Heap`). With kemal 1.15.0
# and Crystal 1.21.0 the addresses match the runners' binaries to the byte.
# Run from the repository; needs `shards install` done in bench/kemal. Run
# under the host's heavy lock.
set -euo pipefail
rev=$1 out=$(realpath -m "$2")
repo=$(git rev-parse --show-toplevel)
tmp=$(mktemp -d "${TMPDIR:-$repo/..}/kemal-build.XXXXXX")
k=$tmp/kemal
mkdir -p "$tmp/performance" && cp -r "$repo/bench/kemal" "$k"
cp "$repo/bench/performance/header_policy.cr" "$tmp/performance/"
rm -rf "$k/lib/gcry" && mkdir -p "$k/lib/gcry" && git -C "$repo" archive "$rev" src | tar -x -C "$k/lib/gcry"
if [ -n "${HEAPPAD:-}" ]; then git -C "$repo" show 5a379e02 -- src | (cd "$k/lib/gcry" && patch -p1); fi
if [ -n "${PAD:-}" ]; then
  # shellcheck disable=SC2016
  { printf '@[NoInline]\ndef __placement_pad\n  asm(".skip %d, 0x90" :::: "volatile")\nend\n\n__placement_pad\n\n' "$PAD"
    cat "$k/src/server.cr"; } > "$k/src/server.tmp" && mv "$k/src/server.tmp" "$k/src/server.cr"
fi
(cd "$k" && crystal build -Dgc_none --release src/server.cr -o "$out")
nm -n "$out" > "$out.nm"
rm -rf "$tmp"
