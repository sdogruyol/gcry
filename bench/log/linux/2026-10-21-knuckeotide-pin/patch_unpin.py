#!/usr/bin/env python3
"""Counterfactual binary: the same crystal-metric executable, with the dead
spill slots zeroed just before Knuckeotide's timed run.

    patch_unpin.py IN OUT SITE CAVE OFF[,OFF...]

SITE: address of the `call GC.collect` that opens the timed run inside
`Benchmark::run` (5-byte e8 rel32). CAVE: a function the Knuckeotide run never
executes (`Nbody#energy`), overwritten with

    movq $0, OFF+8(%rsp)   for each OFF   (+8: the call pushed a return address)
    jmp  <the original call target>

and SITE is retargeted to CAVE, so GC.collect still runs and returns to SITE+5
with nothing else changed: same layout, same code everywhere else. The zeroed
slots hold `res`, `res + 12` and `seq`, dead once the constructor returned.
Text virtual addresses equal file offsets in these PIE binaries (checked).
"""
import struct, sys

src, dst, site, cave = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), int(sys.argv[4], 16)
offs = [int(x, 16) for x in sys.argv[5].split(",")]
b = bytearray(open(src, "rb").read())
assert b[site] == 0xE8, "SITE is not a call rel32"
target = site + 5 + struct.unpack_from("<i", b, site + 1)[0]
code = bytearray()
for o in offs:
    d = o + 8
    assert d < 0x80
    code += bytes([0x48, 0xC7, 0x44, 0x24, d, 0, 0, 0, 0])
code += b"\xe9" + struct.pack("<i", target - (cave + len(code) + 5))
b[cave:cave + len(code)] = code
struct.pack_into("<i", b, site + 1, cave - (site + 5))
open(dst, "wb").write(b)
print("call 0x%x -> cave 0x%x (%d bytes) -> 0x%x" % (site, cave, len(code), target))
