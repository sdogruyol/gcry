# The allocation entry's frame held 512 unwritten bytes (2026-10-20)

`GC.malloc` and `GC.malloc_atomic` inline `check_fork_poison!`. Its message
buffer (`uninitialized UInt8[RawOut::LIMIT]`, 512 bytes) therefore sat in
the frame of every allocation entry. That frame is live across every
collection an allocation triggers, above `collect_entry_sp`. Nothing on the
normal path writes the buffer, so the conservative scan read 512 bytes of
whatever deeper calls had last left at that depth as roots. The fix moves
the buffer into a `@[NoInline]` `fork_poison_exit`, called only in a forked
child. In the x86-64 release build, `GC::malloc_atomic<UInt64>`'s frame goes
from `sub $0x258,%rsp` to `sub $0x78,%rsp` (`local/jsonparsepull-churn.txt`).

Commit `c2dd2226` on `occupancy-claim-038`, the bottom commit, independent
of the occupancy claim above it.

## How it was found

This explains the occupancy claim's unattributed "25 MB more chunks unmapped
and mapped again" (`../2026-10-19-occupancy-claim-038/`). The run was
crystal-metric JsonParsePull with pacing off, so both trees follow the same
schedule. Debug copies counted every `@unmapped_bytes` site
(`local/jsonparsepull-churn.txt`):

- Size-class chunks are not the difference. The sweep's empty-chunk flush
  unmaps 106 037 248 bytes on both trees, and `map_chunk` totals are
  identical. Main's three hypotheses (claimed bits counted differently by
  release, warm-retain and dormant; retire after the empty-chunk decision;
  claims during the lazy sweep shifting release by a cycle) are all ruled
  out by this.
- The difference is all in `trim_large_cache`'s detach: 191 516 672 bytes
  against 166 350 848 (+25.2 MB). A trace of every large block at every
  major's sweep shows var keeping a dead 33.5 MB `IO::Memory` buffer, and a
  2.1 MB one, marked through one more collection (kept at the 14th, swept
  at the 15th; base sweeps both at the 14th). After the 14th, the 76 MB
  allocation then recycled a different cached mapping (8.4 MB instead of
  the 33.5 MB one). The 33.5 MB buffer was unmapped a cycle later, and the
  new mapping's pages faulted fresh: +6 150 minor faults, +1.3% peak.
- gdb at that collection, on the real release binaries
  (`local/holder2_gdb.py`): one word, at `0x7fffffff89a0` in
  `GC.malloc_atomic`'s frame, holds the buffer's start on var. On base, no
  word on the stack does. On var the claim changes the inlining:
  `Heap#malloc_atomic` is inlined into `GC.malloc_atomic` (0x837 bytes
  against base's 0xb4 wrapper), so that frame is the one live across the
  collection, and its unwritten buffer is where the stale word sits.

With the buffer out of line, the same claim build matches base in 8 of 8
runs: 127 092–127 131 faults and 417.6–417.8 MB, against base's
127 102–127 113 and 417.5–417.7 MB. Before the fix it was 133 242–133 252
and 423.0–450.6 MB.

## Regression

`process_spec/regression/79_alloc_entry_frame_uninitialized_spec.cr`,
gated by `make alloc-entry-frame` (release build) in CI's x86_64 test job.
A deeper call fills 8 KiB of stack with a pattern. A `GC.malloc_atomic` at
the same depth then triggers a collection. The `post_stw_hook` counts the
pattern's words still present between the allocating call and
`collect_entry_sp`: words no frame on the allocation path wrote. With the
fix 13 survive and the spec passes; with the fix reverted 73 survive and it
fails (x86-64 Linux, Crystal 1.21.0, `--release`). A debug build inlines
nothing and reads 21 either way, so the gate builds `--release`.

## Five runners, the fix alone against base

`Perf A/B`
[39419212059](https://github.com/sdogruyol/gcry/actions/runs/39419212059):
var `c2dd2226` (`occ038-probe-base-fix`, release-0.38.0 `4fc3fe53` plus
this commit), base `origin/release-0.38.0` (`4fc3fe53`). Nine
crystal-metric rows, 15 interleaved reps, Boehm, Kemal 15 trials,
`stats=3`. Files in `fix-<runner>/`, all rows in `table.txt`. Var against
base, median [IQR] of paired reps:

| runner | slower beyond spread (wall) | faster beyond spread (wall) | peak worse beyond spread | peak better beyond spread |
|---|---|---|---|---|
| ubuntu-latest | JsonGenerate +0.8% [+0.1, +1.9], JsonParsePull +1.0% [+0.3, +1.4], RegexDna +0.3% [+0.1, +0.4] | JsonParsePure −0.5%, Revcomp −0.6% | JsonParsePull +1.2% [+0.3, +1.7], Binarytrees +0.2% [+0.1, +0.2] | — |
| ubuntu-24.04-arm | none | JsonParsePure −0.8%, **JsonParseSerializable −3.0%, JsonParsePull −2.9%** | none | JsonParsePure −0.3%, Revcomp −3.3% |
| macos-latest | none | **JsonParsePull −6.8% [−11.8, −3.7]** | none | **JsonParsePure −13.6% (1.07× → 0.93× Boehm), RegexDna −15.6% (0.50× → 0.43×)** |
| macos-15-intel | none | JsonParsePure −4.0% | none | JsonParsePure −1.2%, RegexDna −9.9% |
| windows-latest | none | none | none | none |

On arm64 the JSON rows' Σ scanned falls 26% with 7% more collections in
the first run on two Linux runners, [39414298640](https://github.com/sdogruyol/gcry/actions/runs/39414298640)
(`fix-first-<runner>/`). That is stale roots no longer marking dead
structure.

Kemal `/json`, % of Boehm base → var: macos-15-intel 121.2% → 115.5%,
macos-latest 107.0% → 106.0%, ubuntu-24.04-arm 104.7% → 103.9%, every IQR
overlapping. On ubuntu-latest it is **111.4% [110.4, 116.3] → 105.1%
[102.5, 108.5]**, with CPU per request 22.81 → 24.38 ms per 1 000 requests.
Peaks are level everywhere.

### Placement: the x86 Linux residue is inside the same-source spread

- Kemal on ubuntu-latest,
  [39429021296](https://github.com/sdogruyol/gcry/actions/runs/39429021296)
  (`kemal-pads-ubuntu-latest/`, 20 trials, `pads="p0 p16 p32 p48 bp0
  bp16 bp32 bp48"`, as `2026-10-19-kemal-placement` prescribes): base
  114.7%, var 109.5%. Base's own placement arms span 109.9–114.0%; var's
  span 110.7–115.6%, and `prepad0`, var's source with no pad, reads above
  base. The gap is inside both sources' placement spread: placement, the
  same class the kemal-placement findings closed for 0.37.
- crystal-metric on ubuntu-latest,
  [39429069428](https://github.com/sdogruyol/gcry/actions/runs/39429069428)
  (`pads-ubuntu-latest/`, `pads="2096 p16 bp2096 bp16"`), as % of base:
  JsonGenerate var 99%, var pads 99–101%, base pads 99%; JsonParsePull var
  100%, var pads 99–102%, base pads 100–102%; RegexDna var 99%, var pads
  99–102%, base pads 101–102%. The +0.3% to +1.0% are inside the spread.

**Verdict for the fix alone:** no row is slower beyond its spread anywhere
that placement doesn't cover. macOS and arm64 gain wall and peak.
ubuntu-latest's JsonParsePull peak +1.2% [+0.3, +1.7] is the one rise left.
It stays at 0.79× Boehm, under budget, and is not attributed.
