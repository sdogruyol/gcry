# TCPSocket first-mark watch (tid 441) — 2026-08-03

`GCRY_LIVE_ATTR_WATCH_TID=441` + idle-drain, `PRECISE_MODE=0`, exclusive bin.
(`=2` / leftover `PRECISE_FIBERS` flaky — cleared env for this run.)

## Result

| sample | live 441 | watch sum | stack | parked | heap | parked% |
|--------|----------|-----------|------:|-------:|-----:|--------:|
| post-wrk | 1589 | 1589 | 0 | **35** | **1554** | 2.2% |
| idle+GC | 1593 | 1592 | 1 | 1 | **1590** | 0.1% |

max_atomic @32768 stays ~100 MiB; ESTAB=0 both samples.

## Verdict

1. **TCPSocket is almost never a parked/stack seed** — ~98% first-marked via
   **Heap** edges (transitive closure).
2. Parked still seeds a small ambient set (~2 MiB atomic post-wrk) that the
   heap walk fans into sockets + 32 KiB buffers.
3. So the cut is **not** “scrub TCPSocket words off fiber stacks”; it is
   **whatever parent graph** keeps ~1600 sockets alive (pool, fiber locals,
   server accept list, SSL, …).

## Next

Watch likely parents (Fiber / `PQ::Connection` / HTTP context / pool types) or
add a one-shot “who pointed at this socket” reverse edge sample.
