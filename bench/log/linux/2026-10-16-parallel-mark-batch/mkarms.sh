#!/usr/bin/env bash
# mkarms.sh <base-rev> <impl.patch> <arm>...: source snapshots under arms/.
#
#   base         <base-rev> as it is (pop batch of 256 on each marker's stack)
#   pb<N>        base + impl.patch (mapped per-shard batches) with
#                MARK_POP_BATCH = N; parked markers woken per N held
#   pb<N>w<W>    the same, woken per W held instead of per N
#
# Each arm's diff against base is written to arms/<arm>.diff.
set -euo pipefail
S=/home/naruto/playground/.scratch/ParallelMarkBatch
base=$1 patch=$(realpath "$2"); shift 2
for arm in "$@"; do
  d=$S/arms/$arm
  rm -rf "$d" && mkdir -p "$d"
  git -C $S/wt archive "$base" src bench/crystal_metric shard.yml | tar -x -C "$d"
  if [[ $arm =~ ^pb([0-9]+)(w([0-9]+))?$ ]]; then
    n=${BASH_REMATCH[1]} w=${BASH_REMATCH[3]}
    (cd "$d" && patch -s -p1 < "$patch")
    f=$d/src/gcry/parallel_mark.cr
    sed -i "s/^    MARK_POP_BATCH = 1024\$/    MARK_POP_BATCH = $n/" "$f"
    grep -q "^    MARK_POP_BATCH = $n\$" "$f"
    if [[ -n $w ]]; then
      sed -i "s|wake_parked_markers(depth // MARK_POP_BATCH) if depth > MARK_POP_BATCH|wake_parked_markers(depth // $w) if depth > $w|" "$f"
      grep -q "wake_parked_markers(depth // $w) if depth > $w" "$f"
    fi
  elif [[ $arm != base ]]; then
    echo "unknown arm $arm" >&2; exit 1
  fi
  (cd $S/arms && diff -ru base/src "$arm/src" > "$arm.diff" || true)
  echo "arm $arm"
done
