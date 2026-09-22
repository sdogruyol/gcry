#!/usr/bin/env python3
"""Which gates construct their own red arm, and which only ever had one by hand?

Every gate in this repo asserts something. The question this answers is narrower
and is the one that has bitten twice: can the gate still *fail*? Two gates had
rotted into testing nothing and shipped that way for releases
(`page-release-corruption`, `live-graph-audit`, both fixed in 0.26.0), and the
soak carried an arm labelled "EC4" for six weeks that ran one worker
(`bench/log/linux/2026-09-16-soak-worker-count/`). In each case the assertion
still ran; what was gone was its ability to come out red.

A gate's red direction is *constructed per run* when something the gate itself
executes has to fail:

  * the Makefile recipe prefixes a command with `!`, or asserts on its output
    with `grep -q`; or
  * the harness forks a child with a knob or flag that breaks the thing under
    test, and asserts on what the child did; or
  * the recipe runs the harness again under a knob or flag that restores the
    pre-fix behaviour, and the harness judges that arm itself. `--control` does
    not count: a control has to *pass*.

The third criterion was added on 2026-09-16, when `make dead-stack-root` — whose
three of four arms *require* the victim to die — was counted as "by hand" by the
first two. The tool under-counted and using it is what found that; the numbers
below moved by one gate as a result, not because anything in the tree changed.

The fork detector originally looked for `Process.run`. This repo forks through
`BoundedChild.run` (a `Process.new` with a deadline, written after a hung child
took a CI job down) and through `Process.new` directly; both are that second
criterion. A harness named only in a `--cross-compile` recipe is compiled, not
run, so it does not count. The restoring-knob regex is the names
`docs/HARDENING.md` already calls red arms, not a new class of arm. A child
arm named by `--mode=` is the same second criterion as `--child`: `scrub_midswap`
forks itself as `--mode=stale-off`, sets the guard off on the heap rather than
through an env knob, and requires that child to corrupt (2026-09-21; it had been
counted "by hand" for want of a `GCRY_*` string).

Otherwise the red direction was established once, by hand, by whoever wrote the
gate — and that fact lives in `ROADMAP.md` prose ("broken on purpose and
observed red"), which nothing re-checks.

This is a census, not a gate: it asserts nothing and fails nothing. Its output is
a number that FINDINGS can quote and a reader can re-derive. The classification
is mechanical and therefore approximate in both directions — a harness that
breaks its subject in-process without forking reads as "not constructed", a
probe that forks children (`thread-startup-cost`) reads as constructed, and a
`--control` arm that must *pass* is correctly not counted as a red arm, because a
negative control shows the harness is not the cause, not that the gate can fail.

  python3 bench/gate_arm_census.py            # summary
  python3 bench/gate_arm_census.py --list     # per-gate table
"""

from __future__ import annotations

import re
import signal
import sys
from pathlib import Path

# `| head` on a census is the obvious way to read it, and a tool that dies on
# SIGPIPE while the subject of the day is swallowed exit statuses would be a
# poor joke.
try:
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
except (AttributeError, ValueError):  # not POSIX, or not the main thread
    pass

ROOT = Path(__file__).resolve().parent.parent


def makefile_targets() -> dict[str, list[str]]:
    targets: dict[str, list[str]] = {}
    current: str | None = None
    for line in (ROOT / "Makefile").read_text().splitlines():
        head = re.match(r"^([A-Za-z0-9_.-]+):(?!=)", line)
        if head:
            current = head.group(1)
            targets[current] = []
        elif line.startswith("\t") and current:
            targets[current].append(line[1:])
    return targets


def recipe_runs_binary(recipe: str, stem: str) -> bool:
    """The recipe executes the built harness, not only compiles it.

    Type-check targets list `bench/*.cr` for `crystal build --cross-compile`
    and never run them. Counting those as per-run would credit a compile with
    a red arm the job never constructs.
    """
    for line in recipe.splitlines():
        if f"$(BIN)/{stem}" not in line and f"bin/{stem}" not in line:
            continue
        if "--cross-compile" in line:
            continue
        if re.search(r"\bbuild\b", line) and "-o" in line:
            continue
        return True
    return False


def harness_constructs_red(stem: str) -> bool:
    """The harness forks a child under a breaking knob/flag and judges it."""
    path = ROOT / "bench" / f"{stem}.cr"
    if not path.exists():
        return False
    src = path.read_text()
    forks = (
        re.search(r"Process\.(?:run|new)|run_child|spawn_child|BoundedChild", src)
        is not None
    )
    judges = (
        re.search(r"failures <<|failures \+=|exit 1|exit\(1\)", src) is not None
    )
    breaks = re.search(r'"GCRY_\w+"\s*=>|--child|--overshoot|--mode=', src) is not None
    return forks and judges and breaks


# Knob names that mean "restore the behaviour this gate exists to catch".
# The extra alternatives are names HARDENING already calls a red arm; they
# were missing from the detector, not from the recipes.
BREAKING_KNOB = re.compile(
    r"GCRY_[A-Z0-9_]*(NOROOT|UNROOTED|NOGROW|DISABLE|_CAP|INJECT|FROM_BASE|LIBC"
    r"|NO_EVICT|FREE_OLD|SKIP_WHEN_BUSY|FIXED_SLOTS|BOUNDED_RESUME|ROOT_LAZY"
    r"|LATE_CLEAR|UNCHECKED)"
    r"[A-Z0-9_]*=|GCRY_[A-Z0-9_]+=0(\s|$)"
)

