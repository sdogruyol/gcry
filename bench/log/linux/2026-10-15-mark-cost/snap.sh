#!/usr/bin/env bash
# snap.sh <name> [rev]: snapshot the worktree (working tree if no rev) into arms/<name>.
set -euo pipefail
S=/home/naruto/playground/.scratch/MarkCost
name=$1 rev=${2:-}
rm -rf "$S/arms/$name" && mkdir -p "$S/arms/$name"
cd $S/wt
if [[ -n $rev ]]; then
  git archive "$rev" src bench/crystal_metric shard.yml | tar -x -C "$S/arms/$name"
else
  cp -r src shard.yml "$S/arms/$name/" && mkdir -p "$S/arms/$name/bench" && cp -r bench/crystal_metric "$S/arms/$name/bench/"
fi
echo snap $name
