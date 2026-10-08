#!/bin/bash
# The Crystal compiler built and run with gcry as its GC, its own spec suite
# under gcry, and the interpreter (`crystal i`) in a gcry-built compiler.
#
#   ci/compiler-spec.sh [--backend gcry|boehm] STEP...
#
# Steps, run in the order given:
#   compiler     host `crystal` builds the compiler from the matching
#                crystal-lang/crystal checkout -> .compiler-gcry/bin/crystal-<backend>
#   interpreter  the same with `-Dinterpreter`  -> .compiler-gcry/bin/crystal-<backend>-i
#   smoke        the stage-1 compiler builds and runs gcry's samples/hello.cr and
#                samples/json_churn.cr (-Dgc_none) and Crystal's
#                samples/binary-trees.cr (Boehm)
#   stage2       the stage-1 compiler builds the compiler again, with the same
#                backend; stage 2 then builds and runs samples/hello.cr
#   spec[=DIRS]  host `crystal` builds Crystal's compiler specs (spec/compiler/DIRS,
#                comma-separated; default: the whole of compiler_spec.cr) with the
#                backend and runs them
#   interp       `crystal-<backend>-i i` runs the programs in ci/compiler-interp/
#
# The checkout is the crystal-lang/crystal commit `crystal version` reports, as
# in ci/std-spec.sh, cloned once into `.compiler-gcry/` (or `$COMPILER_GCRY_SRC`).
# Compiler flags follow Crystal's Makefile (`make crystal`): the compiler is a
# release build unless `COMPILER_GCRY_RELEASE=0`. `LLVM_CONFIG` defaults to the
# `llvm-config` on PATH. Extra spec-runner arguments go in `$SPEC_ARGS`.
#
# Exit status is non-zero if any step fails.
set -euo pipefail

backend=gcry
steps=()
while [ $# -gt 0 ]; do
  case "$1" in
  --backend) backend="$2"; shift 2 ;;
  compiler | interpreter | smoke | stage2 | spec | spec=* | interp) steps+=("$1"); shift ;;
  *) echo "usage: $0 [--backend gcry|boehm] {compiler|interpreter|smoke|stage2|spec[=DIRS]|interp}..." >&2; exit 2 ;;
  esac
done
case "$backend" in gcry | boehm) ;; *) echo "unknown backend: $backend" >&2; exit 2 ;; esac
[ ${#steps[@]} -gt 0 ] || { echo "no step given" >&2; exit 2; }

crystal="${CRYSTAL:-crystal}"
root="$(cd "$(dirname "$0")/.." && pwd)"
export LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config)}"

version_line="$("$crystal" version | head -n 1)"
version="$(printf '%s\n' "$version_line" | awk '{print $2}')"
commit="$(printf '%s\n' "$version_line" | sed -n 's/.*\[\([0-9a-f]*\)\].*/\1/p')"
if [ -z "$version" ] || [ -z "$commit" ]; then
  echo "cannot read version and commit from: $version_line" >&2
  exit 2
fi

cache="$root/.compiler-gcry"
src="${COMPILER_GCRY_SRC:-$cache/crystal-$commit}"
bin="$cache/bin"
mkdir -p "$bin"
if [ ! -f "$src/src/compiler/crystal.cr" ]; then
  rm -rf "$src"
  url=https://github.com/crystal-lang/crystal
  if [[ "$version" != *-* ]] &&
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$version" "$url" "$src" 2>/dev/null &&
    [[ "$(git -C "$src" rev-parse HEAD)" == "$commit"* ]]; then
    :
  else
    rm -rf "$src"
    git clone -q --filter=blob:none --no-checkout "$url" "$src"
    git -C "$src" -c advice.detachedHead=false checkout -q "$commit"
  fi
fi
echo "compiler-spec: $version_line, backend $backend, source $src, LLVM $("$LLVM_CONFIG" --version)"

# gcry has to be the program's GC from the first allocation, so it is required
# ahead of the compiler; `-Dgc_none` keeps Boehm out of the link.
printf 'require "gcry"\nrequire "./crystal"\n' >"$src/src/compiler/gcry_crystal.cr"

backend_flags=()
backend_path="$src/src:$src/lib"
compiler_entry=src/compiler/crystal.cr
if [ "$backend" = gcry ]; then
  backend_flags=(-Dgc_none)
  backend_path="$root/src:$backend_path"
  compiler_entry=src/compiler/gcry_crystal.cr
fi
# Crystal's Makefile: FLAGS and COMPILER_FLAGS for `make crystal`.
flags=(-Dstrict_multi_assign -Dpreview_overload_order)
compiler_flags=(-Dwithout_libxml2 -Dwithout_openssl -Dwithout_zlib)
release=()
[ "${COMPILER_GCRY_RELEASE:-1}" = 1 ] && release=(--release)

