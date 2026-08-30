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

It also fits the family this tree has been closing all month from the other
side: `../2026-08-26-registers-were-never-roots/`,
`../2026-08-27-signal-frame-below-sp/`, the suspended-SP clamp, the low-water
skip. Every one of those is a way for a live object reachable only from a
running fiber's stack to lose its only root.

## The experiments, in order of power

All are one restart each, and the first two are A/Bs that answer yes or no.

1. **`GCRY_FULL_SUSPENDED_STACK=1`** — declines the suspended-SP clamp and scans
   a running fiber's stack from the guard page instead. The widest stack-root
   setting there is; it exists precisely so "the root the clamp dropped" can be
   ruled in or out in one run. **If the crash stops, the clamp is the defect.**
   Costs pause time, nothing else.
2. **`GCRY_STACK_LOW_WATER=0`** — disables the low-water skip, so the scan starts
   lower. Documented as only ever making the scan *wider* (Kemal EC4 pause
   3.60 → 8.06 ms). If 1 does not stop it and this does, the skip is reading
   `/proc/self/pagemap` wrong.
3. **`GCRY_THREAD_BLOCK_AUDIT=1 GCRY_DYING_TYPE_ID=<n>`** with *n* the app's own
   `Hash(String, String).new.crystal_type_id` (type ids are per-binary; print it
   at boot). After the mark and before the sweep this reads every used block of
   that type, reports each one the mark did **not** reach, and says whether the
   address was in a suspended thread's registers and whether the collecting
   thread's stack scan offered it. That names the miss at the collection that
   causes it — before the request that dies.
4. `GCRY_SUSPENDED_SP_SLACK=N` — extra bytes kept below a suspended thread's SP,
   where the kernel writes the signal frame.

Secondary, and only if all four come back clean: the release paths
(`GCRY_KEEP_CHUNKS=1`, `GCRY_DISABLE_MADVISE=1`, `GCRY_LARGE_CACHE=4194304`), and
`/gc-stats` for `type_id_root_false_negatives`, `sweep_small_uninitialised`,
`sweep_large_uninitialised`, `release_double`, `release_remapped`,
`large_taken_used`, `large_cached_twice`, `layout_hash_bodies`.

## The record

| when | app | build | address | frame |
|---|---|---|---|---|
| earlier | acikturkiye | — | `0x0` | `String#empty?` ← `unescape_url_param` |
| 2026-08-27 | acikturkiye | 0.21.1 `-Dpreview_mt -Dexecution_context` | `0x4` | same |
| 2026-08-29 | invidious | 0.21.3 | `0x0` | same, ← `rss_channel` |
| **2026-08-30** | **acikturkiye** | — | **`0x4`** | **same, full chain** |

Four sightings, two applications, two of them on builds carrying the fix that
was inferred to explain the frame. The build for this one has not been
confirmed and should be: acikturkiye was on 0.21.2 as of 2026-08-28 and 0.21.3
was tagged on the 29th.
