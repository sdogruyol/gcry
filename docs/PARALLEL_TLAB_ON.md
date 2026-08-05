# Parallel TLAB-on — correctness plan

**Branch:** `plan/parallel-tlab-on`  
**Status:** kickoff (plan only — no product default change)  
**Parent FINDINGS:** [bench/log/linux/2026-07-29-parallel-tlab-FINDINGS.md](../bench/log/linux/2026-07-29-parallel-tlab-FINDINGS.md)

## Goal

Make **`GCRY_TLAB=1` under EC>1** a **correctness-credible** path (then optionally
thr), **without** regressing the **supported Parallel opt-in** (TLAB **off** +
lazy sweep).

This is **not** “make TLAB the default” and **not** “beat Boehm on EC4 thr
first.” Correctness gates before any thr claim.

## Current matrix (do not blur)

| Config | Status | Notes |
|--------|--------|-------|
| EC1, TLAB off | **Product default** | Linux Kemal headline (~87% / ~0.80×) |
| EC>1, TLAB **off**, lazy on, munmap off | **Supported opt-in** | ~79% `/json`, ~5–6× RSS; soft 0/40 |
| EC>1 + `GCRY_PARALLEL_DORMANT=1` | Supported RSS stretch | ~75% @ ~4× |
| `GCRY_TLAB=1` (any EC) | **Unsupported** | stderr warn; research / A/B |
| `GCRY_PARALLEL_RELEASE=1` | **Unsupported** | hang / in-STW sweep risk |

Ship rule: **never** change Parallel defaults or TLAB-off behavior to chase
TLAB-on thr. Escapes stay opt-in behind env + warn until promoted.

## What we already know (TLAB-on)

From FINDINGS (2026-07-31 … 2026-08-02):

- **Thr:** EC4 TLAB-on ~**½** of TLAB-off (~24–26k vs ~42–55k). Not a win.
- **Why thr loses:** hit path still pays `find_block` + slot lock; refill /
  counters historically contended with `@alloc_lock` / `@index_lock`.
- **Correctness history:** process-STW × TLAB freelist UAF class was fixed;
  CI gates `stw_mt_property_test --tlab` (workers 2,4 + nursery combo).
- **EC1 TLAB:** correctness-supported as opt-in, **not** a thr default (~71–77%
  of TLAB-off abs on quiet cuts).
- **Soak:** older TLAB@EC4 soak had DIE rates worse than TLAB-off; re-measure
  on tip before claiming quiet.

## Non-goals (this epic phase)

- Changing process default EC size or enabling TLAB by default
- Enabling Parallel empty munmap (`PARALLEL_RELEASE`)
- Maps / write-barrier / Windows
- Kemal EC1 ≥90%@≤0.85× (shard-only exhausted; separate epic)

## Correctness definition (“credible”)

TLAB-on under Parallel is **credible** when all of the following hold on tip
(same host method as FINDINGS; record SHA + Crystal):

1. **STW property:** `stw_mt_property_test --tlab --workers=2,4` and
   `--tlab --nursery --workers=2,4` green (CI already; local med-of-N soak).
2. **Soft soak:** EC4 + `GCRY_TLAB=1` soft-soak **0/40** (same harness as
   TLAB-off productize). No unexplained SEGV / DIE.
3. **Invariant:** `GCRY_DEBUG_INVARIANTS=1` compatible smoke (or documented
   exclusion if checker×alloc still unsafe — do not paper over).
4. **No regress on supported path:** EC4 TLAB-off soft **0/40** and quiet
   `/json` within noise of ~79% band after any TLAB-on fix lands.
5. **Warn policy:** keep stderr unsupported warn until (1)–(4) land **and**
   a written promote decision; then either drop warn or split
   “correctness-ok / thr-experimental.”

Thr gate is **secondary** and only after (1)–(4):
- Soft target: TLAB-on EC4 `/json` **≥** TLAB-off − 10pp (same host), or a
  documented reason the gap is structural.
- Do **not** require ≥ Boehm EC4 to promote correctness.

## Work sequence (ordered)

### Phase A — Baseline tip (measure, no code)

Re-cut on current `master` / this branch tip, Crystal ≥ 1.21, WSL2:

| # | Harness | Pass |
|---|---------|------|
| A1 | `stw_mt_property_test --tlab --workers=2,4` (+ nursery) | exit 0 |
| A2 | Soft-soak EC4 TLAB-**off** (control) | 0/40 |
| A3 | Soft-soak EC4 TLAB-**on** | 0/40 (or file failures) |
| A4 | Quiet Kemal EC4 med-of-3 `/json` TLAB-off vs TLAB-on | record % / RSS / pause |

**Harness note:** `bench/soft_soak_ec4.sh` currently **refuses** `GCRY_TLAB=1`
(supported-path gate). For A3 add an explicit escape, e.g.
`SOFT_SOAK_ALLOW_TLAB=1`, or a sibling `soft_soak_ec4_tlab.sh` that keeps the
same classify logic but does **not** unset `GCRY_TLAB`. Do not weaken A2’s
refusal on the default script.

