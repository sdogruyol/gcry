#!/bin/sh
# usage: build.sh <main.cr> <out> <crystal-version> [flags...]
main=$1; out=$2; v=$3; shift 3
C=$HOME/.local/share/mise/installs/crystal/$v/bin/crystal
cd /home/naruto/playground/.scratch/Reg21c && flock /home/naruto/playground/.scratch/heavy.lock $C build -Dgc_none -Dgcry_block_headers "$@" $main -o bin/$out
