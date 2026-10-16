"""Phase and layout of chosen functions in Windows objects cross-compiled here.

usage: obj_phase.py FUNC_REGEX LABEL=path/to/m.obj...

`crystal build -Dgc_none --release --cross-compile --target
x86_64-pc-windows-msvc main.cr -o m` writes the object link.exe gets on the
runner. A release build is one `.text` section, the link puts it first at
RVA 0x1000, and every function's offset in the object matched the runner's
link map (1 421 of 1 421 for v0.36.0). So a function's offset mod 64 here is
its cache-line phase in the binary the runner timed.

Per object and matching function: offset, offset mod 64, size and layout
signature (objlayout.py: same signature, same code byte for byte but for
constants and call targets).
"""
import re, sys

from objlayout import functions

pat = re.compile(sys.argv[1])
for arg in sys.argv[2:]:
    label, obj = arg.split("=", 1)
    for name, (off, size, sig) in sorted(functions(obj).items(), key=lambda kv: kv[1][0]):
        if pat.search(name):
            print(f"{label:10} {off:#9x} mod64={off % 64:2d} size={size:5d} layout={sig}  {name[:60]}")
