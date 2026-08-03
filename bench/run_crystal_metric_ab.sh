#!/usr/bin/env bash
# Same-host Boehm vs gcry A/B for vendored crystal-metric.
#
# Each bench runs in a **fresh process** (no suite-order heap pollution).
# JsonParsePure / Primes looked ~20× / ~8× in a shared process after
# JsonGenerate; alone they are closer to ~5× / investigate separately.
#
# Usage:
#   bash bench/run_crystal_metric_ab.sh
#   TRIALS=1 FILTER=core bash bench/run_crystal_metric_ab.sh
#   FILTER=stress TRIALS=1 bash bench/run_crystal_metric_ab.sh
#   FILTER=Binarytrees,Threadring TRIALS=1 bash bench/run_crystal_metric_ab.sh
#   FILTER=all TRIALS=1 bash bench/run_crystal_metric_ab.sh
#
# Output: bench/log/<linux|macos>/<stamp>/
#
# Gates: none (informational). Product bar remains Kemal /json + acikturkiye.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
CM="$ROOT/bench/crystal_metric"
TRIALS="${TRIALS:-3}"

# core: stable GC-shape signals (process-fresh).
FILTER_CORE="Binarytrees,Brainfuck,Brainfuck2,Knuckeotide,RegexDna,Revcomp,Threadring,Matmul,JsonGenerate,JsonParseSerializable,JsonParsePull"
# stress: alloc-storm / JSON::Any — honest only when process-fresh.
FILTER_STRESS="Primes,JsonParsePure"
FILTER_GC="${FILTER_CORE},${FILTER_STRESS}"
# Full language suite (includes compute-bound noise).
FILTER_ALL="Pidigits,Binarytrees,Brainfuck,Brainfuck2,Fannkuchredux,Fasta,Knuckeotide,Mandelbrot,Matmul,Nbody,RegexDna,Revcomp,Spectralnorm,Threadring,Base64Encode,Base64Decode,Primes,JsonGenerate,JsonParsePure,JsonParseSerializable,JsonParsePull,Mandelbrot2,Noise,Sudoku,TextRaytracer,NeuralNet"

FILTER_ARG="${FILTER:-gc}"
case "$FILTER_ARG" in
  core)   FILTER="$FILTER_CORE" ;;
  stress) FILTER="$FILTER_STRESS" ;;
  gc)     FILTER="$FILTER_GC" ;;
  all)    FILTER="$FILTER_ALL" ;;
  *)      FILTER="$FILTER_ARG" ;;
esac

# Split comma list → benches array (no empty entries).
IFS=',' read -r -a BENCHES <<<"$FILTER"
BENCHES=("${BENCHES[@]// /}")

PLATFORM="linux"
case "$(uname -s)" in
  Darwin) PLATFORM="macos" ;;
esac

RUN_LABEL="${LABEL:-$(date -u +%Y-%m-%d-%H%M%S)-crystal-metric}"
RUN_DIR="$ROOT/bench/log/$PLATFORM/$RUN_LABEL"
mkdir -p "$BIN" "$RUN_DIR"

command -v python3 >/dev/null || { echo "ERROR: python3 not found"; exit 1; }
command -v crystal >/dev/null || { echo "ERROR: crystal not found"; exit 1; }

if ! [[ "$TRIALS" =~ ^[1-9][0-9]*$ ]]; then
  echo "TRIALS must be a positive integer (got: $TRIALS)" >&2
  exit 1
fi
if [[ "${#BENCHES[@]}" -eq 0 ]]; then
  echo "ERROR: empty FILTER" >&2
  exit 1
fi

cd "$CM"
shards install --production 2>/dev/null || shards install

echo "Building crystal-metric-boehm..."
crystal build --release main.cr -o "$BIN/crystal-metric-boehm"
echo "Building crystal-metric-gcry..."
crystal build -Dgc_none --release main.cr -o "$BIN/crystal-metric-gcry"

HAVE_GNU_TIME=0
if command -v /usr/bin/time >/dev/null 2>&1 && /usr/bin/time -v true >/dev/null 2>&1; then
  HAVE_GNU_TIME=1
fi

# One bench, one process. Writes stdout log + optional .time (GNU time -v).
run_bench() {
  local bin="$1" label="$2" bench="$3" trial="$4"
  local out="$RUN_DIR/${label}-${bench}-trial-${trial}.log"
  local rc=0
  set +e
  if [[ "$HAVE_GNU_TIME" -eq 1 ]]; then
    /usr/bin/time -v "$bin" "$bench" >"$out" 2>"${out}.time"
    rc=$?
  else
    "$bin" "$bench" >"$out" 2>&1
    rc=$?
    : >"${out}.time"
  fi
  set -e
  if ! grep -qE "^${bench}:.*(ok|err|FAIL).* in [0-9.]+s" "$out"; then
    echo "FAIL: $label $bench trial $trial produced no bench line (exit $rc)" >&2
    cat "$out" >&2 || true
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "  note: $label $bench trial $trial exit=$rc (checksum drift OK for timing)" >&2
  fi
}

echo ""
echo "=== crystal-metric A/B (process-fresh, trials=$TRIALS, filter=$FILTER_ARG) ==="
echo "  benches: ${BENCHES[*]}"
echo "  log: $RUN_DIR"

