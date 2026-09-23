# `make stw-ack-window` counted threads; the question was about one thread

**Date:** 2026-09-23 · CI run `35839647107` (`sampling gates (x86_64)`, step
`STW stop epoch`) · local: Linux 7.0.0-31-generic x86_64 (QEMU), Crystal 1.21.0

The step went red on a commit that changed only the parallel-mark
helpers' idle loop — code that does not run in this harness (one mark
worker, no helpers):

```
no-tls       slot=0 acked=true woke=true no_tls_delta=1 listed_delta=1 ack_unavailable=0
no-tls+old   slot=0 acked=false woke=true no_tls_delta=1 listed_delta=1 ack_unavailable=0
FAIL the shipped path added 1 thread(s) to Crystal's list from a signal handler
```

The shipped line refutes its own verdict. The harness holds `Thread.lock`
while it signals the raw pthread, exactly as a stop does. A handler that
called into the runtime — `::Thread.current` taking its creating branch —
would block on that lock and **never acknowledge**; that is the red arm,
`acked=false`. The shipped arm acknowledged (`acked=true`) through its
reserved slot and counted the no-TLS delivery (`no_tls_delta=1`), which
is the fixed path working.

So `listed_delta=1` came from somewhere else. The measurement was
`Thread.unsafe_each` counted before and ~400 ms later, and any thread
joining Crystal's list in that window counts — most plausibly a runtime
thread started lazily around the child's first `sleep`. Locally, 30 of
30 shipped runs read `listed_delta=0`; in CI, one failure in the last
30+ runs of that step. A rare race in the instrument, not in the
collector.

## The fix

Ask the question the gate is about: was **this raw thread** adopted? The
accessor the pre-table path calls creates a `Thread` for the calling
thread, so the adopted object's `@system_handle` is exactly the raw
thread's `tid`. `adopted` counts listed threads carrying that handle;
both arms now assert on it — shipped must be 0, the red arm must be 1 —
and `listed_delta` stays printed for context.

```
no-tls       … listed_delta=0 adopted=0     (shipped: PASS)
no-tls+old   … listed_delta=1 adopted=1     (red arm: still red)
```

Identity instead of a count removes the window entirely rather than
narrowing it.
