# "SIGSEGV at 0x0" was a poison word, and the writer was the collector

Date: 2026-09-12 · host: AMD Ryzen AI 9 465, Linux 7.2.4 · tree `0f95cdd` +
this change

## The report named what was written and never who wrote it

Every fault on `make thread-churn-uaf`'s poisoned arm — 14 of 18, for weeks —
printed the same first line:

```
gcry: SIGSEGV at 0x0 — gcry's freed-block poison (GCRY_POISON_FREED) is in the
faulting context. Something followed a pointer read out of a block that had
already been freed: a use-after-free, not a wild pointer
```

and then nothing about the *writer*, because the only backtrace available was
Crystal's. `Exception::CallStack` allocates its DWARF tables — hundreds of
kilobytes on a fat binary — and needs `Fiber.current`, neither of which exists
in a signal handler on a heap that is already broken. Measured, it produced
`Failed to raise an exception: END_OF_STACK` and
`Thread#current_fiber cannot be nil`, and its allocation **changed the crash**:
the DWARF buffer became the released block, which cost two rounds of
misattribution (`../2026-09-12-thread-churn-large-uaf/`).

## The instrument

A signal-safe walk, from the faulting `ucontext`, allocation-free and
lock-free:

* the faulting PC as `exe+offset` against the load bias captured at `GC.init`
  — the only form that survives a PIE;
* `sp`, `fp`, and on x86_64 `cr2`, the hardware faulting address, printed
  beside `si_addr` rather than instead of it;
* the frame-record chain (`[fp]`/`[fp+8]`, the same shape on x86_64 and
  aarch64), bounded by frame count, a monotonic `fp` and a window above `sp`;
* and, because Crystal builds without `--release` keep locals `%rsp`-relative
  and omit the frame pointer, a conservative fallback: the words above `sp`
  that land in this binary's text. Noise is the right trade — a chain with
  three extra entries names the writer, an empty report does not.

The report ends with the `addr2line` command already assembled.

## First run, first answer

```
gcry: writer — the faulting instruction is at 0x5646a04a54f6 = exe+0x1aa4f6.
      sp 0x7ffe83432d60 fp 0x7ffe83433f68 cr2 0x0
gcry: writer — return addresses above sp: addr2line -f -C -e <binary>
      0x1aa1a9 0x106d50 0x18a7d6 0x13df60 ...
```

```
mark_ref_slot        src/gcry/collect_scan.cr:44
scan_thread_roots    src/gcry/collect_scan.cr:139
                     src/gcry/gc_override.cr:1310
run_collection_body  src/gcry/collect.cr:2182
```

**The writer is the collector.** Not a mutator reading a freed block — gcry
itself, inside its own execution-context root pin.

## And "at 0x0" was never an address

`cr2` said 0 as well, so the instruction really did touch 0 — except the
register did not hold 0. Read out of the same ucontext:

```
rax 0xdead7fb15cbe0848   [rsp+0x10] 0xdead7fb15cbe0848
```

That is a **tagged poison word**: `0xDEAD` in the top 16 bits and the freed
block's address, `0x7fb15cbe0848`, in the low 48. Dereferencing it is a
non-canonical access, and Linux reports a non-canonical fault at address
**0**. So:

* every "SIGSEGV at 0x0" on this arm was a poison dereference, not a null one;
* the poison-in-register line was right about the poison and wrong about the
  reader — it said "something followed a pointer read out of a freed block",
  and the something was the collector;
* and the report could not say which of the nine pin sites did it, because
  each is macro expansion attributed to its `{% if %}`.

## The fix on gcry's side, and what it is not

`mark_ref_slot` computes its argument as `pointerof(obj.@ivar)`, so it is only
as good as `obj` — and `obj` comes out of Crystal's EC structures. It now
refuses a slot address that is zero, non-canonical, or carries the poison tag,
counts it (`ec_root_poisoned_slots`, `ec_root_null_slots`) and names the site
and the freed block the first time:

