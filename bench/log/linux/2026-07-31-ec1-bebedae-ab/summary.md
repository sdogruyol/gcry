# EC1 thr: bebedae (v0.15 cut) vs HEAD (`cfa6435`)

Host: WSL2 · Crystal 1.21.0 · `wrk -c 100 -d 30` · median-of-3 · interleaved · soft=0

**Binaries rebuilt with distinct hashes** (earlier `kemal-gcry-bebedae` was a
mistaken copy of HEAD — discard those A/Bs).

## Quiet cut (gate)

Session files: `final-raw.tsv`, `final-slash-raw.tsv`.

| Binary | `/json` % Boehm | `/` % Boehm | vs bebedae `/json` |
|--------|---------------:|------------:|-------------------:|
| bebedae (`bebedae69`) | **~85%** | ~82% | 100% |
| HEAD (`cfa6435`) | **~81%** | ~79% | **~95.5%** |
| Boehm | 100% | 100% | — |

v0.15 PERF claimed ~86%; this host reproduces bebedae in the mid-80s.
**HEAD still ~4pp of Boehm short → no 0.16 tag.**

## Bisect (relative thr, noisy host)

| Tip | Notes |
|-----|--------|
| bebedae → a84 / 65f | ≈ bebedae (scrub 512 + Thread.lock OK) |
| **57e9e44** | **~55%** — Parallel full fiber/pthread STW on EC1 |
| 4cb9ef4 / 94aadaf | ~94% beb — multi gate helps; `phase_stacks` still ~3ms (SYSMON/`"main"`) |
| af1a74a | ~97% beb — post-STW flush appears; stacks still ~3ms |
| 97ad560 | ~88% beb — size-class freelist locks |
| **cfa6435 (HEAD)** | **~95% beb** — cheap EC1 other-thread scan; stacks ~0.02ms again |

## Phase snapshot (`d=12` wrk, illustrative)

| | stacks ms | sweep ms | flush ms | scrub MB | cols |
|--|----------:|---------:|---------:|---------:|-----:|
| bebedae | 0.02 | ~5–6 | 0* | ~26 | ~60 |
| 94a / af1 | **~3.3** | ~5–6 | ~1.8 | ~3.7 | ~70 |
| HEAD | **0.02** | **~9–10** | ~2–3 | ~3.7 | ~67 |

\* `phase_flush` metric absent on bebedae.

## Rejected levers

- **EC1 4 KiB blind scrub** (bebedae-style): restores scrub volume, **hurts** thr
  vs 512+`clear_range_safe` (and 4 KiB×`clear_range_safe` worse — page probes).
- **`GCRY_TYPE_ID_GATE=1`**: not the residual gap.
- **EC1 freelist → `@alloc_lock`**: small noisy gain; nesting risk with
  `with_alloc_lock` / refill — reverted.

## Residual (after `cfa6435`)

~4–5% vs bebedae / ~4pp of Boehm. Suspects not closed:

1. Higher `phase_sweep` on HEAD (~9–10 vs ~5–6 ms).
2. Post-STW `phase_flush` (~2–3 ms; empty/dormant/page release).
3. Slightly higher collect rate (less parked-fiber scrub volume).
4. Alloc-path atomics / size-class locks (net partially masked by scan fix).

## Sweep fix (working tree → `kemal-gcry-sweep2`)

1. STW: non-CAS `live_objects_sub` / `free_bytes_add`; batch dead count on
   fully-empty chunks.
2. Empty dormant/munmap: set rebuild mask → one `rebuild_size_class_freelist`
   per class (was `unlink_freelist_range` × empties).
3. `flush_pending_dormant_chunks` returns if `dormant_chunk_bytes == 0`.

Phase smoke (`d=12`): sweep2 p50 **7.9ms** / sweep **3.6ms** vs bebedae
p50 ~10ms / sweep ~6.7ms; flush ~1.5ms.

### Thr vs bebedae (same-host, Boehm hot ~40–43k)

| Session | sweep2 %beb `/json` | sweep2 %B | bebedae %B | notes |
|---------|--------------------:|----------:|-----------:|-------|
| `sweep2-thr-raw` med-of-3 | **98.0%** | 78.5% | 80.1% | `/` **100.8%** beb; RSS ~0.79× |
| `sweep2-final-raw` med-of-5 | **97.3%** | 77.8% | 79.9% | host Boehm elevated |

Absolute % of Boehm depressed for **both** while Boehm runs ~41k (v0.15 cut
had Boehm ~38k → bebedae ~86%). Relative gap to v0.15 closed.

Soft soak: **0/10** EC1. `collect_spec` + dormant regression green.

## Next

1. Quiet-host re-cut (Boehm ~36–39k band) → PERF.md / 0.16 if `/json` ~86%.
2. Commit sweep/accounting changes when ready.
