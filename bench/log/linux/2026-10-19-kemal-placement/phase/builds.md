# Hot functions' address mod 64 in each Kemal build

`nm -n` of the Kemal server (`bench/kemal`, kemal 1.15.0, Crystal 1.21.0, `-Dgc_none --release`), gcry `src/` at each revision.
v0.36.0 and v0.37.0 from the runners' artifacts; the others built here with `ab.sh`'s `kbuild` steps (`scripts/kemal_build.sh`), whose addresses match the runners' to the byte
(var, base and prepad0 compared: every function at the same address). `a975+pad` and `tip+pad` add probe 5a379e02's 472 KiB `StaticArray` to the `Heap`;
`v0.37.0 pad16` is v0.37.0 with 16 bytes of nops ahead of `server.cr` (the runners' `pad16` arm).

| build | `JSON::Builder::Escape#write` | `Char#to_s<IO+>` | `Heap#malloc_atomic` | `Heap#malloc` |
|---|---:|---:|---:|---:|
| v0.36.0 | 16 | 32 | 0 | 32 |
| 50b1315e | 0 | 16 | 0 | 32 |
| ec551749 | 16 | 32 | 16 | 48 |
| fa51f65f | 0 | 16 | 0 | 32 |
| a975d5cd | 32 | 48 | 16 | 32 |
| 272d73e5 | 32 | 48 | 16 | 32 |
| 4b625c87 (= dab25144 src, the 0.37 tip measured 2026-10-17/18) | 32 | 48 | 16 | 32 |
| v0.37.0 | 48 | 0 | 32 | 32 |
| a975d5cd + pad | 48 | 0 | 16 | 32 |
| 4b625c87 + pad | 48 | 0 | 16 | 32 |
| v0.37.0 pad16 | 32 | 48 | 48 | 48 |
