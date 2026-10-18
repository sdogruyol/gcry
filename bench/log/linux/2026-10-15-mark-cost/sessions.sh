#!/usr/bin/env bash
set -x
cd /home/naruto/playground/.scratch/MarkCost
./build.sh deferB
./build.sh mask
./build.sh sbatch
./build.sh rtag
python3 wt/bench/log/linux/2026-10-15-mark-cost/boehmmark.py 7 Primes,JsonParsePure,JsonGenerate,Binarytrees bin/cm-boehm 1 > logs/boehm1.txt 2>&1
B=bin/cm-
python3 wt/bench/log/linux/2026-10-15-mark-cost/marksum.py 7 Primes,JsonParsePure,JsonGenerate,Binarytrees logs/s1-raw.json \
  base1=${B}base:GCRY_PARALLEL_MARK=1 deferB1=${B}deferB:GCRY_PARALLEL_MARK=1 mask1=${B}mask:GCRY_PARALLEL_MARK=1 sbatch1=${B}sbatch:GCRY_PARALLEL_MARK=1 rtag1=${B}rtag:GCRY_PARALLEL_MARK=1 \
  basedef=${B}base deferBdef=${B}deferB maskdef=${B}mask rtagdef=${B}rtag > logs/s1.txt 2> logs/s1.err
for b in Binarytrees Primes JsonParsePure JsonGenerate; do
  GCRY_PARALLEL_MARK=1 GCRY_TRACE=1 GCRY_TRACE_FILE=logs/trace1-$b.ndjson GCRY_TRACE_ALLOC_SAMPLE=0 taskset -c 0-3 bin/cm-base $b > /dev/null
  GCRY_TRACE=1 GCRY_TRACE_FILE=logs/tracedef-$b.ndjson GCRY_TRACE_ALLOC_SAMPLE=0 taskset -c 0-3 bin/cm-base $b > /dev/null
done
#!/usr/bin/env bash
set -x
cd /home/naruto/playground/.scratch/MarkCost
for a in sb64 sb1024 sbrt; do ./build.sh $a; done
GC_MARKERS=1 GC_PRINT_STATS=1 taskset -c 0-3 bin/cm-boehm Primes > logs/boehm-stats-Primes.txt 2>&1
B=bin/cm-
python3 wt/bench/log/linux/2026-10-15-mark-cost/marksum.py 7 Primes,JsonParsePure,JsonGenerate,Binarytrees logs/s2-raw.json \
  boehm1=${B}boehm:GC_MARKERS=1 \
  base1=${B}base:GCRY_PARALLEL_MARK=1 sb64_1=${B}sb64:GCRY_PARALLEL_MARK=1 sbatch1=${B}sbatch:GCRY_PARALLEL_MARK=1 sb1024_1=${B}sb1024:GCRY_PARALLEL_MARK=1 \
  rtag1=${B}rtag:GCRY_PARALLEL_MARK=1 sbrt1=${B}sbrt:GCRY_PARALLEL_MARK=1 \
  basedef=${B}base rtagdef=${B}rtag sbrtdef=${B}sbrt > logs/s2.txt 2> logs/s2.err
#!/usr/bin/env bash
set -x
cd /home/naruto/playground/.scratch/MarkCost
for a in sbprod sbprod4k pb1024; do ./build.sh $a; done
MAIN=$PWD/main_stack.cr ./build.sh base
MAIN=$PWD/main_stack.cr ./build.sh sbprod
B=bin/cm-
python3 wt/bench/log/linux/2026-10-15-mark-cost/marksum.py 7 Primes,JsonParsePure,JsonGenerate,Binarytrees logs/s3-raw.json \
  boehm1=${B}boehm:GC_MARKERS=1 \
  base1=${B}base:GCRY_PARALLEL_MARK=1 sbprod1=${B}sbprod:GCRY_PARALLEL_MARK=1 sbprod4k_1=${B}sbprod4k:GCRY_PARALLEL_MARK=1 \
  basedef=${B}base sbproddef=${B}sbprod pb1024def=${B}pb1024 > logs/s3.txt 2> logs/s3.err
for b in Primes JsonParsePure JsonGenerate Binarytrees; do
  for a in base sbprod; do
    echo "$b $a serial $(GCRY_PARALLEL_MARK=1 taskset -c 0-3 bin/cm-$a-main_stack $b 2>&1 >/dev/null | grep MARKSTACK)"
    echo "$b $a default $(taskset -c 0-3 bin/cm-$a-main_stack $b 2>&1 >/dev/null | grep MARKSTACK)"
  done
