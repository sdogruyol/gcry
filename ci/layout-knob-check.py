#!/usr/bin/env python3
"""A harness that pins a knob the compile default ignores must build the layout that honours it.

`GCRY_BITMAP_ALLOC=0`, `GCRY_NURSERY=<n>` and `GCRY_TLAB=1` are inert on the
headerless layout, which has been the compile default since 0.26.0 — they warn
on stderr and change nothing. A gate whose arms pin one of them and whose
recipe builds `-Dgc_none` alone therefore measures a configuration it did not
ask for, and the arm it cares about never runs.

That is not hypothetical. Measured 2026-09-14, both page-release gates had
rotted exactly this way: `make page-release-corruption` reported `unlinked 0`
on its HOLED arm in 4 of 4 runs and `make live-graph-audit` reported
`walk 0 B` on both walking arms. Their own engagement checks caught it and
refused to certify — which is the right behaviour and still a red run to
diagnose, so the requirement now lives at the build.

The knob list is read out of `gc_override.cr`'s warning block rather than
hard-coded, so a knob that joins it is covered without touching this file.

Scope: harnesses the Makefile builds. A binary handed an inert knob from a
workflow line is out of scope — `.github/workflows/ci.yml` does that on
purpose, to exercise the warnings.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# `gcry: GCRY_BITMAP_ALLOC=0 is ignored on the headerless layout`
IGNORED = re.compile(r'"gcry: (GCRY_[A-Z0-9_]+)(=\d+)? is ignored on the headerless layout')
# A Makefile recipe line that compiles a source, with whatever flags surround it.
BUILD = re.compile(r"^\t.*?build\s+(?P<flags>[^\n]*?)(?P<src>(?:bench|samples|ci)/\S+\.cr)(?P<rest>[^\n]*)$", re.M)


def inert_knobs() -> dict[str, str | None]:
    """Knob -> the value that is inert, or None when any set value is."""
    text = (ROOT / "src/gcry/gc_override.cr").read_text()
    knobs: dict[str, str | None] = {}
    for name, value in IGNORED.findall(text):
        knobs[name] = value.lstrip("=") or None
    if not knobs:
        sys.exit("FAIL: no 'ignored on the headerless layout' warnings found in gc_override.cr")
    return knobs


def pinned(text: str, knob: str, inert_value: str | None) -> bool:
    """Does this harness pin `knob` to a value the headerless layout ignores?"""
    for match in re.finditer(rf'"{knob}"\s*=>\s*"([^"]*)"', text):
        value = match.group(1)
        if inert_value is None:
            # `GCRY_NURSERY` and friends: inert whenever it is set to anything
            # the collector would act on.
            if value not in ("", "0"):
                return True
        elif value == inert_value:
            return True
    return False


def env_pins(prefix: str, knobs: dict[str, str | None]) -> list[str]:
    """Inert knobs a recipe line sets before invoking a binary."""
    hit = []
    for knob, inert in knobs.items():
        m = re.search(rf"(?:^|\s){knob}=(\S+)", prefix)
        if not m:
            continue
        value = m.group(1)
        if inert is None:
            if value not in ("", "0"):
                hit.append(knob)
        elif value == inert:
            hit.append(knob)
    return hit


def main() -> int:
    knobs = inert_knobs()
    makefile = (ROOT / "Makefile").read_text()
    builds: dict[str, list[str]] = {}
    binaries: dict[str, list[str]] = {}
    for m in BUILD.finditer(makefile):
        flags = m.group("flags") + m.group("rest")
        builds.setdefault(m.group("src"), []).append(flags)
        out = re.search(r"-o\s+\$\(BIN\)/(\S+)", flags)
        if out:
            binaries.setdefault(out.group(1), []).append(flags)

    checked = 0
    bad = []
    # Rule one: the harness pins the knob in its own arms, so the binary the
    # Makefile builds from it has to be the layout that honours the knob.
    for path in sorted(ROOT.glob("bench/**/*.cr")) + sorted(ROOT.glob("samples/**/*.cr")):
        text = path.read_text()
        rel = path.relative_to(ROOT).as_posix()
        hit = [k for k, v in knobs.items() if pinned(text, k, v)]
        if not hit:
            continue
        recipes = builds.get(rel, [])
        if not recipes:
            continue  # not a Makefile gate; nothing to require
        checked += 1
        if not any("-Dgcry_block_headers" in r for r in recipes):
            bad.append(f"{rel} pins {', '.join(sorted(hit))} in its arms and is only built headerless")

    # Rule two: the recipe sets the knob on the command line, so *that* binary
    # has to be the one built with headers — `make heap-counters` and
    # `make poison-freed` both keep a headerless binary beside the header one,
    # and handing the knob to the wrong one is the same silent no-op.
    for line in makefile.split("\n"):
        if not line.startswith("\t") or "$(BIN)/" not in line:
            continue
        run = re.search(r"^\t@?(?P<prefix>[^|]*?)\$\(BIN\)/(?P<bin>[A-Za-z0-9_.-]+)", line)
        if not run or " build " in line:
            continue
        hit = env_pins(run.group("prefix"), knobs)
        if not hit:
            continue
        name = run.group("bin")
        recipes = binaries.get(name, [])
        if not recipes:
            continue
        checked += 1
        if not any("-Dgcry_block_headers" in r for r in recipes):
            bad.append(f"$(BIN)/{name} is run with {', '.join(sorted(hit))} and is built headerless")

    if bad:
        print("FAIL: a gate pins a knob the headerless compile default ignores, and never")
        print("builds the layout that honours it — so the arm it pins for does not run.")
        for line in bad:
            print(f"  {line}")
        print("Add -Dgcry_block_headers to its recipe (and a {% raise %} in the harness).")
        return 1

    print(f"ok — {checked} gate arms pin a headerless-inert knob and every one of them "
          f"builds -Dgcry_block_headers ({', '.join(sorted(knobs))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