# build_compiler HOST_CRYSTAL OUT [-Dwithout_interpreter]
build_compiler() {
  local host="$1" out="$2"
  shift 2
  echo "::group::build $out with $host"
  (cd "$src" && env CRYSTAL_HAS_WRAPPER=true CRYSTAL_PATH="$backend_path" \
    CRYSTAL_CONFIG_PATH="$src/src" \
    CRYSTAL_CONFIG_LIBRARY_PATH="$("$host" env CRYSTAL_LIBRARY_PATH)" \
    CRYSTAL_CONFIG_BUILD_COMMIT="$commit" \
    SOURCE_DATE_EPOCH="$(git -C "$src" show -s --format=%ct HEAD)" \
    nice -n 10 "$host" build "${flags[@]}" "${compiler_flags[@]}" "${backend_flags[@]}" "$@" \
    "${release[@]}" "$compiler_entry" -o "$out")
  local status=$?
  echo "::endgroup::"
  return $status
}

stage1="$bin/crystal-$backend"

# run_program LABEL COMPILER FILE [BUILD_FLAGS...] -- [ARGS...]
run_program() {
  local label="$1" compiler="$2" file="$3"
  shift 3
  local build_args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do build_args+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  local exe="$bin/smoke-$label"
  echo "$label: build $file with $(basename "$compiler")"
  env -u CRYSTAL_PATH "$compiler" build "${build_args[@]}" "$file" -o "$exe" || { echo "$label: BUILD FAILED" >&2; return 1; }
  echo "$label: run"
  "$exe" "$@" || { echo "$label: RUN FAILED" >&2; return 1; }
}

gcry_flags=()
[ "$backend" = gcry ] && gcry_flags=(-Dgc_none)

step_compiler() {
  build_compiler "$crystal" "$stage1" -Dwithout_interpreter && "$stage1" version
}

step_interpreter() {
  build_compiler "$crystal" "$stage1-i" && "$stage1-i" version
}

step_smoke() {
  [ -x "$stage1" ] || { echo "smoke: no $stage1 (run the compiler step first)" >&2; return 1; }
  run_program hello "$stage1" "$root/samples/hello.cr" -Dgc_none &&
    run_program json_churn "$stage1" "$root/samples/json_churn.cr" -Dgc_none -- 3000 &&
    run_program binary_trees "$stage1" "$src/samples/binary-trees.cr" --release -- 16
}

step_stage2() {
  [ -x "$stage1" ] || { echo "stage2: no $stage1 (run the compiler step first)" >&2; return 1; }
  build_compiler "$stage1" "$stage1-stage2" -Dwithout_interpreter &&
    "$stage1-stage2" version &&
    run_program stage2_hello "$stage1-stage2" "$root/samples/hello.cr" -Dgc_none
}

# step_spec [DIRS]
step_spec() {
  local dirs="${1:-}" name=all
  local entry="spec/gcry_compiler_spec_${backend}.cr"
  {
    if [ "$backend" = gcry ]; then echo 'require "gcry"'; fi
    if [ -z "$dirs" ]; then
      echo 'require "./compiler_spec"'
    else
      name="${dirs//,/_}"
      name="${name//\//-}"
      local d
      for d in ${dirs//,/ }; do echo "require \"./compiler/$d/**\""; done
    fi
  } >"$src/$entry"
  local exe="$bin/compiler_spec_${backend}_${name}"
  echo "::group::build $exe"
  (cd "$src" && env CRYSTAL_HAS_WRAPPER=true CRYSTAL_PATH="$backend_path" CRYSTAL_CONFIG_PATH="$src/src" \
    nice -n 10 "$crystal" build "${flags[@]}" "${compiler_flags[@]}" "${backend_flags[@]}" -Dwithout_interpreter \
    --exclude-warnings spec/compiler --exclude-warnings spec/primitives --exclude-warnings src/float/printer \
    "${release[@]}" "$entry" -o "$exe") || { echo "::endgroup::"; echo "spec: BUILD FAILED" >&2; return 1; }
  echo "::endgroup::"
  # The specs compile programs: the stdlib they see is the checkout's.
  # shellcheck disable=SC2086
  (cd "$src" && env CRYSTAL_PATH="$src/src:$src/lib" CRYSTAL_HAS_WRAPPER=true "$exe" --no-color ${SPEC_ARGS:-})
}

step_interp() {
  local compiler="$stage1-i" status=0 f
  [ -x "$compiler" ] || { echo "interp: no $compiler (run the interpreter step first)" >&2; return 1; }
  for f in "$root"/ci/compiler-interp/*.cr; do
    echo "interp: $(basename "$f")"
    if ! (cd "$src" && env -u CRYSTAL_PATH "$compiler" i "$f"); then
      echo "interp: $(basename "$f") FAILED" >&2
      status=1
    fi
  done
  return $status
}

status=0
for s in "${steps[@]}"; do
  case "$s" in
  compiler) step_compiler || status=1 ;;
  interpreter) step_interpreter || status=1 ;;
  smoke) step_smoke || status=1 ;;
  stage2) step_stage2 || status=1 ;;
  spec) step_spec || status=1 ;;
  spec=*) step_spec "${s#spec=}" || status=1 ;;
  interp) step_interp || status=1 ;;
  esac
done
exit $status