done > logs/s3-markstack.txt
./cg.sh base base Primes > logs/cg-base-Primes.log 2>&1
./cg.sh sbprod sbprod Primes > logs/cg-sbprod-Primes.log 2>&1
./build.sh rtagprod
MAIN=$PWD/main_shadow.cr ./build.sh rtagshadow
ALL="Pidigits Binarytrees Brainfuck Brainfuck2 Fannkuchredux Fasta Knuckeotide Mandelbrot Matmul Nbody RegexDna Revcomp Spectralnorm Threadring Base64Encode Base64Decode Primes JsonGenerate JsonParsePure JsonParseSerializable JsonParsePull Mandelbrot2 Noise Sudoku TextRaytracer NeuralNet"
for b in $ALL; do
  echo "$b serial $(GCRY_PARALLEL_MARK=1 taskset -c 0-3 bin/cm-rtagshadow-main_shadow $b 2>&1 >/dev/null | grep SHADOW)"
  echo "$b default $(taskset -c 0-3 bin/cm-rtagshadow-main_shadow $b 2>&1 >/dev/null | grep SHADOW)"
done > logs/s4-shadow.txt
for a in rtagprod rtagred1 rtagred2; do
  (cd arms/$a && taskset -c 0-3 crystal spec -Dgc_none spec/chunk_radix_spec.cr > ../../logs/s4-spec-$a.txt 2>&1; echo "exit $?" >> ../../logs/s4-spec-$a.txt)
done
B=bin/cm-
python3 wt/bench/log/linux/2026-10-15-mark-cost/marksum.py 7 Primes,JsonParsePure,JsonGenerate,Binarytrees logs/s4-raw.json \
  boehm1=${B}boehm:GC_MARKERS=1 \
  sbprod1=${B}sbprod:GCRY_PARALLEL_MARK=1 rtagprod1=${B}rtagprod:GCRY_PARALLEL_MARK=1 \
  sbproddef=${B}sbprod rtagproddef=${B}rtagprod > logs/s4.txt 2> logs/s4.err
./prof.sh sbprod sbprod1 3 Primes,JsonParsePure,JsonGenerate GCRY_PARALLEL_MARK=1
./prof.sh rtagprod rtagprod1 3 Primes,JsonParsePure,JsonGenerate GCRY_PARALLEL_MARK=1
./prof.sh rtagprod rtagproddef 3 Primes,JsonParsePure,JsonGenerate
cd /home/naruto/playground/.scratch/MarkCost/wt
for g in "crystal spec -Dgc_none spec/all_specs.cr" "crystal spec -Dgc_none process_spec" "make lint" "make windows-typecheck" "make mark-audit" "make parallel-mark-process" "make parallel-mark-termination"; do
  n=$(echo "$g" | tr ' /' '__' | cut -c1-60)
  taskset -c 0-3 $g > ../logs/gate-$n.txt 2>&1; echo "exit $?" >> ../logs/gate-$n.txt
done
#!/usr/bin/env bash
set -x
cd /home/naruto/playground/.scratch/MarkCost
./build.sh b37b
B=bin/cm-
python3 wt/bench/log/linux/2026-10-15-mark-cost/marksum.py 7 Primes,JsonParsePure,JsonGenerate,Binarytrees logs/s5-raw.json \
  boehm1=${B}boehm:GC_MARKERS=1 base1=${B}base:GCRY_PARALLEL_MARK=1 batch1=${B}b37b:GCRY_PARALLEL_MARK=1 \
  basedef=${B}base batchdef=${B}b37b > logs/s5.txt 2> logs/s5.err
cd wt
run() { n=$1; shift; taskset -c 0-3 env "$@" > ../logs/g5-$n.txt 2>&1; echo "exit $?" >> ../logs/g5-$n.txt; }
run spec crystal spec -Dgc_none spec/all_specs.cr
run spec-headers crystal spec -Dgc_none -Dgcry_block_headers spec/all_specs.cr
run process crystal spec -Dgc_none process_spec
run process-headers-freelist GCRY_BITMAP_ALLOC=0 crystal spec -Dgc_none -Dgcry_block_headers process_spec
run lint make lint
run windows-typecheck make windows-typecheck
run mark-audit make mark-audit
run parallel-mark-process make parallel-mark-process
run parallel-mark-termination make parallel-mark-termination
run darwin-typecheck crystal build --no-codegen -Dgc_none --cross-compile --target aarch64-apple-darwin samples/hello.cr
