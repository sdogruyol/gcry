#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <sys/wait.h>
#include <fcntl.h>
static long long now_ns(void){struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec*1000000000LL+t.tv_nsec;}
int main(int argc,char**argv){
  pid_t p=fork(); if(!p){execvp(argv[1],argv+1); _exit(127);}
  char path[64]; snprintf(path,64,"/proc/%d/statm",p);
  long last=0, peak=0; long long peak_t=0;
  for(;;){ int st; if(waitpid(p,&st,WNOHANG)==p) break;
    int fd=open(path,O_RDONLY); if(fd<0) break; char b[128]; int n=read(fd,b,127); close(fd); if(n<=0) break; b[n]=0;
    long sz,rss; sscanf(b,"%ld %ld",&sz,&rss); rss*=4; // KiB
    if (rss>peak){peak=rss; peak_t=now_ns();}
    if (labs(rss-last)>8192){ fprintf(stderr,"RSS ts_ns=%lld rss_mib=%ld\n", now_ns(), rss/1024); last=rss; }
    usleep(200);
  }
  fprintf(stderr,"RSSPEAK ts_ns=%lld rss_mib=%ld\n",peak_t,peak/1024);
  return 0;}