```
gcry: an execution-context pin site cannot see its object —
collect_scan.cr:174 computed slot address 0xdead7f3ed48e0848, which is this
heap's freed-block poison: the object it belongs to was read out of memory the
collector had already reclaimed. Skipped rather than dereferenced. The freed
block is 0x7f3ed48e0848
```

Line 174 is the `Fiber::ExecutionContext.unsafe_each` pin block. A collector
must not dereference an address it did not validate, and refusing loses no
root: there is no object at a poisoned address to mark.

**It is not a fix for what put poison there.** A live EC-family object is
being freed, and that is still open — the counter is how often it happens, and
the freed block address is where a `GCRY_POISON_HOLDERS` search should be
pointed next.

## What the poison names: a 16-byte block nothing points at

The tagged poison carries the freed block's address, so the pin site can
describe it — and, since `GCRY_POISON_HOLDERS=1` is the arm that produces
these, run the same holders search on it that the release path now runs:

```
gcry: an execution-context pin site cannot see its object — collect_scan.cr:209
      computed slot address 0xdead7f9f91480848 ... the freed block is 0x7f9f91480848
gcry: the freed block is 0x7f9f91480848, in a chunk of size class 0, payload 16 bytes
gcry: holders — explicit roots: 0 of 5 point into it — gcry is not rooting it
gcry: holders — heap: 0 word(s) in 0 live block(s), from 34440 block(s) in 21 chunk(s)
gcry: holders — stack: ... all below the collector's entry SP
```

Two facts follow, and both are new.

**The receiver was loaded out of that block.** `slot_addr` is
`pointerof(obj.@ivar).address`, an address — and it *equals* the poison word.
Only one block's payload carries its own tag, so the word holding `obj` was
inside block `0x7f9f91480848`. The pin loop's receivers come from two places:
`ec` from the intrusive `Thread::LinkedList(ExecutionContext)`, and `sched`
from `ec.@schedulers`. A 16-byte payload is two words — the shape of a
small `Array`'s buffer, which is raw `type_id 0` memory.

**Nothing points at it, anywhere.** Zero explicit roots, zero live blocks,
and every stack hit inside the collection's own frames. So at the moment the
collector reads through it, the block is unreferenced by anything gcry can
see — which is why it was freed, and why no coverage knob has ever moved this
defect.

**And it is 16 bytes**, which is the size of the victim the thread-death
investigation could not name either
(`../2026-09-12-thread-life-root/`: *"it is 16 bytes and it is not the
`Thread`"*). Two investigations that started from different faults are
looking at the same block.

## Where the fault goes after that

Straight to the other reader of the same structure:

```
gcry: writer — the faulting instruction is at ... = exe+0x32db1a
transfer_schedulers_blocked_on_syscall
  /usr/lib/crystal/fiber/execution_context/monitor.cr:78
```

Crystal's **Monitor** thread, walking `ExecutionContext.each` →
`each_scheduler`, dereferencing the same poison with the same `cr2 0x0`
signature. So the freed object is reachable from the EC/scheduler graph and
both the collector and the Monitor read it. The harness rate is unchanged by
the guard (poisoned 14 of 18), which is the honest reading: the guard stops
gcry from faulting on the damage, and the damage is upstream.

The Monitor is the one thread the stop never suspends
(`stw_signal_exempt?`), its registers are only covered when it parks in
`MonitorGate.enter` — measured 238 of 240 collections, so twice it is
elsewhere — and its stack is scanned through `snapshotted_stack_bounds` with
no recorded SP. That is the next thing to read.

## The next step, precisely

Which of the loop's two loads produced the poisoned receiver. Every pin site
in that block reports `collect_scan.cr:209` because they are macro expansion
attributed to one `{% if %}`, and `mark_ref_slot` takes only `__LINE__`.
Passing a per-site tag through the macro — the ivar name is already in hand at
expansion — separates "the EC list gave me a freed node" from "an
`@schedulers` buffer gave me a freed element", and those are different
defects with different owners.
