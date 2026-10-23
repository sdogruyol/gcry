// Prints which image dyld calls image 0 while this library's constructor
// runs, and whether it is the executable (`_NSGetMachExecuteHeader`).
// Built as a dylib: inserted with DYLD_INSERT_LIBRARIES, or linked into the
// probe as an ordinary dependency.
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdio.h>

void image0_dump(const char *when) {
  const struct mach_header *exe = (const struct mach_header *)_NSGetMachExecuteHeader();
  uint32_t n = _dyld_image_count();
  const struct mach_header *h0 = _dyld_get_image_header(0);
  long exe_index = -1;
  for (uint32_t i = 0; i < n; i++) {
    const struct mach_header *h = _dyld_get_image_header(i);
    if (h && h->filetype == MH_EXECUTE) { exe_index = i; break; }
  }
  fprintf(stderr, "[%s] images=%u image0=%s filetype=%u image0_is_exe=%d first_MH_EXECUTE=%ld\n",
          when, n, _dyld_get_image_name(0), h0 ? h0->filetype : 0, h0 == exe, exe_index);
}

__attribute__((constructor)) static void image0_ctor(void) { image0_dump("dylib-ctor"); }
