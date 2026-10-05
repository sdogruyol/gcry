#!/usr/bin/env python3
# pcprof.py <binary> <samples,samples,...> [func-substring ...]: per-function
# share, and per-instruction counts for functions matching the substrings.
import sys, subprocess, collections, bisect, re
binary, paths = sys.argv[1], sys.argv[2].split(",")
want = sys.argv[3:]
syms = []
for ln in subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout.splitlines():
    p = ln.split(" ", 2)
    if len(p) == 3 and p[0] and p[1] in "tTwW":
        syms.append((int(p[0], 16), p[2]))
addrs = [s[0] for s in syms]
bin_name = binary.split("/")[-1]
func = collections.Counter(); per_pc = collections.Counter(); outside = 0; total = 0
for path in paths:
    samples, maps = [], []
    for line in open(path):
        if line.startswith("S "):
            samples.append(int(line[2:], 16))
        elif line.startswith("M "):
            parts = line[2:].split()
            lo, hi = (int(x, 16) for x in parts[0].split("-"))
            off = int(parts[2], 16)
            name = parts[5] if len(parts) > 5 else ""
            maps.append((lo, hi, off, name))
    total += len(samples)
    for pc in samples:
        hit = None
        for lo, hi, off, name in maps:
            if lo <= pc < hi:
                hit = (name, pc - lo + off); break
        if not hit or not hit[0].endswith(bin_name):
            outside += 1; continue
        off = hit[1]
        i = bisect.bisect_right(addrs, off) - 1
        f = syms[i][1] if i >= 0 else "?"
        func[f] += 1
        per_pc[off] += 1
print(f"samples {total}, outside binary {outside}")
for f, c in func.most_common(25):
    print(f"{c*100/total:5.1f}% {f[:140]}")
for w in want:
    for i, (a, n) in enumerate(syms):
        if w in n:
            end = syms[i + 1][0] if i + 1 < len(syms) else a + 0x1000
            dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-M", "intel", f"--start-address={a}", f"--stop-address={end}", binary], capture_output=True, text=True).stdout
            fc = sum(c for o, c in per_pc.items() if a <= o < end)
            print(f"\n=== {n[:100]} ({fc} samples)")
            for dl in dis.splitlines():
                m = re.match(r"\s+([0-9a-f]+):\s+(.*)", dl)
                if not m: continue
                o = int(m.group(1), 16)
                c = per_pc.get(o, 0)
                print(f"{c:6d} {o:x}: {m.group(2)[:90]}")
            break
