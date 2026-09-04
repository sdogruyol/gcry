# Phase 7 — headerless blocks (`-Dgcry_headerless`)

Branch `simdgc-headerless`, forked from `simdgc`. This is the RSS phase: 16 B
per object, which is **50% of a class-0 block**, aimed at RSS × Boehm < 1.0 —
the half of the shipping bar (`EC1 /json ≥95% @ ≤1.0× RSS`) that the `simdgc`
branch showed it can actually move (bitmap alloc took rss_x 1.004 → 0.893).

## Why this needs staging rather than one commit

Measured blast radius before starting: **207 `BlockHeader` field reads, 97
`from_user`/`user_from`, 154 `header.value` reads, 36 `BlockHeader::SIZE`
arithmetic sites, across 22 files**, plus six diagnostics to port
(`poison_holders`, `invariant`, `mark_audit`, `address_space_audit`,
`heap_dump`, `segv_report`) with their purpose-broken gates re-run and observed
**red**, which is this repo's bar rather than "the specs pass".

In a *conservative* collector a missed site is not a failing test — it is a
use-after-free that surfaces days later under load, which is the shape of the
open `String#empty?` hunt. So each step below is behaviour-preserving on its own
and independently gated.

## Where each header field goes

| field | today | headerless |
|---|---|---|
| `size : UInt32` | header | chunk `size_class` (small) / `mapped_bytes` (large) |
| `next_free : Void*` | header | **already dead** under `bitmap_alloc` — the pool cursor replaced the freelist |
| `FREE` | flag bit | `occ` bitmap (already: `block_allocated?`) |
| mark gen (bits 8–15) | flag bits | `mark` bitmap (done, Phase 1) |
| `LARGE` | flag bit | chunk flag (already `ChunkHeader.large?`) |
| `ATOMIC` | flag bit | **chunk kind** — atomic and pointerful in separate chunks, as Boehm does |
| `NURSERY` | flag bit | chunk flag |
| `FINALIZER` / `DISAPPEARING` | flag bits | per-chunk sparse bitmaps |
| `SWEPT` / poison | flag bit | diagnostics bitmap |

`next_free` being already dead is the encouraging part: 8 of the 16 bytes are
pure waste under `bitmap_alloc` today. It cannot simply be dropped, because an
8-byte header would put payloads at a non-16-aligned offset — the alignment
pinned in `ad50939`. Only going to **zero** bytes preserves alignment, which is
why this is all-or-nothing and why it is a phase rather than a tweak.

## Staging

- **7.1 — accessor layer (no behaviour change).** Route every header field read
  through accessors that take what a headerless build can supply
  (`chunk`, `ordinal`), so the representation can be swapped underneath. This is
  the R7 move — "refactor before it lands, separate commit, so the real diff is
  legible."
- **7.2 — `ATOMIC` → chunk kind.** Atomic and pointerful objects allocate from
  separate chunks; the scan path reads the chunk flag it already has in hand
  instead of the object's header. Independently valuable, and the largest new
  mechanism in the phase. **Watch RSS**: a class that sees both kinds now needs
  two chunks where it needed one, so this can cost fragmentation before
  headerless pays it back. Measure both axes.
- **7.3 — `NURSERY` → chunk flag.**
- **7.4 — `FINALIZER` / `DISAPPEARING` → per-chunk sparse bitmaps**, consulted
  only when the chunk's registration counter is non-zero.
- **7.5 — `SWEPT` / poison → diagnostics bitmap.**
- **7.6 — `size` → chunk class; `find_block` returns a block index** rather than
  a `BlockHeader*`.
- **7.7 — flip the header off** under `-Dgcry_headerless`: `data_start` stops
  reserving 16 B per block, `from_user`/`user_from` become identity.
- **7.8 — port the six diagnostics**, each purpose-broken gate observed red.
- **7.9 — soak both flag arms**, then consider the default.

## Standing gates for every step

Specs across `default` / `GCRY_BITMAP` / `GCRY_BITMAP_ALLOC` / `GCRY_CHUNK_RADIX`,
plus `invariants`, `mark-audit`, `property-test`, `mt-property-test`,
`stw-mt-property-test`, `parallel-mark-process`, `page-release-corruption`,
`heap-counters`, `find-block-race`. Kemal stays the regression guard: no step may
make the default path worse.

## Dependency worth stating

Headerless **requires** the bitmap representation — `FREE` lives in `occ` and the
mark lives in the mark bitmap, neither of which exists on the header path. So
`-Dgcry_headerless` implies `GCRY_BITMAP_ALLOC`, and it inherits that knob's
open question: bitmap alloc costs 8.3% Kemal throughput for 12.1% RSS. If
headerless adds its own RSS win on top, the trade gets more attractive; it does
not make the throughput question go away.

---

# STOPPED 2026-09-03 — and why

Phase 7 is halted after 7.2 and 7.4. The branch is kept as documented
exploration; nothing from it merges.

## The measurement that stopped it

`bench/log/linux/2026-09-03-phase7-payoff-ceiling/` quantified the ceiling —
`live_objects × 16 B` as a share of the heap — before spending 7.6/7.7:

| workload | payoff ceiling | cost already booked |
|---|---|---|
| Kemal `/json` | **0.1%** | −7.9% RSS |
| dense 64 B | 9.1% | −7.9% RSS |
| dense 16 B (class 0) | 44.4% | −7.9% RSS |

