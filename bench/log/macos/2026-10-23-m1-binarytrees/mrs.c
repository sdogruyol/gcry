// What an `mrs` of the thread pointer costs on the hit path's terms: a loop
// of K stores (a callee-saved register frame, an object's zeroing) followed
// by one read of this thread's TSD slot, the way `Platform.tsd_read` does it
// (macOS: `mrs tpidrro_el0`; Linux: `mrs tpidr_el0`), against the same loop
// reading the slot through a plain global (no system register). If the read
// waits for older stores to drain, its cost grows with K; if it is just a
// few cycles of latency, it does not.
//
// cc -O2 -o mrs mrs.c && ./mrs
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define ITERS 200000000L

static uint64_t slot_word;
static uint64_t *volatile global_base = &slot_word;
static uint64_t frame[64];

static inline uint64_t tp(void) {
  uint64_t v;
#if defined(__APPLE__)
  __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(v));
  v &= ~7ULL;
#else
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(v));
#endif
  return v;
}

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

// K stores, then the base from `mrs` (sys = 1) or a global (sys = 0), then a
// load through it as the hit path does.
#define LOOP(K, SYS)                                                    \
  static __attribute__((noinline)) uint64_t loop_##K##_##SYS(void) {    \
    uint64_t acc = 0;                                                   \
    for (long i = 0; i < ITERS; i++) {                                  \
      for (int k = 0; k < K; k++) ((volatile uint64_t *)frame)[k] = i;  \
      uint64_t b = SYS ? tp() : (uint64_t)global_base;                  \
      acc += *(volatile uint64_t *)b;                                   \
    }                                                                   \
    return acc;                                                         \
  }

LOOP(0, 0)
LOOP(0, 1)
LOOP(4, 0)
LOOP(4, 1)
LOOP(14, 0)
LOOP(14, 1)
LOOP(24, 0)
LOOP(24, 1)

static __attribute__((noinline)) uint64_t loop_getspecific(pthread_key_t key) {
  uint64_t acc = 0;
  for (long i = 0; i < ITERS; i++) acc += (uint64_t)pthread_getspecific(key);
  return acc;
}

#define RUN(fn, label)                                                       \
  do {                                                                       \
    double t = now();                                                        \
    uint64_t r = fn;                                                         \
    printf("%-28s %6.3f ns/iter (%llu)\n", label, (now() - t) * 1e9 / ITERS, \
           (unsigned long long)(r & 1));                                     \
  } while (0)

int main(void) {
  pthread_key_t key;
  pthread_key_create(&key, NULL);
  pthread_setspecific(key, &slot_word);
  for (int rep = 0; rep < 3; rep++) {
    RUN(loop_0_0(), "0 stores, global");
    RUN(loop_0_1(), "0 stores, mrs");
    RUN(loop_4_0(), "4 stores, global");
    RUN(loop_4_1(), "4 stores, mrs");
    RUN(loop_14_0(), "14 stores, global");
    RUN(loop_14_1(), "14 stores, mrs");
    RUN(loop_24_0(), "24 stores, global");
    RUN(loop_24_1(), "24 stores, mrs");
    RUN(loop_getspecific(key), "pthread_getspecific");
  }
  return 0;
}
