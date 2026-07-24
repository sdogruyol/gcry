# Process-GC fork reinit smoke (requires -Dwithout_mt: ExecutionContext forbids fork).
# Build: crystal build -Dgc_none -Dwithout_mt samples/fork_reinit.cr -o bin/fork_reinit

{% unless flag?(:without_mt) %}
  abort "build with -Dgc_none -Dwithout_mt (ExecutionContext cannot fork)"
{% end %}

{% if flag?(:gc_none) %}
  require "../src/gcry"
{% else %}
  abort "build with -Dgc_none"
{% end %}

require "c/unistd"
require "c/sys/wait"

parent_ptr = GC.malloc(64)
raise "parent alloc" unless GC.is_heap_ptr(parent_ptr)

pid = LibC.fork
if pid < 0
  raise "fork failed"
elsif pid == 0
  begin
    child_ptr = GC.malloc(128)
    raise "child alloc" unless GC.is_heap_ptr(child_ptr)
    GC.collect
    print "child_ok\n"
    LibC._exit(0)
  rescue
    LibC._exit(1)
  end
end

status = 0
LibC.waitpid(pid, pointerof(status), 0)
exited = (status & 0x7f) == 0
code = (status >> 8) & 0xff
raise "child exited status=#{status}" unless exited && code == 0

GC.collect
raise "parent lost ptr" unless GC.is_heap_ptr(parent_ptr)
puts "parent_ok"
puts "atfork=#{Gcry::Platform.atfork_installed?}"
