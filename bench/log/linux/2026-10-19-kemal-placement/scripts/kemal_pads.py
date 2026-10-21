"""Kemal placement-probe tables from one `perf-ab` artifact.

usage: kemal_pads.py DIR [--path /json] [--hot REGEX]

DIR holds `kemal-runs.json` and `syms/kemal-<arm>.txt` (`nm -n`). For every
arm: its source (`base` arms are `base`, `basepad*`, `baseprepad*`; the rest
are `var`), how far its code moved against the unpadded build of the same
source (the most common address difference over every function both carry,
and the share of functions that moved by it), req/s as % of Boehm and against
`base`, medians of per-trial paired ratios [IQR], the server's CPU per 1 000
requests, and `/gc-stats`' collections and pause per 1 000 requests. `--hot`
adds each matching function's address mod 64 per arm.
"""
import argparse, collections, json, os, re, statistics


def quart(xs):
    q = statistics.quantiles(xs, n=4, method="inclusive") if len(xs) > 1 else [xs[0]] * 3
    return q[0], statistics.median(xs), q[2]


def fmt(q, f="{:+.1f}%"):
    return f"{f.format(q[1])} [{f.format(q[0])}, {f.format(q[2])}]"


def syms(path):
    out = {}
    for line in open(path, errors="replace"):
        p = line.rstrip("\n").split(" ", 2)
        if len(p) == 3 and p[1] in "tTwW" and re.fullmatch(r"[0-9a-f]{16}", p[0]):
            out.setdefault(p[2], int(p[0], 16))
    return out


def source(arm):
    """The unpadded build an arm is a placement probe of: `base` for `base*`,
    `var` for `var` and its pads, and itself for any other revision's arm."""
    if arm == "boehm" or arm.startswith("base"):
        return "boehm" if arm == "boehm" else "base"
    return "var" if arm == "var" or "pad" in arm else arm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--path", default="/json")
    ap.add_argument("--hot", default=None)
    a = ap.parse_args()
    d = json.load(open(os.path.join(a.dir, "kemal-runs.json")))
    rows = [r for r in d["runs"] if r["path"] == a.path and r["rps"]]
    arms = list(d["arms"])
    by = {(r["arm"], r["trial"]): r for r in rows}
    trials = sorted({r["trial"] for r in rows})
    sy = {arm: syms(os.path.join(a.dir, "syms", f"kemal-{arm}.txt")) for arm in arms
          if os.path.exists(os.path.join(a.dir, "syms", f"kemal-{arm}.txt"))}

    def shift(arm):
        ref = source(arm)
        if ref == "boehm" or arm == ref or arm not in sy or ref not in sy:
            return "0", ""
        s, r = sy[arm], sy[ref]
        diffs = collections.Counter(s[n] - r[n] for n in s.keys() & r.keys())
        dv, cnt = diffs.most_common(1)[0]
        return str(dv), f"{100 * cnt / sum(diffs.values()):.1f}%"

    print(f"Kemal `{a.path}`, {len(trials)} trials. Cells: medians of per-trial paired ratios [IQR].\n")
    print("| arm | source | shift (bytes, share of functions) | req/s | % of Boehm | vs base | vs var | CPU ms / 1k req | collections / 1k | pause ms / 1k |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for arm in arms:
        ts = [t for t in trials if (arm, t) in by]
        rps = statistics.median(by[(arm, t)]["rps"] for t in ts)

        def rel(ref):
            tt = [t for t in ts if (ref, t) in by]
            return fmt(quart([100 * (by[(arm, t)]["rps"] / by[(ref, t)]["rps"] - 1) for t in tt])) if ref != arm else "—"

        pb = quart([100 * by[(arm, t)]["rps"] / by[("boehm", t)]["rps"] for t in ts if ("boehm", t) in by])
        per = [1000 / (by[(arm, t)]["requests"] + by[(arm, t)]["warm_requests"]) for t in ts]
        cpu = quart([1000 * (by[(arm, t)]["utime"] + by[(arm, t)]["stime"]) * k for t, k in zip(ts, per)])
        gcs = [(by[(arm, t)].get("gc"), k) for t, k in zip(ts, per)]
        col = [g["collections"] * k for g, k in gcs if g]
        pau = [g["pause_total_ns"] / 1e6 * k for g, k in gcs if g]
        sh, share = shift(arm)
        print(f"| {arm} | {source(arm)} | {sh} {share} | {rps:.0f} | {pb[1]:.1f}% [{pb[0]:.1f}, {pb[2]:.1f}] | "
              f"{rel('base')} | {rel('var')} | {cpu[1]:.2f} [{cpu[0]:.2f}, {cpu[2]:.2f}] | "
              f"{statistics.median(col):.3f} | {statistics.median(pau):.3f} |" if col else
              f"| {arm} | {source(arm)} | {sh} {share} | {rps:.0f} | {pb[1]:.1f}% [{pb[0]:.1f}, {pb[2]:.1f}] | "
              f"{rel('base')} | {rel('var')} | {cpu[1]:.2f} [{cpu[0]:.2f}, {cpu[2]:.2f}] | — | — |")
    if a.hot:
        names = sorted({n for arm in sy for n in sy[arm] if re.search(a.hot, n)})
        gc_arms = [x for x in arms if x in sy and x != "boehm"]
        print("\nAddress mod 64 per arm:\n")
        print("| function | " + " | ".join(gc_arms) + " |")
        print("|---|" + "---:|" * len(gc_arms))
        for n in names:
            print(f"| `{n[:70]}` | " + " | ".join(str(sy[x][n] % 64) if n in sy[x] else "·" for x in gc_arms) + " |")


if __name__ == "__main__":
    main()
