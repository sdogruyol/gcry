"""Symbolise pcprof samples (pcprof.c) against the binary they came from.

usage: pcprof.py BINARY TOP SAMPLE_FILE...

Prints the share of samples per function (all of them above 0.5%), then the
disassembly of the TOP hottest functions in the binary with each
instruction's sample count. A sample's count falls on the instruction the
thread was about to execute, so a stall shows up on the instruction after the
one that caused it more often than on it. Samples in other images (libc,
libsystem, dyld) come from each SAMPLE_FILE's `.other` twin, named by image
and nearest exported symbol (`dladdr`), as `[image] symbol`.
"""
import bisect, collections, os, struct, subprocess, sys


def symbols(binary):
    out = subprocess.run(["nm", "-n", "--defined-only", binary], capture_output=True, text=True).stdout
    addrs, names = [], []
    for line in out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 3 or parts[1] not in "tTwW":
            continue
        a = int(parts[0], 16)
        if addrs and addrs[-1] == a:
            continue
        addrs.append(a)
        names.append(parts[2])
    return addrs, names


def main():
    binary, top = sys.argv[1], int(sys.argv[2])
    files = [p for p in sys.argv[3:] if not p.endswith(".other")]
    pcs = []
    for path in files:
        data = open(path, "rb").read()
        pcs.extend(struct.unpack("<%dQ" % (len(data) // 8), data))
    addrs, names = symbols(binary)
    by_fn = collections.Counter()
    by_pc = collections.Counter()
    for pc in pcs:
        i = bisect.bisect_right(addrs, pc) - 1
        by_fn[i if i >= 0 else "[executable] ?"] += 1
        by_pc[pc] += 1
    for path in files:
        if os.path.exists(path + ".other"):
            for line in open(path + ".other", errors="replace"):
                img, _, sym = line.rstrip("\n").partition("\t")
                by_fn[f"[{os.path.basename(img)}] {sym}"] += 1
    total = sum(by_fn.values())
    print(f"{total} samples, {len(files)} runs")
    for k, n in by_fn.most_common():
        if n * 200 < total:
            break
        name = k if isinstance(k, str) else names[k]
        print(f"{100.0 * n / total:6.2f}% {n:7d}  {name}")
    shown = 0
    for k, n in by_fn.most_common():
        if isinstance(k, str):
            continue
        if shown == top:
            break
        shown += 1
        start, stop = addrs[k], addrs[k + 1] if k + 1 < len(addrs) else addrs[k] + 4096
        print(f"\n== {names[k]}  {100.0 * n / total:.2f}% ({n})  [{start:#x}, {stop:#x})")
        dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", f"--start-address={start:#x}",
                              f"--stop-address={stop:#x}", binary], capture_output=True, text=True).stdout
        for line in dis.splitlines():
            head = line.strip().split(":", 1)[0]
            try:
                a = int(head, 16)
            except ValueError:
                continue
            c = by_pc.get(a, 0)
            pct = f"{100.0 * c / n:5.1f}%" if c else "      "
            print(f"{c:6d} {pct} {line.strip()}")


main()
