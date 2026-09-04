# Which Mach-O sections are the static roots — measured, and the obvious rule is wrong

**Status: the allow-list lost nothing measurable on this toolchain, and the
parity rule the ROADMAP proposed would have been wrong. Darwin now derives its
root set the way Linux does — writable `__DATA*` **minus `SG_READ_ONLY`** minus
TLS — and the `SG_READ_ONLY` term is the part that had to be measured rather
than reasoned.**

Apple M2 Pro, Darwin 25.6.0 / macOS 26.6.2 arm64, Crystal 1.21.0, Apple ld.
`bench/darwin_static_root_sections.cr`, both links.

## What was open

Linux derives the static roots by construction: every writable `PT_LOAD` of the
executable minus the `PT_GNU_RELRO` window (`platform/linux_roots.cr`). A
linker that adds or renames a section is covered without anyone noticing.
Darwin used a **name allow-list** — `__data`, `__bss`, `__common`, with
`__const` explicitly refused — so the same linker change would drop a root
class silently, and a dropped root class sweeps a live object.

The proposed parity rule was: *take every section of a `__DATA*` segment whose
`initprot` carries `VM_PROT_WRITE`, minus TLS.* Three questions were open and
all three were marked INFERRED: is `__DATA.__const` a root under a
`-no_data_const` link? Can TLS alone hold a heap pointer? Is any other writable
`__DATA*` section being lost?

## The census

Default link:

| segment | section | size | initprot | segflags | `mach_vm_region` | old | derived | initprot-only |
|---|---|---|---|---|---|---|---|---|
| `__DATA_CONST` | `__got` | 952 | 0x3 | **0x10** | `r--` | no | no | **yes** |
| `__DATA_CONST` | `__const` | 18456 | 0x3 | **0x10** | `r--` | no | no | **yes** |
| `__DATA` | `__data` | 42 | 0x3 | 0x0 | `rw-` | yes | yes | yes |
| `__DATA` | `__thread_vars` | 96 | 0x3 | 0x0 | `rw-` | no | no | no (TLS) |
| `__DATA` | `__thread_data` | 4 | 0x3 | 0x0 | `rw-` | no | no | no (TLS) |
| `__DATA` | `__thread_bss` | 24 | 0x3 | 0x0 | `rw-` | no | no | no (TLS) |
| `__DATA` | `__common` | 2081640 | 0x3 | 0x0 | `rw-` | yes | yes | yes |

`0x10` is `SG_READ_ONLY`. **This is the finding.** `__DATA_CONST` declares
`initprot = READ|WRITE` in its load command, so "writable `initprot`" admits
it — and dyld mprotects the segment read-only once it has applied the fixups,
which `mach_vm_region` confirms as `r--` at runtime. It is the Mach-O
`PT_GNU_RELRO`. The initprot-only rule would have word-scanned 19456 bytes of
pointer-dense literal pool the mutator cannot write: false retention, no
roots, and no way for a reviewer to notice because nothing breaks.

Two other things the census settles, both of which had been guesses:

* there is **no `__bss`** in this linker's output at all — zerofill goes to
  `__DATA.__common` (`flags=0x1`, `S_ZEROFILL`). The allow-list's `__bss` entry
  has never matched anything here.
* there is **no other writable `__DATA*` section**. The allow-list and the
  derived rule select the identical 2081682 bytes on a default link, and
  `Gcry::Platform.static_root_bytes` reports exactly that, so the two agree
  down to the byte.

Under `-Dgc_none --link-flags=-Wl,-no_data_const`:

| segment | section | size | segflags | `mach_vm_region` | old | derived |
|---|---|---|---|---|---|---|
| `__DATA` | `__got` | 952 | 0x0 | `rw-` | **no** | **yes** |
| `__DATA` | `__const` | 18456 | 0x0 | `rw-` | **no** | **yes** |

So the answer to the first open question is: **structurally yes.** With
`-no_data_const` the `__DATA_CONST` segment disappears, `__const` and `__got`
land in a plainly writable `__DATA` with no `SG_READ_ONLY`, and the allow-list
refuses both. The derived rule takes them, +19456 bytes.

## Did the allow-list actually lose a root?

No — measured, not assumed. The probe walks every word of every refused
`__DATA*` section, asks the heap whether the value is a live object, stashes
the hits XOR'd with a constant so the probe cannot itself be the root, collects
four times, and re-asks. A word still pointing at an address the heap has
reclaimed is a lost root.

| link | refused by allow-list | heap-owned words found | reclaimed while referenced |
|---|---|---|---|
| default | `__DATA_CONST.__got`, `__DATA_CONST.__const`, 3× TLS | 0 | 0 |
| `-no_data_const` | `__DATA.__got`, `__DATA.__const`, 3× TLS | 0 | 0 |

`__const` and `__got` hold pointers the linker and dyld wrote — to static data
and to functions — and Crystal never stores a mutable reference there: class
variables and constants go to `__data`/`__common`. So the widening is
insurance against a linker change, not a bug fix, and this file says so rather
than implying a fix.

TLS answers the same way, and for a reason worth writing down: the
`__thread_*` sections are the **initialisation template**, 124 bytes in total.
The per-thread blocks are allocated by `tlv_allocate_and_initialize` and live
elsewhere, so scanning the template could never find what a thread holds. The
filter is right, and "can TLS alone hold a heap pointer" is not a question
about these sections.

## Why "0 lost" is not vacuous

It would be, on its own: a detector that cannot see a lost root reports zero
for every rule. So the probe runs a `--control` child under
`GCRY_STATIC_BSS_CAP=1`, which refuses a section of 1 MiB or more — and the
probe carries a 1.6 MiB zerofill `Pad` precisely so `__common` clears that
threshold (it is ~470 KiB otherwise).

```
control-scan: dropped_words=38 root_bytes=42 capped_sections=1
(no control verdict line — the child did not survive its own collections)
child exit=10
```

`static_root_bytes` falls from 2081682 to **42** — only `__data` survives — the
scan finds **38 heap-owned words** in the section that was dropped, and the
child then dies, which is what a process whose class variables stopped being
roots does. Both halves of the argument: the scan can see roots where roots
certainly are, and losing that section is fatal.

`GCRY_STATIC_BSS_CAP` was a no-op stub on Darwin before this. That is why this
argument had no Darwin arm — the platform had no way to drop a root class on
purpose. `bench/static_bss_roots.cr`, the Linux gate for the same knob, reads
`/proc/self/maps` and is Linux-only by construction.

## What shipped

`segment_holds_roots?` in `platform/darwin_roots.cr`: `__DATA*` prefix,
`initprot & VM_PROT_WRITE`, `(flags & SG_READ_ONLY) == 0`. Section level keeps
only the TLS filter and the research size cap. `section_is_root_candidate?` and
the `__const` special case are gone.

The range table is now a fixed `StaticArray(RootRange, 32)` — Linux's bound —
which makes `static_root_overflow` and `static_root_bss_lost` real counters
instead of hardcoded `0`, and removes a `LibC.realloc` and a `raise` from a
path that now runs inside `GC.init`. See
`bench/log/macos/2026-09-04-static-root-init-once/FINDINGS.md`.

`make darwin-static-root-sections` runs both links, each with its control
child.
