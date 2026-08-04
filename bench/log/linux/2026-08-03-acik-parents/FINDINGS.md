# Parent graph: TCPSocket / Digest / DB pool (2026-08-03)

Binary type map via `/gc-type-ids` (acik tip exclusive). Watches + pool URI
cap. `PRECISE_MODE=0`, idle 30s.

## Type map (hot)

| tid | name | idle n (typical) |
|-----|------|-----------------:|
| 441 | `TCPSocket` | ~1100–1600 |
| 572 | `OpenSSL::Digest` | ~1000–1500 |
| 437 | `String::Builder` | ~200–400 |
| 467 | `Fiber` | ~60–110 |
| 622 | `PQ::Connection` | ~80–90 |
| 447 | `OpenSSL::SSL::Socket::Client` | **0** live |
| 590 | `PG::Connection` | low |

## First-mark watch

| tid | name | parked | heap |
|-----|------|-------:|-----:|
| 441 | TCPSocket | ~0–2% | **~98%** |
| 572 | OpenSSL::Digest | **0** | **100%** |
| 447 | SSL Client | — | no live objects |

## DB pool cap

`DATABASE_URL` + `max_pool_size=4&max_idle_pool_size=2`:

- idle max_atomic still **~81 MiB**, TCPSocket **~1284**
- crystal-db default `max_idle_pool_size` is already **1**
- **Not** an idle PG pool sizing bug

## Verdict

1. Sockets retained via **heap parents**, not parked stack words.
2. **Not** SSL client sockets (tid 447 absent); plain `TCPSocket` (HTTP accept).
3. **`OpenSSL::Digest` tracks socket count** (JWT / OpenSSL use in acik deps) —
   also heap-only; likely co-retained with request/auth graph.
4. Pool URI caps do not move the 32 KiB atomic band.

## Next

- Trace who holds `TCPSocket` / `OpenSSL::Digest` in the HTTP/JWT path
  (Kemal keep-alive? auth middleware? fiber closure?).
- App: ensure request-scoped Digest/JWT objects are not captured by long-lived
  structures; confirm server `close` on finished connections.
