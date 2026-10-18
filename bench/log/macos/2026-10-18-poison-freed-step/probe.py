#!/usr/bin/env python3
"""PROBE ONLY: tabulate probe/poison_freed_step.sh logs.

Per arm: runs, exit codes, the gate's verdict as shipped (total growth over
four rounds > 4.0 MB) and the proposed one (growth > 4.0 MB in *every* round),
how many runs stepped (any round-on-round growth > 1 MB), where, by how much,
and what the step round's schedule and chunk census said.
"""
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

KV = re.compile(r"(\w+)=(\S+)")


def parse(path):
    runs = []
    cur = None
    for line in Path(path).read_text(errors="replace").splitlines():
        if line.startswith("=== arm="):
            kv = dict(KV.findall(line))
            cur = {"rc": int(kv["rc"]), "secs": float(kv["secs"]), "rounds": {}, "classes": defaultdict(dict),
                   "sizes": None, "fail": []}
            runs.append(cur)
        elif cur is None:
            continue
        elif line.startswith("counters round="):
            kv = dict(KV.findall(line))
            r = int(kv["round"])
            if "class" in kv:
                cur["classes"][r][kv["class"]] = kv
            else:
                cur["rounds"][r] = kv
        elif line.startswith("heap MB per round:"):
            nums = line.split(":", 1)[1].split("(")[0]
            cur["sizes"] = [float(x) for x in nums.split("->")]
        elif line.startswith("FAIL:"):
            cur["fail"].append(line)
    for run in runs:
        # Two decimals when the counters printed them, else the gate's one.
        if run["rounds"]:
            run["mb"] = [float(run["rounds"][r]["heap"]) for r in sorted(run["rounds"])]
        else:
            run["mb"] = run["sizes"] or []
    return runs


def cycles(kv):
    out = []
    for c in filter(None, kv.get("cycles", "").split(",")):
        i, thr, pace = c.split("/")
        out.append((int(i), float(thr), int(pace)))
    return out


def summarize(name, runs):
    print(f"## {name}: {len(runs)} runs")
    if not runs:
        return
    rc = Counter(r["rc"] for r in runs)
    print(f"exit codes: {dict(rc)}; secs median {sorted(r['secs'] for r in runs)[len(runs) // 2]:.2f}")
    old_fail = new_fail = 0
    stepped = []
    for r in runs:
        mb = r["mb"][:4]
        if len(mb) < 4:
            continue
        d = [b - a for a, b in zip(mb, mb[1:])]
        if mb[-1] - mb[0] > 4.0:
            old_fail += 1
        if min(d) > 4.0:
            new_fail += 1
        full = r["mb"]
        fd = [b - a for a, b in zip(full, full[1:])]
        steps = [(i + 2, x) for i, x in enumerate(fd) if x > 1.0]
        if steps:
            stepped.append((r, steps))
    print(f"shipped criterion (last - first > 4.0 MB) fails: {old_fail}/{len(runs)}")
    print(f"proposed criterion (every round > 4.0 MB) fails: {new_fail}/{len(runs)}")
    firsts = sorted(r["mb"][0] for r in runs if r["mb"])
    lasts = sorted(r["mb"][-1] for r in runs if r["mb"])
    if firsts:
        print(f"round-1 heap MB min/median/max: {firsts[0]:.2f}/{firsts[len(firsts) // 2]:.2f}/{firsts[-1]:.2f}; "
              f"last round: {lasts[0]:.2f}/{lasts[len(lasts) // 2]:.2f}/{lasts[-1]:.2f}")
    # Max pace the schedule reached per round, over every run.
    paces = Counter()
    for r in runs:
        for k, kv in r["rounds"].items():
            cs = cycles(kv)
            paces[max((p for _, _, p in cs), default=100)] += 1
    if paces:
        buckets = Counter()
        for p, n in paces.items():
            buckets["100" if p <= 100 else "101-199" if p < 200 else "200-299" if p < 300 else "300"] += n
        print(f"max pace per round (rounds): {dict(sorted(buckets.items()))}")
    print(f"runs with a round-on-round step > 1 MB: {len(stepped)}/{len(runs)}")
    where = Counter(s[0] for _, steps in stepped for s in steps)
    if where:
        print(f"  step at round: {dict(sorted(where.items()))}")
    for r, steps in stepped[:12]:
        desc = []
        for rnd, x in steps:
            kv = r["rounds"].get(rnd, {})
            prev = r["rounds"].get(rnd - 1, {})
            cs = cycles(kv)
            gaps = [b[0] - a[0] for a, b in zip([(0, 0, 0)] + cs, cs)]
            pcls = r["classes"].get(rnd - 1, {})
            ccls = r["classes"].get(rnd, {})
            grew = []
            for k in sorted(set(pcls) | set(ccls)):
                a = int(pcls.get(k, {}).get("chunks", 1))
                b = int(ccls.get(k, {}).get("chunks", 1))
                if b != a:
                    grew.append(f"{k}:{a}->{b}")
            desc.append(f"r{rnd} +{x:.2f} MB (holding {prev.get('holding')}->{kv.get('holding')}, "
                        f"empty {prev.get('empty')}->{kv.get('empty')}; cycle gaps {gaps}, "
                        f"pace {[p for _, _, p in cs]}; chunks {' '.join(grew)})")
        print("  " + " -> ".join(f"{x:.1f}" for x in r["mb"]) + ": " + "; ".join(desc))
    print()


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "probe-out")
    for log in sorted(out.glob("*.log")):
        summarize(log.stem, parse(log))


if __name__ == "__main__":
    main()
