import re, sys
# cgdiff.py A.fn.txt B.fn.txt: per file:function self-Ir difference (callgrind_annotate --show=Ir output).
def load(p):
    d = {}
    for l in open(p):
        m = re.match(r"\s*([\d,]+) \([ \d.]+%\)\s+(.*)$", l)
        if not m or "PROGRAM TOTALS" in l: continue
        f = re.sub(r"\s+\[[^\]]*\]$", "", m.group(2))
        f = re.sub(r"^.*/work/[^/]+/", "", f)
        f = re.sub(r"^.*/share/crystal/src/", "std/", f)
        d[f] = d.get(f, 0) + int(m.group(1).replace(",", ""))
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
print(f"total {sum(a.values())/1e6:.2f}M -> {sum(b.values())/1e6:.2f}M ({sum(b.values())-sum(a.values()):+,})")
for f in ("lib/gcry",):
    sa = sum(v for k, v in a.items() if k.startswith(f)); sb = sum(v for k, v in b.items() if k.startswith(f))
    print(f"{f}: {sa/1e6:.2f}M -> {sb/1e6:.2f}M")
diff = sorted(((b.get(k, 0) - a.get(k, 0), k) for k in set(a) | set(b)), key=lambda x: -abs(x[0]))
for d, k in diff[:int(sys.argv[3]) if len(sys.argv) > 3 else 25]:
    print(f"{d/1e6:+8.2f}M {a.get(k,0)/1e6:9.2f} {b.get(k,0)/1e6:9.2f}  {k[:140]}")
