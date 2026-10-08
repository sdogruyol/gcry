#define _GNU_SOURCE
#include <sys/mman.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <stdint.h>
#ifndef MREMAP_DONTUNMAP
#define MREMAP_DONTUNMAP 4
#endif
#define P 4096UL
static void maps(const char *tag, char *lo, size_t len) {
  FILE *f = fopen("/proc/self/maps", "r"); char line[512]; int n = 0;
  printf("-- %s [%p, %p)\n", tag, lo, lo + len);
  while (fgets(line, sizeof line, f)) {
    uintptr_t a, b; sscanf(line, "%lx-%lx", &a, &b);
    if (b > (uintptr_t)lo && a < (uintptr_t)(lo + len)) { printf("   %s", line); n++; }
  }
  fclose(f); printf("   vmas=%d\n", n);
}
static char *fresh(size_t n) {
  char *p = mmap(0, n, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
  madvise(p, n, MADV_NOHUGEPAGE); p[0] = 1; return p;
}
int main(void) {
  size_t n0 = 64 * P; char *old = fresh(n0); memset(old, 7, n0);
  char *cur = old; size_t curn = n0;
  for (int gen = 0; gen < 4; gen++) {
    size_t nn = curn * 2; char *r = fresh(nn);
    void *x = mremap(cur + P, curn - P, curn - P, MREMAP_MAYMOVE|MREMAP_FIXED|MREMAP_DONTUNMAP, r + P);
    printf("gen %d move %s\n", gen, x == MAP_FAILED ? strerror(errno) : "ok");
    if (x == MAP_FAILED) return 1;
    if (r[P + 5] != 7) printf("content lost!\n");
    printf("old data after move: %d\n", cur[P + 5]);
    memset(r + curn, 7, nn - curn);
    maps("new", r, nn);
    cur = r; curn = nn;
  }
  return 0;
}
