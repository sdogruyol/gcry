# 9950X EC1 thr hunt — CLOSED (MISS)

Host: AMD Ryzen 9 9950X · WSL2 · Crystal 1.21.0 · tip with post-STW sweep.
Method: `wrk -c100 -d30` med-of-3 · post-GC RSS · `/json` primary.
Bar: soft ≥90% @ ≤0.85×; hard ≥95% @ ≤1.0×. **Neither hit on default path.**

| Config | session | `/json` % | RSS × | Notes |
|--------|---------|----------:|------:|-------|
| default | `072122/` | 82.5% | 0.76× | baseline |
| default | `072954/` | 80.3% | 0.76× | confirm |
| `KEEP_CHUNKS=1` | `080248/` | **90.1%** | **3.23×** | thr soft hit; RSS fail |
| `ALLOC_BATCH=4` | `081125/` | — | — | **SEGV** → reject |
| warm 32 MiB | `081646/` | 82.0% | 2.86× | no thr↑ |
| warm 256 MiB | `082409/` | 87.0% | 3.19× | ≈KEEP; RSS fail |

EC4 soft-soak: **40/40 soft=0 hard=0**.

**Escalate:** compiler stack maps (not more retain knobs). No `v0.18.0` tag.
Parent: [2026-08-02-018-FINDINGS.md](../2026-08-02-018-FINDINGS.md).
