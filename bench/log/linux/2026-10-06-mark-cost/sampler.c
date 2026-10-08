// LD_PRELOAD SIGPROF sampler: records the interrupted PC (and the return
// address one frame up via RBP, best-effort) every SAMPLER_US of CPU time,
// dumps "pc caller" lines plus /proc/self/maps to $SAMPLER_OUT at exit.
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <ucontext.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>

#define MAX_SAMPLES (1 << 22)
#include <sys/mman.h>
static uintptr_t *pcs;
static volatile int nsamples;

static void on_prof(int sig, siginfo_t *si, void *ctx) {
  (void)sig; (void)si;
  ucontext_t *uc = (ucontext_t *)ctx;
  int i = __atomic_fetch_add(&nsamples, 1, __ATOMIC_RELAXED);
  if (i >= MAX_SAMPLES) return;
  pcs[i] = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
}

static void dump(void) {
  const char *out = getenv("SAMPLER_OUT");
  if (!out) return;
  struct itimerval z = {0};
  setitimer(ITIMER_PROF, &z, NULL);
  FILE *f = fopen(out, "w");
  if (!f) return;
  int n = nsamples < MAX_SAMPLES ? nsamples : MAX_SAMPLES;
  for (int i = 0; i < n; i++) fprintf(f, "S %lx\n", (unsigned long)pcs[i]);
  FILE *m = fopen("/proc/self/maps", "r");
  char line[512];
  while (m && fgets(line, sizeof line, m)) fprintf(f, "M %s", line);
  if (m) fclose(m);
  fclose(f);
}

__attribute__((constructor)) static void init(void) {
  if (!getenv("SAMPLER_OUT")) return;
  pcs = mmap(NULL, sizeof(uintptr_t) * MAX_SAMPLES, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = on_prof;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigaction(SIGPROF, &sa, NULL);
  int us = getenv("SAMPLER_US") ? atoi(getenv("SAMPLER_US")) : 1000;
  struct itimerval it = {{0, us}, {0, us}};
  setitimer(ITIMER_PROF, &it, NULL);
  atexit(dump);
}
