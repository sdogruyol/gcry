import re, sys
# cglines.py A-lines.txt B-lines.txt: per gcry source line (keyed by file name + line text) self-Ir difference.
def load(p):
    d = {}; cur = None
    for l in open(p):
        m = re.match(r"-- (?:Auto|User)-annotated source: (.*)", l)
        if m: cur = m.group(1).split("/")[-1] if "/gcry/" in m.group(1) or m.group(1).endswith("gcry.cr") else None; continue
        if l.startswith("-- ") or cur is None: continue
        m = re.match(r"\s*([\d,]+) \([ \d.]+%\)\s(.*)$", l)
        if m and not m.group(2).lstrip().startswith(("=>", "<counts")):
            k = (cur, m.group(2).strip()); d[k] = d.get(k, 0) + int(m.group(1).replace(",", ""))
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
print(f"gcry lines {sum(a.values())/1e6:.2f}M -> {sum(b.values())/1e6:.2f}M")
diff = sorted(((b.get(k, 0) - a.get(k, 0), k) for k in set(a) | set(b)), key=lambda x: -abs(x[0]))
for d, k in diff[:int(sys.argv[3]) if len(sys.argv) > 3 else 40]:
    print(f"{d/1e6:+7.2f}M {a.get(k,0)/1e6:7.2f} {b.get(k,0)/1e6:7.2f} {k[0]}: {k[1][:110]}")
