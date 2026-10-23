# gdb -q -batch -x hj.py   (env: BIN, TRACE, BENCH, OLD_PAYLOAD, AFTER_MAPPED, ENVS, ASLR)
#
# JsonGenerate's high peak: who holds the IO::Memory buffer the last doubling
# left behind? At the entry of the first `Gcry::Heap#run_collection_body` after
# the large map with mapped=AFTER_MAPPED (the 256 MiB buffer, i.e. after
# `run`), search every thread's stack and registers, and the binary's writable
# segments, for words from which the block with GCRY_TRACE_LARGE payload
# OLD_PAYLOAD is reachable in <= 3 hops (first 16 words of each object). At
# the next collection's entry report whether that block was freed (retained =
# the high-peak mode). ASLR stays on unless ASLR=0, because the mode is rare
# without it.
import gdb, os, re, struct

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGPWR SIGXCPU SIGUSR1 SIGUSR2 SIGSEGV nostop noprint pass")
if os.environ.get("ASLR", "1") != "0":
    gdb.execute("set disable-randomization off")
gdb.execute("set environment GCRY_TRACE_LARGE=1")
gdb.execute("set environment SILENT=1")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
exe = os.environ["BIN"]
trace = os.environ["TRACE"]
bench = os.environ.get("BENCH", "JsonGenerate")
old_payload = int(os.environ.get("OLD_PAYLOAD", "134217729"))
after_mapped = int(os.environ.get("AFTER_MAPPED", "268439552"))
gdb.execute("file %s" % exe)
gdb.execute("starti %s > /dev/null 2> %s" % (bench, trace))
inf = gdb.selected_inferior()
pid = inf.pid
real = os.path.realpath(exe)
base0 = None
segs = []
for l in open("/proc/%d/maps" % pid):
    if l.rstrip().endswith(real):
        lo = int(l.split("-")[0], 16)
        if base0 is None:
            base0 = lo
sym = None
for l in os.popen("nm %s" % exe):
    if "Gcry::Heap#run_collection_body" in l:
        sym = int(l.split()[0], 16)
gdb.execute("break *0x%x" % (base0 + sym))
ARCH_X86 = "x86" in gdb.execute("show architecture", to_string=True)
REGS = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"] if ARCH_X86 else ["x%d" % i for i in range(31)]
SPREG = "rsp" if ARCH_X86 else "sp"
NW = 16
DEPTH = int(os.environ.get("DEPTH", "1"))


def trace_lines():
    return open(trace).read().splitlines()


def find_block():
    blk = None
    for l in trace_lines():
        m = re.search(r"large (map|grow) base=(0x[0-9a-f]+) mapped=(\d+)(?:->(\d+))? payload=(\d+) coll=(\d+)", l)
        if m and int(m.group(5)) == old_payload:
            blk = (int(m.group(2), 16), int(m.group(4) or m.group(3)))
    return blk


def after_run():
    return any(("mapped=%d " % after_mapped) in l for l in trace_lines())


def maps():
    out = []
    for l in open("/proc/%d/maps" % pid):
        f = l.split()
        lo, hi = (int(x, 16) for x in f[0].split("-"))
        out.append((lo, hi, f[1], f[5] if len(f) > 5 else ""))
    return out


cache = {}


def words_at(addr, rs):
    if addr in cache:
        return cache[addr]
    res = None
    if addr % 8 == 0:
        for lo, hi, perm, _ in rs:
            if perm.startswith("r") and lo <= addr and addr + NW * 8 <= hi:
                try:
                    res = struct.unpack("<%dQ" % NW, inf.read_memory(addr, NW * 8).tobytes())
                except Exception:
                    res = None
                break
    cache[addr] = res
    return res


def holds(w, lo, hi, rs, depth, path):
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


def scan_range(label, a, b, lo, hi, rs, depth, frames=None):
    try:
        mem = inf.read_memory(a, b - a).tobytes()
    except Exception:
        # A thread stack's mapping can run into its guard: read what reads.
        mem = b""
        p = a
        while p < b:
            try:
                mem += inf.read_memory(p, 4096 - (p % 4096)).tobytes()
            except Exception:
                break
            p += 4096 - (p % 4096)
    words = struct.unpack_from("<%dQ" % (len(mem) // 8), mem)
    for i, w in enumerate(words):
        s = a + 8 * i
        if a <= w < b:
            continue
        p = holds(w, lo, hi, rs, depth, [])
        if not p:
            continue
        owner = ""
        if frames:
            o = None
            for lvl, name, frsp, pc in frames:
                if frsp <= s:
                    o = (lvl, name, frsp, pc)
            if o:
                owner = " frame %d %s sp+0x%x pc=+0x%x" % (o[0], o[1], s - o[2], o[3] - base0)
        print("    %s slot 0x%x%s path %s" % (label, s, owner, " -> ".join("0x%x" % x for x in p)))


stage = 0
n = 0
blk = None
while True:
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if inf.pid == 0 or not inf.is_valid() or not inf.threads():
        break
    n += 1
    if stage == 0:
        if not after_run():
            continue
        blk = find_block()
        lo, hi = blk[0], blk[0] + blk[1]
        print("coll %d (first after run): old block 0x%x..0x%x" % (n, lo, hi))
        cache.clear()
        rs = maps()
        cur = gdb.selected_thread()
        for t in inf.threads():
            t.switch()
            sp = int(gdb.parse_and_eval("$" + SPREG)) & 0xFFFFFFFFFFFFFFFF
            frames = []
            f = gdb.newest_frame()
            while f is not None:
                try:
                    frames.append((f.level(), f.name() or "?", int(f.read_register(SPREG)), int(f.pc())))
                except Exception:
                    pass
                f = f.older()
            top = None
            for mlo, mhi, perm, name in rs:
                if mlo <= sp < mhi:
                    top = mhi
            print("  thread %d lwp %d sp=0x%x top=0x%x (%d KiB) %s" % (t.num, t.ptid[1], sp, top or 0, ((top or sp) - sp) // 1024, frames[0][1] if frames else "?"))
            for r in REGS:
                try:
                    w = int(gdb.parse_and_eval("$" + r)) & 0xFFFFFFFFFFFFFFFF
                except Exception:
                    continue
                p = holds(w, lo, hi, rs, DEPTH, [])
                if p:
                    print("    reg %s path %s" % (r, " -> ".join("0x%x" % x for x in p)))
            if top:
                scan_range("stack", sp, top, lo, hi, rs, DEPTH if t.num == 1 else 1, frames)
            if t.num == 1:
                for lvl, name, frsp, pc in frames[:40]:
                    print("      frame %d sp=0x%x pc=+0x%x %s" % (lvl, frsp, pc - base0, name))
        cur.switch()
        for mlo, mhi, perm, name in rs:
            if name == real and "w" in perm:
                scan_range("static", mlo, mhi, lo, hi, rs, 1)
        stage = 1
        continue
    if stage == 1:
        lo = blk[0]
        try:
            flags = struct.unpack("<I", inf.read_memory(lo + 20, 4).tobytes())[0]
            state = "FREED" if flags & 2048 else "RETAINED"
        except Exception:
            state = "UNMAPPED (freed)"
        print("coll %d: old block %s" % (n, state))
        stage = 2
print("collections seen", n)
