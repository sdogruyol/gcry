# gdb -q -batch -x holders2.py   (env: BIN, TRACE, BENCH, PAYLOAD, COLLS, ENVS)
#
# Indirect holders of one large block. At the entry of every
# `Gcry::Heap#run_collection_body` listed in COLLS (1-based collection index,
# comma separated), take the large block whose GCRY_TRACE_LARGE payload is
# PAYLOAD (the latest such map), and search backwards from the main thread's
# stack and registers: a root word w is a holder at depth 1 if one of the
# first 16 words at w points into the block, at depth 2 if one of the first 16
# words of an object one of w's first 16 words points at does, and so on to
# depth 3. Each holder is reported with its frame, slot offset and the path.
import gdb, os, re, struct

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("set environment GCRY_TRACE_LARGE=1")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
exe = os.environ["BIN"]
trace = os.environ["TRACE"]
bench = os.environ.get("BENCH", "RegexDna")
payload = int(os.environ["PAYLOAD"])
colls = set(int(x) for x in os.environ["COLLS"].split(","))
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
NW = 16


def target():
    blk = None
    for l in open(trace):
        m = re.search(r"large (map|grow) base=(0x[0-9a-f]+) mapped=(\d+)(?:->(\d+))? payload=(\d+) coll=(\d+)", l)
        if m and int(m.group(5)) == payload:
            blk = (int(m.group(2), 16), int(m.group(4) or m.group(3)), int(m.group(6)))
    return blk


def readable():
    rs = []
    for l in open("/proc/%d/maps" % pid):
        a, perm = l.split()[0], l.split()[1]
        if perm.startswith("r"):
            lo, hi = (int(x, 16) for x in a.split("-"))
            rs.append((lo, hi))
    return rs


cache = {}


def words_at(addr, rs):
    if addr in cache:
        return cache[addr]
    res = None
    if addr % 8 == 0:
        for lo, hi in rs:
            if lo <= addr and addr + NW * 8 <= hi:
                try:
                    res = struct.unpack("<%dQ" % NW, inf.read_memory(addr, NW * 8).tobytes())
                except Exception:
                    res = None
                break
    cache[addr] = res
    return res


def holds(w, lo, hi, rs, depth, path):
    """Path (list of addrs) from w to the block, or None."""
    if lo <= w < hi:
        return path + [w]
    if depth == 0:
        return None
    ws = words_at(w, rs)
    if ws is None:
        return None
    for u in ws:
        if u == w or u < 0x10000:
            continue
        p = holds(u, lo, hi, rs, depth - 1, path + [w])
        if p:
            return p
    return None


n = 0
while True:
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if inf.pid == 0 or not inf.is_valid() or not inf.threads():
        break
    n += 1
    if n not in colls:
        continue
    blk = target()
    if blk is None:
        print("coll %d: block not mapped yet" % n)
        continue
    lo, hi = blk[0], blk[0] + blk[1]
    try:
        flags = struct.unpack("<I", inf.read_memory(lo + 20, 4).tobytes())[0]
        state = "FREED" if flags & 2048 else "used"
    except Exception:
        state = "unmapped"
    cache.clear()
    rs = readable()
    sp = int(gdb.parse_and_eval("$sp"))
    top = None
    for l in open("/proc/%d/maps" % pid):
        if "[stack]" in l:
            top = int(l.split()[0].split("-")[1], 16)
    mem = inf.read_memory(sp, top - sp).tobytes()
    words = struct.unpack_from("<%dQ" % (len(mem) // 8), mem)
    frames = []
    f = gdb.newest_frame()
    while f is not None:
        try:
            frsp = int(f.read_register("rsp"))
        except Exception:
            frsp = 0
        frames.append((f.level(), f.name() or "?", frsp, int(f.pc())))
        f = f.older()
    print("coll %d block 0x%x payload=%d born=%d %s" % (n, lo, payload, blk[2], state))
    for r in REGS:
        w = int(gdb.parse_and_eval("$" + r)) & 0xFFFFFFFFFFFFFFFF
        p = holds(w, lo, hi, rs, 3, [])
        if p:
            print("    reg %s path %s" % (r, " -> ".join("0x%x" % x for x in p)))
    for i, w in enumerate(words):
        s = sp + 8 * i
        if sp <= w < top:
            continue
        p = holds(w, lo, hi, rs, 3, [])
        if not p:
            continue
        owner = None
        for lvl, name, frsp, pc in frames:
            if frsp <= s:
                owner = (lvl, name, frsp, pc)
        print("    slot 0x%x frame %s path %s" % (s, "%d %s sp+0x%x pc=+0x%x" % (owner[0], owner[1], s - owner[2], owner[3] - base0) if owner else "?",
                                              " -> ".join("0x%x" % x for x in p)))
    for lvl, name, frsp, pc in frames:
        print("  frame %d sp=0x%x pc=+0x%x %s" % (lvl, frsp, pc - base0, name))
print("collections seen", n)
