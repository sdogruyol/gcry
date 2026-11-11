set pagination off
set confirm off
set print thread-events off
handle SIGPWR nostop noprint pass
handle SIGXCPU nostop noprint pass
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass
starti
watch -l *(unsigned int*)0x7ffff63feb64
commands
  silent
  printf "WRITE high=%#x thread %d\n", *(unsigned int*)0x7ffff63feb64, $_thread
  bt 6
  continue
end
continue
