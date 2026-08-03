#!/usr/bin/env bash
# Same-host Boehm vs gcry A/B for vendored crystal-metric (GC-sensitive subset).
#
# Usage:
#   bash bench/run_crystal_metric_ab.sh
#   TRIALS=1 FILTER=Binarytrees,JsonParsePure,Threadring bash bench/run_crystal_metric_ab.sh
#   FILTER=all TRIALS=1 bash bench/run_crystal_metric_ab.sh   # full language suite
#
# Output: bench/log/<linux|macos>/<stamp>/crystal-metric-{summary.md,summary.json,*.log}
#
# Gates: none (informational). Product bar remains Kemal /json + acikturkiye.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin"
CM="$ROOT/bench/crystal_metric"
TRIALS="${TRIALS:-3}"
# Default = GC-sensitive subset from the suite plan.
DEFAULT_FILTER="Binarytrees,Brainfuck,Brainfuck2,Knuckeotide,RegexDna,Revcomp,Threadring,Matmul,Primes,JsonGenerate,JsonParsePure,JsonParseSerializable,JsonParsePull"
FILTER="${FILTER:-$DEFAULT_FILTER}"
if [[ "$FILTER" == "all" ]]; then
  FILTER=""
fi

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

cd "$CM"
shards install --production 2>/dev/null || shards install

echo "Building crystal-metric-boehm..."
crystal build --release main.cr -o "$BIN/crystal-metric-boehm"
echo "Building crystal-metric-gcry..."
crystal build -Dgc_none --release main.cr -o "$BIN/crystal-metric-gcry"

run_one() {
  local bin="$1" label="$2" trial="$3" out="$4"
  local args=()
  local rc=0
  if [[ -n "$FILTER" ]]; then
    args+=("$FILTER")
  fi
  # Prefer GNU time peak RSS when available; fall back to bare wall parse.
  # metric.cr exits 1 when any bench misses expected checksum — common on
  # Crystal ≥1.21 for Json*/string hashes. Wall times are still valid for GC A/B.
  set +e
  if command -v /usr/bin/time >/dev/null 2>&1 && /usr/bin/time -v true >/dev/null 2>&1; then
    /usr/bin/time -v "$bin" "${args[@]}" >"$out" 2>"${out}.time"
    rc=$?
  else
    "$bin" "${args[@]}" >"$out" 2>&1
    rc=$?
    : >"${out}.time"
  fi
  set -e
  if ! grep -qE '^[A-Za-z0-9_]+:.*(ok|err|FAIL).* in [0-9.]+s' "$out"; then
    echo "FAIL: $label trial $trial produced no bench lines (exit $rc)" >&2
    cat "$out" >&2 || true
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "  note: $label trial $trial exit=$rc (checksum drift OK for timing A/B)" >&2
  fi
}

echo ""
echo "=== crystal-metric A/B (trials=$TRIALS filter=${FILTER:-ALL}) ==="
echo "  log: $RUN_DIR"

for t in $(seq 1 "$TRIALS"); do
  echo "  trial $t / $TRIALS — boehm"
  run_one "$BIN/crystal-metric-boehm" boehm "$t" "$RUN_DIR/boehm-trial-${t}.log"
  echo "  trial $t / $TRIALS — gcry"
  run_one "$BIN/crystal-metric-gcry" gcry "$t" "$RUN_DIR/gcry-trial-${t}.log"
done

python3 - "$RUN_DIR" "$TRIALS" "$FILTER" "$PLATFORM" <<'PY'
import json, re, sys, statistics
from pathlib import Path

run_dir = Path(sys.argv[1])
trials = int(sys.argv[2])
filt = sys.argv[3]
platform = sys.argv[4]

line_re = re.compile(
    r"^(?P<name>[A-Za-z0-9_]+):\s+(?P<status>ok|err|FAIL).*?\bin\s+(?P<secs>[0-9.]+)s",
    re.I | re.M,
)
rss_re = re.compile(r"Maximum resident set size \(kbytes\):\s+(\d+)")

