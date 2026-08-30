# The fourth sighting says the slot was zeroed, not the String

2026-08-30, acikturkiye production, full stack this time (previous sightings had
three frames; this has thirty):

```
Invalid memory access (signal 11) at address 0x4
[0x557ec7ac7015] empty?             at string.cr:3015:3
[0x557ec7d750aa] unescape_url_param at kemal/src/kemal/param_parser.cr:119:7
[0x557ec7d75050] parse_url          at kemal/src/kemal/param_parser.cr:158:32
[0x557ec7d74f17] url                at kemal/src/kemal/param_parser.cr:124:5
[0x557ec7f63e96] show               at src/controllers/web/api/v1/users_controller.cr:54:15
…  route_handler → websocket_handler → filter_handler → web_api_auth
   → api_auth → admin_api_auth → static_file → exception_handler
   → head_request → request_log → init_handler → request_processor
[0x557ec7aae252] run                at fiber.cr:168:11
```

The request before it completed normally 56 seconds earlier
(`200 GET /web/api/v1/user/603 3.33ms`), so this is not a wedged process — it is
one request, on a route with URL parameters, on a healthy server.

## The Kemal code, exactly

```crystal
def initialize(@request : HTTP::Request, url : Hash(String, String) = {} of String => String)
  # Own a copy so in-place URI decode cannot mutate a shared/cached Radix params hash.
  @url = url.dup
  …

private def unescape_url_param(value : String)
  value.empty? ? value : URI.decode(value)
rescue
  value
end

private def parse_url
  @url.each { |key, value| @url[key] = unescape_url_param(value) }
end
```

`value` is yielded out of `@url.each`, and `@url` is a `Hash(String, String)`
**`dup`ed one request ago**. Its values are non-nilable Strings; Crystal cannot
produce a null there.

## What the address settles

`String#empty?` is `bytesize == 0`, and `@bytesize` sits at offset 4. So a fault
at **`0x4`** means the reference itself was `0` — `value_ptr + 4` with
`value_ptr == 0`.

That is worth stating as a negative, because it rules out the reading everyone
reaches for first:

- **It is not a swept-then-reused String.** That leaves the slot holding the
  String's old address; the read would fault at `old_addr + 4`, somewhere in the
  heap, not at `0x4`. Every one of these four sightings faulted at `0x0` or
  `0x4` — the two lowest offsets of a *null* reference — never at a heap
  address.
- **The slot itself read zero**, which means the memory holding the slot was
  zeroed: the `@entries` buffer was reclaimed and handed to another allocation
  that cleared it, or the page under it went back to the kernel.

## Which corrects yesterday's recipe

`../2026-08-29-invidious-empty-frame/FINDINGS.md` offered `GCRY_POISON_FREED=1`
as the one experiment that halves the search space, on the grounds that a freed
block reads `0xdeadf2ee…` instead of zero. **That is wrong when the block is
reused**: gcry clears a block on hand-out unless the memory is still
mmap-fresh, and the clear overwrites the poison. So a `0x0` reading under poison
does *not* mean "no block was freed here", and the negative result the invidious
recipe would have produced could not have been read the way it promised.
Corrected in place.

## What the zero points at instead

Follow what has to be true for the entries buffer to die.

`scan_hash_body` word-scans the **whole** Hash body — `words = size // word`,
every word either `mark_noscan`ed (if it is a recorded blob offset) or
`mark_impl`ed. `scan_hash_object` does the same two columns from the layout.
Either way, **if the Hash object is scanned at all, its `@entries` word is
marked** and the buffer survives the collection.

So the buffer dying means the Hash object was never marked. The Hash is
`ParamParser@url`, held by the `ParamParser`, held by the `HTTP::Server::Context`,
held by nothing but **the stack of the fiber serving that request**.

That makes a fiber stack root miss the leading hypothesis, ahead of the Hash
layout machinery this frame has always been blamed on — and it explains a detail
that has been in the record since the first sighting without being used: both
applications fault at *the first thing in the request that dereferences a
heap String*. If the whole per-request tree lost its root, `parse_url` is simply
where the process notices.

## The build, and what it eliminates

**Confirmed: 0.21.3, `--release --debug -Dgc_none`** — no `-Dpreview_mt`, no
`-Dexecution_context`. So this is the *second* sighting on a build carrying the
chunk-index fix, on the second application, and it is **EC1: single-threaded**.

That is worth more than any knob, because of what it rules out.
`multi_mutator_threads?` returns true only above **two** threads in Crystal's
list; EC1 has main plus at most SYSMON, so it is **false**, and therefore
`stw_multi` is false for every collection this process has ever run. Which
means:

- **No mutator thread is ever suspended.** The collector runs on the mutator's
  own thread, inside an allocation. The whole family this tree spent the month
  closing — `../2026-08-26-registers-were-never-roots/`,
  `../2026-08-27-signal-frame-below-sp/`, the suspended-SP clamp, the GP-register
  capture — is *unreachable here*. None of it can be this crash.
