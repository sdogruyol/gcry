"""Interleaved Kemal A/B (bench/kemal) on Linux and macOS: req/s and peak RSS.

usage: kemal_ab.py --out DIR --trials N --arm boehm=bin/kemal-boehm
                   --arm base=... --arm var=... [--paths /json,/]

Per trial and path, every arm in random order: start the server fresh, wait
until `/` answers, warm with wrk for --warm seconds, measure with wrk for
--duration seconds, then read the server's peak RSS and SIGTERM it. Linux
reads `VmHWM` from /proc before the signal: `wait4`'s `ru_maxrss` there
carries the pre-`exec` high-water mark, Python's ~20 MiB, which is above a
Kemal server's peak. macOS has no /proc and does not inherit it in the same
way: there `ru_maxrss` (bytes) is read after the exit, and the floor of the
method is measured by running `true` the same way (`floor` in the outputs).
No CPU pinning: macOS has no `taskset`, and a hosted runner's few vCPUs are
shared by wrk and the server, so absolute req/s are low and noisy — the
paired per-trial ratio is the number to read.

Outputs `kemal-runs.json` and `kemal-summary.md` in --out. Windows is not
supported: there is no wrk.
"""
import argparse, json, os, random, re, signal, statistics, subprocess, sys, time, urllib.request


def wait_up(port):
    for _ in range(200):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=1).read()
            return True
        except OSError:
            time.sleep(0.05)
    return False


def wrk(port, path, secs, threads, conns):
    out = subprocess.run(["wrk", f"-t{threads}", f"-c{conns}", f"-d{secs}s", f"http://127.0.0.1:{port}{path}"],
                         capture_output=True, text=True).stdout
    m = re.search(r"Requests/sec:\s+([0-9.]+)", out)
    non2xx = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", out)
    return (float(m.group(1)) if m else None), (int(non2xx.group(1)) if non2xx else 0)


def quart(xs):
    q = statistics.quantiles(xs, n=4, method="inclusive") if len(xs) > 1 else [xs[0]] * 3
    return q[0], statistics.median(xs), q[2]


def vm_hwm(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            return next(int(l.split()[1]) * 1024 for l in f if l.startswith("VmHWM:"))
    except OSError:
        return None


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--trials", type=int, default=9)
    ap.add_argument("--arm", action="append", required=True, help="name=path")
    ap.add_argument("--paths", default="/json,/")
    ap.add_argument("--warm", type=int, default=3)
    ap.add_argument("--duration", type=int, default=10)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--connections", type=int, default=50)
    ap.add_argument("--port", type=int, default=3101)
    a = ap.parse_args()
    arms = dict(s.split("=", 1) for s in a.arm)
    names, paths = list(arms), a.paths.split(",")
    os.makedirs(a.out, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GCRY_")}
    env["PORT"] = str(a.port)
    rows = []
    t0 = subprocess.Popen(["true"])
    floor = os.wait4(t0.pid, 0)[2].ru_maxrss * (1 if sys.platform == "darwin" else 1024)
    for t in range(a.trials):
        for path in paths:
            order = names[:]
            random.shuffle(order)
            for arm in order:
                p = subprocess.Popen([arms[arm]], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                up = wait_up(a.port)
                rps = non2xx = None
                if up:
                    wrk(a.port, path, a.warm, a.threads, a.connections)
                    rps, non2xx = wrk(a.port, path, a.duration, a.threads, a.connections)
                hwm = vm_hwm(p.pid)
                p.send_signal(signal.SIGTERM)
                _, status, ru = os.wait4(p.pid, 0)
                peak = hwm or ru.ru_maxrss * (1 if sys.platform == "darwin" else 1024)
                rows.append(dict(trial=t, path=path, arm=arm, rps=rps, non2xx=non2xx, peak=peak, up=up))
                time.sleep(0.3)  # let the port go before the next server binds it
        print(f"trial {t + 1}/{a.trials} done", file=sys.stderr, flush=True)
        with open(os.path.join(a.out, "kemal-runs.json"), "w") as f:
            json.dump(dict(arms=arms, args=vars(a), platform=sys.platform, floor=floor, runs=rows), f, indent=0)
    ref = "boehm" if "boehm" in arms else names[0]
    lines = [f"Kemal, {a.trials} trials, wrk -t{a.threads} -c{a.connections} {a.duration} s after {a.warm} s warm-up; "
             f"cells: req/s as % of {ref} and peak RSS × {ref}, medians of per-trial paired ratios [IQR]. "
             + ("Peak RSS: VmHWM." if sys.platform.startswith("linux") else
                f"Peak RSS: ru_maxrss; floor of the method (`true`): {floor / 2**20:.1f} MiB."), ""]
    for path in paths:
        by = {(r["arm"], r["trial"]): r for r in rows if r["path"] == path and r["rps"]}
        lines += [f"## `{path}`", "", "| arm | req/s (median) | % of " + ref + " | peak RSS | × " + ref + " |",
                  "|---|---:|---:|---:|---:|"]
        for arm in names:
            ts = [t for t in range(a.trials) if (arm, t) in by and (ref, t) in by]
            if not ts:
                continue
            rps = statistics.median(by[(arm, t)]["rps"] for t in ts)
            pk = statistics.median(by[(arm, t)]["peak"] for t in ts) / 2**20
            sp = quart([100 * by[(arm, t)]["rps"] / by[(ref, t)]["rps"] for t in ts])
            mx = quart([by[(arm, t)]["peak"] / by[(ref, t)]["peak"] for t in ts])
            lines.append(f"| {arm} | {rps:.0f} | {sp[1]:.1f}% [{sp[0]:.1f}, {sp[2]:.1f}] | {pk:.1f} MiB | "
                         f"{mx[1]:.2f}× [{mx[0]:.2f}, {mx[2]:.2f}] |")
        lines.append("")
    bad = [r for r in rows if not r["up"] or not r["rps"] or r["non2xx"]]
    if bad:
        lines.append(f"Failed or non-2xx runs: {bad}")
    summary = "\n".join(lines) + "\n"
    with open(os.path.join(a.out, "kemal-summary.md"), "w") as f:
        f.write(summary)
    print(summary)


if __name__ == "__main__":
    main()
