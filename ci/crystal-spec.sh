#!/usr/bin/env bash
# `crystal spec`, minus the step that flakes on Windows. Every Makefile target
# that runs specs goes through here.
#
#   ci/crystal-spec.sh [compile flags...] [spec files or dirs...] [-- runner options...]
#
# Arguments starting with `-` before a `--` are compile flags (`-Dgc_none`,
# `--error-trace`, `--release`; flags that take a separate value are not
# supported), the rest are spec files or directories (default `spec`, as for
# `crystal spec`), and anything after `--` goes to the spec runner.
#
# Why: `crystal spec` compiles to `<cache>/crystal-run-spec.tmp.exe`, runs it,
# and deletes it. On the Windows runners that delete races a handle on the
# image that outlives the process, and the step fails with "Error deleting
# file ... crystal-run-spec.tmp.exe ... you've found a bug in the Crystal
# compiler" after the specs have already printed `0 failures`. ci/windows.ps1
# has worked around it for its own spec runs since 2026-09-23 (the comment over
# `Invoke-CrystalSpec` has the history); the Makefile targets the Windows gates
# jobs run did not, and `make bitmap-marks-freelist` failed that way on windows
# arm64 on 2026-10-14 (run 38633380085, job 116090337173; the rerun passed).
#
# So on Windows (Git Bash / MSYS2: `uname -s` is MINGW*, MSYS* or CYGWIN*) the
# specs are built under a name of their own in $BIN and run, which is what
# `crystal spec` does minus the delete. Everywhere else this is exactly
# `$CRYSTAL spec "$@"`. GCRY_SPEC_BUILD=1 forces the build-then-run path on any
# host, which is how its example counts were checked against `crystal spec`'s
# on Linux.
#
# The build goes through an entry file that `require`s each spec file, the way
# `crystal spec` itself does, never by handing the files to `crystal build` as
# several main sources: then a `{% skip_file %}` in one of them skips every
# main source after it too. `spec/segv_report_spec.cr` opens with
# `skip_file unless flag?(:unix)`, and the first version of the ps1 workaround
# lost the 57 examples that sort after it (281 -> 224, run 35849478402) and
# stayed green. Through `require` only that one file is skipped.
set -euo pipefail

CRYSTAL="${CRYSTAL:-crystal}"
BIN="${BIN:-bin}"

windows=0
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) windows=1 ;;
esac

if [ "$windows" = 0 ] && [ "${GCRY_SPEC_BUILD:-0}" != 1 ]; then
  exec "$CRYSTAL" spec "$@"
fi

flags=()
paths=()
runner=()
while [ $# -gt 0 ]; do
  case "$1" in
    --)
      shift
      runner=("$@")
      break
      ;;
    -*) flags+=("$1") ;;
    *) paths+=("$1") ;;
  esac
  shift
done
[ ${#paths[@]} -eq 0 ] && paths=(spec)

# The entry file lives in $BIN and its `require`s are relative to it, so each
# is prefixed with the way back up to here, as ci/windows.ps1 does: relative
# rather than absolute because a Git Bash path (`/c/...`) means nothing to the
# Windows compiler.
case "$BIN" in
  /* | [A-Za-z]:*)
    echo "ci/crystal-spec.sh: BIN must be relative to the repository root, got $BIN" >&2
    exit 1
    ;;
esac
up=""
IFS=/ read -r -a parts <<<"$BIN"
for part in "${parts[@]}"; do
  case "$part" in
    "" | .) ;;
    ..)
      echo "ci/crystal-spec.sh: BIN must be under the repository root, got $BIN" >&2
      exit 1
      ;;
    *) up="../$up" ;;
  esac
done
if [ -z "$up" ]; then up="./"; fi

# One entry file and binary per argument list, so targets that run the specs
# under different flags (or a parallel make) never build over each other.
label=$(printf '%s\n' "${flags[@]+"${flags[@]}"}" "${paths[@]}" | cksum | cut -d' ' -f1)
mkdir -p "$BIN"
entry="$BIN/crystal_spec_$label.cr"
binary="$BIN/crystal_spec_$label"
[ "$windows" = 1 ] && binary="$binary.exe"

# `crystal spec` expands a directory to its `**/*_spec.cr` and takes a file as
# given. A bash glob rather than `find | sort`: on Windows a PATH that puts
# System32 first hands those names to `find.exe` and `sort.exe`, which are
# other tools.
shopt -s globstar nullglob
files=()
for path in "${paths[@]}"; do
  if [ -d "$path" ]; then
    for file in "${path%/}"/**/*_spec.cr; do
      if [ -f "$file" ]; then files+=("$file"); fi
    done
  elif [ -f "$path" ]; then
    files+=("$path")
  else
    echo "ci/crystal-spec.sh: no such spec file or directory: $path" >&2
    exit 1
  fi
done
if [ ${#files[@]} -eq 0 ]; then
  echo "ci/crystal-spec.sh: no *_spec.cr under ${paths[*]}" >&2
  exit 1
fi
: >"$entry"
for file in "${files[@]}"; do
  printf 'require "%s%s"\n' "$up" "${file#./}" >>"$entry"
done

# Said in the log, so a run shows which of the two paths it took: the specs'
# own output is the same either way.
echo "ci/crystal-spec.sh: ${#files[@]} spec files via $entry -> $binary (built and run, not \`crystal spec\`)" >&2
"$CRYSTAL" build "${flags[@]+"${flags[@]}"}" "$entry" -o "$binary"
exec "$binary" "${runner[@]+"${runner[@]}"}"
