#!/usr/bin/env python3
"""No class variable the stopped world touches may have a lazy initializer.

A Crystal class variable **declared with an initializer that is not a literal**
is set up lazily behind `Crystal.once`, which takes a process-wide mutex. Two
places in this collector cannot pay that:

  * `GC.init`, which runs before `Crystal.main` has set the once machinery up.
    Darwin's `install_stw_sp_capture` boots its capture table there, and
    `@@table = Pointer(UInt8).null` made every `-Dgc_none` binary on that
    platform die at startup before printing anything. Two reverts and eight
    probe rounds.
  * Inside the stopped world. The collector suspends threads asynchronously on
    Darwin and Windows, so a suspended thread can be holding the once mutex
    while the collector reaches its first read of a lazily-initialized class
    variable — and then nothing ever resumes. `@@stw_handles =
    Pointer(LibC::HANDLE).null`, read from `resume_suspended_threads`, wedged
    all six Windows jobs for their whole 20-minute budget, three runs in a row.

The rule is in the comments of all three platform files, and it has now been
broken twice by the same expression. So it is mechanical: in these files a class
variable is declared `uninitialized`, or with a literal (`false`, `0`, `nil`),
and given its real value in a method.
"""
from __future__ import annotations

import pathlib
import re
import sys

# Files whose class variables are read from `GC.init` or inside the stopped
# world. Not a whole-tree rule: everything else in the tree runs after
# `Crystal.main` and may use whatever initializer reads best.
GUARDED = [
    "src/gcry/stw_slots.cr",
    "src/gcry/platform/linux_stw.cr",
    "src/gcry/platform/darwin_stw.cr",
    "src/gcry/platform/windows_stw.cr",
]

# A declaration is `@@name = <rhs>` at the start of a line (any indent). The
# safe right-hand sides are `uninitialized ...` and literals the compiler folds
# into static data.
LITERAL = re.compile(
    r"""^(
        uninitialized\s .* |
        true | false | nil |
        -?\d[\d_]*(?:_[iuf]\d+)? |
        -?\d+\.\d+(?:_f\d+)? |
        0x[0-9a-fA-F_]+(?:_[iu]\d+)? |
        0b[01_]+(?:_[iu]\d+)? |
        "[^"]*" | :\w+
    )$""",
    re.VERBOSE,
)

DECL = re.compile(r"^\s*(@@\w+)\s*=\s*(.+?)\s*$")


def offenders(path: pathlib.Path) -> list[tuple[int, str, str]]:
    found = []
    seen: set[str] = set()
    for number, line in enumerate(path.read_text().splitlines(), start=1):
        match = DECL.match(line)
        if not match:
            continue
        name, rhs = match.group(1), match.group(2)
        # Only the first `@@x = ...` in a file is the declaration; later ones
        # are assignments inside methods, which run after `Crystal.main` or
        # from a method the collector calls deliberately.
        if name in seen:
            continue
        seen.add(name)
        if rhs.endswith(("&&", "||", "+", "(")) or LITERAL.match(rhs):
            continue
        found.append((number, name, rhs))
    return found


def main() -> int:
    bad = []
    checked = 0
    for name in GUARDED:
        path = pathlib.Path(name)
        if not path.exists():
            print(f"FAIL: {name} is in the guard list and does not exist")
            return 1
        checked += 1
        for number, var, rhs in offenders(path):
            bad.append(f"  {name}:{number}: {var} = {rhs}")

    if bad:
        print("FAIL: class variables the stopped world reads, declared with a lazy initializer:")
        print("\n".join(bad))
        print()
        print("A non-literal initializer is set up behind `Crystal.once`, which takes a")
        print("process-wide mutex. Read from `GC.init` it crashes before `Crystal.main`;")
        print("read inside the stopped world it deadlocks against a suspended thread that")
        print("holds that mutex. Declare it `uninitialized` and assign in a method.")
        return 1

    print(f"ok — no lazily-initialized class variables in the {checked} files the stopped world reads")
    return 0


if __name__ == "__main__":
    sys.exit(main())
