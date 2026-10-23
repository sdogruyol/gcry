// pcprof: a PC-sampling profiler for one thread, preloaded into the program
// (`DYLD_INSERT_LIBRARIES` on macOS, `LD_PRELOAD` on Linux). It samples the
// thread that runs the constructors -- the main thread, which is
// Binarytrees' mutator and, with one marker, its collector -- every
// PCPROF_US microseconds (default 100) and writes the samples' program
// counters, less the main image's load bias so that they match `objdump`'s
// addresses, as raw little-endian u64 to $PCPROF_OUT.<pid> at exit.
//
// macOS: a sampler thread `thread_suspend`s the main thread, reads its PC
// with `thread_get_state` and resumes it, as `sample(1)` does, at ~10 kHz
// (ITIMER_PROF is tick-based there). Linux: a CLOCK_MONOTONIC POSIX timer
// signals the main thread (SIGEV_THREAD_ID) and the handler reads the PC
// from its ucontext.
//
// The sampler writes only into a preallocated array: no allocation, no lock,
// so suspending the main thread anywhere (in the collector, in libc) is safe.
// gcry's own stop-the-world suspends registered Crystal threads only, so it
// leaves the sampler alone; the sampler suspending the main thread while it
// collects is one more suspend count, which Mach adds.
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach/mach.h>
#else
#include <link.h>
#include <sys/syscall.h>
#include <ucontext.h>
#endif

#define MAX_SAMPLES (1 << 22)

static uint64_t samples[MAX_SAMPLES];
static volatile long nsamples;
static uint64_t bias;
static volatile int stop;

static void record(uint64_t pc) {
  long i = __atomic_fetch_add(&nsamples, 1, __ATOMIC_RELAXED);
  if (i < MAX_SAMPLES) samples[i] = pc - bias;
}

static long interval_us(void) {
  const char *s = getenv("PCPROF_US");
  long us = s ? atol(s) : 100;
  return us > 0 ? us : 100;
}

#ifdef __APPLE__
static thread_act_t target;
static pthread_t sampler;

static void *sample_loop(void *arg) {
  (void)arg;
  struct timespec ts = {0, interval_us() * 1000};
  while (!stop) {
    nanosleep(&ts, NULL);
    if (thread_suspend(target) != KERN_SUCCESS) break;
#if defined(__aarch64__)
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(target, ARM_THREAD_STATE64, (thread_state_t)&st, &count);
    uint64_t pc = kr == KERN_SUCCESS ? (uint64_t)arm_thread_state64_get_pc(st) : 0;
#else
    x86_thread_state64_t st;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    kern_return_t kr = thread_get_state(target, x86_THREAD_STATE64, (thread_state_t)&st, &count);
    uint64_t pc = kr == KERN_SUCCESS ? st.__rip : 0;
#endif
    thread_resume(target);
    if (pc) record(pc);
  }
  return NULL;
}
#else
static void on_tick(int sig, siginfo_t *si, void *ctx) {
  (void)sig;
  (void)si;
  ucontext_t *uc = ctx;
#if defined(__aarch64__)
  record(uc->uc_mcontext.pc);
#else
  record(uc->uc_mcontext.gregs[REG_RIP]);
#endif
}

static int first_object(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  *(uint64_t *)data = info->dlpi_addr;
  return 1;
}
#endif

__attribute__((constructor)) static void pcprof_start(void) {
  if (!getenv("PCPROF_OUT")) return;
#ifdef __APPLE__
  bias = (uint64_t)_dyld_get_image_vmaddr_slide(0);
  target = mach_thread_self();
  pthread_create(&sampler, NULL, sample_loop, NULL);
#else
  dl_iterate_phdr(first_object, &bias);
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = on_tick;
  sa.sa_flags = SA_SIGINFO | SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGPROF, &sa, NULL);
  struct sigevent ev;
  memset(&ev, 0, sizeof ev);
  ev.sigev_notify = SIGEV_THREAD_ID;
  ev.sigev_signo = SIGPROF;
  ev._sigev_un._tid = (pid_t)syscall(SYS_gettid);
  timer_t t;
  if (timer_create(CLOCK_MONOTONIC, &ev, &t) == 0) {
    long us = interval_us();
    struct itimerspec it = {{us / 1000000, (us % 1000000) * 1000}, {us / 1000000, (us % 1000000) * 1000}};
    timer_settime(t, 0, &it, NULL);
  }
#endif
}

__attribute__((destructor)) static void pcprof_stop(void) {
  const char *out = getenv("PCPROF_OUT");
  if (!out) return;
  stop = 1;
#ifdef __APPLE__
  pthread_join(sampler, NULL);
#else
  signal(SIGPROF, SIG_IGN);
#endif
  char path[4096];
  snprintf(path, sizeof path, "%s.%d", out, (int)getpid());
  FILE *f = fopen(path, "wb");
  if (!f) return;
  long n = nsamples < MAX_SAMPLES ? nsamples : MAX_SAMPLES;
  fwrite(samples, sizeof samples[0], (size_t)n, f);
  fclose(f);
}
