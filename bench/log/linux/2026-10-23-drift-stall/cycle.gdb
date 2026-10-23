set pagination off
set $h = *(long*)&'Gcry::default_heap'
printf "heap=%lx\n", $h
set $head = *(long*)($h + 6576)
printf "chunks head=%lx index_count=%d\n", $head, *(int*)($h + 6516)
set $slow = $head
set $fast = $head
set $i = 0
set $found = 0
while $i < 1000000 && $fast != 0
  set $fast = *(long*)$fast
  if $fast == 0
    loop_break
  end
  set $fast = *(long*)$fast
  set $slow = *(long*)$slow
  set $i = $i + 1
  if $slow == $fast
    set $found = 1
    loop_break
  end
end
if $found
  set $len = 1
  set $p = *(long*)$slow
  while $p != $slow
    set $p = *(long*)$p
    set $len = $len + 1
  end
  set $mu = 0
  set $a = $head
  set $b = $slow
  while $a != $b
    set $a = *(long*)$a
    set $b = *(long*)$b
    set $mu = $mu + 1
  end
  printf "CYCLE: %d chunks from the head, then a loop of %d chunks entered at %lx\n", $mu, $len, $a
  set $q = $a
  set $k = 0
  while $k < $len && $k < 400
    printf "  loop[%d] %lx mapped=%lu class=%u flags=%x\n", $k, $q, *(unsigned long*)($q + 8), *(unsigned int*)($q + 16), *(unsigned int*)($q + 20)
    set $q = *(long*)$q
    set $k = $k + 1
  end
else
  printf "no cycle: list ends after %d double steps\n", $i
end
thread apply 1 bt 6
