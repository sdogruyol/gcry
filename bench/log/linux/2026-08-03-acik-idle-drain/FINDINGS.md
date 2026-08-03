# Idle-drain: 32 KiB atomic retention (2026-08-03)

Product-ish path: exclusive bin, **`PRECISE_MODE=0`** (conservative stacks —
`=2` SEGV'd flaky under current tip+NEAR_DELTA; retention question does not
need exclusive). `wrk -c100 -d15` → dual collect → sample → idle **45s** →
dual collect → sample.

## Result

| sample | ESTAB | max_atomic @32768 | live | TCPSocket (tid 441) | Builder (437) |
|--------|------:|------------------:|-----:|--------------------:|--------------:|
| post-wrk | **0** | **95.4 MiB** (n≈3054) | 110 | n=1518 | n=594 |
| idle+GC | **0** | **95.7 MiB** (n≈3061) | 108 | n=1522 | n=329 |

Atomics ≈ **100% byteish**. Typed live stays ~few MiB.

## Verdict

**(B) false / stale reachability** — not live sockets, not a healthy pool sized
to ESTAB:

1. Zero ESTAB immediately after wrk and after idle.
2. ~1500 `TCPSocket` objects + ~95 MiB of 32 KiB `malloc_atomic` IO buffers
   remain across idle dual-collect.
3. Matches `IO::DEFAULT_BUFFER_SIZE` (32 KiB) via `IO::Buffered` / FD / HTTP
   response paths — not Array layouts.

So the RSS gap is **dead socket/buffer graph kept alive by conservative
roots** (parked stacks / heap edges), not “wrk still connected”.

## Note

`PRECISE_STACK=2` SEGV under this bin during the same session (even
`NEAR_DELTA=32`). Treat exclusive soak as regressed until bisected; idle-drain
used mode=0 on purpose.

## Next

1. Cut false roots that pin `TCPSocket` / buffered IO (scrub, stack precision
   without UAF, or finalize/close path).
2. Or app-side: ensure response/IO buffers released on close; PG pool caps.
3. Do **not** expect exclusivef FP-fill tuning to move this band.