def parse_log(path: Path):
    text = path.read_text(errors="replace")
    benches = {}
    for m in line_re.finditer(text):
        benches[m.group("name")] = {
            "status": m.group("status").lower(),
            "secs": float(m.group("secs")),
        }
    rss_kib = None
    tpath = Path(str(path) + ".time")
    if tpath.exists():
        tm = rss_re.search(tpath.read_text(errors="replace"))
        if tm:
            rss_kib = int(tm.group(1))
    return benches, rss_kib

def median(xs):
    return statistics.median(xs) if xs else None

boehm_by = {}
gcry_by = {}
boehm_rss = []
gcry_rss = []

for t in range(1, trials + 1):
    b, br = parse_log(run_dir / f"boehm-trial-{t}.log")
    g, gr = parse_log(run_dir / f"gcry-trial-{t}.log")
    for name, row in b.items():
        boehm_by.setdefault(name, []).append(row["secs"])
    for name, row in g.items():
        gcry_by.setdefault(name, []).append(row["secs"])
    if br is not None:
        boehm_rss.append(br)
    if gr is not None:
        gcry_rss.append(gr)

names = sorted(set(boehm_by) | set(gcry_by))
rows = []
for name in names:
    bm = median(boehm_by.get(name, []))
    gm = median(gcry_by.get(name, []))
    pct = (bm / gm * 100.0) if (bm and gm and gm > 0) else None
    # Wall % of Boehm: lower time is better → gcry_time/boehm_time * 100
    # Plan said "wall % of Boehm" like thr: higher better for thr.
    # For time, report gcry as % of Boehm wall: (boehm/gcry)*100 so >100 means gcry faster.
    # Clearer: report ratio gcry_secs/boehm_secs and pct_of_boehm_speed = boehm/gcry*100
    speed_pct = (bm / gm * 100.0) if (bm and gm and gm > 0) else None
    rows.append({
        "bench": name,
        "boehm_s_med": round(bm, 4) if bm is not None else None,
        "gcry_s_med": round(gm, 4) if gm is not None else None,
        "gcry_speed_pct_of_boehm": round(speed_pct, 1) if speed_pct is not None else None,
        "gcry_wall_x": round(gm / bm, 3) if (bm and gm and bm > 0) else None,
    })

rss_x = None
if boehm_rss and gcry_rss:
    rss_x = round(median(gcry_rss) / median(boehm_rss), 3)

summary = {
    "suite": "crystal-metric",
    "role": "secondary_gc",
    "platform": platform,
    "trials": trials,
    "filter": filt if filt else "all",
    "benches": rows,
    "boehm_peak_rss_kib_med": int(median(boehm_rss)) if boehm_rss else None,
    "gcry_peak_rss_kib_med": int(median(gcry_rss)) if gcry_rss else None,
    "peak_rss_x": rss_x,
    "note": "Informational only. Product bar remains Kemal /json + acikturkiye. speed_pct>100 means gcry faster (less wall).",
}

(run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

lines = [
    "# crystal-metric Boehm vs gcry (secondary)",
    "",
    f"- platform: `{platform}`",
    f"- trials: {trials} (median wall)",
    f"- filter: `{filt if filt else 'all'}`",
    f"- role: **secondary GC suite** — not a ship headline",
    "",
    "| Bench | Boehm s (med) | gcry s (med) | speed % Boehm | wall × |",
    "|-------|-------------:|-------------:|-------------:|-------:|",
]
for r in rows:
    lines.append(
        f"| {r['bench']} | {r['boehm_s_med']} | {r['gcry_s_med']} | "
        f"{r['gcry_speed_pct_of_boehm']} | {r['gcry_wall_x']} |"
    )
lines += [
    "",
    f"Peak RSS × (med, GNU time): **{rss_x if rss_x is not None else 'n/a'}**",
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
