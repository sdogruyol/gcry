# gdb -q -batch -x ww4.py (env BIN, OFF): at the second FALSEWORD printf
# whose slot-entry is OFF, watch that slot through the next collection and
# report every store into it (value, function, backtrace for the shape
# low32 == 1 with a nonzero high half).
import gdb, os, builtins


def print(*a):
    builtins.print(*a)
    gdb.flush()


gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGPWR SIGXCPU SIGUSR1 SIGUSR2 SIGSEGV nostop noprint pass")
gdb.execute("set environment SILENT=1")
exe = os.environ["BIN"]
off = int(os.environ.get("OFF", "-1424"))
gdb.execute("file %s" % exe)
gdb.execute("starti JsonGenerate > /dev/null")
inf = gdb.selected_inferior()
gdb.execute("break printf if $_memeq((char*)$rdi, \"FALSEWORD\", 9) && $r8 == %d" % off)
slots = []
while True:
    gdb.execute("continue", to_string=True)
    s = int(gdb.parse_and_eval("$rcx")) & 0xFFFFFFFFFFFFFFFF
    slots.append(s)
    print("FALSEWORD slot=0x%x" % s)
    if len(slots) >= 2 and slots[-1] == slots[-2]:
        break
slot = slots[-1]
gdb.execute("watch -l *(unsigned long*)0x%x" % slot)
n = 0
while n < 3000:
    try:
        out = gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if not inf.threads():
        break
    pc = int(gdb.parse_and_eval("$pc"))
    v = int(gdb.parse_and_eval("*(unsigned long*)0x%x" % slot)) & 0xFFFFFFFFFFFFFFFF
    if "FALSEWORD" in out or "Breakpoint" in out and "printf" in out:
        print("-- reached the scan (FALSEWORD), value=0x%x" % v)
        break
    n += 1
    name = gdb.newest_frame().name()
    print("store %d value=0x%x in %s pc=0x%x" % (n, v, name, pc))
    if (v & 0xFFFFFFFF) == 1 and v > 0xFFFFFFFF or (v >> 32) != 0 and (v & 0xFFFFFFFF) < 0x100:
        print(gdb.execute("bt 10", to_string=True))
        print(gdb.execute("x/4i $pc-12", to_string=True))
