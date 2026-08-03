# tip+EC acik baseline — valid 2xx (2026-08-03)

Host: WSL2 / Ryzen 9 9950X. Demo DB migrated + seeded (405 submissions).
`wrk -c100 -d30`, med-of-3, `REQUIRE_2XX=1`. Script: `bench/acik_stackmap_ab.sh`.
Session: this directory. Smoke (1×15s): `../2026-08-03-acik-tip-baseline2/`.

## Invalid prior cuts

| Session | Problem |
|---------|---------|
| `acik-tip-baseline`, `acik-stackmap-smoke3` | Demo DB missing `submissions` → **100% Non-2xx** |
| Reported ~**15–16×** RSS | Exception-path retention, not the fat-app gate |

Harness now fails trials with Non-2xx (`REQUIRE_2XX=1`).

## Valid med-of-3 (non2xx=0)

| variant | thr med | thr % Boehm | RSS KiB med | × Boehm |
|---------|--------:|------------:|------------:|--------:|
| boehm (system 1.21.0) | 255 | 100% | 43504 | 1.00× |
| sys (system + gcry, no EC) | 263 | 103% | 370060 | **8.51×** |
| tipec (tip + EC + gcry) | 260 | 102% | 368052 | **8.46×** |

Trials (RSS KiB):

| | boehm | sys | tipec |
|--|------:|----:|------:|
| 1 | 43764 | 370060 | 378324 |
| 2 | 43504 | 371260 | 323028 |
| 3 | 23160 | 366672 | 368052 |

## Verdict

1. **tip+EC is not the RSS regressor** vs system Crystal+gcry — both ~**8.5×**.
2. Prior “~15× tip base” was a **false alarm** (broken DB).
3. Valid cut on this host is still **worse** than the i3 Linux tip headline
   ~**3.43×** (`docs/ACIKTURKIYE.md`) — host / demo-data / current gcry tree,
   not tip compiler. Gate for stack maps remains closing that gap.
4. Thr is ~**Boehm-parity** on real 200s (exception-path thr ~400 was noise).

## Next

- Walker hit wiring + exclusive A/B against this ~8.5× baseline
- Optionally bisect why 9950X demo cut ≫ i3 3.43× (separate from tip)
