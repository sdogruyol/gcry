// pcprof: a PC-sampling profiler for one thread, preloaded into the program
// (`DYLD_INSERT_LIBRARIES` on macOS, `LD_PRELOAD` on Linux). It samples the
// thread that runs the constructors -- the main thread, which is
// Binarytrees' mutator and, with one marker, its collector -- every
// PCPROF_US microseconds (default 100). At exit it writes the samples that
// fell in the executable, less its load bias so that they match `objdump`'s
// addresses, as raw little-endian u64 to $PCPROF_OUT.<pid>, and every other
// sample as an `image<TAB>nearest symbol` line (`dladdr`) to
// $PCPROF_OUT.<pid>.other.
//
// macOS: a sampler thread `thread_suspend`s the main thread, reads its PC
// with `thread_get_state` and resumes it, as `sample(1)` does, at ~10 kHz
// (ITIMER_PROF is tick-based there). Linux: a CLOCK_MONOTONIC POSIX timer
// signals the main thread (SIGEV_THREAD_ID) and the handler reads the PC
// from its ucontext.
//
// The sampler writes only into a preallocated buffer: no allocation, no
// lock, so suspending the main thread anywhere (in the collector, in libc) is
// safe. The buffer is an anonymous mapping, not a static array: both
// collectors scan every loaded image's data and bss as roots, and run 1 and
// 2's 32 MiB `.bss` array put 13-21% of gcry's samples in its static-root
// scan (`scan_static_ranges`), the profiler measuring itself.
// gcry's own stop-the-world suspends registered Crystal threads only, so it
// leaves the sampler alone; the sampler suspending the main thread while it
// collects is one more suspend count, which Mach adds.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <mach/mach.h>
#else
#include <link.h>
#include <sys/syscall.h>
#include <sys/auxv.h>
#endif

#define MAX_SAMPLES (1 << 22)

static uint64_t *samples;
static volatile long nsamples;
static uint64_t bias;
static volatile int stop;

#ifdef __APPLE__
// The executable's slide, found by its file type: while an inserted
// library's constructor runs, image 0 need not be the executable (run 1's
// first version took image 0 and subtracted another image's slide).
static uint64_t executable_slide(void) {
  uint32_t n = _dyld_image_count();
  for (uint32_t i = 0; i < n; i++) {
    const struct mach_header *h = _dyld_get_image_header(i);
    if (h && h->filetype == MH_EXECUTE) return (uint64_t)_dyld_get_image_vmaddr_slide(i);
  }
  return 0;
}

// Which dyld image index is the executable, and what image 0 is, at the
// constructor and again at exit: gcry's static-root walk takes image 0 as
// the executable (`darwin_roots.cr`), and run 1 found it is not one here.
static char images_note[2048];

static void note_images(const char *when) {
  uint32_t n = _dyld_image_count();
  int exe = -1;
  for (uint32_t i = 0; i < n; i++) {
    const struct mach_header *h = _dyld_get_image_header(i);
    if (h && h->filetype == MH_EXECUTE) {
      exe = (int)i;
      break;
    }
  }
  const char *name0 = n ? _dyld_get_image_name(0) : "?";
  size_t len = strlen(images_note);
  snprintf(images_note + len, sizeof images_note - len, "%s: %u images, executable at %d, image 0 %s\n", when, n,
           exe, name0 ? name0 : "?");
}
#endif

// Raw PCs; the destructor sorts them into the executable's (written less its
// load bias) and every other image's (named with `dladdr`).
static void record(uint64_t pc) {
  long i = __atomic_fetch_add(&nsamples, 1, __ATOMIC_RELAXED);
  if (i < MAX_SAMPLES) samples[i] = pc;
}

// The executable's base as `dladdr` reports it (`dli_fbase`).
static const void *executable_base(void) {
#ifdef __APPLE__
  uint32_t n = _dyld_image_count();
  for (uint32_t i = 0; i < n; i++) {
    const struct mach_header *h = _dyld_get_image_header(i);
    if (h && h->filetype == MH_EXECUTE) return h;
  }
  return NULL;
#else
  Dl_info info;
  if (!dladdr((void *)getauxval(AT_PHDR), &info)) return NULL;
  return info.dli_fbase;
#endif
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
  void *buf = mmap(NULL, MAX_SAMPLES * sizeof(uint64_t), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (buf == MAP_FAILED) return;
  samples = buf;
#ifdef __APPLE__
  bias = executable_slide();
  note_images("constructor");
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
  snprintf(path, sizeof path, "%s.%d.other", out, (int)getpid());
  FILE *o = fopen(path, "w");
  const void *base = executable_base();
  long n = nsamples < MAX_SAMPLES ? nsamples : MAX_SAMPLES;
  for (long i = 0; i < n; i++) {
    Dl_info info;
    int found = dladdr((void *)samples[i], &info);
    if (found && info.dli_fbase == base) {
      uint64_t pc = samples[i] - bias;
      fwrite(&pc, sizeof pc, 1, f);
    } else if (o) {
      const char *img = found && info.dli_fname ? info.dli_fname : "?";
      const char *sym = found && info.dli_sname ? info.dli_sname : "?";
      fprintf(o, "%s\t%s\n", img, sym);
    }
  }
  fclose(f);
  if (o) fclose(o);
#ifdef __APPLE__
  note_images("exit");
  snprintf(path, sizeof path, "%s.%d.images", out, (int)getpid());
  FILE *im = fopen(path, "w");
  if (im) {
    fputs(images_note, im);
    fclose(im);
  }
#endif
}
