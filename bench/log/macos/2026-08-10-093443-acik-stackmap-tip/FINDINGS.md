# A live String's tail was overwritten under gcry + the execution-context runtime

**Status: real, reproduced 2 of 3 trials here. Superseded —
`bench/log/macos/2026-08-11-080733-acik-ec-isolation/FINDINGS.md` ran the
missing `boehmec` arm and isolated it to the collector: Boehm on the same
compiler with the same EC flags is 0/3, gcry is 3/3. The confound described
below is resolved; the analysis of the signature still stands.**

This session was started to re-cut the published Darwin fat-app `0.63×` RSS on
its own harness at tip. It did not produce a quotable RSS number — 2 of 3 `base`
trials died on `Non-2xx=1`, which `REQUIRE_2XX` correctly rules invalid for the
gate. The interesting part is *why* those trials went non-2xx.

## The signature

```
ERR ... > Unknown column: user_profile_picture\0\0\0\0<
  deserializing AcikTurkiye::DB::Submission::SubmissionStruct
| Unknown column: user_profile_picture\0\0\0\0< (DB::MappingException)
|   from array.cr:1414 in 'on_unknown_db_column'
|   from lib/db/src/db/serializable.cr:105:7 in 'read'
|   from lib/db/src/db/query_methods.cr:253:9 in '->'
|   from lib/kemal/src/kemal/route_handler.cr:164:39 in 'call'
```

The real alias in `acikturkiye/src/models/submission.cr:146` is
`u.profile_picture_path AS user_profile_picture_path` — **25 characters**.

The corrupted name is `user_profile_picture` (20 bytes) + `\0\0\0\0<` (5 bytes)
= **25 bytes**. The length is right. The first 20 bytes are right. Only the
trailing `_path` is gone, replaced by four NULs and one byte of something else
(`0x3C`).

That rules out the boring readings. It is not a truncated read, not a wrong
`bytesize`, and not a misparse of the row description: the allocation is intact
and correctly sized, and its **tail was written over in place**. That is what a
live object looks like after it has been freed and part of its storage handed to
something else — four bytes of a zeroed region plus one byte of a subsequent
write.

## Scope — where it happens and where it does not

| configuration | GC | Crystal | EC flags | trials | corrupted |
|---|---|---|---|---|---|
| `acik_stackmap_ab.sh` `base` | gcry | probe `4a965f423` (1.22.0-dev) | `-Dpreview_mt -Dexecution_context` | 3 | **2** |
| `acik_stackmap_ab.sh` `boehm` | Boehm | asdf 1.21.0 | none | 3 | 0 |
| `run_all.sh` gcry (`…-053800`, `…-061944`) | gcry | asdf 1.21.0 | none | 9 + 9 | 0 |
| `run_all.sh` boehm (`…-053800`) | Boehm | asdf 1.21.0 | none | 9 | 0 |

Detection is by NUL bytes in the server log, which is exact here: the two failing
trials carry 8 NULs each (the signature appears twice per failure, once in the
message and once in the exception line), every other log has none. The
`Non-2xx=1` counts from `wrk` line up with the NUL counts trial for trial.

The other `ERR` lines in the `run_all.sh` logs are unrelated and appear under
both collectors: `Error while writing data to the client` / `Closed stream` at
the end of a `wrk` run, i.e. clients hanging up.

## What is NOT established

**That gcry causes it.** The Boehm arm of this harness is built with the *system*
compiler and **no EC flags** (`build_one boehm "$SYS_CRYSTAL" build --release`),
while `base` gets the probe compiler *and* `-Dpreview_mt -Dexecution_context`.
So "gcry vs Boehm" is confounded with "multi-threaded EC vs not" and "tip
compiler vs 1.21.0". The 18 clean gcry trials above differ from the 2 dirty ones
on exactly those two axes, not on the collector.

**That it is related to the 2026-08-08 production SIGSEGV.** Same class —
something live was reused — and prod runs this app on gcry, so it is worth
asking whether prod builds with `-Dpreview_mt -Dexecution_context`. But nothing
here connects them, and the prod diagnosis is still an unproven bet.

## The experiment that isolates it

Build acikturkiye with **Boehm, the probe compiler, and the EC flags**, and run
the same load:

```sh
cd ../acikturkiye
ACIKTURKIYE_ENV=demo ../crystal/bin/crystal build --release \
  -Dpreview_mt -Dexecution_context src/acikturkiye.cr -o bin/acikturkiye-boehmec
```

* corrupts too → not gcry; it is the MT/EC path or the tip compiler, and the
  finding belongs upstream.
* stays clean → gcry drops a root under multi-threaded EC, and that is a
  correctness bug ahead of everything else on the roadmap.

Either way the arm is missing from `acik_stackmap_ab.sh`, which has no
"Boehm + EC" variant — `boehm` is deliberately the system build. Adding one is
what makes this harness able to answer the question it just raised.

Rate is unknown beyond 2 of 3 at 30 s and ~30k requests per trial. Establishing
it needs more trials than this session ran.
