"""Every run at once: which function's placement predicts Kemal `/json`?

usage: phase_joint.py PHASES.json... -- RUN_DIR=CPU... [--fn NAME]...

PHASES.json are fn_phases.py outputs (merged; an arm name means the same
binary in every run, which `cmp` confirms for the arms these runs share).
Each RUN_DIR (`perf-ab` artifact) gives, per arm, the median over trials of
100·ln(arm req/s / `base` req/s) in the same trial, so every run is measured
against the same v0.36.0 binary and runs on one CPU model pool.

For each hot function, observations on one CPU model are grouped by (layout
signature, address mod 64) of that function in the arm's binary; R² is the
share of the variance of the effects inside each CPU model that the grouping
explains, pooled over models. A permutation test (2 000 shuffles of the
effects within each CPU model, same groups) gives how often a grouping that
size explains as much by chance. `--fn` adds a per-CPU table of the mean
effect by that function's address mod 64, and R² at other granularities.
"""
import json, math, random, statistics, sys


def effects(run_dir):
    d = json.load(open(f"{run_dir}/kemal-runs.json"))
    by = {(r["arm"], r["trial"]): r["rps"] for r in d["runs"] if r["path"] == "/json" and r["rps"]}
    trials = sorted({t for _, t in by})
    out = {"base": 0.0}
    for a in d["arms"]:
        if a in ("boehm", "base"):
            continue
        xs = [100 * math.log(by[(a, t)] / by[("base", t)]) for t in trials if (a, t) in by and ("base", t) in by]
        out[a] = statistics.median(xs)
    return out


def r2(ph, fn, obs, mod=64):
    per, sst, ssw = ph[fn], 0.0, 0.0
    for cpu in sorted({o[0] for o in obs}):
        pts = [(per[a][2], per[a][0] % mod, e) for c, _, a, e in obs if c == cpu]
        mu = statistics.mean(e for *_, e in pts)
        sst += sum((e - mu) ** 2 for *_, e in pts)
        g = {}
        for s, p, e in pts:
            g.setdefault((s, p), []).append(e)
        ssw += sum(sum((e - statistics.mean(v)) ** 2 for e in v) for v in g.values())
    return 1 - ssw / sst


def perm_p(ph, fn, obs, n=2000):
    rnd, real, hits = random.Random(7), r2(ph, fn, obs), 0
    for _ in range(n):
        shuffled = []
        for cpu in {o[0] for o in obs}:
            sub = [o for o in obs if o[0] == cpu]
            es = [o[3] for o in sub]
            rnd.shuffle(es)
            shuffled += [(c, r, a, e) for (c, r, a, _), e in zip(sub, es)]
        hits += r2(ph, fn, shuffled) >= real
    return real, hits / n


def main():
    args = sys.argv[1:]
    cut = args.index("--")
    phase_files, rest = args[:cut], args[cut + 1:]
    fns = [rest[i + 1] for i, x in enumerate(rest) if x == "--fn"]
    runs = [x for i, x in enumerate(rest) if x != "--fn" and (i == 0 or rest[i - 1] != "--fn")]
    ph = {}
    for p in phase_files:
        for fn, per in json.load(open(p)).items():
            ph.setdefault(fn, {}).update(per)
    obs = []
    for spec in runs:
        rd, cpu = spec.rsplit("=", 1)
        for a, e in effects(rd).items():
            obs.append((cpu, rd, a, e))
    arms = {o[2] for o in obs}
    # Functions are grouped by the arms' grouping they induce; one line per class.
    classes = {}
    for fn, per in ph.items():
        if not arms <= set(per):
            continue
        key = tuple(sorted((per[a][2], per[a][0] % 64, a) for a in sorted(arms)))
        key = tuple(sorted({tuple(sorted(a for s, p, a in key if (s, p) == sp)) for sp in {(s, p) for s, p, _ in key}}))
        classes.setdefault(key, []).append(fn)
    print(f"{len(obs)} observations ({len(arms)} binaries) on {len({o[0] for o in obs})} CPU models\n")
    print("| R² | p (permutation) | groups | functions (first 4 by name) |")
    print("|---:|---:|---:|---|")
    rows = []
    for key, members in classes.items():
        real, p = perm_p(ph, members[0], obs)
        rows.append((real, p, len(key), sorted(members)))
    for real, p, k, members in sorted(rows, reverse=True):
        names = ", ".join(f"`{m[:60]}`" for m in members[:4])
        print(f"| {real:.2f} | {p:.3f} | {k} | {len(members)}: {names} |")
    for fn in fns:
        print(f"\n`{fn}`: R² by granularity: " + ", ".join(f"mod {m} {r2(ph, fn, obs, m):.2f}" for m in (16, 32, 64, 128, 4096)))
        print("\n| CPU | address mod 64 | mean effect vs v0.36.0 | n | arms (effect) |")
        print("|---|---:|---:|---:|---|")
        for cpu in sorted({o[0] for o in obs}):
            g = {}
            for c, _, a, e in obs:
                if c == cpu:
                    g.setdefault(ph[fn][a][0] % 64, []).append((a, e))
            for phase in sorted(g):
                v = [e for _, e in g[phase]]
                print(f"| {cpu} | {phase} | {statistics.mean(v):+.1f}% | {len(v)} | "
                      + ", ".join(f"{a} {e:+.1f}" for a, e in g[phase]) + " |")


if __name__ == "__main__":
    main()