Log under `bench/log/linux/YYYY-MM-DD-ec4-tlab-on-baseline/`.  
Update FINDINGS hub with a short “tip baseline” section.

**Stop / branch decision after A:**

- If A3 fails (soft/hard) → Phase **B** (crash/UAF class).
- If A3 green but A4 RSS/thr cliffs → Phase **B′** (RSS / reclaim) before C.
- Tip baseline `2026-08-05-ec4-tlab-on-baseline/`: A1–A3 **PASS**; A4 TLAB-on
  quiet RSS ~**126×** vs TLAB-off ~**6×** → **B′ next**, not thr C.

### Phase B — Crash / soft correctness (only if A1–A3 fail)

Likely residual classes (historical; confirm with A failures):

1. **STW × TLAB freelist** — suspended mutator holding slot/refill; sweep must
   not assume global freelist alone owns FREE nodes.
2. **Empty-chunk / index vs TLAB heads** — stale FREE after release (EC1
   `find_block` SEGV history); Parallel munmap stays **off**.
3. **Nursery × TLAB** — CI covers `--tlab --nursery`; any tip failure gets a
   minimal repro + seed before “perf” work.
4. **Fiber scan depth** — TLAB forces fuller stack scan; LAG / scrub knobs
   must not be “fixed” by weakening roots.

Rules for B patches:

- Prefer tests first (`stw_mt_property_test` seed, or a tiny focused bench).
- Every patch runs **A2** (TLAB-off soak) before merge to this plan branch.
- No Parallel default flips in B.

### Phase B′ — RSS / reclaim under TLAB-on *(measured 2026-08-05)*

Soft-soak does **not** gate RSS. Tip A4: TLAB-on alone ~**126×** RSS /
~1.9 GiB (Parallel reclaim off). Hub:
`bench/log/linux/2026-08-05-ec4-tlab-rss-bp/`.

**Cause:** Parallel empty reclaim off + TLAB chunk growth — not a freelist
UAF. **Fix (research env, no default flip):**

```bash
EC_PARALLELISM=4 GCRY_TLAB=1 \
  GCRY_PARALLEL_DORMANT=1 GCRY_EMPTY_CHUNK_RETAIN=33554432
```

| | `/json` abs | RSS × |
|--|------------:|------:|
| TLAB-on alone | ~48k | ~**126×** |
| TLAB + dormant32 | ~**58k** | ~**3.5×** |
| TLAB-off Parallel | ~108k | ~**6×** |

Soft-soak B1 recipe **20/20** soft=0. **Do not** enable `PARALLEL_RELEASE`.
Optional later: stderr hint when `GCRY_TLAB=1`∧EC>1 without dormant; or
auto bounded dormant (product PR).

### Phase C — Thr residual (only after B/B′ quiet)

Only if crash gates are green **and** quiet RSS is in a plausible band:

1. Profile TLAB hit path (lock + `find_block`) under EC4 `/json`.
2. One lever at a time; reject if TLAB-off quiet regresses.
3. Candidates (from FINDINGS — re-validate, do not assume): atomic counters
   on hit, safer epoch/`find_block` elision, refill batching that does not
   amplify `@index_lock`.

Keep `GCRY_TLAB` warn until promote criteria below.

### Phase D — Promote decision

Promote TLAB-on from **unsupported** → **correctness-supported opt-in**
(still not default) only if:

- [ ] A1–A3 green on two hosts or two days (noise control)
- [ ] A4 documented; thr gap accepted or closed enough
- [ ] POLICY / HARDENING / COMPARISON / PERF Parallel section updated
- [ ] stderr warn removed or reworded (“thr experimental”)
- [ ] Supported TLAB-off path unchanged (defaults + lazy + no munmap)

## Harnesses (use these — don’t invent)

| Tool | Role |
|------|------|
| `bench/stw_mt_property_test.cr --tlab` | Process STW × Parallel alloc |
| `make soft-soak-ec4` (or EC4 soak scripts used in productize) | Soft/hard errors |
| `bench/kemal` + `EC_PARALLELISM=4` | Thr / RSS quiet cuts |
| `bench/nursery_tlab_smoke.cr` | Nursery × TLAB smoke |
| CI jobs already building `--tlab` variants | Regression net |

## Doc touchpoints (when promoting — not day one)

- [docs/POLICY.md](POLICY.md) — Parallel row  
- [docs/HARDENING.md](HARDENING.md) — `GCRY_TLAB`  
- [docs/PERF.md](PERF.md) — Parallel opt-in section  
- [docs/COMPARISON.md](COMPARISON.md) — “stay on Boehm if…”  
- [DESIGN.md](../DESIGN.md) — Parallel+TLAB frontier  
- FINDINGS hub — tip baseline + promote note  

## First concrete next step

**Phase A on this branch:** tip baseline A1→A4, write
`bench/log/linux/<session>/FINDINGS.md`, then decide B vs C.

Do not start thr micro-opts before A3 is green.
