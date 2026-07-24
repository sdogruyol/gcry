# pthread_atfork handlers for process GC. Child inherits the heap mapping but
# must reset locks / STW / thread-local tables (dead parent threads vanish).

require "c/pthread"

lib LibC
  fun pthread_atfork(prepare : ->, parent : ->, child : ->) : Int32
end

module Gcry
  module Platform
    @@atfork_installed = false
    @@fork_prepare : Proc(Nil)? = nil
    @@fork_parent : Proc(Nil)? = nil
    @@fork_child : Proc(Nil)? = nil

    def self.atfork_installed? : Bool
      @@atfork_installed
    end

    def self.set_atfork_handlers(prepare : -> Nil, parent : -> Nil, child : -> Nil) : Nil
      @@fork_prepare = prepare
      @@fork_parent = parent
      @@fork_child = child
    end

    # Register once. Call after set_atfork_handlers from GC.init.
    def self.install_atfork : Nil
      {% unless flag?(:unix) %}
        return
      {% end %}
      return if @@atfork_installed
      return unless @@fork_prepare && @@fork_parent && @@fork_child

      rc = LibC.pthread_atfork(
        -> { @@fork_prepare.try(&.call) },
        -> { @@fork_parent.try(&.call) },
        -> { @@fork_child.try(&.call) },
      )
      @@atfork_installed = rc == 0
    end
  end
end
