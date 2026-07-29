#!/usr/bin/env bash
# Code coverage runner for gcry.
# Uses kcov (DWARF-based) for line/branch coverage and crystal built-in tools
# for unreachable methods and macro coverage.
#
# Usage:
#   ./ci/coverage.sh              # full coverage (kcov + unreachable + macro)
#   ./ci/coverage.sh kcov         # kcov only
#   ./ci/coverage.sh unreachable  # crystal tool unreachable only
#   ./ci/coverage.sh macro        # crystal tool macro_code_coverage only
#
# Environment:
#   COVERAGE_DIR  — output directory (default: ./coverage)
#   MIN_COVERAGE  — exit code 1 if branch coverage below this % (default: 0 / no gate)
#   KCOV_ARGS     — extra kcov flags (e.g. --exclude-pattern=test/)
#   SKIP_KCOV     — set to 1 to skip kcov even if available

set -euo pipefail
cd "$(dirname "$0")/.."

COVERAGE_DIR="${COVERAGE_DIR:-coverage}"
MIN_COVERAGE="${MIN_COVERAGE:-0}"
SKIP_KCOV="${SKIP_KCOV:-0}"
BIN_DIR="${BIN_DIR:-bin}"

mkdir -p "$COVERAGE_DIR" "$BIN_DIR"

mode="${1:-all}"

install_kcov() {
  if command -v kcov &>/dev/null; then
    return 0
  fi
  echo "kcov not found, attempting to install..."
  if command -v apt-get &>/dev/null; then
    # Try Debian package (kcov v43 is in Debian testing)
    if apt-get install -y -qq kcov 2>/dev/null; then
      echo "kcov installed via apt"
      return 0
    fi
    # Build from source (Ubuntu 24.04 dropped the package)
    echo "Building kcov from source..."
    local deps=(binutils-dev build-essential cmake libssl-dev libcurl4-openssl-dev \
                libelf-dev libstdc++-12-dev zlib1g-dev libdw-dev libiberty-dev)
    apt-get install -y -qq "${deps[@]}"
    local tmpdir
    tmpdir="$(mktemp -d)"
    git clone --depth 1 --branch v43 https://github.com/SimonKagstrom/kcov.git "$tmpdir"
    mkdir -p "$tmpdir/build"
    cmake -S "$tmpdir" -B "$tmpdir/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$tmpdir/build" -j"$(nproc)"
    cmake --install "$tmpdir/build" --prefix /usr/local
    rm -rf "$tmpdir"
    echo "kcov v43 built from source"
  else
    echo "WARNING: no package manager found, skipping kcov"
    return 1
  fi
}

run_kcov() {
  if [ "$SKIP_KCOV" = "1" ]; then
    echo "SKIP_KCOV=1, skipping kcov"
    return 0
  fi
  install_kcov || return 0

  # Build the spec binary (debug info required for DWARF)
  echo "Building spec binary for kcov..."
  crystal build spec/all_specs.cr -o "$BIN_DIR/all_specs" --error-trace

  # Run kcov
  echo "Running kcov..."
  kcov --clean \
       --include-path="./src" \
       --exclude-pattern="/.shards" \
       $KCOV_ARGS \
       "$COVERAGE_DIR" \
       "$BIN_DIR/all_specs" \
       --order=random

  # Print summary
  if [ -f "$COVERAGE_DIR/index.json" ]; then
    local covered
    local total
    covered=$(python3 -c "import json; d=json.load(open('$COVERAGE_DIR/index.json')); print(d.get('covered_lines', 0))" 2>/dev/null || echo "0")
    total=$(python3 -c "import json; d=json.load(open('$COVERAGE_DIR/index.json')); print(d.get('total_lines', 0))" 2>/dev/null || echo "0")
    if [ "$total" -gt 0 ] && [ "$covered" -gt 0 ]; then
      local pct=$((covered * 100 / total))
      echo "kcov: $covered / $total lines covered ($pct%)"

      # Coverage gate
      if [ "$MIN_COVERAGE" -gt 0 ] && [ "$pct" -lt "$MIN_COVERAGE" ]; then
        echo "ERROR: coverage $pct% is below threshold $MIN_COVERAGE%"
        exit 1
      fi
    fi
  fi
}

run_unreachable() {
  echo "Running crystal tool unreachable..."
  crystal tool unreachable --format codecov spec/all_specs.cr \
    > "$COVERAGE_DIR/unreachable.codecov.json" 2>/dev/null || true
  local count
  count=$(crystal tool unreachable spec/all_specs.cr 2>/dev/null | wc -l)
  echo "Unreachable methods: $count"
}

run_macro_coverage() {
  echo "Running crystal tool macro_code_coverage..."
  crystal tool macro_code_coverage --format codecov spec/all_specs.cr \
    > "$COVERAGE_DIR/macro_coverage.codecov.json" 2>/dev/null || true
  echo "Macro coverage report generated"
}

case "$mode" in
  kcov)
    run_kcov
    ;;
  unreachable)
    run_unreachable
    ;;
  macro)
    run_macro_coverage
    ;;
  all)
    run_kcov
    run_unreachable
    run_macro_coverage
    echo ""
    echo "--- Coverage summary ---"
    echo "Reports in: $COVERAGE_DIR/"
    ls -la "$COVERAGE_DIR/" 2>/dev/null | grep -v '^total'
    ;;
  *)
    echo "Usage: $0 [all|kcov|unreachable|macro]"
    exit 1
    ;;
esac