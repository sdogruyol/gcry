#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
static long flt(void){struct rusage r; getrusage(RUSAGE_SELF,&r); return r.ru_minflt;}
static double now(void){struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9;}
int main(){
  size_t n=64<<20; char*p=mmap(0,n,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
  long f0=flt(); double t0=now(); memset(p,1,n); double t1=now(); long f1=flt();
  printf("first touch: %ld faults %.2f ms\n", f1-f0,(t1-t0)*1e3);
  t0=now(); madvise(p,n,MADV_FREE); t1=now(); printf("madv_free: %.2f ms\n",(t1-t0)*1e3);
  f0=flt(); t0=now(); memset(p,2,n); t1=now(); f1=flt();
  printf("after free: %ld faults %.2f ms\n", f1-f0,(t1-t0)*1e3);
  f0=flt(); t0=now(); memset(p,3,n); t1=now(); f1=flt();
  printf("warm: %ld faults %.2f ms\n", f1-f0,(t1-t0)*1e3);
  t0=now(); void*q=mremap(p,n,n*2,MREMAP_MAYMOVE); t1=now(); printf("mremap grow: %.3f ms moved=%d\n",(t1-t0)*1e3,q!=p);
  f0=flt(); t0=now(); memset(q,4,n); t1=now(); f1=flt();
  printf("after mremap old part: %ld faults %.2f ms\n", f1-f0,(t1-t0)*1e3);
  f0=flt(); t0=now(); memset((char*)q+n,4,n); t1=now(); f1=flt();
  printf("after mremap new part: %ld faults %.2f ms\n", f1-f0,(t1-t0)*1e3);
  t0=now(); munmap(q,2*n); t1=now(); printf("munmap 128M: %.2f ms\n",(t1-t0)*1e3);
  return 0;}
