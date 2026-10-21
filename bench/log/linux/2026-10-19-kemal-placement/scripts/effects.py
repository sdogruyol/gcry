"""Each arm's req/s against the mean of all gcry arms in the same trial.

usage: effects.py OUT.json RUN_DIR[=LABEL]...

RUN_DIR holds a `kemal-runs.json` (`perf-ab` artifact). Per trial, every
gcry arm's `/json` req/s is divided by the geometric mean of all gcry arms in
that trial, which takes out what moves the whole trial (the host, the
neighbours) and leaves where each arm sits among the others. Prints, per run
and arm, the median of those per-trial effects with a bootstrap 95% CI of the
median (2 000 resamples, fixed seed), and writes {label: {arm: [per-trial
effects]}} to OUT.json for phase_classes.py.
"""
import json, math, os, random, statistics, sys


def effects(run_dir, path="/json"):
    d = json.load(open(os.path.join(run_dir, "kemal-runs.json")))
    rows = [r for r in d["runs"] if r["path"] == path and r["rps"]]
    arms = [a for a in d["arms"] if a != "boehm"]
    by = {(r["arm"], r["trial"]): r["rps"] for r in rows}
    out = {a: [] for a in arms}
    for t in sorted({r["trial"] for r in rows}):
        if not all((a, t) in by for a in arms):
            continue
        m = statistics.mean(math.log(by[(a, t)]) for a in arms)
        for a in arms:
            out[a].append(100 * (math.exp(math.log(by[(a, t)]) - m) - 1))
    return out


def ci(xs, n=2000):
    rnd = random.Random(1)
    ms = sorted(statistics.median(rnd.choices(xs, k=len(xs))) for _ in range(n))
    return ms[int(0.025 * n)], ms[int(0.975 * n)]


def main():
    out, runs = sys.argv[1], sys.argv[2:]
    res = {}
    for spec in runs:
        rd, _, label = spec.partition("=")
        e = effects(rd)
        res[label or rd] = e
        print(f"\n{label or rd}: `/json` req/s against the trial's mean of all gcry arms, "
              f"median of {len(next(iter(e.values())))} trials [bootstrap 95% CI]\n")
        print("| arm | effect |")
        print("|---|---:|")
        for a, xs in e.items():
            lo, hi = ci(xs)
            print(f"| {a} | {statistics.median(xs):+.1f}% [{lo:+.1f}, {hi:+.1f}] |")
    json.dump(res, open(out, "w"))


if __name__ == "__main__":
    main()
