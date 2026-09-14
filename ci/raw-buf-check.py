#!/usr/bin/env python3
"""A line writer must never be handed a buffer smaller than the length it stops at.

`Gcry::RawOut.append` truncates at `LIMIT` and knows nothing about the caller's
buffer, so a buffer below `LIMIT` is not a truncated line — it is a stack
smash. Measured 2026-09-14: the SIGSEGV report's kept-release line is 377 bytes
and its buffer was 256, so writing it ran 121 bytes past the end, clobbered a
local (the report then contradicted a block count it had printed two clauses
earlier) and the return address (the report died at 0x0 inside itself, with the
fault it had been called for still undescribed). Thirty-two other buffers were
under `LIMIT` at that moment. Two of them could already reach past their own
end: the chunk-index/list disagreement line in `collect_scan.cr` is 417 bytes
with every number at full width against a 352-byte buffer, and 349 on an
ordinary mapped chunk — three bytes of margin — and the thread-list tripwire's
index line is 295 against 288.

The same question is asked of the two hand-rolled writers that predate
`RawOut` — `EcQueueAudit` stops at 300 with 320-byte buffers, `StwWatchdog` at
250 with 256 — because the invariant is about the pair, not about one module.

Silent until it is not: a short line fits, and the buffer is only wrong for
inputs nobody has printed yet. That is what makes it a gate.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

DECL = re.compile(r"\b(\w+)\s*=\s*uninitialized\s+UInt8\[([\w:]+)\]")
ALIAS = re.compile(r"\b(\w+)\s*=\s*(\w+)\.to_unsafe\b")
SHARED_WRITE = re.compile(r"RawOut\.(?:append\w*|flush)\(\s*(\w+)(?:\.to_unsafe)?\s*,")
LOCAL_WRITE = re.compile(r"(?<![\w.])append\w*\(\s*(\w+)(?:\.to_unsafe)?\s*,")
LOCAL_WRITER = re.compile(r"def self\.append\w*\(\s*\w+\s*:\s*UInt8\*")
# `while i < n && len < 300` and `return len if len + n > 1023`: the two shapes
# a hand-rolled writer states its bound in.
LOCAL_BOUND = re.compile(r"len\s*<\s*(\d+)|len\s*\+\s*\w+\s*>\s*(\d+)")
LIMIT_DECL = re.compile(r"^\s*LIMIT\s*=\s*(\d+)\s*$", re.M)
CONST = re.compile(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(\d+)\s*$", re.M)


def shared_limit() -> int:
    text = (ROOT / "src/gcry/raw_out.cr").read_text()
    match = LIMIT_DECL.search(text)
    if not match:
        sys.exit("FAIL: could not read LIMIT out of src/gcry/raw_out.cr")
    return int(match.group(1))


def size_of(spec: str, cap: int, consts: dict[str, int]) -> int | None:
    """Bytes a declaration reserves, or None when the size cannot be read.

    `consts` are the integer constants of the file the buffer is declared in,
    which is where a size like `ADDRESS_SPACE_READ_BLOCK` comes from.
    """
    if spec.isdigit():
        return int(spec)
    name = spec.split("::")[-1]
    if name == "LIMIT":
        return cap
    return consts.get(name)


def local_bound(text: str, cap: int) -> int | None:
    """How far this file's own writer will write, or None if it has none."""
    if not LOCAL_WRITER.search(text):
        return None
    found = [int(g) for m in LOCAL_BOUND.finditer(text) for g in m.groups() if g]
    # A writer whose bound is `LIMIT` rather than a literal is `RawOut` itself.
    return max(found) if found else cap


def main() -> int:
    cap = shared_limit()
    seen: set[str] = set()
    bad: list[str] = []
    unknown: list[str] = []
    for path in sorted(ROOT.glob("src/**/*.cr")) + sorted(ROOT.glob("bench/**/*.cr")):
        text = path.read_text()
        mine = local_bound(text, cap)
        if "RawOut." not in text and mine is None:
            continue
        # Every declaration, not the last one per name: a file reuses `buf` in
        # method after method, and the one that overflows is whichever line is
        # longest — not whichever was written last.
        decls: dict[str, list[tuple[str, int]]] = {}
        for m in DECL.finditer(text):
            decls.setdefault(m.group(1), []).append(
                (m.group(2), text[: m.start()].count("\n") + 1))
        consts = {m.group(1): int(m.group(2)) for m in CONST.finditer(text)}
        # `buf = raw.to_unsafe` then `RawOut.append(buf, ...)`: the pointer the
        # writer is handed is often one hop from the array that backs it. The
        # hop is followed *as well as* the name itself, never instead of it —
        # one method's `buf = raw.to_unsafe` must not hide the `buf` arrays
        # every other method in the file declares.
        alias = {m.group(1): m.group(2) for m in ALIAS.finditer(text)}
        written: list[tuple[str, int]] = [
            (m.group(1), cap) for m in SHARED_WRITE.finditer(text)]
        if mine is not None:
            written += [(m.group(1), mine) for m in LOCAL_WRITE.finditer(text)]
        for name, bound in sorted(set(written)):
            for backing in sorted({name, alias.get(name, name)}):
                for spec, line in decls.get(backing, ()):
                    where = f"{path.relative_to(ROOT)}:{line}"
                    if where in seen:
                        continue
                    seen.add(where)
                    size = size_of(spec, cap, consts)
                    if size is None:
                        unknown.append(
                            f"{where} {backing} = uninitialized UInt8[{spec}]")
                    elif size < bound:
                        bad.append(
                            f"{where} {backing} is {size} B, its writer stops at {bound}")

    if bad or unknown:
        print("FAIL: a line writer can write past the end of a buffer it is handed.")
        print("The writer bounds on its own limit and cannot see the buffer, so the")
        print("bytes past the end land on the stack frame around it.")
        for line in bad:
            print(f"  {line}")
        for line in unknown:
            print(f"  {line} — size is not a literal this check can read")
        return 1

    print(f"ok — {len(seen)} raw line buffers are all at least as big as the writer's limit "
          f"(RawOut: {cap} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
