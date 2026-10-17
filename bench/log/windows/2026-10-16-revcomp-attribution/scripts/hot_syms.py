"""Addresses of Revcomp's hot functions in each binary of a perf-ab artifact.

usage: hot_syms.py SYMS_DIR [ARM...]

SYMS_DIR is the artifact's `syms/` (link maps on Windows, `nm -n` elsewhere).
Prints, per binary, each function's RVA and its offset mod 64, the cache-line
phase placement acts on, for the functions the timed section spends its time
in: the per-line loop, the String and IO::Memory methods it calls, and gcry's
allocation entry points. MSVC maps write Crystal's names with `.XX.` hex
escapes (`.2A.` is `*`); they are decoded before matching.
"""
import os, re, sys

HOT = [
    r"^\*Revcomp#revcomp<String>:",
    r"^\*String#tr<String, String>:String",
    r"^\*String#chomp:String",
    r"^\*String#size:Int32",
    r"^\*Slice\(UInt8\)@Slice\(T\)#\[\]<Int32, Int32>",
    r"^\*IO::Memory#write<Slice\(UInt8\)>",
    r"^\*IO::Memory@IO#write_string<Slice\(UInt8\)>",
    r"^\*Gcry::Heap#malloc_atomic<UInt64>",
    r"^\*Gcry::Heap#allocate:atomic:clear",
    r"^GC_malloc_atomic$",
    r"^GC_realloc$",
    r"^\*__placement_pad",
]


def demangle(s):
    return re.sub(r"\.([0-9A-F]{2})\.", lambda m: chr(int(m.group(1), 16)), s)


def load(path):
    out = {}
    with open(path, errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) >= 4 and re.fullmatch(r"0001:[0-9a-f]{8}", p[0]) and re.fullmatch(r"[0-9a-f]{16}", p[2]):
                # map, code section: "0001:000f24e0  name  00000001400f34e0 f  obj"
                name, addr = demangle(p[1]), int(p[2], 16)
            elif len(p) >= 3 and re.fullmatch(r"[0-9a-f]{8,16}", p[0]) and p[1] in "tT":
                name, addr = " ".join(p[2:]), int(p[0], 16)
            else:
                continue
            name = name.lstrip("_") if name.startswith("_GC") else name
            for pat in HOT:
                if re.search(pat, name) and pat not in out:
                    out[pat] = (name, addr)
    return out


d = sys.argv[1]
files = sorted(f for f in os.listdir(d) if f.endswith(".txt"))
if len(sys.argv) > 2:
    files = [f for f in files if f[:-4].removeprefix("ab-") in sys.argv[2:]]
for f in files:
    syms = load(os.path.join(d, f))
    print(f"\n{f[:-4]}")
    for pat in HOT:
        if pat in syms:
            name, addr = syms[pat]
            print(f"  {addr:#012x}  mod64={addr % 64:2d}  {name[:70]}")
