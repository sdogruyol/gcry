# A third sighting at `String#empty?`, on the build that was supposed to fix it

2026-08-29. Reported by **fixju**, running invidious on **gcry 0.21.3**:

```
Invalid memory access (signal 11) at address 0x0
[0x6abf1b] url        at /usr/share/crystal/src/string.cr:3015:3
[0x960e5e] rss_channel at /invidious/src/invidious/routes/feeds.cr:159:8
[0x9eb3a0] call        at /invidious/src/invidious/helpers/handlers.cr:31:37
[0x9e5413] call        at kemal/src/kemal/filter_handler.cr:28:7
[0x9d8c4f] handle_client at http/server/request_processor.cr:58:11
[0x44bd8c] run         at fiber.cr:168:11
```

`string.cr:3015` in Crystal 1.21.0 is `def empty? : Bool` — verified against the
same compiler this tree builds with. The frame is symbolised `url` because
`String#empty?` is inlined into its caller.

## What it refutes

This is the **third** sighting at that frame and the **second** application. The
history is in `bench/url_params_hash.cr`:

| when | app | build | address |
|---|---|---|---|
| earlier | acikturkiye | — | `0x0` |
| 2026-08-27 | acikturkiye | 0.21.1, `-Dpreview_mt -Dexecution_context` | `0x4` |
| **2026-08-29** | **invidious** | **0.21.3** | **`0x0`** |

0.21.2's release notes said of the chunk-index insert defect: *"the fixed defect
produces exactly that shape (a null reference read out of a live structure) in
multi-threaded builds, so 0.21.2 is the build production should be on"*, and
flagged that as an inference rather than a measurement. The label was right and
the inference is now dead: 0.21.3 carries that fix and the frame still faults.

Nothing in 0.21.3 could have caused it either — its only default-path change is
the out-of-memory path (`../2026-08-29-oom-hangs-not-raises/`). This is
pre-existing and older than both fixes.

## What it adds

The address. `0x0` is not a stale pointer into reused memory: a block that has
been handed to somebody else holds their data, not zeros. A value slot of a live
`Hash(String, String)` reading **exactly zero** is a page that went back to the
kernel and faulted in fresh.

That points away from the mark and at the **release** paths, which on Linux run
by default and retain nothing:

- `GCRY_EMPTY_CHUNK_RETAIN` — Linux process default **0**, empty chunks released
- `GCRY_LARGE_CACHE` — Linux process default **0**
- the dormant madvise and the page-release walk

It also fits the route. `rss_channel` opens with `env.params.url["ucid"]` and
`HTTP::Params.parse(env.params.query["params"]? || "")` — the same
`Hash(String, String)` traffic that Kemal's `unescape_url_param` walks in the
acikturkiye sightings. Both applications fault at the first thing that reads a
query parameter's characters.

## The one experiment worth a restart — **withdrawn 2026-08-30**

This section offered `GCRY_POISON_FREED=1` as the experiment that halves the
search space: a freed String would read `0xdeadf2ee…` and fault
non-canonically, so a fault still at `0x0` would mean nothing had been freed
and a release path was the subject.

**That does not follow.** gcry clears a block on hand-out unless the memory is
still mmap-fresh, so a block that is freed *and reused* has its poison
overwritten by the clear and reads zero again. A `0x0` under poison is
therefore consistent with both readings, and the negative result this recipe
would have produced could not have been read the way it promised. Withdrawn
before anyone spent a restart on it.

The fourth sighting, the next day, settled the same question from the address
itself and pointed somewhere else entirely — a fiber stack root miss rather
than a release path. See `../2026-08-30-zeroed-hash-slot/FINDINGS.md`, which
carries the current recipe.

## Everything else worth collecting

Asked of the reporter, in order of value:

1. **Build flags** — `-Dpreview_mt` / `-Dexecution_context`? The multi-threaded
   windows in this collector are only reachable with them, and the 0.21.1
   sighting was on such a build.
2. **Which `GCRY_*` are set** in the unit file or environment — particularly
   `GCRY_PAGE_DONTNEED` (documented **known unsound**: the post-STW walk
   madvises a run computed from a live mask taken in the pause) and
   `GCRY_MOSTLY_EMPTY`. If either is on, that alone is a candidate and turning
   it off is the first thing to try.
3. **`/gc-stats` after some uptime.** Any non-zero in these is an alarm, and
   each names a different defect: `type_id_root_false_negatives`,
   `sweep_small_uninitialised`, `sweep_large_uninitialised`, `release_double`,
   `release_remapped`, `large_taken_used`, `large_cached_twice`.
4. **`GCRY_SEGV_REPORT=1`** — gcry's own handler, which for a heap address says
   whether it is in a live chunk, in a FREE block, or in a range gcry released,
   with the base, the size, the release path and the collection number. For a
   null fault it will say the address was never gcry's, which is itself worth
   having on the record; it becomes decisive if the poison run moves the fault
   onto a heap address.

## Knob bisect, if the crash is frequent enough to A/B

Each of these turns off one release path. The one that stops the crash names it.

| knob | what it stops |
|---|---|
| `GCRY_KEEP_CHUNKS=1` | empty chunks are never released |
| `GCRY_LARGE_CACHE=4194304` | large mappings are retained instead of unmapped |
| `GCRY_DISABLE_MADVISE=1` | the page-release walk issues no `madvise` |

A crash that survives all three is not a release path and the mark is back in
the frame.

## Status

Open. No fix, and no local reproduction: `bench/url_params_hash.cr` was built
for exactly this shape, crashed 1 of 8 once, then 0 of 112 across every arm, and
its own header tells the next person not to read its silence as an answer. The
only instrument that has ever reproduced this is a real application under real
load, which is why the recipe above is aimed at the reporter's process rather
than at this tree.
