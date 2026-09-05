#!/usr/bin/env python3
"""Rotate base, same-binary null, and candidate microbenchmarks in fresh processes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

from analyze import paired_ratios


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--metric", default="ns_per_alloc", help="positive cost metric; lower is better")
    parser.add_argument("--args", nargs=argparse.REMAINDER, default=[])
    args = parser.parse_args()
    if args.rounds < 2:
        parser.error("at least two rounds required")
    args.output.mkdir(parents=True, exist_ok=False)
    arms = {"base": str(args.base.resolve()), "null": str(args.base.resolve()), "candidate": str(args.candidate.resolve())}
    manifest = dict(arms=arms, arguments=args.args, rounds=args.rounds, metric=args.metric,
                    binary_sha256={name: hashlib.sha256(Path(path).read_bytes()).hexdigest() for name, path in arms.items()},
                    environment={k: v for k, v in os.environ.items() if k.startswith("GCRY_") or k in ("EC_PARALLELISM", "CRYSTAL_WORKERS")},
                    load_start=os.getloadavg())
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2))
    values = {name: [] for name in arms}
    with (args.output / "trials.jsonl").open("w") as output:
        for round_id in range(args.rounds):
            names = list(arms)
            for position in range(len(names)):
                name = names[(position + round_id) % len(names)]
                row = dict(arm=name, round=round_id, position=position, load1=os.getloadavg()[0])
                try:
                    result = subprocess.run([arms[name], *args.args], capture_output=True, text=True, timeout=60)
                    (args.output / f"{round_id:03d}-{name}.txt").write_text(result.stdout + result.stderr)
                    if result.returncode:
                        raise ValueError(f"exit {result.returncode}")
                    samples = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
                    samples = [sample for sample in samples if args.metric in sample]
                    if len(samples) != 1 or samples[0][args.metric] <= 0:
                        raise ValueError("expected one positive measurement; run survival cases separately")
                    row["sample"] = samples[0]
                    values[name].append(samples[0][args.metric])
                except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                    row["error"] = str(error)
                output.write(json.dumps(row) + "\n")
                output.flush()
                if "error" in row:
                    print(json.dumps(row), flush=True)
                    return 1
            print(f"round {round_id + 1}/{args.rounds}", flush=True)
    summary = {name: paired_ratios(xs, values["base"]) for name, xs in values.items()}
    summary["load_end"] = os.getloadavg()
    (args.output / "analysis.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
