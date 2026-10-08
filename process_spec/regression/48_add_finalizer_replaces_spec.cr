require "../../src/gcry"
require "spec"

# `GC.add_finalizer` twice on one object (readiness-2 review).
#
# Crystal's allocator registers every instance of a type with `#finalize`, and
# a type may register itself again (`GC.add_finalizer(self)` in `initialize`).
# Under Boehm that is `GC_register_finalizer_ignore_self` twice, and the
# second replaces the first: `#finalize` runs once. Until 2026-10-08 gcry kept
# one row per call, so it ran twice — 2000 runs for 1000 objects — and a
# `#finalize` that closes or frees did it twice.

private OBJECTS = 1000

# Runs per object, one table per class so an object of one example finalized
# late cannot count against the other's. Libc memory, so counting allocates
# nothing on the finalizer's path.
private RUNS_TWICE  = LibC.malloc(OBJECTS * sizeof(Int32)).as(Int32*)
private RUNS_THRICE = LibC.malloc(OBJECTS * sizeof(Int32)).as(Int32*)

private class RegisteredTwice
  def initialize(@id : Int32)
    GC.add_finalizer(self)
  end

  def finalize
    RUNS_TWICE[@id] += 1
  end
end

private class RegisteredThrice
  def initialize(@id : Int32)
    GC.add_finalizer(self)
    GC.add_finalizer(self)
  end

  def finalize
    RUNS_THRICE[@id] += 1
  end
end

private def finalized(runs : Int32*) : Int32
  n = 0
  OBJECTS.times { |i| n += 1 if runs[i] > 0 }
  n
end

private def run(runs : Int32*, &build : ->) : Nil
  runs.clear(OBJECTS)
  # On a finished fiber, so no frame of this one still holds an object.
  done = Channel(Nil).new
  spawn { build.call; done.send(nil) }
  done.receive
  20.times do
    GC.collect
    # Over what the collection freed, so a stale word does not keep naming a
    # dead object's block.
    2_000.times { Bytes.new(64) }
    break if finalized(runs) == OBJECTS
  end
end

describe "Regression: GC.add_finalizer replaces, as Boehm's ignore-self registration" do
  it "runs #finalize once per object registered twice (allocator + initialize)" do
    run(RUNS_TWICE) { OBJECTS.times { |i| RegisteredTwice.new(i) } }
    OBJECTS.times { |i| RUNS_TWICE[i].should be <= 1 }
    # Nearly all of them died; a conservatively held few may not.
    finalized(RUNS_TWICE).should be >= OBJECTS - 10
  end

  it "runs #finalize once per object registered three times" do
    run(RUNS_THRICE) { OBJECTS.times { |i| RegisteredThrice.new(i) } }
    OBJECTS.times { |i| RUNS_THRICE[i].should be <= 1 }
    finalized(RUNS_THRICE).should be >= OBJECTS - 10
  end
end
