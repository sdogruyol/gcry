#!/usr/bin/env python3
# Per-symbol machine-code comparison of two binaries: objdump -d, addresses,
# immediates and call targets normalised. Usage: mc_diff.py BASE VAR
import collections
import re
import subprocess
import sys


def funcs(path):
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-M", "intel", path],
                         capture_output=True, text=True, check=True).stdout
    fs = collections.OrderedDict()
    cur = None
    for line in out.splitlines():
        m = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if m:
            cur = m.group(1)
            fs[cur] = []
            continue
        if cur and "\t" in line:
            ins = line.split("\t", 1)[1]
            ins = re.sub(r"0x[0-9a-f]+", "X", ins)
            ins = re.sub(r"\b[0-9a-f]{4,}\b", "A", ins)
            ins = re.sub(r"<[^>]*>", "<>", ins)
            fs[cur].append(ins)
    return fs


b, w = funcs(sys.argv[1]), funcs(sys.argv[2])
print(f"functions: base {len(b)}, var {len(w)}")
for k in b:
    if k in w and b[k] != w[k]:
        print(f"changed: {k}: {len(b[k])} -> {len(w[k])}")
print("only in base:", [k for k in b if k not in w])
print("only in var:", [k for k in w if k not in b])
