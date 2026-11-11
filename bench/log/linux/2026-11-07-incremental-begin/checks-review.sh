#!/usr/bin/env bash
# After the review fixes: children loops, machine-code comparison, checks.
cd /home/naruto/playground/.scratch/IncBegin/wt
L=/home/naruto/playground/.scratch/heavy.lock
D=bench/log/linux/2026-11-07-incremental-begin
B=/home/naruto/playground/.scratch/IncBegin/bin
cp $D/quick-entry.cr quick-entry.cr
flock $L crystal build -Dgc_none quick-entry.cr -o $B/quick-hl
flock $L crystal build -Dgc_none -Dgcry_block_headers quick-entry.cr -o $B/quick-hd
rm -f quick-entry.cr
{
  echo "## headerless 1.21 unpinned"; flock $L $D/child_loop.sh $B/quick-hl 100 0
  echo "## headerless 1.21 pinned"; flock $L $D/child_loop.sh $B/quick-hl 100 1
  echo "## headers GCRY_BITMAP_ALLOC=0 unpinned"; GCRY_BITMAP_ALLOC=0 flock $L $D/child_loop.sh $B/quick-hd 100 0
  echo "## headers GCRY_BITMAP_ALLOC=0 pinned"; GCRY_BITMAP_ALLOC=0 flock $L $D/child_loop.sh $B/quick-hd 100 1
} > $D/rates-review.txt 2>&1
flock $L $D/loaded_loop.sh $B/quick-hd 500 > $D/rates-review-loaded.txt 2>&1
flock $L crystal build -Dgc_none --release --no-debug bench/churn.cr -o $B/churn-wt2
python3 $D/mc_diff.py $B/churn-base $B/churn-wt2 > $D/mc_diff_review.txt
rm -rf lib/ameba bin/ameba
/home/naruto/playground/.scratch/verify.sh .
run() { echo "=== $*"; flock "$L" "$@" 2>&1 | tail -4; echo "exit=${PIPESTATUS[0]}"; }
run make windows-typecheck
run make darwin-typecheck
run make alloc-entry-frame
C=$HOME/.local/share/mise/installs/crystal/1.22.2/bin
run env PATH="$C:$PATH" crystal spec -Dgc_none process_spec
echo CHECKS-DONE
