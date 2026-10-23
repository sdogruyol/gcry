# gdb -q -batch -x holders_boehm.py   (env: BIN, RES_PC = offset of the
# instruction after Knuckeotide#initialize's `IO::Memory#to_s` call, i.e. where
# `res`, the 6.1 MB Fasta output String, is in %rax; ENVS)
#
# Boehm build of crystal-metric. At the entry of every GC_finish_collection
# (marking done, nothing reclaimed yet): is `res` marked (GC_is_marked), and
# which words of the main stack [sp, stack top) or registers point into it?
import gdb, os, struct

gdb.execute("set pagination off")
gdb.execute("set confirm off")
# Boehm suspends threads (Crystal's SYSMON among them) with SIGPWR / SIGXCPU.
gdb.execute("handle SIGPWR nostop noprint pass")
gdb.execute("handle SIGXCPU nostop noprint pass")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
exe = os.environ["BIN"]
gdb.execute("file %s" % exe)
gdb.execute("starti Knuckeotide > /dev/null")
inf = gdb.selected_inferior()
pid = inf.pid
real = os.path.realpath(exe)
base0 = None
for l in open("/proc/%d/maps" % pid):
    if l.rstrip().endswith(real):
        base0 = int(l.split("-")[0], 16)
        break
syms = {}
for l in os.popen("nm %s" % exe):
    p = l.split()
    if len(p) == 3:
        syms[p[2]] = int(p[0], 16)
b_res = gdb.Breakpoint("*0x%x" % (base0 + int(os.environ["RES_PC"], 16)))
# Optional: SEQ_PC (the `GC_gcollect` call opening the timed run) and SEQ_EXPR
# (a gdb expression for the seq IO::Memory's buffer there, read through the
# dead `seq` spill slot), to report that buffer's mark bit as well.
seq_pc = base0 + int(os.environ["SEQ_PC"], 16) if os.environ.get("SEQ_PC") else None
if seq_pc:
    gdb.Breakpoint("*0x%x" % seq_pc)
seq = None
b_fin = gdb.Breakpoint("*0x%x" % (base0 + syms["GC_finish_collection"]))
b_clear = None
if os.environ.get("CLEAR") == "1":
    b_clear = gdb.Breakpoint("*0x%x" % (base0 + syms["GC_clear_stack_inner"]))
print("version 0x%x" % int(gdb.parse_and_eval("(unsigned)GC_get_version()")))
res = None
size = 0
n = 0
clears = 0
last = None
while True:
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if inf.pid == 0 or not inf.threads():
        break
    pc = int(gdb.parse_and_eval("$pc"))
    if pc == base0 + int(os.environ["RES_PC"], 16):
        res = int(gdb.parse_and_eval("$rax"))
        size = int(gdb.parse_and_eval("(unsigned long)GC_size((void*)%d)" % res))
        print("res 0x%x GC_size %d at collection %d" % (res, size, n))
        continue
    if seq_pc is not None and pc == seq_pc:
        seq = int(gdb.parse_and_eval(os.environ["SEQ_EXPR"])) & 0xFFFFFFFFFFFFFFFF
        print("seq buffer 0x%x GC_size %d at collection %d" % (seq, int(gdb.parse_and_eval("(unsigned long)GC_size((void*)%d)" % seq)), n))
        continue
    if b_clear is not None and pc == base0 + syms["GC_clear_stack_inner"]:
        clears += 1
        continue
    n += 1
    if res is None:
        continue
    marked = int(gdb.parse_and_eval("(int)GC_is_marked((void*)%d)" % res))
    seq_marked = int(gdb.parse_and_eval("(int)GC_is_marked((void*)%d)" % seq)) if seq else -1
    sp = int(gdb.parse_and_eval("$sp"))
    top = None
    for l in open("/proc/%d/maps" % pid):
        if "[stack]" in l:
            top = int(l.split()[0].split("-")[1], 16)
    mem = inf.read_memory(sp, top - sp).tobytes()
    words = struct.unpack_from("<%dQ" % (len(mem) // 8), mem)
    hits = [(sp + 8 * i, w) for i, w in enumerate(words) if res <= w < res + size]
    frames = []
    f = gdb.newest_frame()
    while f is not None:
        try:
            frsp = int(f.read_register("rsp"))
        except Exception:
            frsp = 0
        frames.append((f.level(), f.name() or "?", frsp, int(f.pc())))
        f = f.older()
    key = (marked, seq_marked, tuple(s for s, _ in hits))
    if key == last:
        continue
    last = key
    print("coll %d res marked=%d seq_buffer marked=%d stack_hits=%d clears=%d" % (n, marked, seq_marked, len(hits), clears))
    for s, w in hits:
        owner = None
        for lvl, name, frsp, fpc in frames:
            if frsp <= s:
                owner = (lvl, name, frsp, fpc)
        print("    slot 0x%x -> +0x%x frame %d %s sp=0x%x+0x%x pc=+0x%x" % (s, w - res, owner[0], owner[1], owner[2], s - owner[2], owner[3] - base0))
    if os.environ.get("FRAMES") == "1":
        for lvl, name, frsp, fpc in frames:
            print("  frame %d sp=0x%x pc=+0x%x %s" % (lvl, frsp, fpc - base0, name))
print("collections seen", n, "clears", clears)
