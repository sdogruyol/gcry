# `make ec-queue-audit` faulted on macos-latest (2026-10-04)

Master CI run 37167225781 on `aaf1433`, job `test (darwin native)`: the
audit run reported three 192-byte blocks of the watched `Thread` type
(`type_id 173`) unmarked and about to be swept — "on Crystal's thread list:
no — it has either not published yet or exited", no register or list
reference — and the process then took a SIGSEGV at address 0
(`ci-excerpt.txt`). The re-run of the job passed.

The commits under test changed only parallel-mark paths (`08a7eeb` push
buffers, `2f9c916` radix counters, `aaf1433` `mark_noscan`'s lock); this gate
marks serially, where all three are the code it ran before. This is the shape
of the thread family's earlier sightings in this gate (ROADMAP: a 192-byte
`Thread` block freed and reissued, aarch64, not reproduced on re-run). One
more sighting, on macOS this time; no new lead.
