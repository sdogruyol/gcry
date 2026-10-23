# gdb -q -batch -x holders_gcry.py   (env: BIN, TRACE, BENCH, MINPAY, ENVS)
#
# At the entry of every `Gcry::Heap#run_collection_body` (the collection, after
# the world is stopped and before the mark), for every large block of at least
# MINPAY bytes that GCRY_TRACE_LARGE has reported mapped: is its chunk FREED,
# and which words of the collecting (main) thread's stack, [sp, stack top), or
# of its registers, point into it? Each hit is attributed to the innermost
# frame whose SP is at or below the slot, with the slot's offset from that SP.
import gdb, os, re, struct

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("set environment GCRY_TRACE_LARGE=1")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
exe = os.environ["BIN"]
trace = os.environ["TRACE"]
bench = os.environ.get("BENCH", "Knuckeotide")
minpay = int(os.environ.get("MINPAY", "1000000"))
gdb.execute("file %s" % exe)
gdb.execute("starti %s > /dev/null 2> %s" % (bench, trace))
inf = gdb.selected_inferior()
pid = inf.pid
real = os.path.realpath(exe)
base0 = None
for l in open("/proc/%d/maps" % pid):
    if l.rstrip().endswith(real):
        base0 = int(l.split("-")[0], 16)
        break
sym = None
for l in os.popen("nm %s" % exe):
    if "Gcry::Heap#run_collection_body" in l:
        sym = int(l.split()[0], 16)
gdb.execute("break *0x%x" % (base0 + sym))

REGS = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]


def blocks():
    out = {}
    for l in open(trace):
        m = re.search(r"large (map|grow) base=(0x[0-9a-f]+) mapped=(\d+)(?:->(\d+))? payload=(\d+) coll=(\d+)", l)
        if not m:
            continue
        b = int(m.group(2), 16)
        mapped = int(m.group(4) or m.group(3))
        pay = int(m.group(5))
        if m.group(1) == "map":
            out[b] = dict(mapped=mapped, payload=pay, born=int(m.group(6)))
        elif b in out:
            out[b]["mapped"] = mapped
            out[b]["payload"] = pay
    return {b: v for b, v in out.items() if v["payload"] >= minpay}


n = 0
last = {}
while True:
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if inf.pid == 0 or not inf.is_valid() or not inf.threads():
        break
    n += 1
    sp = int(gdb.parse_and_eval("$sp"))
    top = None
    for l in open("/proc/%d/maps" % pid):
        if "[stack]" in l:
            top = int(l.split()[0].split("-")[1], 16)
    mem = inf.read_memory(sp, top - sp).tobytes()
    words = struct.unpack_from("<%dQ" % (len(mem) // 8), mem)
    regs = {r: int(gdb.parse_and_eval("$" + r)) & 0xFFFFFFFFFFFFFFFF for r in REGS}
    frames = []
    f = gdb.newest_frame()
    while f is not None:
        try:
            frsp = int(f.read_register("rsp"))
        except Exception:
            frsp = 0
        frames.append((f.level(), f.name() or "?", frsp, int(f.pc())))
        f = f.older()
    for b, v in sorted(blocks().items()):
        try:
            flags = struct.unpack("<I", inf.read_memory(b + 20, 4).tobytes())[0]
            state = "FREED" if flags & 2048 else "used"
        except Exception:
            state = "unmapped"
        lo, hi = b, b + v["mapped"]
        hits = [(sp + 8 * i, w) for i, w in enumerate(words) if lo <= w < hi]
        rhits = [r for r, w in regs.items() if lo <= w < hi]
        key = (state, tuple(s for s, _ in hits), tuple(rhits))
        if last.get(b) == key:
            continue
        last[b] = key
        print("coll %d block 0x%x payload=%d born=%d %s stack_hits=%d regs=%s" % (n, b, v["payload"], v["born"], state, len(hits), rhits))
        for s, w in hits:
            owner = None
            for lvl, name, frsp, pc in frames:
                if frsp <= s:
                    owner = (lvl, name, frsp, pc)
            if owner:
                print("    slot 0x%x -> 0x%x (+0x%x) frame %d %s sp=0x%x+0x%x pc=+0x%x" % (s, w, w - lo, owner[0], owner[1], owner[2], s - owner[2], owner[3] - base0))
            else:
                print("    slot 0x%x -> 0x%x (+0x%x) frame ?" % (s, w, w - lo))
    if n == 1 or os.environ.get("FRAMES_EVERY") == "1":
        for lvl, name, frsp, pc in frames:
            print("  frame %d sp=0x%x pc=+0x%x %s" % (lvl, frsp, pc - base0, name))
print("collections seen", n)
