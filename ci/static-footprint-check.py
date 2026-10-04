#!/usr/bin/env python3
"""gcry's own writable static data must stay small.

The static-root scan reads the executable's writable segments word by word at
every collection. A class variable gcry declares there is scanned with them,
whatever it holds. Until 2026-09-28 the precise-layout tables were
`StaticArray` class variables: 448 KiB of type ids and offsets, 88% of Kemal's
static roots, 130 µs of every pause, none of it able to point at the heap
(`bench/log/linux/2026-09-28-layout-off-bss/`). Tables that size belong in
`malloc`ed storage, which no root scan reads.

Builds a minimal `-Dgc_none` program and reads its symbol table. It fails when
one `Gcry::` symbol in `.data` or `.bss` is bigger than PER_SYMBOL, or all of
them together are bigger than TOTAL. Linux only: the symbol names are read
from `nm -C`.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

PER_SYMBOL = 16 * 1024
TOTAL = 64 * 1024

PROGRAM = 'require "../src/gcry"\nGC.collect\n'


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as tmp:
        src = root / "ci" / "_static_footprint.cr"
        src.write_text(PROGRAM)
        binary = pathlib.Path(tmp) / "static_footprint"
        try:
            subprocess.run(["crystal", "build", "-Dgc_none", str(src), "-o", str(binary)],
                           cwd=root, check=True)
        finally:
            src.unlink()
        out = subprocess.run(["nm", "-S", "-C", str(binary)], capture_output=True, text=True,
                             check=True).stdout

    sizes: list[tuple[int, str]] = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) != 4 or parts[2] not in ("b", "B", "d", "D"):
            continue
        if not parts[3].startswith("Gcry::"):
            continue
        sizes.append((int(parts[1], 16), parts[3]))
    sizes.sort(reverse=True)
    total = sum(size for size, _ in sizes)

    bad = [f"  {name}: {size // 1024} KiB (limit {PER_SYMBOL // 1024} KiB)"
           for size, name in sizes if size > PER_SYMBOL]
    if total > TOTAL:
        bad.append(f"  all Gcry:: static data: {total // 1024} KiB (limit {TOTAL // 1024} KiB)")
    if bad:
        print("FAIL: gcry static data the static-root scan reads at every collection:")
        print("\n".join(bad))
        print()
        print("Largest:")
        for size, name in sizes[:8]:
            print(f"  {size:8d}  {name}")
        print()
        print("Move large tables to malloc'ed storage and keep only a pointer in the class "
              "variable (see Gcry::StwSlots::Table#reserve).")
        return 1

    largest = f"{sizes[0][1]} {sizes[0][0]} B" if sizes else "none"
    print(f"ok — gcry static data {total // 1024} KiB in {len(sizes)} symbols, largest {largest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
