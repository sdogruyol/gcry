# A precise layout that skipped an ivar and still called itself precise

**Date:** 2026-08-15 · host: WSL2 x86_64, 20 CPU, Crystal 1.21.0 (`57cf7da50`),
`-Dgc_none` · tip @ `f396fc4`

The v0.20.0 scheduler-root audit left one question it could not answer with the
harness it had: `Layout.register` drops ivars it cannot classify, and the
scheduler graph is pinned explicitly either way, so `bench/scheduler_roots.cr` is
green whether or not the drop is real. `bench/ivar_layout_roots.cr` holds an
object behind nothing but such an ivar. It is real, it is not confined to the
type the audit named, and the type the audit named is not an instance.

## What the walk does with an ivar it cannot classify

`Layout.register` sorts each ivar into one of three outcomes: a scan offset, a
noscan offset, or `force_scan_cap` — give up on precision for the whole type and
scan its body conservatively. An ivar that is none of `Reference`, `Pointer`, a
pointer-safe union, a `Value`-with-ivars or a `StaticArray` reaches **none** of
the three. It gets no offset, and it does not force the fallback. The entry is
installed as precise, `scan_object` scans exactly the offsets it lists, and the
word is never read.

`register_hash` already asks the right question of its key and value types —
`K.has_inner_pointers?`, `V.has_inner_pointers?`, word-scan the slot if so. The
plain-ivar walk one screen above it did not.

## Measured, both directions, both registration routes

`bench/ivar_layout_roots.cr`. The leaf's address reaches the harness only as
`addr ^ KEY`; the constructing frame is `NoInline` and the stack is wiped before
the collection, so a stale word cannot root it.

| arm | ivar | entry before | leaf before | entry after | leaf after |
|---|---|---|---|---|---|
| module | `@payload : Probe::Payload` | precise, `scan=[8]` | **swept** | `scan_cap` | live |
| proc | `@job : Proc(UInt64)` | precise, `scan=[8]` | **swept** | `scan_cap` | live |
| control | `@payload : Probe::Leaf` | precise, `scan=[8,16]` | live | unchanged | live |

Identical with `GCRY_AUTO_LAYOUTS=1`, which is the shipping route into the same
macro. The control is what makes the other two attributable: the holder is rooted
from a global in all three, and only the ivar's declared type differs.

The gate is the first column, not the last. The installed entry is a static
property of the registration — it cannot come out green because a pointer
happened to be spilled somewhere convenient.

## How much of this ships

Compile-time census over `Reference.all_subclasses` for a program requiring
`json`, `http/server` and `socket`, applying the same predicate the walk applies:
**186 concrete types walked, 19 dropped ivars.**

```
Process::ExitError#args           : Enumerable(String)   MODULE
Fiber#proc                        : Proc(Nil)
Thread#func                       : Proc(Thread, Nil)
Fiber::ExecutionContext::Isolated#spawn_context : Fiber::ExecutionContext MODULE
Fiber::ExecutionContext::Isolated#func : Proc(Nil)
Log::BroadcastBackend#dispatcher  : Log::Dispatcher      MODULE
Log::MemoryBackend#dispatcher     : Log::Dispatcher      MODULE
Log::IOBackend#dispatcher         : Log::Dispatcher      MODULE
Log::IOBackend#formatter          : Log::Formatter       MODULE
Log::Metadata#first               : NamedTuple(key: Symbol, value: Log::Metadata::Value)
OpenSSL::SSL::Socket::Client#ssl  : LibSSL::SSL
OpenSSL::SSL::Socket::Server#ssl  : LibSSL::SSL
OpenSSL::SSL::Context::Client#handle : LibSSL::SSLContext
OpenSSL::SSL::Context::Server#handle : LibSSL::SSLContext
OpenSSL::SSL::Server#wrapped      : Socket::Server       MODULE
OpenSSL::X509::Extension#ext      : LibCrypto::X509_EXTENSION
OpenSSL::X509::Name#name          : LibCrypto::X509_NAME
OpenSSL::X509::Certificate#cert   : LibCrypto::X509
HTTP::WebSocketHandler#proc       : Proc(HTTP::WebSocket, HTTP::Server::Context, Nil)
```

`Fiber#proc` is the widest of them: a `Proc` is two words, and the second points
at the closure's heap-allocated environment. Under `GCRY_AUTO_LAYOUTS=1` every
`Fiber` was scanned precisely with that slot omitted, so a fiber's captured
environment had no root *from the fiber*. It survives in practice by other
routes — the fiber's own stack, the caller that spawned it — which is exactly why
nothing noticed.

## The type the audit named is not an instance

`@event_loop : Crystal::EventLoop` was recorded (2026-08-14, ROADMAP and
CHANGELOG) as the shipping example. On Crystal 1.21.0 it is not:

```
Crystal::EventLoop: module?=false ref=true abstract=true
Log::Dispatcher:    module?=true  ref=false
Socket::Server:     module?=true  ref=false
```

`Crystal::EventLoop` is an **abstract class**, so it is `< Reference` and its
offset is emitted. Every ivar of `Fiber::ExecutionContext::Parallel::Scheduler`
classifies, including that one — checked one by one. The defect is real and the
reasoning that found it was right; the example was wrong. Nothing about the
2026-08-10 soak SEGV changes: the scheduler graph was never the victim of this,
and the soak sets no `GCRY_AUTO_LAYOUTS` anyway.

## The fix

One predicate, in the fallback the walk already had:

```crystal
{% if (t < Value && t.instance_vars.size > 0) || t <= StaticArray || t.has_inner_pointers? %}
  {% force_scan_cap = true %}
{% end %}
```

Strictly more conservative: it only ever moves a type from precise to
`scan_cap`, never the reverse. Cost, measured on the `json_churn` shape with a
4000-object live set under `GCRY_AUTO_LAYOUTS=1`: **precise 4012 / conservative
45, unchanged in both directions** (3 runs each, identical) — none of the types
on that workload's live path have an affected ivar. The 9 types that do change
bucket are in the census above.

## Unrelated, and open: `make invariants` is red on Linux too

The v0.20.0 board carries "`make invariants` has never passed on Darwin" with a
Darwin-specific hypothesis (`MADV_FREE_REUSABLE` leaves block headers intact
where Linux's `MADV_DONTNEED` does not). On this host it fails on **Linux
x86_64**, at tip `f396fc4`, with the same signature:

```
1) keeps empty chunks dormant within empty_chunk_retain
   gcry invariant: live_objects mismatch: actual=6502 reported=1
   spec/collect_spec.cr:202
```

plus `spec/mt_spec.cr:118`. Reproduced with the layout fix stashed, so it is not
this change. Linux CI runs the identical command and is green, so the difference
is the host or the compiler build, not the platform — which the stated hypothesis
does not survive. Not chased here; the item needs re-scoping before it is worked.
