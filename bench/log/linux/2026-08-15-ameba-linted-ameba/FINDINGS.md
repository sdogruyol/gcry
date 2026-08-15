# The lint gate linted ameba, and four regression specs never ran

**Date:** 2026-08-15 · host: WSL2 x86_64, Crystal 1.21.0 (`57cf7da50`)
· tip @ `f27396a`

Carried on the board as "one gate is still not a gate". It is now measured, and
it cost more than the lint findings: the same rule that was being ignored was
also pointing at four tests that never ran.

## Why it linted the wrong tree

```yaml
- name: Ameba
  run: |
    shards install --development
    cd lib/ameba && shards build
    cp -f bin/ameba ../../bin/ameba
    ../../bin/ameba          # ← still inside lib/ameba
```

A GitHub `run:` block is one shell, so the `cd` persists. The binary ran with its
working directory inside ameba's own checkout: it inspected **346 files** —
ameba's source, not gcry's — and never loaded gcry's `.ameba.yml` either. Every
green Ameba check on record is that.

Reproduced here by accident, which is the useful part: a `cd lib/ameba` earlier
in this session persisted across tool calls, and `./bin/ameba` reported exactly
`346 inspected, 0 failures`. From the repo root it is **82 files**.

`make lint` was always right — make runs each recipe line in its own shell, so
the binary runs from the root — so the fix is to call it instead of duplicating
it wrongly.

## And the config had a key ameba does not read

```yaml
ExcludedPaths:      # ameba reads `Excluded` (config/loader.cr:51); this is ignored
  - lib
  - bin
  - bench
```

Harmless in practice — `Globs` already limited the walk to
`src`/`spec`/`process_spec`/`samples`, and `lib` is ameba's own default
exclusion — but it is a line that looks like a rule and is not one. Fixed to
`Excluded`, with `lib` kept explicitly because setting the key *replaces* the
default rather than adding to it.

## What the first honest run found

**10 issues, 82 files.** Nine were style: three `while true` → `loop do`
(`heap.cr` ×2, `tlab.cr`), one `else nil` on a `case` (`stack_maps.cr`), one
verbose block in a spec, and four `Lint/SpecFilename`.

The four filename warnings were the finding worth having:

```
spec/regression/1_live_objects_dormant.cr
spec/regression/2_hash_layout_entries_size.cr
spec/regression/3_scan_cap_alloc_size_mismatch.cr
spec/regression/4_signal_stack_false_root.cr
```

Four regression tests, one per historical GC defect, and **`crystal spec` never
ran any of them** — it collects `*_spec.cr`, and these are not. They ran only
inside `spec/all_specs.cr`, the kcov / ASan entrypoint, so they were exercised in
two Linux-only jobs and in none of the per-platform spec runs. Renamed: the suite
goes **163 → 167 examples**, and the four now run everywhere `crystal spec` does,
Darwin included. All four pass.

`spec/all_specs.cr` keeps its name and is excluded from that rule with the reason
written next to it: renaming *it* would make `crystal spec` load the entrypoint
and every file it requires, running the whole suite twice.

## After

`make lint`: **82 inspected, 0 failures**. `crystal spec`: 167 examples, 0
failures. The CI step now runs `make lint`.

One of the four is worth a second look on its own: `1_live_objects_dormant.cr`
was written for a v0.14.0 counter drift whose signature is
`actual=6502, reported=1` — the same numbers the invariant walker produced this
morning from the *other* side of the comparison. It asserts the counter, so it
could not have caught the walker bug; the coincidence is that dormant chunks have
now produced that exact pair twice, from opposite directions.
