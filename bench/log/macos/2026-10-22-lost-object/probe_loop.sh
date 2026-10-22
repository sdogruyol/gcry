#!/usr/bin/env bash
# The `tlab-nursery-sample` tlab-only harness, round-robin over builds (arms)
# and shapes (variants) until a wall-clock budget runs out, to measure how
# often a pinned object is found DEAD (the 2026-10-21 `d1549e2f` sighting) per
# arm and variant on the same runner. Every run is bounded by
# `bench/run_bounded.sh`, which captures a stall with `sample` and classifies
# Crystal's Parallel-scheduler deadlock as exit 3.
#
#   probe_loop.sh <arms> <variants-file> <minutes> <outdir> <tag>
#
# <arms> is `name=binary[,name=binary...]`. The variants file has one variant
# per line, `#` comments allowed:
#
#   name|parallel|bound_s|collects_per_run|harness args (SEED = the round's seed)
#
# Each round runs every variant on every arm, arms innermost, so the arms
# share the runner's state minute by minute. `parallel` runs that many
# processes of the variant at once (each its own bounded run), to
# oversubscribe the runner's three cores. SEED cycles 1..10 with the round,
# offset by 10 per extra process (runs.csv's seed column is that
# substitution; a variant that spells its own `--seed=` ignores it). Every
# run's exit code and wall time go to runs.csv. A log is kept when the run did
# not exit 0, passed without a TLAB hit, or printed DEAD / cookie broken / a
# watchdog line.
# Plain bash 3.2: this runs under macOS's /bin/bash.
arms="$1"; variants="$2"; minutes="$3"; out="$4"; tag="$5"
runner="${RUN_BOUNDED:-bench/run_bounded.sh}"
mkdir -p "$out"
csv="$out/runs.csv"
echo "tag,round,arm,variant,proc,seed,rc,secs,collects,lost,heap_collections" > "$csv"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
deadline=$(( $(date +%s) + minutes * 60 ))

one_run() { # <arm> <binary> <variant> <round> <proc> <seed> <bound> <collects> <args...>
  arm="$1"; bin="$2"; name="$3"; round="$4"; p="$5"; seed="$6"; bound="$7"; collects="$8"; shift 8
  log="$out/$arm-$name-r$round-p$p.log"
  t0=$(now)
  GCRY_BITMAP_ALLOC=0 GCRY_POISON_HOLDERS=1 GCRY_THREAD_CENSUS=1 GCRY_THREAD_BLOCK_AUDIT=1 GCRY_STW_WATCHDOG_MS=10000 \
    "$runner" "$bound" "$log" -- "$bin" "$@"
  rc=$?
  t1=$(now)
  lost=$(grep -cE "DEAD|cookie broken" "$log")
  # The instrumented harness prints the heap's own collection count per phase;
  # the shipped one prints nothing, and the column is then empty.
  hc=$(grep -oE "heap_collections=[0-9]+" "$log" | cut -d= -f2 | tr '\n' ' ' | sed 's/ $//')
  keep=0
  [ "$rc" != 0 ] && keep=1
  [ "$lost" != 0 ] && keep=1
  grep -q "STOP-THE-WORLD STALLED" "$log" && keep=1
  [ "$rc" = 0 ] && ! grep -qE "tlab_hits=[1-9]" "$log" && keep=1
  [ "$keep" = 0 ] && rm -f "$log"
  echo "$tag,$round,$arm,$name,$p,$seed,$rc,$(perl -e "printf '%.3f', $t1 - $t0"),$collects,$lost,$hc" > "$out/.row-$p"
  [ "$rc" != 0 ] && echo "$tag round $round $arm $name p$p seed $seed: rc=$rc lost=$lost"
  return 0
}

round=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  round=$((round + 1))
  while IFS='|' read -r name par bound collects args; do
    case "$name" in ''|\#*) continue ;; esac
    for spec in $(echo "$arms" | tr ',' ' '); do
      [ "$(date +%s)" -ge "$deadline" ] && break 2
      arm="${spec%%=*}"; bin="${spec#*=}"
      base_seed=$(( (round - 1) % 10 + 1 ))
      p=0
      while [ "$p" -lt "$par" ]; do
        p=$((p + 1))
        seed=$((base_seed + (p - 1) * 10))
        one_run "$arm" "$bin" "$name" "$round" "$p" "$seed" "$bound" "$collects" ${args//SEED/$seed} < /dev/null &
      done
      wait
      p=0
      while [ "$p" -lt "$par" ]; do
        p=$((p + 1))
        cat "$out/.row-$p" >> "$csv"
        rm -f "$out/.row-$p"
      done
    done
  done < "$variants"
done

python3 - "$csv" "$tag" <<'EOF' | tee "$out/summary.txt"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
print(f"{sys.argv[2]}: rounds={max((int(r['round']) for r in rows), default=0)} runs={len(rows)}")
keys = []
for r in rows:
    k = (r["arm"], r["variant"])
    if k not in keys:
        keys.append(k)
for arm, v in keys:
    rs = [r for r in rows if r["arm"] == arm and r["variant"] == v]
    rc = {}
    for r in rs:
        rc[r["rc"]] = rc.get(r["rc"], 0) + 1
    lost_runs = sum(1 for r in rs if int(r["lost"]) > 0)
    collects = sum(int(r["collects"]) for r in rs if r["rc"] in ("0", "1"))
    heap = [sum(int(x) for x in r["heap_collections"].split()) for r in rs
            if r["rc"] == "0" and r["heap_collections"]]
    extra = (sum(heap) - sum(int(r["collects"]) for r in rs if r["rc"] == "0" and r["heap_collections"])) if heap else None
    secs = sorted(float(r["secs"]) for r in rs if r["rc"] == "0")
    p50 = secs[len(secs) // 2] if secs else 0.0
    mx = secs[-1] if secs else 0.0
    print(f"  {arm} {v}: runs={len(rs)} rc={dict(sorted(rc.items()))} lost_runs={lost_runs} "
          f"collects~{collects} extra_heap_collections={extra} p50={p50:.2f}s max={mx:.2f}s")
EOF
exit 0
