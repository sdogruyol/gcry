# A sighting the report excluded by name, and the branch that made it do so

Date: 2026-09-13/14 (overnight) · host: AMD Ryzen AI 9 465, Linux 7.2.4 ·
tree: `5e1c101`

## The sighting

Running `make thread-churn-uaf` in a loop overnight — while an 8 h soak and two
`chunk_list_drift` children had the machine busy — its **guarded** arm faulted on
two consecutive runs, 1 of 24 attempts each time:

```
  default    0 of 24 failed (0.0%)
  guarded    1 of 24 failed (4.2%)
  poisoned   0 of 24 failed (0.0%)

guarded sighting:
  gcry: SIGSEGV at 0x7f5ed0e69768 — outside gcry's heap span
  [0x7f5eceebf000, 0x7f5ed0ab5000) — never a gcry allocation, so a swept object
  is not the explanation
```

The fault is **3.8 MB above the span end**, and the arm that produced it is the
one that exists to make such an address legible: `GCRY_UNMAP_GUARD=1` keeps a
released chunk mapped as `PROT_NONE` and records base, size, release path,
collection, the first user word and how many blocks were still allocated when it
went. The ledger almost certainly held the answer. The report did not ask.

## Why it did not ask

```crystal
unless heap.in_heap_span?(addr)
  ... "never a gcry allocation, so a swept object is not the explanation"
  return
end
...
if g = heap.guarded_release_at(a)   # only reachable from inside the span
```

`heap_span_hi` is the top of the **live** chunks, and releasing a chunk is
exactly what moves its address out of the span — the guard then keeps that
address reserved so nothing can map over it, which is why a fault there is
*expected* to be out of span. So the one branch that could have named the
release was the one branch the address could never reach, and the report ended
on a sentence that excludes the mechanism by name: *a swept object is not the
explanation*.

It is the same failure shape as the 2026-08-20 reading, recorded in the code
right above it: "never a gcry allocation" is true of the address and the
inference after the comma is not.

Fixed by asking through one helper from both branches, which is now what
`report_released_range` is for.

## What could not be built, and what each attempt taught

A synthetic control for the out-of-span half took three attempts and produced
three facts rather than a test:

1. **A burst of size-class chunks** releases chunks that live ones bracket, so
   the span covers them from both sides. And any allocation *after* the release
   — a `puts` is enough — maps above the guarded range and puts it back inside,
   because the guard reserves the address so the allocator must go higher.
2. **A large object** is released to the **large cache**, not to the kernel:
   `large_mapped_bytes` never moved across four collections, and
   `large_cache_retain = 0` does not survive the adaptive retain policy that
   resets the budget each major.
3. **Remembering the address roots the object.** The harness recorded it in a
   `UInt64` local to poke it later; a `UInt64` in a live stack slot is
   indistinguishable from a pointer to a conservative scan, so the chunk never
   died and the guard recorded nothing — `guard slots used: 0`. Masking the
   value did not help: the allocation path holds the pointer too.

So `make released-range-report` covers the half that can be built — a fault into
a guarded release is named, 0 failures in 8 runs — and the out-of-span half is
defended by sharing the helper with it. The next sighting is the test, and it
will print the named line instead of the sentence that excluded it.

## Note on the rate

The guarded arm's 1 of 24, twice, is also the first sighting since the
2026-09-13 latch and mark-clear fixes, and it happened under heavy load. It is
not attributed: the report could not read it. That is the point of this change.
