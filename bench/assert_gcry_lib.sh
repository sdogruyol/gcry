#!/usr/bin/env bash
# Refuse to build a benchmark binary against the wrong gcry.
#
# The Kemal and acikturkiye benches take gcry as a `path: ../..` shard, and
# `shards install` materialises that as an **absolute** symlink,
# `lib/gcry -> /home/you/gcry`. That is correct for the checkout that ran the
# install and silently wrong for every other tree: a worktree whose `lib/` was
# copied, a scratch tree seeded from the main checkout, or a `shards install`
# that kept an existing `lib/` because the lock had not changed. The build then
# compiles the *main checkout's* collector, and the harness attributes the
# number to the branch it thinks it is measuring.
#
# It has already cost two published tables. ROADMAP.md records
# `acikturkiye/lib/gcry` as "a symlink to the main checkout, so running the
# harness from a worktree selects the script, not the collector" — one wasted
# run. And PR #34's log retracts PR #33's Kemal table outright: it had measured
# the wrong tree through exactly this link.
#
# So: after `shards install`, before `crystal build`, resolve the link and
# require it to be the tree the harness is running from. A mismatch is a hard
# failure with both paths printed, not a warning — a wrong number with a
# warning above it is still a wrong number.
#
#   bench/assert_gcry_lib.sh <path/to/lib/gcry> <expected gcry root>
set -euo pipefail

lib="${1:?usage: assert_gcry_lib.sh <lib/gcry> <expected-root>}"
want="${2:?usage: assert_gcry_lib.sh <lib/gcry> <expected-root>}"

if [ ! -e "$lib" ]; then
  echo "assert_gcry_lib: $lib does not exist — run shards install first" >&2
  exit 2
fi

got_real="$(readlink -f "$lib")"
want_real="$(readlink -f "$want")"

if [ "$got_real" != "$want_real" ]; then
  echo "assert_gcry_lib: REFUSING TO BUILD — the bench would compile the wrong collector" >&2
  echo "  $lib" >&2
  echo "    resolves to: $got_real" >&2
  echo "    expected:    $want_real" >&2
  echo "  (shards writes lib/gcry as an absolute symlink; a copied or stale lib/ keeps" >&2
  echo "   pointing at whichever checkout ran the install. rm -rf lib/ and reinstall.)" >&2
  exit 1
fi

# A checkout that is not what git thinks it is measures nothing either.
if ! git -C "$want_real" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "assert_gcry_lib: $want_real is not a git work tree" >&2
  exit 1
fi

echo "gcry lib: $got_real ($(git -C "$want_real" rev-parse --short HEAD)$(git -C "$want_real" diff --quiet || echo ' +dirty'))"
