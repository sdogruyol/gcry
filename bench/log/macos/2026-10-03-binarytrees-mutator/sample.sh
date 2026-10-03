#!/bin/bash
set -e
cd bench/crystal_metric
rm -rf lib && mkdir -p lib/gcry && cp -r ../../src lib/gcry/src
crystal build --release main.cr -o ../../bin/boehm
crystal build -Dgc_none --release main.cr -o ../../bin/gcry
cd ../..
for arm in gcry boehm; do
  for i in 1; do
    (bin/$arm Binarytrees > /tmp/$arm-$i.out 2>&1) &
    pid=$!
    sleep 0.05
    sample $pid 2 1 -mayDie -file /tmp/$arm-$i.sample > /dev/null 2>&1 || true
    wait $pid || true
    echo "=== $arm run $i: $(grep -oE 'in [0-9.]+s' /tmp/$arm-$i.out | tail -1)"
    awk '/Sort by top of stack/{p=1} p' /tmp/$arm-$i.sample | head -24
    echo "--- call graph, nodes >= 15 samples"
    awk '/^Call graph:/{p=1} /^Total number in stack/{p=0} p' /tmp/$arm-$i.sample | awk '{ if (match($0, /[0-9]+ /)) { n=substr($0, RSTART, RLENGTH)+0; if (n >= 15) print } }' | cut -c1-170 | head -90
  done
done
