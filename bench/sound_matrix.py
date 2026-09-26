#!/usr/bin/env python3
"""Tuned against GCRY_SOUND=1 across three process shapes, paired per round.

`docs/SOUND-DEFAULTS.md` leaves one question open: whether the complete root
scan (`GCRY_SOUND=1`, `lag = 0`) is affordable where the scan is large, and it
rejected answers from one workload on one host. This measures the three shapes
the Kemal bench server can take, in one job, per round:

  ec1          the default execution context, main + SYSMON (2 threads)
  ec1+thread   the same with one parked thread of the program's own
               (`EXTRA_THREADS=1`) — past gcry's multi-mutator boundary
  ec4          `EC_PARALLELISM=4` (needs the `-Dpreview_mt -Dexecution_context`
               build)

For each: `/json` req/s (wrk, 10 s after a 2 s warm-up), the server's own pause
p50, and post-GC RSS. Order rotates per round, and the sound/tuned ratio is taken
within a round, so host drift cancels.

  bench/sound_matrix.py --ec1 bin/kemal-gcry --mt bin/kemal-gcry-mt --rounds 8 \\
      --json out.json

`--profile NAME:KEY=VAL[,...]` compares another configuration against tuned
the same way (`dormant:GCRY_PARALLEL_DORMANT=1`); the default is sound.

Linux and macOS (RSS from /proc, else `ps`).
"""
import argparse, json, os, re, statistics, subprocess, sys, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--ec1", required=True, help="gcry Kemal server, default build")
ap.add_argument("--mt", required=True, help="gcry Kemal server, -Dpreview_mt -Dexecution_context")
ap.add_argument("--rounds", type=int, default=8)
ap.add_argument("--port", default="3090")
ap.add_argument("--wrk", default="wrk")
ap.add_argument("--json", help="write the raw samples here")
ap.add_argument("--profile", default="sound:GCRY_SOUND=1",
                help="the arm compared against tuned, NAME:KEY=VAL[,KEY=VAL] "
                     "(default sound:GCRY_SOUND=1; e.g. dormant:GCRY_PARALLEL_DORMANT=1)")
a = ap.parse_args()

SHAPES = {
    "ec1": (a.ec1, {}),
    "ec1+thread": (a.ec1, {"EXTRA_THREADS": "1"}),
    "ec4": (a.mt, {"EC_PARALLELISM": "4"}),
}
prof_name, _, prof_env = a.profile.partition(":")
PROFILES = {"tuned": {}, prof_name: dict(kv.split("=", 1) for kv in prof_env.split(",") if kv)}
# The collector's own `soundness` label names the root profile only; an arm is
# checked against it as "sound" when it sets GCRY_SOUND=1 and "tuned" otherwise.
EXPECT = {name: ("sound" if env.get("GCRY_SOUND") == "1" else "tuned") for name, env in PROFILES.items()}
URL = f"http://127.0.0.1:{a.port}"


def rss_kib(pid):
    try:
        return int(re.search(r"VmRSS:\s+(\d+)", open(f"/proc/{pid}/status").read()).group(1))
    except OSError:
        return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                                  capture_output=True, text=True).stdout.strip())


def one(binary, env):
    p = subprocess.Popen([binary], env=dict(os.environ, PORT=a.port, **env),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(400):
            try:
                urllib.request.urlopen(URL + "/", timeout=1).read()
                break
            except OSError:
                time.sleep(0.05)
        subprocess.run([a.wrk, "-t4", "-c100", "-d2s", URL + "/json"], capture_output=True)
        out = subprocess.run([a.wrk, "-t4", "-c100", "-d10s", URL + "/json"],
                             capture_output=True, text=True).stdout
        rps = float(re.search(r"Requests/sec:\s+([\d.]+)", out).group(1))
        s = json.loads(urllib.request.urlopen(URL + "/gc-stats").read())
        pause_ms = s["pause_p50_ns"] / 1e6
        # The collector's own label, so an arm that did not boot the profile it
        # is named for is refused rather than averaged in.
        label = s.get("soundness")
        for _ in range(2):
            urllib.request.urlopen(URL + "/gc-collect").read()
        time.sleep(0.3)
        return {"rps": rps, "pause_ms": pause_ms, "rss_kib": rss_kib(p.pid), "soundness": label}
    finally:
        p.kill()
        p.wait()
        time.sleep(0.3)


arms = [(sh, pr) for sh in SHAPES for pr in PROFILES]
res = {arm: [] for arm in arms}
for r in range(a.rounds):
    k = r % len(arms)
    for sh, pr in arms[k:] + arms[:k]:
        binary, env = SHAPES[sh]
        got = one(binary, {**env, **PROFILES[pr]})
        if got["soundness"] != EXPECT[pr]:
            sys.exit(f"{sh}/{pr} booted as {got['soundness']!r}, not {EXPECT[pr]!r}")
        res[(sh, pr)].append(got)
    print(f"round {r + 1}/{a.rounds}", file=sys.stderr, flush=True)

med = statistics.median
print("| shape | profile | req/s | pause p50 ms | post-GC RSS MB |")
print("|---|---|---:|---:|---:|")
for sh in SHAPES:
    for pr in PROFILES:
        v = res[(sh, pr)]
        print(f"| {sh} | {pr} | {med(x['rps'] for x in v):.0f} | {med(x['pause_ms'] for x in v):.3f} "
              f"| {med(x['rss_kib'] for x in v) / 1024:.1f} |")
print()
print(f"| shape | {prof_name}/tuned req/s per round: median (min–max) | pause | RSS |")
print("|---|---|---:|---:|")
for sh in SHAPES:
    t, s = res[(sh, "tuned")], res[(sh, prof_name)]
    thr = [y["rps"] / x["rps"] for x, y in zip(t, s)]
    pz = [y["pause_ms"] / x["pause_ms"] for x, y in zip(t, s) if x["pause_ms"] > 0]
    rs = [y["rss_kib"] / x["rss_kib"] for x, y in zip(t, s)]
    print(f"| {sh} | {med(thr):.3f} ({min(thr):.3f}–{max(thr):.3f}) | {med(pz):.2f}× | {med(rs):.2f}× |")
if a.json:
    json.dump({f"{sh}/{pr}": v for (sh, pr), v in res.items()}, open(a.json, "w"), indent=1)
