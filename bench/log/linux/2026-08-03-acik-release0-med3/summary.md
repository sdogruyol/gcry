# release0 med3 (LARGE_CACHE=0 + EMPTY_CHUNK_RETAIN=0)

wrk -c100 -d30, tip+EC base bin, dual gc-collect, process RSS.

| variant | thr med | % Boehm | RSS KiB med | × Boehm | live_sc MiB med |
|---------|--------:|--------:|------------:|-------:|----------------:|
| boehm | 136.2 | 100.0 | 44972 | 1.00× | 0.0 |
| base | 127.4 | 93.5 | 98332 | 2.19× | 17.5 |
| release0 | 127.7 | 93.7 | 44812 | 1.00× | 12.7 |

Per-trial:

- boehm t1: 142.6 rps, RSS=44972 KiB, live_sc=0.0 MiB, lcache=0, empty=0, non2xx=0
- boehm t2: 135.7 rps, RSS=49888 KiB, live_sc=0.0 MiB, lcache=0, empty=0, non2xx=0
- boehm t3: 136.2 rps, RSS=44764 KiB, live_sc=0.0 MiB, lcache=0, empty=0, non2xx=0
- base t1: 134.7 rps, RSS=98332 KiB, live_sc=15.9 MiB, lcache=32, empty=16, non2xx=0
- base t2: 127.4 rps, RSS=97756 KiB, live_sc=18.7 MiB, lcache=32, empty=16, non2xx=0
- base t3: 122.0 rps, RSS=104932 KiB, live_sc=17.5 MiB, lcache=32, empty=16, non2xx=0
- release0 t1: 127.7 rps, RSS=44812 KiB, live_sc=12.7 MiB, lcache=0, empty=0, non2xx=0
- release0 t2: 127.3 rps, RSS=37740 KiB, live_sc=10.1 MiB, lcache=0, empty=0, non2xx=0
- release0 t3: 131.4 rps, RSS=62652 KiB, live_sc=15.2 MiB, lcache=0, empty=0, non2xx=0

Source: `/home/uchiha/playground/gcry/bench/log/linux/2026-08-03-acik-release0-med3/release0.tsv`
