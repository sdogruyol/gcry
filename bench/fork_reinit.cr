# Standalone fork+reinit regression test.
#
# Verifies that after LibC.fork, the child process can reinit the GC heap
# and safely allocate, and the parent continues to work normally.
#
# Build & run:
#   crystal build -Dgc_none bench/fork_reinit.cr -o bin/fork_reinit
#   ./bin/fork_reinit

require "../src/gcry"

failures = 0
ok = 0

# Phase 1: parent allocs, fork, child reinit+alloc, parent continues
parent_ptr = GC.malloc_atomic(128)
if parent_ptr.null?
  puts "FAIL: parent malloc_atomic(128) returned null"
  failures += 1
else
  ok += 1
end

pid = LibC.fork
if pid == 0
  # --- child ---
  Gcry.default_heap.after_fork_child_reinit
  child_ptr = GC.malloc_atomic(64)
  if child_ptr.null?
    LibC._exit(1)
  end
  LibC._exit(0)
end

# --- parent ---
LibC.waitpid(pid, nil, 0)

after_ptr = GC.malloc_atomic(256)
if after_ptr.null?
  puts "FAIL: parent malloc_atomic(256) after fork returned null"
  failures += 1
else
  ok += 1
end

GC.collect
survive_ptr = GC.malloc_atomic(32)
if survive_ptr.null?
  puts "FAIL: parent malloc_atomic(32) after GC.collect returned null"
  failures += 1
else
  ok += 1
end

puts "fork_reinit: #{ok} passed, #{failures} failed"
exit(failures > 0 ? 1 : 0)
