# Callgrind totals per build (one run each, `cg.sh`)

Events: Ir instructions, D1mr/D1mw L1d read/write misses, DLmr/DLmw last-level read/write misses, Bcm conditional-branch mispredicts — all *simulated* by valgrind (65 KiB 2-way I1/D1, 16 MiB LL, its own branch predictor), not the CPU's. `gcry` = instructions whose source line is in `lib/gcry/src` (inlined gcry code counts as gcry, wherever it was inlined); `stdlib` = Crystal's `src/`; `bench` = `metric.cr`; `libc` = glibc. GCRY_COLLECT_SCRUB=0 in every arm (valgrind's main stack has no room for the collector's below-SP scrub).

## Revcomp

| build | Ir | gcry Ir | stdlib Ir | bench Ir | libc Ir | D1mr | D1mw | DLmr | DLmw | Bcm |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| v0.35.0 | 27,677,687,750 | 787,580,511 | 21,671,922,028 | 4,772,121,253 | 445,709,474 | 30,338,358 | 32,144,037 | 29,161,981 | 31,873,584 | 173,254,867 |
| 6dc6e7d0 | 27,659,402,875 | 808,073,448 | 21,667,045,116 | 4,772,121,253 | 411,806,574 | 29,229,290 | 29,108,624 | 26,187,221 | 28,669,582 | 173,440,821 |
| b1cdc0ed | 27,673,092,443 | 821,879,203 | 21,668,329,031 | 4,772,121,253 | 410,408,038 | 27,519,228 | 29,006,538 | 26,183,970 | 28,648,709 | 173,361,763 |
| 48e7c749 | 27,640,423,599 | 792,795,074 | 21,664,881,351 | 4,772,121,253 | 410,272,295 | 28,817,057 | 29,016,115 | 26,196,520 | 28,562,935 | 172,902,962 |
| v0.36.0 | 27,638,934,061 | 792,465,983 | 21,664,412,777 | 4,772,121,253 | 409,580,934 | 28,795,315 | 28,929,241 | 26,193,355 | 28,545,862 | 172,852,769 |

### Revcomp: gcry functions by Ir (top 8 across builds)

| function | v0.35.0 | 6dc6e7d0 | b1cdc0ed | 48e7c749 | v0.36.0 |
|---|---:|---:|---:|---:|---:|
| `*Gcry::Heap#malloc_atomic<UInt64>:Pointer(Void)` | 617,289,132 | 623,866,472 | 623,446,996 | 623,446,555 | 623,446,569 |
| `*Gcry::Heap::tls_cursor_cache` | 46,182,150 | 46,182,353 | 46,182,353 | 46,182,220 | 46,182,192 |
| `*String#byte_slice?<Int32, Int32>:(String | Nil)` | 32,269,044 | 32,269,044 | 32,269,044 | 32,269,044 | 32,269,044 |
| `*String::new'<Pointer(UInt8), Int32, Int32>:String` | 28,166,970 | 28,166,970 | 28,166,970 | 28,166,970 | 28,166,970 |
| `*GC::malloc_atomic<UInt32>:Pointer(Void)` | 22,533,498 | 22,533,498 | 22,533,498 | 22,533,498 | 22,533,498 |
| `*Gcry::Heap#stop_world_quiescing_roots:Nil` | 433,993 | 1,868,929 | 13,832,054 | 267,734 | 762,319 |
| `*Gcry::Heap#mark_impl_unlocked<Pointer(Void), Bool, Bool, Gcry::Heap::` | 4,514,922 | 9,430,156 | 7,355,297 | 3,224,515 | 3,079,564 |
| `*Gcry::Heap#mark_worker_loop:Nil` | 8,601,224 | 9,288,562 | 8,552,808 | 8,958,730 | 8,527,487 |

## Brainfuck

| build | Ir | gcry Ir | stdlib Ir | bench Ir | libc Ir | D1mr | D1mw | DLmr | DLmw | Bcm |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| v0.35.0 | 60,286,408,379 | 7,567,104 | 41,845,884,908 | 18,431,336,235 | 1,266,843 | 28,368 | 23,777 | 6,289 | 15,340 | 54,889,974 |
| 6dc6e7d0 | 59,757,137,043 | 30,898,231 | 41,293,403,341 | 18,431,336,235 | 1,147,827 | 27,016 | 21,730 | 6,081 | 14,637 | 31,725,961 |
| b1cdc0ed | 59,729,177,314 | 11,464,518 | 41,284,862,193 | 18,431,336,235 | 1,163,399 | 27,924 | 21,645 | 6,078 | 14,634 | 31,492,349 |
| 48e7c749 | 59,755,126,672 | 23,781,766 | 41,297,812,439 | 18,431,336,235 | 1,844,643 | 34,720 | 35,572 | 6,079 | 14,635 | 31,961,442 |
| v0.36.0 | 59,778,620,135 | 5,516,743 | 41,340,207,682 | 18,431,336,235 | 1,208,175 | 29,014 | 21,455 | 6,080 | 14,634 | 33,832,747 |

### Brainfuck: gcry functions by Ir (top 8 across builds)

| function | v0.35.0 | 6dc6e7d0 | b1cdc0ed | 48e7c749 | v0.36.0 |
|---|---:|---:|---:|---:|---:|
| `*Gcry::Heap#stop_world_quiescing_roots:Nil` | 279,463 | 16,037,902 | 5,670,031 | 19,890,831 | 243,907 |
| `*Gcry::Heap#start_world:Nil` | 4,475,599 | 12,251,339 | 3,334,572 | 1,401,347 | 2,801,347 |
| `*Gcry::Heap#mark_impl_unlocked<Pointer(Void), Bool, Bool, Gcry::Heap::` | 761,044 | 667,438 | 518,483 | 517,381 | 519,887 |
| `*Gcry::Heap#mark_worker_loop:Nil` | 423,504 | 423,250 | 426,045 | 445,614 | 431,688 |
| `*Gcry::Heap#scan_static_ranges:UInt64` | 388,172 | 387,276 | 387,124 | 387,092 | 387,124 |
| `*Gcry::Heap#scan_mutator_stack:Nil` | 240,998 | 188,060 | 188,060 | 188,060 | 188,060 |
| `*Gcry::Heap#scan_edges_inline<Pointer(UInt64), UInt64, Bool, Nil>:Nil` | 216,581 | 216,875 | 216,803 | 216,874 | 216,780 |
| `*Gcry::Heap#note_mutator_candidate<UInt64>:Nil` | 183,716 | 143,234 | 143,234 | 143,234 | 143,234 |

## Simulated I1 misses (whole run)

| build | Revcomp | Brainfuck |
|---|---:|---:|
| v0.35.0 | 37,159 | 13,270 |
| 6dc6e7d0 | 32,472 | 13,174 |
| b1cdc0ed | 31,964 | 12,867 |
| 48e7c749 | 34,466 | 12,946 |
| v0.36.0 | 33,416 | 13,033 |

Under 40 000 misses in 27–60 billion instructions: the hot code of both benches fits a 64 KiB I1 in every build, so the simulated I-cache sees no placement effect. What placement does change — µop-cache (DSB) windows, branch alignment, loop-stream behaviour — valgrind does not model.
