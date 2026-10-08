require "../../src/gcry"
require "spec"

# Crystal types every class's instance-variable initializers in one pass, and
# whatever an initializer calls is typed then — before later classes'
# initializers are attached. Stdlib has one that allocates
# (`Crystal::ThreadLinkedList`'s `@mutex = Thread::Mutex.new`, through its
# error path), so everything reachable from `GC.malloc` is typed in that pass.
# Under gcry that included `File.open` (the stack-map loader), which reaches
# every `Exception#message`; a `message` that builds an object whose own
# `initialize` uses an initialized ivar then failed to compile:
# "instance variable '@deps' of IvarInitNode must be Array(Int32), not Nil".
# The Crystal compiler is such a program (`Crystal::ASTNode#@dependencies`),
# so it could not be built with gcry at all.
#
# This file is the compile-time half of the gate: if the collector's malloc
# path reaches `File` (or anything else with that reach) again, `process_spec`
# does not build.
private class IvarInitNode
  getter deps : Array(Int32) = [] of Int32

  def initialize
    @deps.push 1
  end
end

private class IvarInitError < Exception
  def message
    "deps=#{IvarInitNode.new.deps.size}"
  end
end

describe "ivar initializer typing under gcry" do
  it "compiles an exception whose message builds an object with ivar initializers" do
    IvarInitError.new.message.should eq("deps=1")
  end
end
