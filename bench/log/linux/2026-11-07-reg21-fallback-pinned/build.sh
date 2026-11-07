#!/bin/sh
# usage: build.sh <main.cr> <out> [flags...]   (Crystal 1.22.2, headerless)
main=$1; out=$2; shift 2
C=$HOME/.local/share/mise/installs/crystal/1.22.2/bin/crystal
cd /home/naruto/playground/.scratch/Reg21d && flock /home/naruto/playground/.scratch/heavy.lock $C build -Dgc_none "$@" $main -o bin/$out
