# Mark-miss A/B (soft realloc errors)

Kemal EC4, TLAB off, `wrk -c100 -d8` `/json`, 40× each. Soft =
log contains `pointer is not a gcry allocation` (process may still be alive).

| Config | Soft | Hard (SEGV in log) |
|--------|-----:|-------------------:|
| default (release empties) | 22/40 | 0 in clean-* (1 die in earlier fail set) |
| `GCRY_STW_STACK_LAG=2097152` | 24/40 | 0 |
| `GCRY_KEEP_CHUNKS=1` | 5/40 | 0 |

Follow-up gate (no empty release when multi-mutator): see
`../2026-07-31-ec4-no-release-parallel/` — soft **3/40**, hard **0**, OK **40/40**.

LAG increase does not help. Empty-chunk munmap amplifies residual mark-miss.
