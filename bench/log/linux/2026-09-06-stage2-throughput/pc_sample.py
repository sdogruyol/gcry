# PC-only sampler for one thread: ptrace attach/GETREGS/detach, symbolised via nm.
import ctypes, os, sys, subprocess, time, collections, bisect, re
pid = int(sys.argv[1]); exe = sys.argv[2]; n = int(sys.argv[3]); interval = float(sys.argv[4])
libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.restype = ctypes.c_long
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
ATTACH, DETACH, GETREGS = 16, 17, 12
class Regs(ctypes.Structure):
    _fields_ = [(x, ctypes.c_ulong) for x in "r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs".split()]
maps = []; bases = {}
for line in open(f"/proc/{pid}/maps"):
    p = line.split()
    if len(p) >= 6 and p[5].startswith("/"):
        lo, hi = (int(x, 16) for x in p[0].split("-"))
        if int(p[2], 16) == 0: bases.setdefault(p[5], lo)
        if 'x' in p[1]: maps.append((lo, hi, int(p[2], 16), p[5]))
syms = {}
def load_syms(path):
    out = subprocess.run(["nm", "-n", "--defined-only", "-D" if ".so" in path else "-a", path], capture_output=True, text=True).stdout
    addrs, names = [], []
    for l in out.splitlines():
        p = l.split(" ", 2)
        if len(p) == 3 and p[1] in "tTwW":
            addrs.append(int(p[0], 16)); names.append(p[2])
    return addrs, names
def sym(pc):
    for lo, hi, off, path in maps:
        if lo <= pc < hi:
            if path not in syms:
                try: syms[path] = load_syms(path)
                except Exception: syms[path] = ([], [])
            addrs, names = syms[path]
            # PIE/shared: file offset = pc - lo + off; nm addresses are vaddr; for the exe (PIE) vaddr==file offset for text mostly
            a = pc - bases.get(path, lo - off)
            i = bisect.bisect_right(addrs, a) - 1
            return (os.path.basename(path), names[i] if i >= 0 else hex(a))
    return ("?", hex(pc))
tid = pid  # main thread
c = collections.Counter(); fails = 0
for _ in range(n):
    if libc.ptrace(ATTACH, tid, None, None) != 0:
        fails += 1; time.sleep(interval); continue
    os.waitpid(tid, 0x40000000)
    r = Regs(); libc.ptrace(GETREGS, tid, None, ctypes.byref(r))
    libc.ptrace(DETACH, tid, None, None)
    c[sym(r.rip)] += 1
    time.sleep(interval)
tot = sum(c.values())
def cat(mod, name):
    if "Gcry" in name or "gcry" in name or "__crystal_malloc" in name or name.startswith("GC_") or "Kernels" in name: return "gc"
    if mod.startswith("libgc"): return "gc"
    if "memset" in name or "memcpy" in name or "memmove" in name: return "libc-mem"
    if mod != os.path.basename(exe): return "lib:" + mod
    return "app"
byc = collections.Counter()
for (mod, name), k in c.items(): byc[cat(mod, name)] += k
print(f"samples={tot} attach_fail={fails}")
for k, v in byc.most_common(): print(f"  {k:14} {v*100/tot:5.1f}%")
print("top symbols:")
for (mod, name), k in c.most_common(28): print(f"  {k*100/tot:5.1f}%  {mod}: {name[:110]}")
