#!/usr/bin/env python3
"""Instrument Crystal LLVM IR with ASan, and require a failing UAF control.

-Dasan alone is only a Crystal conditional flag. It neither instruments loads
nor links a sanitizer runtime. This Linux check uses Clang's ASan pass on
functions explicitly tagged sanitize_address, then links the ASan runtime.
The focused specs avoid conservative stack scanning, which intentionally reads
stack regions that ASan considers poisoned. This is not full-heap GC poisoning.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def build(source, output, crystal, clang, flags):
    command = [crystal, "build", *flags, "--single-module", "--emit", "llvm-ir",
               "--verbose", "--error-trace", str(source), "-o", str(output)]
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        print(result.stdout + result.stderr, file=sys.stderr)
        result.check_returncode()
    # Preserve the compiler's dependency/library choices when replacing its
    # object with the instrumented IR. Never execute the printed shell command.
    links = [shlex.split(line) for line in result.stdout.splitlines()
             if " -o " in line and str(output) in line]
    if not links:
        raise RuntimeError("Crystal did not print its link command")
    link = links[-1]
    libs = link[link.index("-o") + 2:]
    ir = output.with_suffix(".ll")
    lines = []
    functions = 0
    for line in ir.read_text().splitlines():
        if line.startswith("define "):
            line, count = re.subn(
                r"\) (?=(?:local_unnamed_addr|unnamed_addr|#|!dbg|personality|\{))",
                ") sanitize_address ", line, count=1)
            if count != 1:
                raise RuntimeError(f"Cannot instrument function: {line}")
            functions += 1
        lines.append(line)
    if not functions:
        raise RuntimeError("No LLVM functions were instrumented")
    ir.write_text("\n".join(lines) + "\n")
    subprocess.run([clang, "-x", "ir", str(ir), "-fsanitize=address", "-g", "-O1",
                    "-o", str(output), *libs], cwd=ROOT, check=True)
    print(f"ASan: instrumented {functions} functions in {source}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--crystal", default=os.environ.get("CRYSTAL", "crystal"))
    parser.add_argument("--clang", default=os.environ.get("CLANG", "clang-19"))
    parser.add_argument("--source", type=Path, default=ROOT / "ci" / "asan_specs.cr")
    args = parser.parse_args()
    out = ROOT / "bin" / "asan"
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:halt_on_error=1")
    control = out / "control"
    build(ROOT / "ci" / "asan_control.cr", control, args.crystal, args.clang, [])
    result = subprocess.run([str(control)], cwd=ROOT, env=env, text=True,
                            capture_output=True, timeout=60)
    report = result.stdout + result.stderr
    (out / "control.txt").write_text(report)
    if result.returncode == 0 or "ERROR: AddressSanitizer: heap-use-after-free" not in report:
        raise RuntimeError("ASan control did not detect the intentional use-after-free")
    print("ASan control: intentional heap-use-after-free detected", flush=True)
    for name, flags in [("header", []), ("headerless", ["-Dgcry_headerless"])]:
        binary = out / name
        build(args.source.resolve(), binary, args.crystal, args.clang, flags)
        subprocess.run([str(binary)], cwd=ROOT, env=env, timeout=120, check=True)


if __name__ == "__main__":
    main()
