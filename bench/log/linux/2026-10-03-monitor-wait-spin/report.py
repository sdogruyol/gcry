#!/usr/bin/env python3
# report.py <samples> <binary> [top]: symbolize samples in the main binary
import sys, subprocess, collections
path, binary = sys.argv[1], sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
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
def locate(pc):
    for lo, hi, off, name in maps:
        if lo <= pc < hi:
            return name, pc - lo + off
    return "?", pc
by_obj = collections.Counter()
in_bin = collections.Counter()
for pc in samples:
    name, off = locate(pc)
    if name.endswith(binary.split("/")[-1]):
        in_bin[off] += 1
    else:
        by_obj[name] += 1
offs = sorted(in_bin)
import json
out = subprocess.run(["llvm-symbolizer", "--obj=" + binary, "--functions=short", "--inlining=true", "--output-style=JSON"],
                     input="\n".join(hex(o) for o in offs), capture_output=True, text=True).stdout
func = collections.Counter(); line_ctr = collections.Counter(); leaf_outer = collections.Counter()
for off, ln in zip(offs, out.strip().split("\n")):
    rec = json.loads(ln)
    frames = rec.get("Symbol") or [{"FunctionName": "??", "FileName": "", "Line": 0}]
    c = in_bin[off]
    f0 = frames[0]
    func[f0["FunctionName"]] += c
    line_ctr[f"{f0['FileName'].split('/src/')[-1]}:{f0['Line']}"] += c
    leaf_outer[frames[-1]["FunctionName"]] += c
total = len(samples)
print(f"samples {total}; outside binary: " + ", ".join(f"{k.split('/')[-1] or '[anon]'} {v}" for k, v in by_obj.most_common(5)))
print("\n-- leaf function (inlined frame) --")
for k, v in func.most_common(top): print(f"{v*100/total:5.1f}% {k[:150]}")
print("\n-- outermost real function --")
for k, v in leaf_outer.most_common(top // 2): print(f"{v*100/total:5.1f}% {k[:150]}")
print("\n-- source line --")
for k, v in line_ctr.most_common(top): print(f"{v*100/total:5.1f}% {k[:150]}")