# Arms named by a flag rather than a knob. `--control` is deliberately absent:
# a control has to *pass*, so it shows the harness is not the cause and not that
# the gate can fail.
BREAKING_FLAG = re.compile(
    r"--(noroot|unrooted|leaking|inject|broken|disabled|stall|libc|"
    r"lazy|no-evict|overshoot|nogrow)\b"
)


def recipe_constructs_red(recipe: str, harnesses: list[str]) -> bool:
    """The recipe requires a command to fail, asserts on its output, or runs the
    harness again under a knob that restores the pre-fix behaviour."""
    must_fail = re.search(r"(^|\s|;)!\s*\S", recipe, re.M) is not None
    asserts_output = re.search(r"\|\s*grep -q", recipe) is not None
    broken_arm = False
    for line in recipe.splitlines():
        if not (BREAKING_KNOB.search(line) or BREAKING_FLAG.search(line)):
            continue
        if any(harness_judges(h) for h in harnesses):
            broken_arm = True
    return must_fail or asserts_output or broken_arm


def harness_judges(stem: str) -> bool:
    """The harness decides an arm rather than only printing it."""
    path = ROOT / "bench" / f"{stem}.cr"
    if not path.exists():
        return False
    return (
        re.search(r"failures <<|failures \+=|exit 1|exit\(1\)", path.read_text())
        is not None
    )


def census() -> list[tuple[str, bool, bool, list[str]]]:
    rows = []
    for name, lines in makefile_targets().items():
        recipe = "\n".join(lines)
        harnesses = sorted(set(re.findall(r"bench/([a-z0-9_]+)\.cr", recipe)))
        if not harnesses:
            continue
        rows.append(
            (
                name,
                recipe_constructs_red(recipe, harnesses),
                any(
                    harness_constructs_red(h) and recipe_runs_binary(recipe, h)
                    for h in harnesses
                ),
                harnesses,
            )
        )
    return sorted(rows)


def classify_prose(per_run_names):
    """A claim that a gate was broken by hand is worth what re-checks it.

    Counting all of them as unchecked was true when it was written and stopped
    being true as the arms were built: several name a gate that now constructs
    its red direction every run, and several rest on a `process_spec`
    assertion that runs on every push. What is left — a claim with neither — is
    the number this line was trying to report.
    """
    text = (ROOT / "ROADMAP.md").read_text().splitlines()
    all_targets = set(makefile_targets())
    backed, script_backed, spec_backed, unbacked = [], [], [], []
    for i, line in enumerate(text, 1):
        if "broken on purpose" not in line and "observed red" not in line:
            continue
        ctx = " ".join(text[max(0, i - 8):i + 2])
        # `\s+`, because ROADMAP wraps: a claim naming "`make\n      raw-buf-check`"
        # went into the unbacked pile for the width of the column it was typed in.
        gates = set(re.findall(r"make\s+([a-z0-9-]+)", ctx))
        if gates & per_run_names:
            backed.append((i, sorted(gates & per_run_names)))
        elif gates & all_targets:
            # A gate the census does not judge — `raw-buf-check` and friends are
            # `ci/*.py` checks with no bench harness, so they have no row above.
            # They still run on every push and still fail the build.
            script_backed.append((i, sorted(gates & all_targets)))
        elif re.search(r"process_spec|[a-z_]+_spec\b", ctx):
            spec_backed.append((i, None))
        else:
            unbacked.append((i, None))
    return backed, script_backed, spec_backed, unbacked


def main() -> int:
    rows = census()
    per_run = [r for r in rows if r[1] or r[2]]
    by_hand = [r for r in rows if not (r[1] or r[2])]

    if "--list" in sys.argv:
        print(f"{'gate':<32}{'recipe':<8}{'harness':<9}red arm")
        for name, mk, hz, _ in rows:
            verdict = "per run" if (mk or hz) else "by hand, once"
            print(f"{name:<32}{int(mk):<8}{int(hz):<9}{verdict}")
        print()

    print(f"harness-driven gates:              {len(rows)}")
    print(f"red direction constructed per run: {len(per_run)}")
    print(f"red direction established by hand: {len(by_hand)}")
    per_run_names = {r[0] for r in rows if r[1] or r[2]}
    backed, script_backed, spec_backed, unbacked = classify_prose(per_run_names)
    total = len(backed) + len(script_backed) + len(spec_backed) + len(unbacked)
    print(f"prose claims of a hand break:      {total}"
          f" — {len(backed)} name a gate that builds its arm per run,"
          f" {len(script_backed)} a script gate, {len(spec_backed)} rest on a spec,"
          f" {len(unbacked)} on nothing")
    if unbacked and "--list" in sys.argv:
        print("  unbacked, by ROADMAP line: "
              + ", ".join(str(n) for n, _ in unbacked))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