Phase 7 is a **small-object-density** optimisation, not a general RSS win. On
the workload gcry ships against it returns essentially nothing while costing
7.9%, and the remaining work is the 207-site header removal — the highest UAF
risk in the plan — for a benefit with no end-to-end instrument on this box.

## The goal it existed to serve is already met

Phase 7 targeted RSS × Boehm < 1.0. `GCRY_BITMAP_ALLOC=1` already delivers
**rss_x 0.893** (`2026-09-03-simdgc-kemal-e2e`), passing the recorded baseline
gate that the default arm (1.004) fails. The RSS half of the shipping bar is
met without headerless.

## What the halted work cost, and who pays it

Nothing, because it never merged. 7.2 (+7.9% RSS) and 7.4 (+9.5% free path) are
both pure cost without the header removal that justifies them, so neither is
worth salvaging onto `simdgc`. Verified before stopping: the phase's changes did
**not** erode the branch's speed gains — `phase_sweep` −4.0% (t=−0.55),
`ns_per_alloc` −0.4% (t=−0.98), `phase_mark` −0.5% (t=−0.57), all n.s.

Worth keeping in view: the chunk-kind RSS cost appears **only** where a workload
mixes atomic and pointerful allocations in the same size classes. Kemal does
(strings are atomic); `gc_phases` does not, and shows no cost there. A future
attempt should not assume the 7.9% is universal.

## If this is ever restarted

Restart conditions, not a schedule:
1. A workload with **many small live objects** is the actual target (the fat
   app, acikturkiye), and an end-to-end instrument for it exists.
2. The payoff is re-measured on that workload first — the ceiling is cheap to
   compute and should always precede the work.
3. It is judged on `gc_phases --size=2` (40% ceiling) with Kemal as regression
   guard only, per the instrument split recorded in the payoff FINDINGS.

Steps 7.2 and 7.4 are complete, gated and specced on this branch, so a restart
resumes at 7.5 rather than from scratch.

---

# RESTARTED 2026-09-03 (user decision) — status as of 2026-09-04 00:30

- [x] 7.2 chunk kinds · [x] 7.3 nursery off (now *enforced*) · [x] 7.4 finalizer index
- [x] 7.5 SWEPT/poison → folded into `diag_flags` (7.8) · [x] 7.6 size from chunk
- [x] 7.7 header removed — **−44.5% RSS at 16 B**, root cause of the last defect
      was `ChunkHeader.contains?` starting at `data_start` (large objects never
      scanned); `property_test` passes 100 000 iterations
- [x] 7.8 six diagnostics ported; all five diagnostic gates pass both arms,
      both builds; two live bugs found on the way (flag setters writing into
      objects; nursery never actually disabled)
- [x] 7.9 soak — headerless **PASSED** 5 h (+3.2 MB / 4 MB, errors=0);
      this branch's header+bitmap arm failed its RSS bound by 8% (no leak,
      errors=0). 5 h control of the PR branch's header build running, due ~11:51.
- [ ] open: headerless scans ~25% more objects on gc_phases fan-out 6
      (mark 2.6x slower there); reproduces in that benchmark only, not in
      five controlled probes. Not a marking hole. Unattributed.

---

# Review findings on PR #1 (fixed here, 2026-09-04)

1. **Bounded scan** — `clamped_scan_size` had stopped clamping small blocks on
   the header path. On this branch every scan derives length from the chunk
   (`block_payload`), so a corrupt header size cannot lengthen it; the dead
   wrapper is removed and `spec/bounded_scan_spec.cr` pins it (that spec
   walks 2³¹ bytes and SIGSEGVs on the PR branch).
2. **CPUID gate** — the AVX2 clone is built `+bmi,+bmi2,+popcnt`; detection now
   requires POPCNT, BMI1, BMI2 or clamps to scalar (`cpu.cr`).
3. **Dormant revive** — the bitmap pool skipped dormant chunks and the only
   revive was freelist-shaped, so a class that went dormant mapped a new chunk
   on every refill. `bitmap_revive_dormant` flips the flag, returns the bytes,
   zeroes both bitmaps; `spec/dormant_revive_spec.cr` pins it.
4. **Docs** — the mark prefetch ring is on by default on every representation;
   `GCRY_PREFETCH=0` restores the plain drain. Stated in the Kemal FINDINGS.
5. *(found while fixing 3)* **Warm retain on bitmap chunks** —
   `freelist_reserve_fully_dead` linked a fully-dead bitmap chunk's blocks into
   a freelist nothing reads (double-booked free bytes; header writes into
   objects under headerless). Guarded with `!bitmap_alloc_chunk?`. Default off,
   so latent.

## The mark-cost regression (2026-09-04): attributed and fixed

Not a marking difference. `run_collection`'s inlined ~9 KB frame sat *above*
the entry SP it recorded, so the previous cycle's mark batches were scanned as
mutator roots; the header build rejected them as `user − 16`, headerless
accepted them as base pointers. Fixed by outlining the body (`@[NoInline]`)
and scrubbing the dead stack below the entry SP on entry and exit
(`GCRY_COLLECT_SCRUB`, default 16 KB). Census after: identical to header.
Details: `bench/log/linux/2026-09-03-phase7-headerless-rss/FINDINGS.md`
Update 11.

