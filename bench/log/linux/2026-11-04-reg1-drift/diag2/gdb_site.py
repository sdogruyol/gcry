import gdb
gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGUSR1 SIGUSR2 SIGXCPU SIGPWR SIGSEGV nostop noprint pass")
OFFS = [4952, 4920]
gdb.execute("starti -e 'returns live_objects' > /dev/null 2>&1")
base = 0
for l in gdb.execute("info proc mappings", to_string=True).splitlines():
    if "d6full_hl122" in l:
        base = int(l.split()[0], 16); break
gdb.execute("break *0x%x" % (base + 0x4c0c90))
gdb.execute("continue")
maps = []
for l in gdb.execute("info proc mappings", to_string=True).splitlines():
    p = l.split()
    if len(p) >= 2 and p[0].startswith("0x"):
        maps.append((int(p[0], 16), int(p[1], 16)))
for th in gdb.selected_inferior().threads():
    th.switch()
    f = gdb.newest_frame()
    sp0 = int(f.read_register("rsp"))
    top = next((hi for lo, hi in maps if lo <= sp0 < hi), 0)
    print("THREAD", th.num, th.name, "sp=0x%x top=0x%x sp=bottom%d" % (sp0, top, sp0 - top))
    if th.name != "SYSMON":
        continue
    frames = []
    while f is not None:
        try:
            sp = int(f.read_register("rsp"))
        except Exception:
            sp = 0
        frames.append((sp, f.name(), int(f.pc())))
        f = f.older()
    for i, (sp, name, pc) in enumerate(frames):
        print("  frame %d sp=bottom%d pc=0x%x %s" % (i, sp - top, pc, name))
    for off in OFFS:
        a = top - off
        owner = None
        for i, (sp, name, pc) in enumerate(frames):
            nxt = frames[i + 1][0] if i + 1 < len(frames) else top
            if sp <= a < nxt:
                owner = (i, name, a - sp)
        v = int(gdb.parse_and_eval("*(unsigned long*)0x%x" % a))
        print("SLOT bottom-%d addr=0x%x val=0x%x owner=%s" % (off, a, v, owner))
gdb.execute("kill")
