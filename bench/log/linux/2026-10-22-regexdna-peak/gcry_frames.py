# gdb -q -batch -x gcry_frames.py
#   env: BIN, BENCH, MODE=ctl|hide, LOG, [ENVS="K=V ..."], [ONLY=<regex on the
#   frame's function>], [VERBOSE=1: every word], [OUT=stdout file],
#   [TRACE=stderr file]
#
# Upper bound of "no stale word in gcry's own frames". At the entry of every
# `Gcry::Heap#run_collection_body` (world stopped, before the mark) walk the
# collecting thread's physical frames from the collector up to the first
# frame that is not gcry's (`Gcry::*`, `GC::*`): the allocation entry and the
# slow path an allocation-triggered collection runs on. In each, every word
# outside the prologue's callee-saved pushes (the mutator's registers, which
# are real roots) that holds an address in an anonymous mapping is counted,
# and with MODE=hide zeroed for the collection and restored when
# `run_collection_body` returns, before any of those frames runs again. Those
# words are gcry's own spills and slots no instruction on the slow path wrote;
# at an allocation-triggered collection none of them is a mutator object the
# program still uses (GC.realloc's pointer would be, and is reported). At
# `_exit`, VmHWM is printed. MODE=ctl stops at the same two points per
# collection and changes nothing: the pace reads pause time, so an arm with
# fewer ptrace stops would collect on a different schedule.
import gdb, os, re, struct, subprocess

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGPWR SIGXCPU SIGUSR1 SIGUSR2 nostop noprint pass")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
exe = os.environ["BIN"]
bench = os.environ.get("BENCH", "RegexDna")
mode = os.environ.get("MODE", "ctl")
log = open(os.environ.get("LOG", "/dev/stdout"), "w")
gdb.execute("file %s" % exe)
gdb.execute("starti %s > %s 2> %s" % (bench, os.environ.get("OUT", "/dev/null"), os.environ.get("TRACE", "/dev/null")))
inf = gdb.selected_inferior()
pid = inf.pid
real = os.path.realpath(exe)
base0 = None
for l in open("/proc/%d/maps" % pid):
    if l.rstrip().endswith(real):
        base0 = int(l.split("-")[0], 16)
        break

syms = []
for l in subprocess.run(["nm", "-C", "-n", "--defined-only", exe], capture_output=True, text=True).stdout.splitlines():
    p = l.split(" ", 2)
    if len(p) == 3 and p[1] in "tT":
        syms.append((int(p[0], 16), p[2]))
addrs = [a for a, _ in syms]
import bisect


def sym_of(pc):
    i = bisect.bisect_right(addrs, pc - base0) - 1
    return syms[i] if i >= 0 else (0, "?")


pushes = {}


def npush(start):
    if start in pushes:
        return pushes[start]
    out = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "--start-address=0x%x" % start,
                          "--stop-address=0x%x" % (start + 64), exe], capture_output=True, text=True).stdout
    n = 0
    for l in out.splitlines():
        m = re.match(r"\s+[0-9a-f]+:\s+(\S+)", l)
        if not m:
            continue
        if m.group(1) == "push":
            n += 1
        elif m.group(1) in ("endbr64",):
            continue
        else:
            break
    pushes[start] = n
    return n


body = None
for a, n in syms:
    if "Gcry::Heap#run_collection_body" in n:
        body = a
gdb.execute("break *0x%x" % (base0 + body))
gdb.execute("break _exit")


def anon_ranges():
    rs = []
    for l in open("/proc/%d/maps" % pid):
        f = l.split()
        if len(f) == 5 or (len(f) == 6 and f[5] == ""):
            lo, hi = (int(x, 16) for x in f[0].split("-"))
            rs.append((lo, hi))
    rs.sort()
    return rs


def in_ranges(w, rs, los):
    i = bisect.bisect_right(los, w) - 1
    return i >= 0 and rs[i][0] <= w < rs[i][1]


def gcry_name(n):
    return "Gcry::" in n or n.startswith("*GC::") or n.startswith("GC::")


n = 0
tot_hidden = 0
ret_bp = None
ret_addr = None
saved = []
while True:
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if inf.pid == 0 or not inf.is_valid() or not inf.threads():
        break
    pc = int(gdb.parse_and_eval("$pc"))
    if pc == base0 + body:
        n += 1
        rs = anon_ranges()
        los = [r[0] for r in rs]
        # physical frames
        frames = []
        f = gdb.newest_frame()
        while f is not None:
            if f.type() != gdb.INLINE_FRAME:
                frames.append((int(f.read_register("rsp")), int(f.pc())))
            f = f.older()
        hidden = []
        names = []
        for i in range(1, len(frames) - 1):
            sp, fpc = frames[i]
            start, name = sym_of(fpc)
            if not gcry_name(name):
                break
            cfa = frames[i + 1][0]
            top = cfa - 8 - 8 * npush(start)
            names.append(name.split("<")[0].lstrip("*"))
            if top <= sp:
                continue
            mem = inf.read_memory(sp, top - sp).tobytes()
            for k, w in enumerate(struct.unpack_from("<%dQ" % ((top - sp) // 8), mem)):
                if in_ranges(w, rs, los) and re.search(os.environ.get("ONLY", "."), name):
                    hidden.append((sp + 8 * k, w, name))
        if any("realloc" in nm for nm in names):
            log.write("coll %d REALLOC on path %s\n" % (n, names))
        log.write("coll %d frames %s words %d\n" % (n, " < ".join(names), len(hidden)))
        if os.environ.get("VERBOSE") == "1":
            for a, w, nm in hidden:
                fsp = [f for f in frames if f[0] <= a][-1][0]
                log.write("    0x%x (sp+0x%x) = 0x%x in %s\n" % (a, a - fsp, w, nm.split("<")[0]))
        tot_hidden += len(hidden)
        # Both modes stop again where `run_collection_body` returns, so the
        # control pays the same ptrace stops (the pacing reads pause time).
        saved = [(a, w) for a, w, _ in hidden]
        if mode == "hide":
            for a, _ in saved:
                inf.write_memory(a, struct.pack("<Q", 0))
        ret = struct.unpack("<Q", inf.read_memory(int(gdb.parse_and_eval("$sp")), 8).tobytes())[0]
        ret_addr = ret
        ret_bp = gdb.Breakpoint("*0x%x" % ret, internal=True)
    elif ret_addr is not None and pc == ret_addr:
        if mode == "hide":
            for a, w in saved:
                inf.write_memory(a, struct.pack("<Q", w))
        saved = []
        ret_bp.delete()
        ret_bp = None
        ret_addr = None
    else:
        why = gdb.execute("info program", to_string=True)
        if "breakpoint 2" not in why:
            log.write("other stop: %s\n" % why.strip().replace("\n", " | "))
            continue
        hwm = rss = None
        for l in open("/proc/%d/status" % pid):
            if l.startswith("VmHWM:"):
                hwm = int(l.split()[1])
        log.write("exit: collections %d words_seen %d VmHWM %d kB\n" % (n, tot_hidden, hwm))
        log.flush()
        gdb.execute("continue", to_string=True)
        break
log.flush()
