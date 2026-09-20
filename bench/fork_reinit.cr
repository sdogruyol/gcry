# Fork reinit. The production path is pthread_atfork, not a manual
# `after_fork_child_reinit`. Until 2026-09-20 the x86_64 CI harness called
# reinit itself, ignored the child's exit status, and only checked that
# malloc was non-null — it would have stayed green with atfork uninstalled.
#
# Green requires the handler installed and the child able to malloc+collect
# without a manual reinit. `--disabled` is `GCRY_DISABLE_ATFORK=1`: handler
# not installed, and `GC.malloc` after `note_fork_child` must `_exit(69)`
# without allocating (`raise` re-enters malloc). Dropping the knob: exit 64.
# Dropping `check_fork_poison!`: the child mallocs (exit 11), FAIL.
#
# Build: crystal build -Dgc_none -Dwithout_mt bench/fork_reinit.cr -o bin/fork_reinit
# Run:   ./bin/fork_reinit
#        GCRY_DISABLE_ATFORK=1 ./bin/fork_reinit --disabled

{% unless flag?(:gc_none) %}
  {% raise "fork_reinit requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:unix) %}
  puts "fork_reinit: skipped (no fork)"
{% else %}
  {% unless flag?(:without_mt) %}
    {% raise "fork_reinit requires -Dwithout_mt (ExecutionContext cannot fork)" %}
  {% end %}

  require "../src/gcry"
  require "c/unistd"
  require "c/sys/wait"

  DISABLED = ARGV.includes?("--disabled")

  # Child exits:
  #   0  green: malloc+collect survived
  #  11  --disabled: malloc succeeded (poison did not fire)
  #  13  green: malloc null / not a heap pointer
  #  14  green: collect dropped the child's pointer
  #  15  green: malloc or collect raised
  #  69  --disabled: poison `_exit` (GC::FORK_POISON_EXIT)

  installed = Gcry::Platform.atfork_installed?
  if DISABLED
    if installed
      STDERR.puts "--disabled needs GCRY_DISABLE_ATFORK=1: atfork still installed, so this arm would require the poison `_exit` while the handler still reinits."
      exit 64
    end
  else
    unless installed
      STDERR.puts "fork_reinit: atfork not installed (GCRY_DISABLE_ATFORK?). The green arm is the handler, not a manual reinit."
      exit 64
    end
  end

  def wait_child(pid : LibC::PidT) : Int32
    # Blocking wait, same as `samples/fork_reinit.cr`. A WNOHANG loop sleeps
    # and Crystal's runtime reaps the child out from under us (ECHILD).
    # Hang bound is the recipe's `timeout`, not this wait.
    status = 0
    r = LibC.waitpid(pid, pointerof(status), 0)
    if r != pid
      STDERR.puts "fork_reinit: waitpid failed"
      exit 1
    end
    signaled = status & 0x7f
    unless signaled == 0
      STDERR.puts "fork_reinit: child signaled #{signaled}"
      exit 1
    end
    (status >> 8) & 0xff
  end

  parent_ptr = GC.malloc(64)
  unless parent_ptr && GC.is_heap_ptr(parent_ptr)
    STDERR.puts "fork_reinit: parent malloc failed"
    exit 1
  end

  pid = LibC.fork
  if pid < 0
    STDERR.puts "fork_reinit: fork failed"
    exit 1
  end

  if pid == 0
    if DISABLED
      GC.note_fork_child
      GC.malloc(128)
      LibC._exit(11)
    else
      begin
        child_ptr = GC.malloc(128)
        if child_ptr.null? || !GC.is_heap_ptr(child_ptr)
          LibC._exit(13)
        end
        GC.collect
        unless GC.is_heap_ptr(child_ptr)
          LibC._exit(14)
        end
        LibC._exit(0)
      rescue
        LibC._exit(15)
      end
    end
  end

  code = wait_child(pid)
  if DISABLED
    if code == 11
      STDERR.puts "fork_reinit --disabled: malloc succeeded after note_fork_child (poison did not fire)"
      exit 1
    end
    unless code == GC::FORK_POISON_EXIT
      STDERR.puts "fork_reinit --disabled: expected poison _exit #{GC::FORK_POISON_EXIT}, got #{code}"
      exit 1
    end
  else
    if code != 0
      STDERR.puts "fork_reinit: child failed after atfork reinit (exit #{code})"
      exit 1
    end
  end

  GC.collect
  unless GC.is_heap_ptr(parent_ptr)
    STDERR.puts "fork_reinit: parent lost ptr"
    exit 1
  end

  puts DISABLED ? "fork_reinit disabled ok" : "fork_reinit ok"
{% end %}
