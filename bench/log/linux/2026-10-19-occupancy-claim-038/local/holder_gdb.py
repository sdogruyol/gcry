import gdb, re
gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("set environment GCRY_TRACE_LARGE=1")
bp = gdb.Breakpoint("*0x%x" % 0, internal=True) if False else None
import os
gdb.execute("starti Knuckeotide > /dev/null 2> trace_large.txt")
pid0 = gdb.selected_inferior().pid
exe = os.path.realpath(gdb.current_progspace().filename)
base0 = None
for l in open("/proc/%d/maps" % pid0):
    if l.rstrip().endswith(exe):
        base0 = int(l.split("-")[0], 16); break
off = int(os.environ["SYMOFF"], 16)
gdb.execute("break *0x%x" % (base0 + off))
gdb.execute("ignore 1 %s" % os.environ.get("SKIP", "30"))
gdb.execute("continue")
lo = hi = None
for l in open("trace_large.txt"):
    if "payload=6100096" in l:
        b = int(re.search(r"base=(0x[0-9a-f]+)", l).group(1), 16)
        m = int(re.search(r"mapped=(\d+)", l).group(1))
        lo, hi = b, b + m
print("block range %x-%x" % (lo, hi))
sp = int(gdb.parse_and_eval("$sp"))
inf = gdb.selected_inferior()
# stack top: read /proc maps
pid = inf.pid
top = None
for l in open("/proc/%d/maps" % pid):
    if "[stack]" in l:
        top = int(l.split()[0].split("-")[1], 16)
hits = []
a = sp
mem = inf.read_memory(sp, top - sp).tobytes()
import struct
for i in range(0, len(mem) - 7, 8):
    v = struct.unpack_from("<Q", mem, i)[0]
    if lo <= v < hi:
        hits.append((sp + i, v))
print("hits", [(hex(s), hex(v)) for s, v in hits])
# frames
f = gdb.newest_frame()
frames = []
while f is not None:
    try:
        cfa = int(f.read_register("rsp"))
    except Exception:
        cfa = 0
    frames.append((f.level(), f.name(), cfa))
    f = f.older()
for lvl, name, rsp in frames:
    print("frame %d rsp=%x %s" % (lvl, rsp, name))
for s, v in hits:
    owner = None
    for lvl, name, rsp in frames:
        if rsp <= s:
            owner = (lvl, name)
    print("slot %x value %x -> frame %s" % (s, v, owner))
gdb.execute("kill")
