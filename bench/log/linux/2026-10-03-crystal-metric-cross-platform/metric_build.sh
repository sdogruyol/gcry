#!/bin/bash
# Build crystal-metric twice from the same source: Boehm, and gcry as process GC.
set -e
cc=${CRYSTAL:-crystal}
cd bench/crystal_metric
rm -rf lib && mkdir -p lib/gcry && cp -r ../../src lib/gcry/src
"$cc" build --release main.cr -o ../../bin/cm-boehm.exe
"$cc" build -Dgc_none --release main.cr -o ../../bin/cm-gcry.exe
ls -la ../../bin/cm-*
