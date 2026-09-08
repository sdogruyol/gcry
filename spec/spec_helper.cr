require "spec"
require "../src/gcry"

# The thread this file was required on, which is the process's initial thread:
# nothing has waited yet. It is not where every example runs. Crystal 1.21's
# execution-context monitor hands a scheduler whose thread it catches inside
# `open(2)` (`Fiber.syscall`) to a pool thread, and the main fiber carries on
# there — measured on Darwin at one move per ~1 000–3 000 `File.open` calls
# from the main fiber. The moved fiber still reports `Thread.current.name` as
# `DEFAULT-0`, because the name belongs to the scheduler, so only the pthread
# id can say. An example that needs the initial thread itself — its stack
# bounds follow `RLIMIT_STACK`; a pool thread's are its mmap — has to check.
module SpecInitialThread
  class_property pthread : UInt64 = 0_u64

  def self.current? : Bool
    Gcry::Platform.current_thread_id == pthread
  end
end

SpecInitialThread.pthread = Gcry::Platform.current_thread_id
