# Darwin EC4 with `GCRY_SOUND=1`, after the resident-count low-water

CI run `36253830147` (tree `6ed9fc9`), job "darwin EC4 root-phase cut",
`darwin_root_phase_reps=4`, Kemal `/json` at EC4 on `macos-latest`,
`GCRY_ROOT_PHASE_TIMING=1`.

| config | n | roots µs | stacks µs | pause ms |
|---|---:|---:|---:|---:|
| tuned | 299 | 2 321 | 123 | 3.10 |
| tuned-nolw (`GCRY_STACK_LOW_WATER=0`) | 350 | 8 046 | 271 | 9.08 |
| sound (`GCRY_SOUND=1`) | 344 | **3 068** | 140 | **3.86** |

The same cut before the change (CI run `36245905484`): sound roots
19 267 µs, pause 20.8 ms. `*-extra.json`: the resident path answered
7 555, 8 180 and 8 708 ranges in the sound reps, fell back 0 times, and
`page_query_errors` is 0 everywhere; tuned and tuned-nolw do not reach it
(their windows are 16 pages). Context and the paired matrix:
`../../linux/2026-09-26-sound-matrix/FINDINGS.md`.
