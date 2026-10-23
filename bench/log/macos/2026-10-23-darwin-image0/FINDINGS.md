# Darwin: image 0 is not always the executable

## Question

`platform/darwin_roots.cr` resolved the static roots from
`_dyld_get_image_header(0)` / `_dyld_get_image_vmaddr_slide(0)`, and
`stack_maps.cr` read `__LLVM_STACKMAPS` from the same image. The
m1-binarytrees profiler (`2026-10-23-m1-binarytrees/pcprof.c`, run
39919145181) saw image 0 be something else inside an inserted library's
constructor. Is it still something else when gcry reads it?

When: `GC.init` → `ensure_static_root_cache` → `scan_dyld_static_roots`, on the
main thread, once; refreshes (every 64 majors, or after a maps-generation bump)
re-run it, possibly in a stopped world. The main-thread TLS window is taken
once at init from the TLV sizes that walk records.

## Probe

`probe.sh` (`make darwin-image0`): `inject.c` built as a dylib prints
dyld's view from its constructor; `bench/darwin_image0.cr` prints it again
at Crystal main and checks

- identity: `Platform.exe_bias` equals the slide of the image whose header is
  `_NSGetMachExecuteHeader()`; the program's own code is in gcry's exe
  `__TEXT`; the main-thread TLS range is non-empty;
- root: with `shared_lib_roots = false`, an array referenced only by a class
  variable survives four collections and allocation churn of its size.

Arms: plain; `DYLD_INSERT_LIBRARIES=libinject.dylib`; the dylib linked as a
normal dependency; linked + inserted; two inserted libraries.

## Result

Red on the unfixed tree, commit 71d7c88c, run 39939811092:

| arm | image 0 at Crystal main (both runners) | arm64 | x86_64 |
|---|---|---|---|
| plain | the executable | OK | OK |
| insert | `libinject.dylib` (MH_DYLIB, exe is index 1) | SIGSEGV | SIGSEGV |
| linked | the executable | OK | OK |
| linked+insert | `libinject.dylib` | SIGSEGV | SIGSEGV |
| insert-two | `libinject.dylib` (exe is index 2) | SIGSEGV | SIGSEGV |

So an inserted library is image 0 from its constructor through `main` and
after; a linked dependency is not. The crash is in the root arm's first
`GC.collect`: `Thread::Mutex#lock` at address 0x8 under
`stop_world_threads` (and `Thread::LinkedList#push` in a starting thread),
i.e. objects held only in the executable's class variables were collected.
With the default `shared_lib_roots = true` the executable's `__DATA` was
still scanned, through the add-image callback, as a "library" (its header
was not `@@exe_mh`); what was lost then was everything else read from image 0:

- main-thread TLS: the TLV size came from the dylib (0), so
  `take_main_thread_tls` added nothing — main-thread `@[ThreadLocal]`
  values were not roots;
- `exe_bias` / `exe_text?`: the dylib's slide and `__TEXT`;
- stack maps: `__LLVM_STACKMAPS` looked up in the dylib, so precise stack
  scanning had no maps.

A Crystal-allocating constructor in an inserted dylib was not built: a
dylib constructor runs before the executable's `main`, so `GC.init` has not
run and gcry is not reachable from it; the observation that matters (image 0
at `GC.init` time) is the Crystal-main line above.

## Fix

`Platform.executable_image`: the header from `_NSGetMachExecuteHeader()`,
matched against `_dyld_get_image_header(i)` for its slide. Memoised as
`executable_image_cached` (`@@exe_mh`, `@@exe_slide`) after `GC.init`, so a
refresh or a stack-map load inside a stopped world does not walk dyld's
image list (dyld4's loaders lock). `bench/darwin_static_root_sections.cr`
uses it too.

Green on 2cd3ef14, run 39940435237: all five arms OK on macos-latest
(arm64) and macos-15-intel, and `crystal spec -Dgc_none process_spec`
230 examples, 0 failures on both.

Rebased onto release-0.39.0 (1d7f5d84), run 39942327761: the same, all ten
arm runs OK and process_spec 230/0 on both runners. The probe branch
`probe/darwin-image0` was deleted after these runs.
