"""Interleaved crystal-metric A/B, process-fresh, on Linux, macOS and Windows.

usage: ab.py --out DIR --reps N --arm base=bin/ab-base --arm var=bin/ab-var
             [--arm boehm=bin/ab-boehm] BENCH...

Every (rep, bench) runs each arm once, as a fresh process, in a random order.
Per run it records:

- `time`: the benchmark's own timed section, parsed from its `in N.NNNs` line
  (leaves out crystal-metric's setup);
- `wall`: whole-process wall time, setup included — what the README's Linux
  tables quote as speed;
- `peak`: the process's peak resident memory in bytes. macOS reads it from
  `wait4`'s `ru_maxrss` (bytes there); Windows from `PeakWorkingSetSize` on
  the exited process's handle, which is not Linux RSS: pages decommitted and
  committed again count twice. Linux runs the bench under GNU `/usr/bin/time
  -f %M` instead: Linux carries the pre-`exec` memory's high-water mark into
  the child's `ru_maxrss`, and a child forked from this script would start at
  Python's ~20 MiB, above a Kemal-sized process (`time` itself is ~2 MiB).
  Each run's floor is measured by running `true` the same way (`floor` in
  runs.json and the summary);
- `mark`: Σ `mark_ns` from `GCRY_TRACE` (gcry arms only; Boehm writes none);
- `result`: `ok`, or the value an `err` line printed. Several benches print
  `err` on Crystal >= 1.21 under every collector, Boehm included; a bench whose
  results differ between arms is flagged in the summary, since the arms then
  did not do the same work.

Outputs: `runs.json` (every run), `summary.md`, and on stdout the summary plus
the historical `AB <bench>: mark … ms; time … s` lines for `base` against
`var`. Ratios are medians of per-rep paired ratios (the arms of one rep ran
back to back), with the interquartile range of those ratios in brackets.
"""
import argparse, json, os, random, re, shutil, statistics, subprocess, sys, tempfile, time

WIN = os.name == "nt"
LINUX_TIME = shutil.which("time", path="/usr/bin") if sys.platform.startswith("linux") else None
LINE = re.compile(r"^(\w+):\s+(ok|err)(.*?)\bin\s+([0-9.]+)s", re.M)

if WIN:
    import ctypes
    import ctypes.wintypes as wt

    class PMC(ctypes.Structure):
        _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]

    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    psapi.GetProcessMemoryInfo.argtypes = [wt.HANDLE, ctypes.POINTER(PMC), wt.DWORD]


