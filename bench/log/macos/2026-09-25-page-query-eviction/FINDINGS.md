# `mach_vm_page_query` under real memory pressure: evicted pages read not-skippable

**Date:** 2026-09-25 · GitHub `macos-latest` (Apple Silicon, 16 KiB pages) ·
CI run `36180059391` (dispatch, `page_query_pressure=auto`) ·
`bench/darwin_page_query.cr`

## The open question

A Darwin port of the stack low-water skip may skip a page only if it was never
written. Residency alone cannot say that: a page written and then compressed
or swapped reads absent, and skipping it drops a root. The candidate predicate
reads `mach_vm_page_query`'s disposition and calls a page skippable only when
it is neither `PRESENT` nor `PAGED_OUT`. Four of the probe's five arms had held
since 2026-08-15; the fifth — a written page that leaves residency with its
contents intact — never ran, because nothing made the runner evict.

## Why the earlier attempt could not

`--pressure=2048` mapped 2 GiB of ballast writing **one byte per page**. The
compressor squeezes such pages to almost nothing, and 2 GiB is well under the
runner's memory, so 0 of 256 written pages ever left residency.

## What changed

* the ballast is incompressible: every word of every page from a xorshift
  generator;
* `--pressure=auto` sizes it at 1.25 × `hw.memsize`, so it cannot fit.

## Result

    page size 16384 (sysconf), region 256 pages, 4096 KiB
    untouched: 256/256 skippable; dispositions none×256
    written:   256/256 not skippable; dispositions PRESENT|REF|DIRTY×256
    zero-proof: 219/256 skippable, 0 of them non-zero (37 pages were written)
    reclaimed: 0/256 skippable, 0 of them non-zero; dispositions PRESENT|0x800×256
    paged-out: 256 of 256 written pages left residency under 8960 MiB of pressure;
               dispositions PAGED_OUT×256
    VERDICT: the bits mean what the skip needs [...] A Darwin low-water
    implementation is unblocked.

Every written page left residency, and every one reported `PAGED_OUT` — so
`!PRESENT && !PAGED_OUT` does not mistake an evicted page for an untouched
one. With the other four arms, the predicate is sound on this platform for the
cases the skip turns on. The job passed (the host survived the pressure).
