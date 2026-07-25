# acikturkiye dogfood (macOS)

**Darwin-only.** Do not fold these into the Linux verdict in [ACIKTURKIYE.md](ACIKTURKIYE.md).

Same app and script as Linux: sibling `../acikturkiye`, `wrk -c 100 -d 30`, `--release`, median-of-3 vs Boehm, post-`/gc-collect` RSS.

## Platform notes

| | |
|--|--|
| Crystal | **≥ 1.21** — rebuild on that toolchain (`gcry` `.tool-versions`) |
| STW | Mach suspend (signal STW under HTTP was ~hang / ~2 req/s) |
| Soft-dirty | N/A |
| Host page | **16 KiB** on Apple Silicon — free-page reclaim uses `sysconf(PAGESIZE)` |
| Free-page RSS | `MADV_DONTNEED` is a no-op; process default uses `mach_vm_deallocate` + `allocate(FIXED)` |
| Blacklist | Default **off** on Darwin (`GCRY_BLACKLIST=1` to opt in) |
| Conservative scan | Untyped payloads (`type_id ≤ 0`) are **object-base only** (cuts interior false hits) |
| Compare | Only same-host Darwin Boehm — never cite vs Linux % |

## Verdict — macOS aarch64 (2026-07-25)

Same host, Crystal 1.21.0, Apple Silicon, `wrk -c 100 -d 30`, median of 3, scrub **off** (`LABEL=macos-aarch64-20260725`):

| | thr (trial median) | post-GC RSS × |
|--|-------------------:|--------------:|
| **gcry vs Boehm** | **~94%** | **~16.6×** |

### RSS work (same day)

Shipped earlier: 16 KiB `mach_vm` free-page release, Darwin blacklist off, skip `__const` roots, `type_id > 0` gate, base-only scan of untyped buffers.

Further shard-only pass (still same day):

| Change | Result |
|--------|--------|
| Darwin `large_cache_retain=0` | Avoids retaining free large maps |
| `scan_cap` / `GCRY_SCAN_CAPS` | Clips size-class padding; **did not move** `size_class_live_bytes` on this app (~0.66–0.88 GiB either way) |
| Hardened `register_layouts` (mixed unions + embedded structs → scan_cap) | Safer `GCRY_AUTO_LAYOUTS=1`; still not process-default (under-retention risk) |
| Default AUTO / leaf empties / scan_cap `base_only` | **Rejected** — UAF or higher RSS under wrk |

| Smoke (`wrk -c 100 -d 15–20`) | thr % | post-GC RSS × |
|--|------------------------:|--------------:|
| After reclaim + buffer base-only | **~85–88%** | **~10–14×** (noisy; live set dominates) |

`free_bytes` after collect stays small — reclaim works. **`size_class_live_bytes` stays ~0.7–0.9 GiB`** (dense conservative live). That is the ceiling without stack maps.

**5× Boehm RSS (~≤230 MiB on this host) is not reachable with safe shard-only heuristics.** Same wall as Linux acikturkiye (~2.8×): needs **compiler stack maps**. Do not average with [ACIKTURKIYE.md](ACIKTURKIYE.md).

| Trial | thr % Boehm | post-GC RSS × | gcry / Boehm req/s |
|------:|------------:|--------------:|-------------------:|
| 1 | 91.6% | 17.03× | 947 / 1034 |
| 2 | 94.0% | 19.68× | 889 / 946 |
| 3 | 93.6% | 15.64× | 838 / 895 |
| **median** | **94.0%** | **16.63×** | — |

Timeouts: 0 / 0 all trials.

## History (macOS)

| Date / label | thr % | RSS × | Notes |
|--------------|------:|------:|-------|
| 2026-07-24 smoke | — | — | Pre-Mach hang (~2.5 rps) |
| 2026-07-25 `macos-aarch64-20260725` | **~94%** | **~16.6×** | Mach STW; median of 3 |
| 2026-07-25 RSS pass | ~88% | **~12–14×** | `mach_vm` @ 16 KiB; blacklist off; buffer base-only; **5× blocked** |
| 2026-07-25 shard polish | ~85% | **~10–14×** smoke | `large_cache=0`; scan_cap opt-in; AUTO still unsafe as default |

## How to measure

```sh
# Crystal 1.21+
cd ../acikturkiye
ACIKTURKIYE_ENV=demo crystal build -Dgc_none --release src/acikturkiye.cr -o bin/acikturkiye-gcry
ACIKTURKIYE_ENV=demo crystal build --release src/acikturkiye.cr -o bin/acikturkiye-boehm
LABEL=macos-aarch64-$(date +%Y%m%d) ../gcry/bench/median_acikturkiye_boehm.sh
# Update THIS file only
```

Toy Kemal (macOS): [PERF-macos.md](PERF-macos.md).
