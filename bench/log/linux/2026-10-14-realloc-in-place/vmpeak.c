#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
/* Writes "VMPEAK <kB> VMHWM <kB>" to fd 2 at exit, read from /proc/self/status. */
__attribute__((destructor)) static void vmpeak_report(void) {
  char buf[8192]; int fd = open("/proc/self/status", O_RDONLY); if (fd < 0) return;
  ssize_t n = read(fd, buf, sizeof buf - 1); close(fd); if (n <= 0) return; buf[n] = 0;
  char *p = strstr(buf, "VmPeak:"), *h = strstr(buf, "VmHWM:");
  long peak = 0, hwm = 0; if (p) sscanf(p + 7, "%ld", &peak); if (h) sscanf(h + 6, "%ld", &hwm);
  char out[128]; int m = snprintf(out, sizeof out, "VMPEAK %ld VMHWM %ld\n", peak, hwm); write(2, out, m);
}
