# Parallel TLAB-off lazy — supported opt-in (productize)

Docs-only ship. Tip after fiber-scrub REJECT. Parent FINDINGS:
`../2026-07-29-parallel-tlab-FINDINGS.md`.

## Verdict

Stretch ~80% **closed (accepted)**. Campaign hold remains lazy tip
**~78.8%** `/json` (`2026-08-01-ec4-lazy-sweep/`). Parallel **TLAB-off** +
lazy sweep promoted to **supported opt-in** (not process default; EC1
remains PERF headline). Still experimental: `GCRY_TLAB=1`,
`GCRY_PARALLEL_RELEASE`.

## Smoke (same tip binary; no code change)

| Gate | Result |
|------|--------|
| EC1 `/json` med-of-3 (`wrk -c100 -d30`) | **~29.3k** (0.16 band; host soft) — `thr-ec1-smoke` → `2026-08-02-062518/` |
| EC4 quiet vs Boehm `/json` med-of-3 | **81.5%** @ ~55k / RSS **~5.5×** — `thr-ec4-quiet` → `2026-08-02-062843/` |

## Docs touched

`CHANGELOG` Unreleased, `docs/PERF.md` (Parallel opt-in section),
COMPARISON, HARDENING, POLICY, INTEGRATION, ANNOUNCE, README, FINDINGS hub.