- **`GCRY_FULL_SUSPENDED_STACK=1` is a no-op on this build.** All it does is
  `return nil if @full_suspended_stack` inside `fiber_stack_sp_scan_low`, and
  that function iterates *other* threads' SPs — of which there are none.
- **`GCRY_STACK_LOW_WATER` and `GCRY_STW_STACK_LAG` are inert too.** Both live
  inside the `stw_multi` branch of `fiber_stack_scan_top`, past
  `return t unless stw_multi`.

All three were recommended yesterday and in the first draft of this file. On
this build they would each have cost a production restart and returned nothing.
Corrected here rather than left to be discovered by spending them.

What is actually live in EC1 is short: the collector's own stack (the current
fiber, scanned from its own SP), parked fibers scanned from
`@context.stack_top` with **no lag, no low-water and no slack**, the static
roots, and heap→heap edges.

`--debug` matters for a different reason: it changes where the compiler keeps
values, so "it stops crashing without `--debug`" would measure the compiler, not
the collector (`../2026-08-26-debug-build-own-stack-root/`). Do not read a
two-build A/B as evidence.

## The experiments, corrected for this build

**Zero restarts — ask the running process.** acikturkiye already exposes
`GET /gc-stats`. Every one of these is a direct test and costs nothing:

| counter | what a non-zero says |
|---|---|
| `fiber_scan_running_stale` | a fiber read `running?` and was scanned from `@context.stack_top`, which is only written at a switch — gcry's own name for scanning the wrong window |
| `fiber_scan_from_sp` / `fiber_scan_from_guard` | which window parked scans actually used |
| `type_id_root_false_negatives` | documented as a production alarm |
| `layout_hash_bodies` | whether the Hash-body path engages at all here |
| `mark_audit_edges` / `mark_audit_misses` | zero unless the audit is armed; listed so its silence is not misread |
| `sweep_small_uninitialised`, `sweep_large_uninitialised` | the two mid-allocation tripwires |
| `release_double`, `release_remapped`, `large_taken_used`, `large_cached_twice` | the release and large-cache alarms |

**One restart, and it splits the remaining space in two.** The question is
whether the Hash was lost through a *heap edge* or through a *root*:

1. **`GCRY_MARK_AUDIT_EVERY=N`** (sampled; the full audit is O(live heap) inside
   the pause). After the mark and before the sweep it walks every marked block
   and reports any base pointer into a **used but unmarked** block — naming the
   parent's address, `type_id`, size and the offset, plus the child. This is the
   instrument that measured the 0.21.0 Hash-body defect at *193 missed edges in
   216 collections*. **If it fires, the loss is a heap edge** and the Hash
   scan machinery is back in the frame.
2. **`GCRY_THREAD_BLOCK_AUDIT=1 GCRY_DYING_TYPE_ID=<n>`**, *n* being the app's
   own `Hash(String, String).new.crystal_type_id` (per-binary; print it at
   boot). It reports every used block of that type the mark did not reach,
   whatever points at it. **If this fires while the mark audit stays silent,
   nothing on the heap pointed at the Hash and the missing root is a stack
   one.**

Note the audit's own warning: it is O(live heap) in the pause and *suppresses
the crash it is looking for*, so a quiet run with it armed is not a clean bill.
`GCRY_MARK_AUDIT_EVERY=N` is the production-affordable form.

Only if both come back clean: the release paths (`GCRY_KEEP_CHUNKS=1`,
`GCRY_DISABLE_MADVISE=1`, `GCRY_LARGE_CACHE=4194304`), which the Linux process
defaults leave wide open — `GCRY_EMPTY_CHUNK_RETAIN=0` and `GCRY_LARGE_CACHE=0`
retain nothing.

## The record

| when | app | build | address | frame |
|---|---|---|---|---|
| earlier | acikturkiye | — | `0x0` | `String#empty?` ← `unescape_url_param` |
| 2026-08-27 | acikturkiye | 0.21.1 `-Dpreview_mt -Dexecution_context` | `0x4` | same |
| 2026-08-29 | invidious | 0.21.3 | `0x0` | same, ← `rss_channel` |
| **2026-08-30** | **acikturkiye** | **0.21.3 `--release --debug`, EC1** | **`0x4`** | **same, full chain** |

Four sightings, two applications, **two of them on 0.21.3** — the build carrying
the fix that was inferred to explain the frame. And the two 0.21.3 sightings
differ in the one dimension that used to carry the explanation: 2026-08-27 was
`-Dpreview_mt -Dexecution_context`, 2026-08-30 is single-threaded. A defect that
shows on both is not in the suspend protocol, because on the EC1 build nothing
is ever suspended.
