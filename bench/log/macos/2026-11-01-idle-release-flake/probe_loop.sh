#!/usr/bin/env bash
# `make idle-release`'s green arm, round-robin over builds (arms) and two
# shapes until a wall-clock budget runs out, to measure how often its release
# check fails per arm on the same runner:
#
#   plain  one run at a time, as `make idle-release` runs it
#   load   three at once on the runner's three cores
#
#   probe_loop.sh <arms> <minutes> <outdir> <tag>
#
# <arms> is `name=binary[,name=binary...]`; a binary may be a wrapper script
# that sets the arm's environment. Every run is bounded by
# `bench/run_bounded.sh` (60 s). Its exit code, wall time and the harness's
# DIAG / IDLEGC lines go to runs.csv; the log of every run that did not exit 0
# is kept whole. Plain bash 3.2: this runs under macOS's /bin/bash.
arms="$1"; minutes="$2"; out="$3"; tag="$4"
runner="${RUN_BOUNDED:-bench/run_bounded.sh}"
mkdir -p "$out"
csv="$out/runs.csv"
echo "tag,round,arm,variant,proc,rc,secs,kept,reread,slept_ms,idle_start_ms,idle_reclaim_end_ms,idle_end_ms,idle_collections,collections,after_world,release" > "$csv"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
deadline=$(( $(date +%s) + minutes * 60 ))

field() { # <line> <key>
  echo "$1" | tr ' ' '\n' | grep "^$2=" | head -1 | cut -d= -f2
}

one_run() { # <arm> <binary> <variant> <round> <proc>
  arm="$1"; bin="$2"; name="$3"; round="$4"; p="$5"
  log="$out/$arm-$name-r$round-p$p.log"
  t0=$(now)
  GCRY_IDLE_RELEASE_MS=50 "$runner" 60 "$log" -- "$bin"
  rc=$?
  t1=$(now)
  d=$(grep -m1 '^DIAG kept=' "$log")
  r=$(grep -m1 '^DIAG read ' "$log")
  rr=$(grep -m1 '^DIAG reread ' "$log")
  g=$(grep -m1 '^IDLEGC ' "$log")
  kept=$(field "$d" kept)
  reread=$(field "$rr" kept)
  slept=$(field "$d" slept_ms)
  is=$(field "$g" start_ms); ire=$(field "$g" reclaim_end_ms); ie=$(field "$g" end_ms)
  idle=$(field "$r" idle); cols=$(field "$r" collections)
  aw=$(field "$r" after_world); rel=$(field "$r" release)
  echo "$tag,$round,$arm,$name,$p,$rc,$(perl -e "printf '%.3f', $t1 - $t0"),$kept,$reread,$slept,$is,$ire,$ie,$idle,$cols,$aw,$rel" > "$out/.row-$p"
  if [ "$rc" != 0 ]; then
    echo "$tag round $round $arm $name p$p: rc=$rc kept=$kept reread=$reread idle_start=$is idle_end=$ie slept=$slept"
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
    kept = sum(1 for r in rs if r["kept"] not in ("", "0"))
    print(f"  {arm} {v}: runs={len(rs)} rc={dict(sorted(rc.items()))} kept_nonzero={kept}")
EOF
exit 0
