"""Instructions per request by function, from cg_kemal.sh profiles.

usage: cg_per_request.py OUT.tsv A.cg=REQUESTS B.cg=REQUESTS

Runs `callgrind_annotate --auto=no --show=Ir --threshold=100` on each
profile, divides every function's exclusive Ir by the requests wrk counted in
that profile's window, and prints the totals, the split between gcry
(`Gcry::`), Crystal's `GC::` shims and everything else, and the functions
whose Ir per request differs most between the two. OUT.tsv gets each
function's mean Ir per request over the profiles (name<TAB>Ir), the ranking
fn_phases.py --top and phase_classes.py --ir read.
"""
import re, subprocess, sys

LINE = re.compile(r"^\s*([\d,]+) \(\s*[\d.]+%\)\s+(.*)$")


def profile(path):
    out = subprocess.run(["callgrind_annotate", "--auto=no", "--show=Ir", "--threshold=100", path],
                         capture_output=True, text=True).stdout
    d = {}
    for line in out.splitlines():
        m = LINE.match(line)
        if not m or "PROGRAM TOTALS" in line:
            continue
        name = re.sub(r" \[[^\]]*\]$", "", m.group(2))
        name = name.split(":", 1)[1] if re.match(r"^[^:]*\.(cr|c|S|h):", name) or name.startswith("???:") else name
        d[name] = d.get(name, 0) + int(m.group(1).replace(",", ""))
    return d


def main():
    out, specs = sys.argv[1], sys.argv[2:]
    per = []
    for s in specs:
        p, req = s.rsplit("=", 1)
        d = profile(p)
        per.append((p, {k: v / int(req) for k, v in d.items()}))
    for p, d in per:
        g = {"gcry": 0.0, "GC::": 0.0, "other": 0.0}
        for k, v in d.items():
            g["gcry" if "Gcry::" in k else "GC::" if k.startswith("*GC::") else "other"] += v
        print(f"{p}: {sum(d.values()):.0f} Ir/request; gcry {g['gcry']:.0f}, GC:: {g['GC::']:.0f}, other {g['other']:.0f}")
    if len(per) == 2:
        (pa, a), (pb, b) = per
        diff = sorted(((b.get(k, 0) - a.get(k, 0)), k) for k in set(a) | set(b))
        print(f"\nlargest differences, {pb} minus {pa} (Ir/request):")
        for dv, k in diff[:8] + diff[-15:]:
            print(f"  {dv:+8.1f}  {a.get(k, 0):8.1f} → {b.get(k, 0):8.1f}  {k[:100]}")
    names = set().union(*(d for _, d in per))
    mean = {k: sum(d.get(k, 0) for _, d in per) / len(per) for k in names}
    with open(out, "w") as f:
        for k in sorted(mean, key=lambda k: -mean[k]):
            f.write(f"{k}\t{mean[k]:.1f}\n")


if __name__ == "__main__":
    main()
