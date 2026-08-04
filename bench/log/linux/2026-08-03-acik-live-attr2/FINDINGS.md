# Live-attr probe (2026-08-03, attr2)

Host: WSL2 9950X. Tip Crystal rebuilt (`1.22.0-dev` + stackmap densify).
Bin: `gcry/.tmp/acik-bin/acikturkiye-exclusive` (acik `bin/` root-owned; wrote elsewhere).
`.llvm_stackmaps: yes`. `GCRY_PRECISE_STACK=2` + `GCRY_LIVE_ATTR=1`.
`wrk -c100 -d15`, dual collect, `/gc-live-attr`.

## Headline

| | |
|--|--:|
| size_class_live | ~77 MiB |
| attr total | ~89 MiB |
| **payload 32768** | **~76 MiB / 2434 objs** |
| first_mark stack / precise / heap | 13.4 / 2.9 / 72.1 MiB |
| stack_maps | loaded, 138740 records, hits 48326, precise_marked 7336 |

Live ≪ prior nonstack ~380 MiB (15s wrk + timeouts; band still **max size-class dominated**).

## Top type_ids (name from `__crystal_type_id_to_class_name_map`)

| id | name | MiB | n | avg |
|---:|------|----:|--:|----:|
| 88 | Array(Set(String)) | 31.8 | 1019 | ~32 KiB |
| 49 | Array(Crystal::Var) | 29.5 | 973 | ~32 KiB |
| 1 | String | 0.6 | 12578 | ~50 B |

**49+88 ≈ 61 MiB** and sit in the 32 KiB size class. Real `Array` headers are tens of bytes — these look like **32 KiB buffers whose first Int32 collides with a type_id** (typed/raw split overstates “typed”). Next: confirm with capacity/len fields or mark only layout-known sizes; don’t chase Array(Crystal::Var) as an app type.

## Notes

- Prior attr1 had no stackmaps (stale `.build/crystal`).
- wrk showed many timeouts this run — treat abs RSS/live as soft; shape (32 KiB class) is the signal.
