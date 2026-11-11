set pagination off
set confirm off
set print thread-events off
set breakpoint pending on
starti
break *(0x555555554000+0x1bfbe0)
commands
  silent
  printf "SLEEP thread %d slot=%#lx word=%#lx\n", $_thread, $rsp-0x18, *(unsigned long*)($rsp-0x18)
  continue
end
continue
