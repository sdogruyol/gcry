# gdb -q -batch -x ww3.py (env BIN, MAX): stop at every FALSEWORD printf of
# the probe build; print the slot's owning frame and the words around it.
import gdb, os, builtins


def print(*a):
    builtins.print(*a)
    gdb.flush()


gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGPWR SIGXCPU SIGUSR1 SIGUSR2 SIGSEGV nostop noprint pass")
gdb.execute("set environment SILENT=1")
exe = os.environ["BIN"]
gdb.execute("file %s" % exe)
gdb.execute("starti JsonGenerate > /dev/null")
inf = gdb.selected_inferior()
real = os.path.realpath(exe)
base0 = None
for l in open("/proc/%d/maps" % inf.pid):
    if l.rstrip().endswith(real):
        base0 = int(l.split("-")[0], 16)
        break
gdb.execute("break printf if $_memeq((char*)$rdi, \"FALSEWORD\", 9)")
n = 0
seen = set()
while n < int(os.environ.get("MAX", "12")):
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if not inf.threads():
        break
    n += 1
    cand = int(gdb.parse_and_eval("$rdx")) & 0xFFFFFFFFFFFFFFFF
    s = int(gdb.parse_and_eval("$rcx")) & 0xFFFFFFFFFFFFFFFF
    off = int(gdb.parse_and_eval("$r8"))
    f = gdb.newest_frame()
    fr = []
    while f is not None:
        fr.append(f)
        f = f.older()
    own = None
    for f in fr:
        if int(f.read_register("rsp")) <= s:
            own = f
    sp = int(own.read_register("rsp")) if own else 0
    key = (own.name() if own else "?", s - sp)
    print("FW %d cand=0x%x slot=0x%x slot-entry=%d owner=%s sp+0x%x pc=+0x%x" % (n, cand, s, off, key[0], s - sp, (int(own.pc()) - base0) if own else 0))
    if key in seen:
        continue
    seen.add(key)
    for lvl, f in enumerate(fr[:6]):
        print("  #%d %s sp=0x%x pc=+0x%x" % (lvl, f.name(), int(f.read_register("rsp")), int(f.pc()) - base0))
    print(gdb.execute("x/24gx 0x%x" % (s - 0x60), to_string=True))
