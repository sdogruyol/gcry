# Kemal wrk performance log

Canonical **version-over-version** record for process-GC HTTP throughput.
Use this (not anecdotal README ranges) when judging whether a release improved performance.

## Methodology (fixed)

| Knob | Value |
|------|--------|
| App | `bench/kemal` — `GET /` (minimal) and `GET /json` (alloc-heavy JSON) |
| Build | `crystal build -Dgc_none --release` (Boehm: omit `-Dgc_none`) |
| Load | `wrk -c 100 -d 30` per path |
| Process | **Fresh server process per path** (do not chain `/` then `/json` in one process) |
| Crystal | record version in each row |
| Host | record OS/arch; prefer same machine for A/B |

**Paths**

| Path | Intent |
|------|--------|
| `/` | Near-zero alloc (“Hello World”) — allocator/GC idle path |
| `/json` | Nested JSON via `JSON.build` (user object + 8 items with blobs) — closer to real API alloc pressure |

**Rules**

1. On every **new version**, A/B the **previous tagged** release vs the new tree on the **same host**, for **both** paths.
2. Record **Requests/sec**, **Latency avg**, and **Latency max** (from wrk).
3. Compute **Δ req/s %** and **Δ lat.avg %** vs the previous gcry version **per path** (not vs Boehm).
4. Optionally re-run Boehm the same day as a ceiling reference.
5. Helper: `make bench-kemal-record PREV=v0.3.0 LABEL=0.4.0` (runs `/` and `/json`).

Do **not** compare numbers taken on different days/hosts without noting it.

## History — `GET /`

| Version | Date (UTC) | Crystal | Host | req/s | lat.avg | lat.max | Δ req/s vs prev | Δ lat.avg vs prev | Notes |
|---------|------------|---------|------|------:|--------:|--------:|----------------:|------------------:|-------|
| 0.1.0 | 2026-07-23 | 1.21.x | (prior) | ~4k | — | — | — | — | Pre–process-tuning. Not re-measured on the 0.3 host. |
| 0.2.0 | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **72101** | 31.19ms | 1.03s | **~+1700%** vs 0.1 (approx) | — | Nursery off; 64 MiB majors; static-root cache; chunk index. |
| 0.3.0 | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **72993** | 20.86ms | 246ms | **+1.2%** | **−33%** | Incremental auto-majors (same-day A/B vs 0.2.0). |
| 0.3.0 (recheck) | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **76227** | 24.08ms | 718ms | — | — | Fresh process; after `/json` handler enrichment (same binary). |
| **0.4.0** | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **76254** | 21.64ms | 494ms | **−2.7%** | **+0.5%** | Same-day A/B vs v0.3.0; full STW majors default (soundness). |
| Boehm (ref) | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **107710** | 8.11ms | 695ms | — | — | Same app/load; ceiling reference. |

## History — `GET /json`

Payload (current tree): nested object + `user` + 8 `items` with small string blobs via `JSON.build` (no `Time` on hot path).

| Version | Date (UTC) | Crystal | Host | req/s | lat.avg | lat.max | Δ req/s vs prev | Δ lat.avg vs prev | Notes |
|---------|------------|---------|------|------:|--------:|--------:|----------------:|------------------:|-------|
| 0.3.0 | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **30112** | 20.33ms | 713ms | — (baseline) | — | First formal `/json` row; enriched payload. Fresh process. |
| **0.4.0** | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **32141** | 16.28ms | 480ms | **−0.6%** vs same-day v0.3.0 (32331) | **−0.4%** | A/B vs tag v0.3.0 same day; STW default. |
| Boehm (ref) | 2026-07-23 | 1.21.0 | WSL2 x86_64 | **41748** | 9.23ms | 668ms | — | — | Same payload/load; ~77% of Boehm req/s under gcry 0.4. |

### Same-day detail (0.3.0 tree, both paths)

```
# gcry GET /
Requests/sec:  76227.06   Latency avg 24.08ms  max 718.14ms

# gcry GET /json
Requests/sec:  30112.04   Latency avg 20.33ms  max 712.97ms

# Boehm GET /
Requests/sec: 107710.07   Latency avg  8.11ms  max 694.68ms

# Boehm GET /json
Requests/sec:  41747.93   Latency avg  9.23ms  max 667.74ms
```

**Verdict:** `/json` is the more meaningful GC stress (~40% of `/` throughput under gcry). Prefer `/json` Δ when judging allocator/collector improvements; keep `/` as a sanity / idle-path check.

## How to record the next version

```sh
# Example: releasing 0.4.0, previous tag v0.3.0
make bench-kemal-record PREV=v0.3.0 LABEL=0.4.0
# Prints one markdown row per path — append under the matching History table,
# and mirror Δ bullets in CHANGELOG (both / and /json).
```
