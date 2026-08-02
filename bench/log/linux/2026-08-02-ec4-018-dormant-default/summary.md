# EC4 Parallel dormant-as-default — REJECT as process default

Session: `bench/log/linux/2026-08-02-151303/` · `EC_PARALLELISM=4` ·
`parallel_empty_chunk_dormant=true` + retain 32 MiB (code trial).

| Path | % Boehm | gcry abs | RSS × |
|------|--------:|---------:|------:|
| `/json` | **68.8%** | 63,361 | **3.29×** |
| `/` | **107.7%** | 107,779 | **3.94×** |

vs reclaim-off baseline **80.5%** @ **5.48×** (`145600/`): RSS win, thr %
misses secondary gate **≥75%** (Boehm loud ~92k this session; gcry abs
actually ↑ vs reclaim-off ~51k). Prior opt-in cut
`2026-08-01-ec4-dormant-lazy/` held **75.1%** @ **4.03×**.

**Verdict:** keep `GCRY_PARALLEL_DORMANT=1` as **supported RSS opt-in**; do
**not** make Parallel dormant process-default. Code trial reverted.