def run_one(exe, bench, trace, args=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GCRY_")}
    env.update(GCRY_TRACE="1", GCRY_TRACE_ALLOC_SAMPLE="0", GCRY_TRACE_FILE=trace)
    if os.path.exists(trace):
        os.remove(trace)
    cmd = [exe] + ([bench] if args is None else args)
    hwm = None
    if LINUX_TIME:
        fd, hwm = tempfile.mkstemp()
        os.close(fd)
        cmd = [LINUX_TIME, "-f", "%M", "-o", hwm] + cmd
    # Output goes to a file, not a pipe: on POSIX the child is reaped with
    # `wait4` before anything is read, and a full pipe would block it.
    with tempfile.TemporaryFile() as out:
        t0 = time.perf_counter()
        p = subprocess.Popen(cmd, env=env, stdout=out, stderr=subprocess.STDOUT)
        if WIN:
            p.wait()
            wall = time.perf_counter() - t0
            # The handle stays open after exit, so the counters stay readable
            # and nothing has to be polled while the bench runs.
            pmc = PMC()
            pmc.cb = ctypes.sizeof(PMC)
            if not psapi.GetProcessMemoryInfo(wt.HANDLE(int(p._handle)), ctypes.byref(pmc), pmc.cb):
                raise OSError(ctypes.get_last_error())
            peak, rc = pmc.PeakWorkingSetSize, p.returncode
        else:
            _, status, ru = os.wait4(p.pid, 0)
            wall = time.perf_counter() - t0
            p.returncode = rc = os.waitstatus_to_exitcode(status)
            peak = ru.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
        out.seek(0)
        text = out.read().decode("utf-8", "replace")
    if hwm:
        # GNU time writes "Command exited with non-zero status N" first when
        # the bench fails; %M (KiB) is always the last line.
        with open(hwm) as f:
            peak = int(f.read().split()[-1]) * 1024
        os.remove(hwm)
    m = [x for x in LINE.finditer(text) if x.group(1) == bench]
    mark = None
    if os.path.exists(trace):
        with open(trace) as f:
            mark = sum(json.loads(l)["mark_ns"] for l in f if '"collect_end"' in l) / 1e6
    r = dict(rc=rc, wall=wall, peak=peak, mark=mark, time=None, result=None)
    if m:
        r["time"] = float(m[-1].group(4))
        r["result"] = "ok" if m[-1].group(2) == "ok" else m[-1].group(3).strip()
    else:
        # crystal-metric exits 1 when a bench prints `err`; only a missing
        # result line is a failed run.
        r["output"] = text[-600:]
    return r


def quart(xs):
    q = statistics.quantiles(xs, n=4, method="inclusive") if len(xs) > 1 else [xs[0]] * 3
    return q[0], statistics.median(xs), q[2]


def summarize(rows, benches, arms, floor):
    med = statistics.median
    by = {}
    for r in rows:
        by.setdefault((r["bench"], r["arm"]), {})[r["rep"]] = r
    ref = "boehm" if "boehm" in arms else arms[0]
    others = [a for a in arms if a != ref]
    lines = [f"Cells: speed as % of {ref} (whole-process wall, {ref}/arm) and peak memory × {ref}; "
             "medians of per-rep paired ratios, [interquartile range]. Peak-memory floor of the method "
             f"(`true` measured the same way): {'n/a' if floor is None else f'{floor / 2**20:.1f} MiB'}.", "",
             f"| bench | {ref} | " + " | ".join(others) + " |",
             "|---|---:|" + "---|" * len(others)]
    notes = []
    for b in benches:
        rr = by.get((b, ref), {})
        if not rr:
            continue
        cells = [f"{med(r['wall'] for r in rr.values()):.3f} s, {med(r['peak'] for r in rr.values()) / 2**20:.0f} MiB"]
        for a in others:
            ar = by.get((b, a), {})
            reps = sorted(set(rr) & set(ar))
            sp = quart([100 * rr[i]["wall"] / ar[i]["wall"] for i in reps])
            mem = quart([ar[i]["peak"] / rr[i]["peak"] for i in reps])
            cells.append(f"{sp[1]:.0f}% [{sp[0]:.0f}, {sp[2]:.0f}] / {mem[1]:.2f}× [{mem[0]:.2f}, {mem[2]:.2f}]")
        lines.append(f"| {b} | " + " | ".join(cells) + " |")
        results = {a: sorted({str(r["result"]) for r in by.get((b, a), {}).values()}) for a in arms}
        if len({tuple(v) for v in results.values()}) > 1:
            notes.append(f"- {b}: results differ between arms: {results}")
        bad = [(a, i) for a in arms for i, r in by.get((b, a), {}).items() if r["time"] is None]
        if bad:
            notes.append(f"- {b}: failed runs (arm, rep): {bad}")
    if "base" in arms and "var" in arms:
        lines += ["", "`var` against `base` (paired, per rep):", "",
                  "| bench | time (timed section) | wall | peak | Σ mark |", "|---|---:|---:|---:|---:|"]
        for b in benches:
            br, vr = by.get((b, "base"), {}), by.get((b, "var"), {})
            reps = sorted(set(br) & set(vr))
            if not reps:
                continue
            cells = []
            for k in ("time", "wall", "peak", "mark"):
                xs = [vr[i][k] / br[i][k] - 1 for i in reps if vr[i][k] and br[i][k]]
                cells.append("n/a" if not xs else "{1:+.1%} [{0:+.1%}, {2:+.1%}]".format(*quart(xs)))
            lines.append(f"| {b} | " + " | ".join(cells) + " |")
    if notes:
        lines += ["", "Notes:"] + notes
    return "\n".join(lines) + "\n"


def main():
    sys.stdout.reconfigure(encoding="utf-8")  # Windows' console default is cp1252
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--arm", action="append", required=True, help="name=path")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("benches", nargs="+")
    a = ap.parse_args()
    arms = dict(s.split("=", 1) for s in a.arm)
    names = list(arms)
    os.makedirs(a.out, exist_ok=True)
    rnd = random.Random(a.seed)
    trace = os.path.join(tempfile.gettempdir(), "ab-trace.ndjson")
    true = shutil.which("true")
    floor = None if WIN or not true else run_one(true, "", trace, args=[])["peak"]
    # One discarded run per binary: Windows Defender scans a fresh image on
    # its first launch, and every OS pages the binary in once.
    for exe in arms.values():
        run_one(exe, a.benches[0], trace)
    rows = []
    for rep in range(a.reps):
        for b in a.benches:
            order = names[:]
            rnd.shuffle(order)
            for arm in order:
                r = run_one(arms[arm], b, trace)
                r.update(rep=rep, bench=b, arm=arm)
                rows.append(r)
                if "output" in r:
                    print(f"WARN rep {rep} {b} {arm}: rc={r['rc']}\n{r['output']}", file=sys.stderr, flush=True)
        print(f"rep {rep + 1}/{a.reps} done", file=sys.stderr, flush=True)
        with open(os.path.join(a.out, "runs.json"), "w") as f:
            json.dump(dict(arms=arms, benches=a.benches, reps=a.reps, platform=sys.platform, floor=floor,
                           peak_method="PeakWorkingSetSize" if WIN else "GNU time %M" if LINUX_TIME else "ru_maxrss",
                           runs=rows), f, indent=0)
    summary = summarize(rows, a.benches, names, floor)
    with open(os.path.join(a.out, "summary.md"), "w", encoding="utf-8") as f:
        f.write(summary)
    print(summary)
    if "base" in arms and "var" in arms:
        for b in a.benches:
            rs = {k: [r for r in rows if r["bench"] == b and r["arm"] == k and r["time"] is not None] for k in ("base", "var")}
            if not rs["base"] or not rs["var"]:
                continue
            bw, vw = (statistics.median(r["time"] for r in rs[k]) for k in ("base", "var"))
            ms = [[r["mark"] for r in rs[k] if r["mark"] is not None] for k in ("base", "var")]
            mk = ""
            if all(ms):
                bm, vm = (statistics.median(x) for x in ms)
                mk = f"mark {bm:.0f} -> {vm:.0f} ms ({vm / bm - 1:+.1%}); " if bm else ""
            print(f"AB {b}: {mk}time {bw:.3f} -> {vw:.3f} s ({vw / bw - 1:+.1%})")


if __name__ == "__main__":
    main()
