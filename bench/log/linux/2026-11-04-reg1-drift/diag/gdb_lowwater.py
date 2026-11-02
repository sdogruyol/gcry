import gdb
gdb.execute("set pagination off")
gdb.execute("set confirm off")
gdb.execute("handle SIGUSR1 SIGUSR2 SIGXCPU SIGPWR SIGSEGV SIGCHLD SIGPIPE nostop noprint pass")
gdb.execute("set detach-on-fork on")
gdb.execute("set follow-fork-mode parent")
gdb.execute("starti > /dev/null 2>&1")
base = 0
for l in gdb.execute("info proc mappings", to_string=True).splitlines():
    if "tip_hdr" in l:
        base = int(l.split()[0],16); break
gdb.execute("break *0x%x" % (base + 0x5e9670))
gdb.execute("continue")
inf = gdb.selected_inferior()
for th in inf.threads():
    if th.name != "SYSMON": continue
    th.switch()
    f = gdb.newest_frame()
    sp = int(f.read_register("rsp"))
    # walk down from sp in 4 KiB pages until a fully zero run of 4 pages
    lowest = sp
    a = (sp - 8) & ~7
    zero_pages = 0
    page = (sp & ~0xfff)
    while zero_pages < 4:
        try:
            mem = bytes(inf.read_memory(page, 4096))
        except Exception:
            break
        nz = [i for i in range(0, 4096, 8) if mem[i:i+8] != b"\0"*8 and page + i < sp]
        if nz:
            lowest = page + nz[0]; zero_pages = 0
        else:
            zero_pages += 1
        page -= 4096
    print("SYSMON sp=0x%x lowest_nonzero=0x%x depth_below_sp=%d" % (sp, lowest, sp - lowest))
gdb.execute("kill")
