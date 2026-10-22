# gdb -q -batch -x zero_slot.py   (env: BIN, TRACE, BENCH, AT, SLOTS, ENVS)
#
# Counterfactual for one stale stack word: at the entry of collection AT
# (`Gcry::Heap#run_collection_body`, world stopped, before the mark), print
# and zero every absolute stack address in SLOTS (comma separated hex), then
# run to the end. GCRY_TRACE's collect_end lines (ENVS GCRY_TRACE_FILE=...)
# show whether the block the word held is swept at that collection.
import gdb, os

gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("set environment GCRY_TRACE_LARGE=1")
for kv in os.environ.get("ENVS", "").split():
    k, v = kv.split("=", 1)
    gdb.execute("set environment %s %s" % (k, v))
exe = os.environ["BIN"]
bench = os.environ.get("BENCH", "RegexDna")
at = int(os.environ["AT"])
slots = [int(x, 16) for x in os.environ.get("SLOTS", "").split(",") if x]
gdb.execute("file %s" % exe)
gdb.execute("starti %s > /dev/null 2> %s" % (bench, os.environ.get("TRACE", "/dev/null")))
inf = gdb.selected_inferior()
real = os.path.realpath(exe)
base0 = None
for l in open("/proc/%d/maps" % inf.pid):
    if l.rstrip().endswith(real):
        base0 = int(l.split("-")[0], 16)
        break
sym = None
for l in os.popen("nm %s" % exe):
    if "Gcry::Heap#run_collection_body" in l:
        sym = int(l.split()[0], 16)
gdb.execute("break *0x%x" % (base0 + sym))
n = 0
while True:
    try:
        gdb.execute("continue", to_string=True)
    except gdb.error:
        break
    if inf.pid == 0 or not inf.is_valid() or not inf.threads():
        break
    n += 1
    if n == at:
        for s in slots:
            v = int(gdb.parse_and_eval("*(unsigned long*)0x%x" % s))
            print("coll %d slot 0x%x = 0x%x -> 0" % (n, s, v))
            gdb.execute("set *(unsigned long*)0x%x = 0" % s)
print("collections seen", n)
