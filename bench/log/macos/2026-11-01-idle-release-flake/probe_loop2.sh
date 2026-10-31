#!/usr/bin/env bash
# Round 2: the shipped `bench/idle_release.cr` (no probe harness), green arm,
# round-robin over builds and the same two shapes as probe_loop.sh:
#
#   plain  one run at a time, as `make idle-release` runs it
#   load   three at once on the runner's three cores
#
#   probe_loop2.sh <arms> <minutes> <outdir> <tag>
#
# Every run is bounded by `bench/run_bounded.sh` (60 s); its exit code, wall
# time, what the gate printed for the last gap and the release check, and its
# first FAIL line go to runs.csv. The log of every run that did not exit 0 is
# kept. Plain bash 3.2: this runs under macOS's /bin/bash.
arms="$1"; minutes="$2"; out="$3"; tag="$4"
runner="${RUN_BOUNDED:-bench/run_bounded.sh}"
mkdir -p "$out"
csv="$out/runs.csv"
echo "tag,round,arm,variant,proc,rc,secs,kept,last_gap_read_ms,idle,collections,fail" > "$csv"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
deadline=$(( $(date +%s) + minutes * 60 ))

one_run() { # <arm> <binary> <variant> <round> <proc>
  arm="$1"; bin="$2"; name="$3"; round="$4"; p="$5"
  log="$out/$arm-$name-r$round-p$p.log"
  t0=$(now)
  GCRY_IDLE_RELEASE_MS=50 "$runner" 60 "$log" -- "$bin"
  rc=$?
  t1=$(now)
  kept=$(sed -n 's/^  empty chunks left mapped by the last collection \([0-9-]*\).*/\1/p' "$log" | head -1)
  lg=$(sed -n 's/.*read \([0-9.]*\) ms after the burst.*/\1/p' "$log" | head -1)
  idle=$(sed -n 's/^  idle collections \([0-9]*\) of \([0-9]*\).*/\1/p' "$log" | head -1)
  cols=$(sed -n 's/^  idle collections \([0-9]*\) of \([0-9]*\).*/\2/p' "$log" | head -1)
  fl=$(grep -m1 '^FAIL' "$log" | tr ',' ';' | cut -c1-120)
  echo "$tag,$round,$arm,$name,$p,$rc,$(perl -e "printf '%.3f', $t1 - $t0"),$kept,$lg,$idle,$cols,$fl" > "$out/.row-$p"
  if [ "$rc" != 0 ]; then
    echo "$tag round $round $arm $name p$p: rc=$rc kept=$kept last_gap=$lg $fl"
  else
    rm -f "$log"
  fi
  return 0
}

round=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  round=$((round + 1))
  for variant in plain load; do
    par=1; [ "$variant" = load ] && par=3
    for spec in $(echo "$arms" | tr ',' ' '); do
      [ "$(date +%s)" -ge "$deadline" ] && break 2
      arm="${spec%%=*}"; bin="${spec#*=}"
      p=0
      while [ "$p" -lt "$par" ]; do
        p=$((p + 1))
        one_run "$arm" "$bin" "$variant" "$round" "$p" < /dev/null &
      done
      wait
      p=0
      while [ "$p" -lt "$par" ]; do
        p=$((p + 1))
        cat "$out/.row-$p" >> "$csv"
        rm -f "$out/.row-$p"
      done
    done
  done
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
    lg = sorted(float(r["last_gap_read_ms"]) for r in rs if r["last_gap_read_ms"])
    tail = f" last-gap read p50={lg[len(lg) // 2]:.1f} max={lg[-1]:.1f} ms, over 205 ms: {sum(1 for x in lg if x > 205.0)}" if lg else ""
    print(f"  {arm} {v}: runs={len(rs)} rc={dict(sorted(rc.items()))}{tail}")
EOF
exit 0
