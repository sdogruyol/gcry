#!/usr/bin/env python3
"""Tables for FINDINGS.md from the probe logs in this directory.

    python3 analyze.py [DIR ...]     (default: every */ here holding *.log.gz)

Each DIR holds one log per arm (`<arm>.log.gz`, as `probe.sh` wrote them,
gzipped). A run starts at `=== arm=… rc=… secs=…`; with `--counters` it
prints one `counters round=N heap=… cycles=…` line per round and one
`counters round=N class=…` line per (size class, kind) with two chunks or
more, then the gate's `heap MB per round:` line. Verdicts are computed on the
first four rounds (the gate's), from the two-decimal `heap=` values where the
counters printed them and from the gate's one-decimal line otherwise:

    shipped   last round minus first > 4.0 MB (bench/poison_freed.cr before
              this change; its exit code is the same verdict on unrounded MB)
    proposed  every round after the first grew by > 4.0 MB (after)
"""
import gzip
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

KV = re.compile(r"(\w+)=(\S+)")
ORDER = ["g037", "c037", "l037", "p037", "t037", "n037", "c036", "p036", "red", "redc"]


def parse(path):
    runs, cur = [], None
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("=== arm="):
                kv = dict(KV.findall(line))
                cur = {"rc": int(kv["rc"]), "rounds": {}, "classes": defaultdict(dict), "sizes": None}
                runs.append(cur)
            elif cur is None:
                continue
            elif line.startswith("counters round="):
                kv = dict(KV.findall(line))
                (cur["classes"][int(kv["round"])].__setitem__(kv["class"], kv) if "class" in kv
                 else cur["rounds"].__setitem__(int(kv["round"]), kv))
            elif line.startswith("heap MB per round:"):
                nums = line.split(":", 1)[1].split("(")[0]
                cur["sizes"] = [float(x) for x in nums.split("->")]
    for r in runs:
        r["mb"] = ([float(r["rounds"][k]["heap"]) for k in sorted(r["rounds"])] if r["rounds"]
                   else (r["sizes"] or []))
        r["paces"] = [max([int(c.split("/")[2]) for c in kv.get("cycles", "").split(",") if c] or [100])
                      for _, kv in sorted(r["rounds"].items())]
    return runs


def row(arm, runs):
    four = [r["mb"][:4] for r in runs if len(r["mb"]) >= 4]
    d = [[b - a for a, b in zip(m, m[1:])] for m in four]
    shipped = sum(1 for m in four if m[-1] - m[0] > 4.0)
    proposed = sum(1 for x in d if min(x) > 4.0)
    stepped = sum(1 for x in d if max(x) > 1.0)
    rounds = sum(len(r["paces"]) for r in runs)
    paced = sum(1 for r in runs for p in r["paces"] if p > 100)
    first = sorted(m[0] for m in four)
    allmb = [x for r in runs for x in r["mb"]]
    growth = max((r["mb"][-1] - r["mb"][0] for r in runs if r["mb"]), default=0)
    step = max((max(x) for x in d), default=0)
    rc = sum(1 for r in runs if r["rc"] != 0)
    pace = f"{paced}/{rounds}" if rounds else "—"
    return (f"| {arm} | {len(runs)} | {rc} | {shipped} | {proposed} | {stepped} | {pace} | "
            f"{first[len(first) // 2]:.2f} | {max(allmb):.2f} | {growth:+.2f} | {step:+.2f} |")


def steps(arm, runs, limit=6):
    """The stepped runs' round-by-round story: cycle lengths, pace, chunks."""
    out = []
    for r in runs:
        mb = r["mb"]
        for i in range(1, len(mb)):
            if mb[i] - mb[i - 1] <= 1.0 or not r["rounds"]:
                continue
            kv, prev = r["rounds"][i + 1], r["rounds"][i]
            cyc = [c.split("/") for c in kv.get("cycles", "").split(",") if c]
            at = [int(c[0]) for c in cyc]
            gaps = [b - a for a, b in zip([0] + at, at)]
            pc, cc = r["classes"].get(i, {}), r["classes"].get(i + 1, {})
            grew = [f"{k} {pc.get(k, {}).get('chunks', '≤1')}→{cc.get(k, {}).get('chunks', '≤1')}"
                    for k in sorted(set(pc) | set(cc))
                    if pc.get(k, {}).get("chunks") != cc.get(k, {}).get("chunks")]
            out.append(f"- {arm}: {' → '.join(f'{x:.1f}' for x in mb)}; round {i + 1} "
                       f"+{mb[i] - mb[i - 1]:.2f} MB, holding {prev['holding']}→{kv['holding']}, "
                       f"empty {prev['empty']}→{kv['empty']}; cycles every {gaps} iterations, "
                       f"pace {[int(c[2]) for c in cyc]}%; chunks {', '.join(grew)}")
            break
        if len(out) >= limit:
            break
    return out


def main():
    here = Path(__file__).resolve().parent
    dirs = [Path(a) for a in sys.argv[1:]] or sorted(p for p in here.iterdir() if p.is_dir())
    for d in dirs:
        logs = {p.name.split(".")[0]: p for p in d.glob("*.log*")}
        if not logs:
            continue
        print(f"### {d.name}\n")
        print("| arm | runs | rc≠0 | shipped fails | proposed fails | stepped >1 MB | rounds paced | "
              "round-1 median MB | max MB | max growth | max round step |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        parsed = {a: parse(logs[a]) for a in ORDER if a in logs}
        for arm, runs in parsed.items():
            print(row(arm, runs))
        print()
        for arm in ("g037", "c037", "l037", "p037"):
            for line in steps(arm, parsed.get(arm, []), limit=4):
                print(line)
        print()


if __name__ == "__main__":
    main()
