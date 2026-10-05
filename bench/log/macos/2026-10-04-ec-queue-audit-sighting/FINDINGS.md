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

## Rate (2026-10-05)

`ecq.sh` beside this file: the gate's audit arm
(`GCRY_EC_QUEUE_AUDIT=1 GCRY_POISON_HOLDERS=1 GCRY_THREAD_BLOCK_AUDIT=1`)
400 times back to back on `ea89c48`, each watched for 240 s:

| runner | runs | `Thread`-block fault | other failure |
|---|---:|---:|---:|
| macos-latest | 400 | 0 | 1 |
| ubuntu-24.04-arm | 400 | 0 | 0 |

The one failure is the gate's own positive control, not the family: in run
114 neither planted queue head was reported ("collected over without a word")
and "the global-queue walk never saw a slot, so nothing here tests it" — no
collection's audit happened to look while the planted slots were there.
[INFERENCE] A timing gap in the harness, 1 in 400.

So the `Thread`-block sighting stays at one in CI and none in 800 here.
