# lldb -b -o "command script import ll.py"   (env: BIN, OUT, BENCH, MAXSTOPS, ENVS)
#
# Runs BIN BENCH under lldb with ASLR left on (JsonGenerate's high peak is an
# address-dependent false root). The probe build (-Dgcry_hold_probe) calls
# `Gcry::Heap.hold_probe_stop(slot)` whenever a stack, static, thread or parked
# root word first-marks a large block of 32 MiB or more; at each such stop this
# prints the slot, the word in it and its neighbours, and the frame chain with
# every frame's SP and CFA, so the frame that owns the slot is named.
import lldb, os


def __lldb_init_module(debugger, _):
    debugger.SetAsync(False)
    exe = os.environ["BIN"]
    out = os.environ["OUT"]
    bench = os.environ.get("BENCH", "JsonGenerate")
    maxstops = int(os.environ.get("MAXSTOPS", "6"))
    target = debugger.CreateTarget(exe)
    bp = target.BreakpointCreateByRegex("hold_probe_stop")
    print("breakpoint locations", bp.GetNumLocations())
    li = lldb.SBLaunchInfo([bench])
    envs = ["SILENT=1"] + os.environ.get("ENVS", "").split()
    li.SetEnvironmentEntries(envs, True)
    li.SetLaunchFlags(li.GetLaunchFlags() & ~lldb.eLaunchFlagDisableASLR)
    li.AddOpenFileAction(1, out, False, True)
    err = lldb.SBError()
    proc = target.Launch(li, err)
    if not err.Success():
        print("launch failed", err)
        return
    stops = 0
    total = 0
    while proc.GetState() == lldb.eStateStopped and stops < maxstops and total < 200:
        total += 1
        th = None
        for t in proc:
            if t.GetStopReason() == lldb.eStopReasonBreakpoint:
                th = t
        if th is None:
            print("stopped for", proc.GetSelectedThread().GetStopDescription(200))
            proc.Continue()
            continue
        f0 = th.GetFrameAtIndex(0)
        slot = f0.FindRegister("x0").GetValueAsUnsigned()
        # Only stack slots of this thread's frames: static words are named by
        # the reps' HOLDPROBE lines already.
        top = th.GetFrameAtIndex(th.GetNumFrames() - 1).GetCFA()
        if not (f0.GetSP() <= slot < top):
            proc.Continue()
            continue
        stops += 1
        e = lldb.SBError()
        words = []
        for k in range(-2, 3):
            words.append(proc.ReadUnsignedFromMemory(slot + 8 * k, 8, e))
        print("STOP %d slot=0x%x words[-2..2]=%s" % (stops, slot, " ".join("0x%x" % w for w in words)))
        owner = None
        for i in range(th.GetNumFrames()):
            f = th.GetFrameAtIndex(i)
            sp, cfa = f.GetSP(), f.GetCFA()
            name = f.GetFunctionName() or f.GetSymbol().GetName() or "?"
            mark = ""
            if sp <= slot < cfa:
                owner = (i, name, slot - sp, cfa - slot)
                mark = "  <== slot at sp+0x%x (cfa-0x%x)" % (slot - sp, cfa - slot)
            print("   #%d sp=0x%x cfa=0x%x pc=0x%x %s%s" % (i, sp, cfa, f.GetPC(), name[:150], mark))
        print("OWNER", owner)
        proc.Continue()
    proc.Kill()
