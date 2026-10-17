#!/usr/bin/env bash
# Phase analysis of FINDINGS §4. Cross-compiles every build's crystal-metric
# for x86_64-pc-windows-msvc here (the object link.exe gets on the runner),
# then asks, per runner CPU, which functions' placement is consistent with how
# fast each build ran, and intersects the CPUs. X is scratch space; RUNS holds
# the downloaded artifacts (`gh run download <id> -D $RUNS/<id>`); the
# commit-by-commit A/B comes from ../2026-10-15-0.36-native/bisect/. Run from
# the repository root.
set -euo pipefail
X=${X:-/home/naruto/playground/.scratch/WindowsRevcomp}
RUNS=${RUNS:-$X/runs}
D=bench/log/windows/2026-10-16-revcomp-attribution
B=bench/log/windows/2026-10-15-0.36-native/bisect
L=/home/naruto/playground/.scratch/heavy.lock
export CRYSTAL_CACHE_DIR=$X/cache
# `link64` is the probe-win-revcomp-link64 branch: v0.36.0 plus link64.diff
# (LARGE_LINK_BYTES = 64).
for v in v0.35.0 123069c3 bfe05bd3 0a0e3165 f2f25ea2 135495f5 b1cdc0ed 49788b15 v0.36.0 4fcee559 link64; do
  b=$X/xb-$v
  [ -f "$b/m.obj" ] && continue
  rm -rf "$b" && mkdir -p "$b/lib/gcry" && cp -r bench/crystal_metric/. "$b/"
  if [ "$v" = link64 ]; then
    git archive v0.36.0 src | tar -x -C "$b/lib/gcry"
    patch -s -d "$b/lib/gcry" -p1 < $D/scripts/link64.diff
  else
    git archive "$v" src | tar -x -C "$b/lib/gcry"
  fi
  (cd "$b" && flock $L crystal build -Dgc_none --release --cross-compile --target x86_64-pc-windows-msvc main.cr -o m > /dev/null)
done
ob() { echo "$X/xb-$1/m.obj"; }
mkdir -p $D/phase
{
  echo "# Offsets of the timed path's functions in each cross-compiled object"
  python3 $D/scripts/obj_phase.py '^\*Gcry::Heap#malloc_atomic<UInt64>|^\*Gcry::Heap#allocate:atomic|^GC_malloc_atomic$|^\*String#tr<String, String>|^\*IO::Memory#write<Slice|^\*IO::Memory@IO#write_string' \
    $(for v in v0.35.0 123069c3 bfe05bd3 0a0e3165 f2f25ea2 135495f5 b1cdc0ed 49788b15 v0.36.0 4fcee559 link64; do printf '%s=%s ' "$v" "$(ob $v)"; done)
} > $D/phase/obj-phases.txt

# arms RUNS_JSON FAST MID BASE_SRC VAR_SRC [MAPS_DIR]: one argument per arm,
# LABEL=CLASS=OBJ[=MAP], classed by its median Revcomp timed section (< FAST
# fast, < MID mid, else slow). `base` is BASE_SRC's code, every other arm
# VAR_SRC's; with MAPS_DIR, where each landed comes from the runner's map.
arms() {
  python3 - "$@" << 'EOF'
import json, statistics, sys
runs, fast, mid, base, var = sys.argv[1:6]
maps = sys.argv[6] if len(sys.argv) > 6 else None
R = json.load(open(runs))
for a in R["arms"]:
    t = statistics.median(r["time"] for r in R["runs"] if r["arm"] == a and r["bench"] == "Revcomp" and r["time"])
    c = "fast" if t < float(fast) else "mid" if t < float(mid) else "slow"
    src = base if a == "base" else var
    print(f"{runs.split('/')[-3]}:{a}={c}=" + src + (f"={maps}/ab-{a}.txt" if maps else ""))
EOF
}
art() { echo "$RUNS/$1/perf-ab-windows-latest"; }
# Commit-by-commit A/B runs: base is the commit, var v0.36.0, no maps.
bis() { arms "$B/$1-runs.json" "$2" "$3" "$(ob $1)" "$(ob v0.36.0)"; }
# Classes per CPU: EPYC 7763 fast < 1.33 s <= mid < 1.38 s <= slow (v0.35.0's
# placements have a middle level); EPYC 9V74 fast < 1.12 s; Xeon 8370C < 1.35 s.
mapfile -t e7763 < <(
  arms "$(art 38895043370)/runs.json" 1.33 1.38 "$(ob v0.35.0)" "$(ob v0.36.0)" "$(art 38895043370)/syms"
  arms "$(art 38895050587)/runs.json" 1.33 1.38 "$(ob v0.35.0)" "$(ob v0.36.0)" "$(art 38895050587)/syms"
  arms "$(art 38895057939)/runs.json" 1.33 1.38 "$(ob v0.36.0)" "$(ob v0.35.0)" "$(art 38895057939)/syms"
  arms "$(art 38901844942)/runs.json" 1.33 1.38 "$(ob v0.36.0)" "$(ob 4fcee559)" "$(art 38901844942)/syms"
  echo "38890076811:tip=fast=$(ob 4fcee559)"
  echo "38890076811:v0.36.0=slow=$(ob v0.36.0)"
  for c in 123069c3 0a0e3165 f2f25ea2 135495f5; do bis $c 1.33 1.38; done
)
mapfile -t e9v74 < <(
  for c in bfe05bd3 b1cdc0ed; do bis $c 1.12 1.12; done
  arms "$(art 38890224933)/runs.json" 1.12 1.12 "$(ob v0.36.0)" "$(ob link64)"
)
mapfile -t x8370 < <(arms "$(art 38901835522)/runs.json" 1.35 1.35 "$(ob v0.36.0)" "$(ob 4fcee559)" "$(art 38901835522)/syms")
rm -f $X/consistent.txt
python3 $D/scripts/phase_consistency.py 64 --both $X/consistent.txt "${e7763[@]}" > $D/phase/epyc7763.txt
python3 $D/scripts/phase_consistency.py 64 --both $X/consistent.txt "${e9v74[@]}" > $D/phase/epyc9v74.txt
python3 $D/scripts/phase_consistency.py 64 --both $X/consistent.txt "${x8370[@]}" > $D/phase/xeon8370c.txt
python3 $D/scripts/phase_fit.py 64 "$(art 38895043370)" "$(art 38895050587)" "$(art 38895057939)" | head -4 > $D/phase/fit-r2.txt
