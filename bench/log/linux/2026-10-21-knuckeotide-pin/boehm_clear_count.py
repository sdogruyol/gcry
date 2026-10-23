# gdb -q -batch -x boehm_clear_count.py   (env: BIN)
# How often Boehm's own stack clearing runs in a Knuckeotide run: hit counts of
# GC_clear_stack (the every-call 2 KiB `dummy` wipe below its frame) and
# GC_clear_stack_inner (the 16 KiB wipe below SP, every 13th call under
# THREADS), and of GC_finish_collection (collections), read at exit_group.
import gdb, os

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGPWR nostop noprint pass")
gdb.execute("handle SIGXCPU nostop noprint pass")
exe = os.environ["BIN"]
gdb.execute("file %s" % exe)
gdb.execute("starti Knuckeotide > /dev/null")
inf = gdb.selected_inferior()
real = os.path.realpath(exe)
base0 = None
for l in open("/proc/%d/maps" % inf.pid):
    if l.rstrip().endswith(real):
        base0 = int(l.split("-")[0], 16)
        break
syms = {}
for l in os.popen("nm %s" % exe):
    p = l.split()
    if len(p) == 3:
        syms[p[2]] = int(p[0], 16)
bps = {}
for name in ["GC_clear_stack", "GC_clear_stack_inner", "GC_finish_collection"]:
    b = gdb.Breakpoint("*0x%x" % (base0 + syms[name]))
    b.ignore_count = 10 ** 9
    bps[name] = b
gdb.execute("catch syscall exit_group")
gdb.execute("continue", to_string=True)
for name, b in bps.items():
    print("COUNT %s %d" % (name, b.hit_count))
gdb.execute("kill")
