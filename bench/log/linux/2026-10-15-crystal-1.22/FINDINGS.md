# Crystal 1.22.0 and gcry's stdlib reopens

Crystal 1.22.0 [39f3f4d08] was released 2026-10-12. gcry pins 1.21.0 in CI.
Questions: does gcry build and pass on 1.22.0, and which of its three stdlib
reopens (`src/gcry/crystal_*_compat.cr`) does it still need?

Raw lines in `results.txt`; the per-run logs of the regression specs are the
`s*.log` files here. Local runs: x86_64 Linux, 1.22.0 installed with
`mise install crystal@1.22.0`, one run per cell, serialised under the shared
heavy lock. Controls are copies of `src/` with one reopen removed; the
committed tree was not edited for them.

## `crystal_process_compat.cr` (execve argv terminator): fixed upstream

1.22.0's `Crystal::System::Process.prepare_args` allocates `args.size + 1`
(`src/crystal/system/unix/process.cr:263-272` in the 1.22.0 tarball, with the
comment "`execve` requires NULL terminator"; crystal-lang/crystal#17184).
1.21.0's allocates `args.size` (`:311-319`). The reopen body is now identical
to the stdlib method it replaces, so it is gated to
`compare_versions(Crystal::VERSION, "1.22.0") < 0`.

`process_spec/regression/73_execve_argv_terminator_spec.cr` asks the
collector whether the terminator slot is inside argv's own block and NULL,
for 1..8 arguments (2, 4, 6, 8 land on exact 16/32/48/64-byte classes):

| compiler | reopen         | headerless | `-Dgcry_block_headers` |
|----------|----------------|------------|------------------------|
| 1.21.0   | removed        | **1 failure** ("2 args: argv block holds 16 bytes, needs 24") | **1 failure** |
| 1.21.0   | gated (applies)| pass       | pass                   |
| 1.22.0   | removed        | pass       | pass                   |
| 1.22.0   | gated (absent) | pass       | pass                   |

So the spec catches the missing slot deterministically where the existing
`process_gc_spec.cr` example ("argv NULL terminator") only fails when the word
past the block happens to be non-NULL, and the gate is right on both sides.

## `crystal_raises_compat.cr` and `crystal_string_builder_compat.cr`: still needed

On 1.22.0 with the reopen removed:

- `13_rescue_string_new_null_spec.cr` (`@[Raises]` on `String.new(chars,
  bytesize, size)`): 1 error, the `ArgumentError` escapes the `rescue`.
  crystal-lang/crystal#17644 is open.
- `22_string_builder_terminator_spec.cr`: 3 of 3 fail. 1.22.0's
  `String::Builder#increase_capacity_by` still returns on
  `new_bytesize <= @capacity` and `to_s` writes `@buffer[real_bytesize]`
  (`src/string/builder.cr:100-131`). crystal-lang/crystal#17645 is open.

With the reopens both pass. They stay unconditional; neither has a version to
gate on yet.

## The suites on 1.22.0

- Local: unit specs 294, process specs 200, process specs on the header
  layout 201, all 0 failures.
- CI run 38721725009, job `specs (x86_64, crystal 1.22.0)`: the same eight
  spec runs as `test (x86_64, crystal 1.21.0)` in that run, identical counts
  (294, 200, 316, 316, 201, 201, then `bitmap-marks-freelist` 316, 201), 0
  failures.
- CI run 38721725009, `std_spec (crystal 1.22.0)`: 18 257 examples (3 761 +
  5 662 + 2 715 + 6 119), 0 failures, 30 pending.
- CI run 38721725009, `compiler built with gcry (crystal 1.22.0)` (job
  116377658416, 48 min): the 1.22.0 compiler built with gcry (LLVM 18.1.3),
  smoke, stage 2 and `crystal i` green, and Crystal's compiler_spec under
  gcry 13 764 examples, 0 failures, 18 pending (1.21.0 leg of the same run:
  13 640, 0 failures, 38 min).

## Side observation

On 2026-10-15 (master run 38709043581) the `std_spec` legs for `latest` and
`nightly` both installed `Crystal 1.22.0 [39f3f4d08]`: install-crystal's
nightly fetched `crystal-1.22.0-1-linux-x86_64.tar.gz` from a CircleCI
artifact. [INFERENCE] The newest nightly artifact is the release build until
master's next nightly lands, so for now the nightly leg tests the release,
not master.
