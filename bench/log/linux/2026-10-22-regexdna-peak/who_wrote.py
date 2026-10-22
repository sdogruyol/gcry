# gdb -q -batch -x who_wrote.py  (env: BIN, BENCH, SLOT, VALUE, ENVS)
# Hardware watchpoint on one stack word: report the writer (pc, function,
# backtrace) of every store that leaves VALUE in it.
import gdb, os

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGPWR SIGXCPU SIGUSR1 SIGUSR2 nostop noprint pass")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
gdb.execute("file %s" % os.environ["BIN"])
gdb.execute("starti %s > /dev/null 2> /dev/null" % os.environ.get("BENCH", "RegexDna"))
slot = int(os.environ["SLOT"], 16)
value = int(os.environ["VALUE"], 16)
gdb.execute("watch *(unsigned long*)0x%x if *(unsigned long*)0x%x == 0x%x" % (slot, slot, value))
hits = 0
while hits < int(os.environ.get("MAX", "3")):
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if not gdb.selected_inferior().threads():
        break
    hits += 1
    print("hit %d pc=%s" % (hits, gdb.parse_and_eval("$pc")))
    print(gdb.execute("bt 12", to_string=True))
    print(gdb.execute("x/2i $pc-8", to_string=True))