for t in $(seq 1 "$TRIALS"); do
  for bench in "${BENCHES[@]}"; do
    [[ -n "$bench" ]] || continue
    echo "  trial $t / $TRIALS — boehm $bench"
    run_bench "$BIN/crystal-metric-boehm" boehm "$bench" "$t"
    echo "  trial $t / $TRIALS — gcry $bench"
    run_bench "$BIN/crystal-metric-gcry" gcry "$bench" "$t"
  done
done

python3 - "$RUN_DIR" "$TRIALS" "$FILTER_ARG" "$PLATFORM" "${BENCHES[@]}" <<'PY'
import json, re, sys, statistics
from pathlib import Path

run_dir = Path(sys.argv[1])
trials = int(sys.argv[2])
filt = sys.argv[3]
platform = sys.argv[4]
benches = sys.argv[5:]

line_re = re.compile(
    r"^(?P<name>[A-Za-z0-9_]+):\s+(?P<status>ok|err|FAIL).*?\bin\s+(?P<secs>[0-9.]+)s",
    re.I | re.M,
)
rss_re = re.compile(r"Maximum resident set size \(kbytes\):\s+(\d+)")

def parse_log(path: Path):
    text = path.read_text(errors="replace")
    secs = None
    status = None
    for m in line_re.finditer(text):
        secs = float(m.group("secs"))
        status = m.group("status").lower()
    rss_kib = None
    tpath = Path(str(path) + ".time")
    if tpath.exists():
        tm = rss_re.search(tpath.read_text(errors="replace"))
        if tm:
            rss_kib = int(tm.group(1))
    return secs, status, rss_kib

def median(xs):
    return statistics.median(xs) if xs else None

rows = []
boehm_rss_all = []
gcry_rss_all = []

for name in benches:
    b_secs, g_secs = [], []
    b_rss, g_rss = [], []
    for t in range(1, trials + 1):
        bs, bst, br = parse_log(run_dir / f"boehm-{name}-trial-{t}.log")
        gs, gst, gr = parse_log(run_dir / f"gcry-{name}-trial-{t}.log")
        if bs is not None:
            b_secs.append(bs)
        if gs is not None:
            g_secs.append(gs)
        if br is not None:
            b_rss.append(br)
            boehm_rss_all.append(br)
        if gr is not None:
            g_rss.append(gr)
            gcry_rss_all.append(gr)
    bm = median(b_secs)
    gm = median(g_secs)
    speed_pct = (bm / gm * 100.0) if (bm and gm and gm > 0) else None
    rows.append({
        "bench": name,
        "boehm_s_med": round(bm, 4) if bm is not None else None,
        "gcry_s_med": round(gm, 4) if gm is not None else None,
        "gcry_speed_pct_of_boehm": round(speed_pct, 1) if speed_pct is not None else None,
        "gcry_wall_x": round(gm / bm, 3) if (bm and gm and bm > 0) else None,
        "boehm_peak_rss_kib_med": int(median(b_rss)) if b_rss else None,
        "gcry_peak_rss_kib_med": int(median(g_rss)) if g_rss else None,
        "peak_rss_x": round(median(g_rss) / median(b_rss), 3) if b_rss and g_rss else None,
    })

# Suite peak RSS × = median of per-bench peak medians (process-fresh).
def med_of(field):
    xs = [r[field] for r in rows if r[field] is not None]
    return median(xs)

rss_x = None
br = med_of("boehm_peak_rss_kib_med")
gr = med_of("gcry_peak_rss_kib_med")
if br and gr and br > 0:
    rss_x = round(gr / br, 3)

summary = {
    "suite": "crystal-metric",
    "role": "secondary_gc",
    "mode": "process_fresh",
    "platform": platform,
    "trials": trials,
    "filter": filt,
    "benches": rows,
    "boehm_peak_rss_kib_med": int(br) if br is not None else None,
    "gcry_peak_rss_kib_med": int(gr) if gr is not None else None,
    "peak_rss_x": rss_x,
    "note": (
        "Informational only. Product bar remains Kemal /json + acikturkiye. "
        "Each bench is a fresh process (no suite-order pollution). "
        "speed_pct>100 means gcry faster (less wall)."
    ),
}

(run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

lines = [
    "# crystal-metric Boehm vs gcry (secondary, process-fresh)",
    "",
    f"- platform: `{platform}`",
    f"- mode: **process-fresh** (one OS process per bench × GC)",
    f"- trials: {trials} (median wall)",
    f"- filter: `{filt}`",
    f"- role: **secondary GC suite** — not a ship headline",
    "",
    "| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × | RSS × |",
    "|-------|-------------:|-------------:|-------------:|-------:|------:|",
]
for r in rows:
    rx = r["peak_rss_x"] if r["peak_rss_x"] is not None else "n/a"
    lines.append(
        f"| {r['bench']} | {r['boehm_s_med']} | {r['gcry_s_med']} | "
        f"{r['gcry_speed_pct_of_boehm']} | {r['gcry_wall_x']} | {rx} |"
    )
lines += [
    "",
    f"Peak RSS × (median of per-bench peaks): **{rss_x if rss_x is not None else 'n/a'}**",
    "",
    "speed % = Boehm_s / gcry_s × 100 (>100 ⇒ gcry fewer wall seconds).",
    "",
]
(run_dir / "summary.md").write_text("\n".join(lines))

print("\n".join(lines))
print(f"wrote {run_dir / 'summary.json'}")
print(f"wrote {run_dir / 'summary.md'}")
PY

echo ""
echo "=== Result ==="
echo "PASS (informational A/B; no gate)"
