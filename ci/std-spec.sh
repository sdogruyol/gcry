#!/bin/bash
# Crystal's own standard-library spec suite (`spec/std`) with gcry as the
# process GC — or with Boehm, as the baseline a failure is judged against.
#
#   ci/std-spec.sh [--backend gcry|boehm] [--chunks N] [--no-build] [-- SPEC_ARGS...]
#
# The suite is taken from the crystal-lang/crystal commit the installed
# compiler reports (`crystal version`), so it always matches the stdlib it
# tests: a release tag when there is one, the exact commit for a nightly.
# It is cloned once into `.std-spec/` (or `$STD_SPEC_SRC`).
#
# `--chunks N` builds N binaries from interleaved slices of the spec files
# instead of one: the whole suite is one ~75 MB executable, and GNU ld 2.46
# writes a corrupt symbol-version table for it (`symbol lookup error:
# undefined symbol: __libc_start_main, version <spec name>`), Boehm build
# included. Smaller links do not hit it.
#
# `--no-build` runs the binaries an earlier invocation with the same backend
# and chunk count left in `bin/`, e.g. again under `GCRY_STRESS=1`.
#
# Exit status is non-zero if any chunk fails to build or any example fails.
set -euo pipefail

backend=gcry
chunks=1
build=1
while [ $# -gt 0 ]; do
  case "$1" in
  --backend) backend="$2"; shift 2 ;;
  --chunks) chunks="$2"; shift 2 ;;
  --no-build) build=0; shift ;;
  --) shift; break ;;
  *) echo "usage: $0 [--backend gcry|boehm] [--chunks N] [--no-build] [-- SPEC_ARGS...]" >&2; exit 2 ;;
  esac
done
case "$backend" in gcry | boehm) ;; *) echo "unknown backend: $backend" >&2; exit 2 ;; esac

crystal="${CRYSTAL:-crystal}"
root="$(cd "$(dirname "$0")/.." && pwd)"

# "Crystal 1.21.0 [57cf7da50] (2026-07-16)" / "Crystal 1.22.0-dev [0123abcde] (…)"
version_line="$("$crystal" version | head -n 1)"
version="$(printf '%s\n' "$version_line" | awk '{print $2}')"
commit="$(printf '%s\n' "$version_line" | sed -n 's/.*\[\([0-9a-f]*\)\].*/\1/p')"
if [ -z "$version" ] || [ -z "$commit" ]; then
  echo "cannot read version and commit from: $version_line" >&2
  exit 2
fi

src="${STD_SPEC_SRC:-$root/.std-spec/crystal-$commit}"
if [ ! -f "$src/spec/std_spec.cr" ]; then
  rm -rf "$src"
  mkdir -p "$(dirname "$src")"
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
echo "std_spec: $version_line, backend $backend, $chunks chunk(s), source $src"

# Each chunk gets its own entry file inside spec/, so the suite's relative
# requires and data paths resolve as they do for `make std_spec`.
entry_prelude() {
  echo 'require "./support/mt_abort_timeout"'
  # Specs call Boehm's `LibGC.size` directly; gcry defines `LibGC` and the
  # `GC_*` functions behind it (src/gcry/c_abi.cr).
  if [ "$backend" = gcry ]; then
    echo 'require "gcry"'
  fi
}

(cd "$src" && find spec/std -name '*_spec.cr' | LC_ALL=C sort) >"$src/.std-spec-files"
total=$(wc -l <"$src/.std-spec-files")
if [ "$chunks" -lt 1 ] || [ "$chunks" -gt "$total" ]; then
  echo "--chunks must be between 1 and $total" >&2
  exit 2
fi

flags=(-Dstrict_multi_assign -Dpreview_overload_order
  --exclude-warnings spec/std --exclude-warnings src/float/printer --exclude-warnings src/random.cr)
[ "$backend" = gcry ] && flags+=(-Dgc_none)
mkdir -p "$root/bin"
export CRYSTAL_PATH="$root/src:$src/src:$src/lib"

status=0
for ((i = 0; i < chunks; i++)); do
  label="std_spec chunk $((i + 1))/$chunks"
  bin="$root/bin/std_spec_${backend}_${chunks}_${i}"
  if [ "$build" -eq 1 ]; then
    entry="spec/gcry_std_spec_${backend}_${chunks}_${i}.cr"
    {
      entry_prelude
      if [ "$chunks" -eq 1 ]; then
        echo 'require "./std/**"'
      else
        awk -v n="$chunks" -v i="$i" '(NR - 1) % n == i { sub(/^spec\//, "./"); printf "require \"%s\"\n", $0 }' \
          "$src/.std-spec-files"
      fi
    } >"$src/$entry"

    echo "::group::$label: build"
    if ! (cd "$src" && "$crystal" build "${flags[@]}" "$entry" -o "$bin"); then
      echo "::endgroup::"
      echo "$label: BUILD FAILED" >&2
      status=1
      continue
    fi
    echo "::endgroup::"
  elif [ ! -x "$bin" ]; then
    echo "$label: no binary at $bin (run without --no-build first)" >&2
    status=1
    continue
  fi
  echo "$label: run"
  if ! (cd "$src" && "$bin" --no-color "$@"); then
    echo "$label: FAILED" >&2
    status=1
  fi
done
exit $status
