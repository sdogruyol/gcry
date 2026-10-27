#!/usr/bin/env bash
# The Darwin CI step `TLAB_NURSERY_RUNS=30 TLAB_ONLY_RUNS=10 make
# tlab-nursery-sample`, repeated: each "step" is that target's 40 runs — 30
# `--nursery --iterations=50` with seeds 1..30, then 10 `--iterations=200`
# (TLAB only) with seeds 1..10, all `--tlab --workers=2,4`, under the target's
# environment, each bounded by `bench/run_bounded.sh` at 120 s with a `sample`
# capture of a stall. Only the bookkeeping differs: every run's exit code and
# wall time go to runs.csv, and a log is kept when the run failed, stalled, was
# classified as the upstream scheduler deadlock, passed without a TLAB hit, or
# printed a watchdog line.
#
#   probe_loop.sh <binary> <steps> <outdir> <tag>
#
# RUN_BOUNDED (default bench/run_bounded.sh) is the bounded runner;
# MAX_STALLS (30) stops the loop early so a stalling build cannot eat the job.
# Plain bash 3.2: this runs under macOS's /bin/bash.
bin="$1"; steps="$2"; out="$3"; tag="$4"
runner="${RUN_BOUNDED:-bench/run_bounded.sh}"
limit="${TLAB_SAMPLE_LIMIT:-120}"
max_stalls="${MAX_STALLS:-30}"
mkdir -p "$out"
csv="$out/runs.csv"
echo "tag,step,arm,seed,rc,secs" > "$csv"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

n=0; pass=0; fail=0; stalled=0; upstream=0; unengaged=0; watchdog=0
s=0
while [ "$s" -lt "$steps" ]; do
  s=$((s + 1))
  i=0
  while [ "$i" -lt 40 ]; do
    i=$((i + 1))
    if [ "$i" -le 30 ]; then arm=tlab-nursery; flags="--nursery --iterations=50"; seed=$i
    else arm=tlab-only; flags="--iterations=200"; seed=$((i - 30)); fi
    log="$out/$arm-s$s-$seed.log"
    t0=$(now)
    GCRY_BITMAP_ALLOC=0 GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 GCRY_STW_WATCHDOG_MS=10000 \
      "$runner" "$limit" "$log" -- "$bin" --tlab $flags --seed=$seed --workers=2,4
    rc=$?
    t1=$(now)
    n=$((n + 1))
    keep=0
    case "$rc" in
      0) if grep -qE "tlab_hits=[1-9]" "$log"; then pass=$((pass + 1)); else unengaged=$((unengaged + 1)); keep=1; fi ;;
      2) stalled=$((stalled + 1)); keep=1 ;;
      3) upstream=$((upstream + 1)); keep=1 ;;
      *) fail=$((fail + 1)); keep=1 ;;
    esac
    if grep -q "STOP-THE-WORLD STALLED" "$log"; then watchdog=$((watchdog + 1)); keep=1; fi
    [ "$keep" = 0 ] && rm -f "$log"
    echo "$tag,$s,$arm,$seed,$rc,$(perl -e "printf '%.3f', $t1 - $t0")" >> "$csv"
    [ "$rc" != 0 ] && echo "$tag step $s $arm seed $seed: rc=$rc"
    if [ $((stalled + upstream)) -ge "$max_stalls" ]; then
      echo "$tag: $max_stalls stalls, stopping early"
      s="$steps"
      break
    fi
  done
done

line="$tag: runs=$n pass=$pass failed=$fail stalled=$stalled upstream=$upstream unengaged=$unengaged watchdog_lines=$watchdog"
echo "$line" | tee "$out/summary.txt"
# Wall time per arm, to show a run near the bound would have been seen.
python3 - "$csv" <<'EOF' | tee -a "$out/summary.txt"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
for arm in ("tlab-nursery", "tlab-only"):
    t = sorted(float(r["secs"]) for r in rows if r["arm"] == arm and r["rc"] == "0")
    if not t:
        continue
    q = lambda p: t[min(len(t) - 1, int(p * len(t)))]
    print(f"  {arm}: n={len(t)} p50={q(0.5):.2f}s p99={q(0.99):.2f}s max={t[-1]:.2f}s")
EOF
exit 0
