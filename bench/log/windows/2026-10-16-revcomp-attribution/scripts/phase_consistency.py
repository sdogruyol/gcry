"""Which functions' placement is consistent with how fast a set of builds ran?

usage: phase_consistency.py MOD [--both FILE] LABEL=CLASS=OBJ[=MAP]...

One argument per build: CLASS is how fast its Revcomp timed section ran
(`fast`, `mid`, `slow`: from the A/B), OBJ a Windows cross-compile of its
source (`crystal build -Dgc_none --release --cross-compile --target
x86_64-pc-windows-msvc main.cr -o m`), which gives each function's code, and
MAP, if given, the runner's link map for that build, which gives where the
function landed (placement-probe arms share their source's code; without a
MAP the object's offsets are used, which match the runner's for unpadded
builds: obj_phase.py).

A function is consistent if no two builds that lay it out the same way (same
layout signature, objlayout.py) at the same offset mod MOD ran in different
classes; `agree` counts the pairs that share code and phase and class. A
function every build carries differently is consistent trivially (agree=0).
Prints the count and the functions Revcomp's timed section runs. With
--both FILE, the consistent names are intersected with FILE's (when it
exists) and written back, so runs on several CPUs narrow one list together.
"""
import os, re, sys
from itertools import combinations

from objlayout import demangle, functions

HOT = r"^\*(Gcry::Heap#malloc_atomic|Gcry::Heap#allocate|String#tr<|String#size:|String#chomp|Revcomp#|IO::Memory#write<Slice|IO::Memory@IO#write_string|Slice\(UInt8\)@Slice\(T\)#\[\]<Int32, Int32>)|^GC_malloc_atomic$"


def bodies(obj):
    """name -> (offset, layout signature)."""
    return {n: (off, sig) for n, (off, _, sig) in functions(obj).items()}


def map_offsets(path):
    out = {}
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) >= 4 and re.fullmatch(r"0001:[0-9a-f]{8}", p[0]) and re.fullmatch(r"[0-9a-f]{16}", p[2]):
            out.setdefault(demangle(p[1]), int(p[0][5:], 16))
    return out


args = sys.argv[1:]
mod = int(args.pop(0))
both = None
if args[0] == "--both":
    args.pop(0)
    both = args.pop(0)
cache, builds = {}, []
for a in args:
    label, cls, obj, *mp = a.split("=")
    if obj not in cache:
        cache[obj] = bodies(obj)
    b = cache[obj]
    if mp:
        offs = map_offsets(mp[0])
        f = {n: (offs[n], b[n][1]) for n in offs if n in b}
    else:
        f = b
    builds.append((label, cls, f))
common = set.intersection(*(set(b[2]) for b in builds))
rows = []
for name in common:
    agree = clash = 0
    for (_, c1, f1), (_, c2, f2) in combinations(builds, 2):
        (a1, h1), (a2, h2) = f1[name], f2[name]
        if h1 == h2 and a1 % mod == a2 % mod:
            if c1 == c2:
                agree += 1
            else:
                clash += 1
    rows.append((clash, -agree, name))
rows.sort()
good = {r[2] for r in rows if r[0] == 0}
print(f"{len(builds)} builds, {len(common)} functions in all, mod {mod}: {len(good)} consistent, "
      f"{sum(1 for r in rows if r[0] == 0 and r[1] < 0)} of them with agreeing pairs")
print("functions on Revcomp's timed path:")
for clash, nagree, name in rows:
    if re.search(HOT, name):
        print(f"  {'consistent' if clash == 0 else 'excluded  '} clash={clash:3d} agree={-nagree:3d} {name[:80]}")
if both:
    inter = sorted(good & set(open(both).read().splitlines())) if os.path.exists(both) else sorted(good)
    print(f"\nconsistent in every set so far ({both}): {len(inter)}")
    for n in inter:
        print(f"  {'HOT ' if re.search(HOT, n) else '    '}{n}")
    with open(both, "w") as f:
        f.write("".join(n + "\n" for n in inter))
