# Two CI rounds spent on a fault that printed one line

Date: 2026-09-18 · host: AMD Ryzen AI 9 465, Linux 7.2.4

## What it cost

`make chunk-search-race` faulted on the Darwin runner, twice on the same commit,
and this is the entire evidence both runs produced:

```
pool: search survived concurrent trim
… seven more arms, each ok …
handoff-fresh: cursor survived a sweep during handoff
Process terminated because of an invalid memory access
```

No address. No backtrace. No signal number. And — because every child prints its
own `ok` and then exits 0 — **no way to tell which of the nine arms produced it**,
or whether it was a child at all rather than the parent dying at exit. Two
30-minute rounds went into narrowing that by reasoning, and the answer is still
an inference.

Two separate blindnesses, both fixed here.

## 1. A library build installs no handler

`bench/chunk_search_race.cr` is built **without** `-Dgc_none` on purpose: its
subject is a library heap. So `GC.init` never runs, nothing calls
`SegvReport.install_if_requested`, and a fault gets Crystal's generic handler.
`large_cache_race.cr` and `dormant_flush_race.cr` already carried the one-liner
for this — `Gcry::SegvReport.install if ENV["GCRY_SEGV_REPORT"]? == "1"` — and
this harness did not.

It does now, and the recipe sets the variable so CI gets the report without
anyone remembering to. Verified locally by giving a scratch copy a deliberate
faulting arm:

```
gcry: SIGSEGV at 0x10 — no gcry heap exists in this process
gcry: writer — the faulting instruction is at 0x55ff32c7cf0a, outside the
executable's own text — a libc or kernel frame. sp 0x7ffcdbdf58d0 fp … cr2 0x10
```

The same variable is now set for `dormant-flush-race`, `large-cache-race` and
`find-block-race`: all three are gates whose failure mode is a fault, all three
were printing one line for it, and all four recipes still pass here.

## 2. The parent did not name the arm

It collected `failed ||= !result.ok` and exited 1 without saying which mode, so a
crash *after* an arm's `ok` line was indistinguishable from the parent crashing.
It now collects the failing modes and prints them, separating a non-zero exit
from a timeout:

```
FAIL: crash — the output above is that child's, stdout and stderr together
```

Verified the same way: a scratch arm that faults is named, and the nine shipped
arms still pass.

## What this does not do

It does not explain the Darwin crash — that needs the next occurrence. It makes
the next occurrence say which arm, on what address, and what gcry knows about
that address, which is the difference between an hour and a round trip.
