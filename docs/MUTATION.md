# Mutation testing feasibility (Phase 7.3)

## Existing tools

Searched for Crystal mutation testing (`crystal-mutate`, mutant-style runners). As of 2026-07 there is **no maintained general Crystal mutation framework** comparable to PIT/mutmut. Compiler AST hooks exist but are not packaged for mutation scoring.

## Scoped approach for gcry

Do **not** build a general mutator. Hand-craft targeted mutants on critical paths and track kill rate with `./bench/mutations/run.sh`:

| Area | File | Example mutants |
|------|------|-----------------|
| Freelist / counters | `heap.cr` | skip `live_objects` dec; disable double-free; ignore mmap fail |
| Mark / flags | `block.cr` | clear `FREE` bit constant |
| Sweep / collect | `collect.cr` | freeze `@collections` |
| Invariants | `invariant.cr` | invert live_objects equality |
| Roots | `roots.cr` | 1-byte scan stride |
| Size classes | `size_classes.cr` | wrong payload for class 1 |
| Trace / dump | `trace.cr`, `heap_dump.cr` | disable enable; undercount |

## Target

- ≥ 10 checked-in mutants in `bench/mutations/run.sh`
- Kill rate = mutants that fail the short kill suite
- Goal: **≥ 80%** killed
- Cadence: optional / local (`make mutate`); not every PR

## Status

**10/10 killed** (2026-07-28) — see `bench/mutations/SCORE.log` after `./bench/mutations/run.sh`.
