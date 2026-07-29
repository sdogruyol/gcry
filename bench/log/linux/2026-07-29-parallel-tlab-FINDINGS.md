# Parallel + TLAB thr A/B (blocked)

Date: 2026-07-29 · host: WSL2 i3-12100F · Crystal 1.21.0 · git `351745e`

## Method

- Kemal `bench/kemal`, `wrk -c 100 -d 30`, median-of-3 (`bench/run_all.sh kemal`).
- Parallelism: `EC_PARALLELISM=N` → `Fiber::ExecutionContext.default.resize(N)` in `server.cr` (not `CRYSTAL_WORKERS`).
- TLAB: `GCRY_FLAGS=GCRY_TLAB=1`.

## Same-day baseline (EC capacity 1, TLAB off)

Session: `bench/log/linux/2026-07-29-200917/`

| Path | % of Boehm | RSS × |
|------|----------:|------:|
| `/` | **87.7%** | **0.78×** |
| `/json` | **83.1%** | **0.79×** |

## Parallel+TLAB thr

**Not measured** — server dies under `/json` load before a stable wrk median.

Short smoke (`wrk -c 100 -d 10 /json`, release `kemal-gcry`):

| Config | Alive? | Notes |
|--------|:------:|-------|
| baseline | yes | ~37k req/s |
| `GCRY_TLAB=1` only | **no** | SEGV mid-load |
| `EC_PARALLELISM=4` only | **no** | `realloc(): invalid pointer` (libc abort) |
| EC=4 + TLAB | **no** | JSON builder corruption → SEGV |

Debug build (`--release --debug --error-trace`) under EC=4+TLAB also raised `pointer is not a gcry allocation` in `Heap#realloc` (String::Builder / Path / StaticFileHandler) before the SEGV while logging.

## Verdict

Property-test gates (steal / FREE-claim×minor / STW SP+greg+TLAB full-stack) are necessary but **not sufficient** for HTTP. Both **TLAB@EC1** and **EC>1 without TLAB** still corrupt under Kemal. Do not flip Parallel / `GCRY_TLAB` defaults; next gate is HTTP-stable Parallel and/or TLAB, then re-cut thr.
