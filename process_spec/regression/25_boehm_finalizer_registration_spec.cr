require "../../src/gcry"
require "spec"

# Boehm's finalizer registration, called through its C
# ABI the way `crystal i` and C libraries call it (src/gcry/c_abi.cr).
#
# Until 2026-10-06 `GC_register_finalizer*` asked `BlockHeader.finalizer?`
# whether the object already had a finalizer. Under the default headerless
# layout a small block has no header — the "header" is the object — so that
# read bit 5 of the object's own bytes 4..7: a block whose second 32-bit word
# was 32 aborted with "the object already has a finalizer" (exit 134), and under
# `crystal i` a finalizable class whose first `Int32` ivar had bit 5 set
# (`Fd.new(33)`) killed the interpreter. The flag was never set there either, so
# a real second registration went through and both finalizers ran, and a null
# `fn` removed nothing. Boehm keeps one finalizer per object, replaces it on a
# second registration and removes it on a null `fn`, handing the old function
# and client data back through `ofn` / `ocd` (`GC_register_finalizer_inner`).
#
# The same entry point also ignored which Boehm call was made: plain
# `GC_register_finalizer` was treated as `_ignore_self`, so an object holding a
# pointer to itself was finalized, where Boehm's ordering finds it on a cycle
# and never finalizes it.
#
# Blocks are built on a finished fiber that scrubbed its frames, their addresses
# kept masked, as in 21_boehm_c_abi_spec.cr. A stale word in the collect call
# chain can still hold one block (that file explains), so counts over several
# blocks allow one to be held; what is never allowed is a wrong callback, wrong
# client data or a finalized cycle.

private ABI_MASK   = 0x3C3C_3C3C_3C3C_3C3C_u64
private ABI_BLOCKS =                         8

private def abi_hide(p : Void*) : UInt64
  p.address ^ ABI_MASK
end

private def abi_unhide(word : UInt64) : Void*
  Pointer(Void).new(word ^ ABI_MASK)
end

@[NoInline]
private def abi_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory")
end

# Runs *block* on a fiber that scrubs its frames before it finishes, so no
# address the block handled is left in a frame the collector scans.
private def abi_on_fiber(&block : ->) : Nil
  done = Channel(Nil).new
  spawn do
    block.call
    abi_scrub
    done.send(nil)
  end
  done.receive
  Fiber.yield
end

# A block of *bytes* that nothing on any stack holds, set up by *init*.
@[NoInline]
private def abi_block(bytes : Int32, atomic : Bool, &init : Void* ->) : UInt64
  hidden = 0_u64
  abi_on_fiber do
    p = atomic ? LibGC.malloc_atomic(bytes) : LibGC.malloc(bytes)
    init.call(p)
    hidden = abi_hide(p)
  end
  hidden
end

# Every finalizer run, (masked object, client data, which callback), in libc
# memory so the log roots nothing. Callbacks reach it through class variables:
# a C finalizer cannot be a closure. Only client data in the current example's
# range `[lo, hi)` is logged: a block an earlier example (or file) left held by
# a stale word can be finalized during a later one.
private module AbiRegLog
  CAP = 64
  @@log = LibC.malloc(LibC::SizeT.new(CAP * 3 * sizeof(UInt64))).as(UInt64*)
  @@count = 0
  @@lo = 0_u64
  @@hi = 0_u64

  def self.reset(lo : UInt64, hi : UInt64) : Nil
    @@lo = lo
    @@hi = hi
    @@count = 0
  end

  def self.count : Int32
    @@count
  end

  def self.record(obj : Void*, cd : Void*, which : UInt64) : Nil
    return if @@count >= CAP || cd.address < @@lo || cd.address >= @@hi
    @@log[3 * @@count] = obj.address ^ ABI_MASK
    @@log[3 * @@count + 1] = cd.address
    @@log[3 * @@count + 2] = which
    @@count += 1
  end

  def self.object(k : Int32) : UInt64
    @@log[3 * k]
  end

  def self.data(k : Int32) : UInt64
    @@log[3 * k + 1]
  end

  def self.which(k : Int32) : UInt64
    @@log[3 * k + 2]
  end
end

private ABI_FIRST  = ->(obj : Void*, cd : Void*) { AbiRegLog.record(obj, cd, 1_u64) }
private ABI_SECOND = ->(obj : Void*, cd : Void*) { AbiRegLog.record(obj, cd, 2_u64) }
private ABI_NO_FN  = LibGC::Finalizer.new(Pointer(Void).null, Pointer(Void).null)

# Client data `salt + i`, every salt above anything another file registers.
private SALT = 0x2500_0000_u64

private def abi_data(i : Int32, salt : UInt64) : Void*
  Pointer(Void).new(salt &+ i.to_u64)
end

private def abi_collect(n : Int32) : Nil
  n.times do
    break if AbiRegLog.count >= ABI_BLOCKS
    LibGC.collect
  end
end

# `ofn` is one word in C; stdlib types it as a `Proc`, so read it as a word.
private def abi_register(p : Void*, fn : LibGC::Finalizer, cd : Void*, *, ignore_self : Bool) : {Void*, Void*}
  ofn = Pointer(Void).new(0xdead_u64)
  ocd = Pointer(Void).new(0xbeef_u64)
  if ignore_self
    LibGC.register_finalizer_ignore_self(p, fn, cd, pointerof(ofn).as(LibGC::Finalizer*), pointerof(ocd))
  else
    LibGC.register_finalizer(p, fn, cd, pointerof(ofn).as(LibGC::Finalizer*), pointerof(ocd))
  end
  {ofn, ocd}
end

# Each log row names a distinct block of *hidden* with its own client data,
# and only the *which* callback ran.
private def abi_log_matches(hidden : Array(UInt64), salt : UInt64, which : UInt64) : Nil
  seen = Set(UInt64).new
  AbiRegLog.count.times do |k|
    AbiRegLog.which(k).should eq(which)
    index = hidden.index(AbiRegLog.object(k))
    index.should_not be_nil
    seen.add?(AbiRegLog.object(k)).should be_true
    AbiRegLog.data(k).should eq(salt &+ index.not_nil!.to_u64)
  end
end

private NO_FINALIZER = {Pointer(Void).null, Pointer(Void).null}

describe "Regression: Boehm finalizer registration" do
  it "registers on a block whose bytes 4..7 read as the old header flag bit" do
    AbiRegLog.reset(SALT + 0x1000, SALT + 0x2000)
    previous = [] of {Void*, Void*}
    hidden = Array(UInt64).new(ABI_BLOCKS) do |i|
      abi_block(32, atomic: true) do |p|
        # Bit 5 of bytes 4..7: `BlockHeader::Flags::FINALIZER` under headerless.
        p.as(UInt32*)[1] = 32_u32
        previous << abi_register(p, ABI_FIRST, abi_data(i, SALT + 0x1000), ignore_self: false)
      end
    end
    previous.should eq([NO_FINALIZER] * ABI_BLOCKS)
    abi_collect(6)
    AbiRegLog.count.should be >= ABI_BLOCKS - 1
    abi_log_matches(hidden, SALT + 0x1000, 1_u64)
  end

  it "replaces a finalizer on a second registration and hands the old one back" do
    AbiRegLog.reset(SALT + 0x2000, SALT + 0x4000)
    previous = [] of {Void*, Void*}
    hidden = Array(UInt64).new(ABI_BLOCKS) do |i|
      abi_block(32, atomic: true) do |p|
        previous << abi_register(p, ABI_FIRST, abi_data(i, SALT + 0x2000), ignore_self: true)
        previous << abi_register(p, ABI_SECOND, abi_data(i, SALT + 0x3000), ignore_self: true)
      end
    end
    ABI_BLOCKS.times do |i|
      previous[2 * i].should eq(NO_FINALIZER)
      previous[2 * i + 1].should eq({ABI_FIRST.pointer, abi_data(i, SALT + 0x2000)})
    end
    abi_collect(6)
    AbiRegLog.count.should be >= ABI_BLOCKS - 1
    abi_log_matches(hidden, SALT + 0x3000, 2_u64)
  end

  it "removes a finalizer on a null fn and hands the old one back" do
    AbiRegLog.reset(SALT + 0x4000, SALT + 0x5000)
    previous = [] of {Void*, Void*}
    ABI_BLOCKS.times do |i|
      abi_block(32, atomic: true) do |p|
        abi_register(p, ABI_FIRST, abi_data(i, SALT + 0x4000), ignore_self: false)
        previous << abi_register(p, ABI_NO_FN, Pointer(Void).null, ignore_self: false)
        # Nothing left to remove: Boehm reports no previous finalizer.
        previous << abi_register(p, ABI_NO_FN, Pointer(Void).null, ignore_self: false)
      end
    end
    ABI_BLOCKS.times do |i|
      previous[2 * i].should eq({ABI_FIRST.pointer, abi_data(i, SALT + 0x4000)})
      previous[2 * i + 1].should eq(NO_FINALIZER)
    end
    4.times { LibGC.collect }
    AbiRegLog.count.should eq(0)
  end

  it "never finalizes a GC_register_finalizer object that points at itself, and does under _ignore_self" do
    heap = Gcry.default_heap
    AbiRegLog.reset(SALT + 0x5000, SALT + 0x6000)
    cycles_before = heap.finalization_cycles
    # Word 0 of each block is its own address: Boehm's normal ordering reaches
    # the object from itself and calls that a cycle.
    plain = Array(UInt64).new(ABI_BLOCKS) do |i|
      abi_block(32, atomic: false) do |p|
        p.as(Void**).value = p
        abi_register(p, ABI_FIRST, abi_data(i, SALT + 0x5000), ignore_self: false)
      end
    end
    3.times { LibGC.collect }
    AbiRegLog.count.should eq(0)
    (heap.finalization_cycles - cycles_before).should be >= ABI_BLOCKS
    allocated = 0
    abi_on_fiber { allocated = plain.count { |h| LibGC.base(abi_unhide(h)) == abi_unhide(h) } }
    allocated.should eq(ABI_BLOCKS)

    # The self pointer is what held them: cleared, they are finalized.
    abi_on_fiber { plain.each { |h| abi_unhide(h).as(Void**).value = Pointer(Void).null } }
    abi_collect(6)
    AbiRegLog.count.should be >= ABI_BLOCKS - 1
    abi_log_matches(plain, SALT + 0x5000, 1_u64)

    # The same self pointer under `_ignore_self` is not a cycle.
    AbiRegLog.reset(SALT + 0x6000, SALT + 0x7000)
    own = Array(UInt64).new(ABI_BLOCKS) do |i|
      abi_block(32, atomic: false) do |p|
        p.as(Void**).value = p
        abi_register(p, ABI_SECOND, abi_data(i, SALT + 0x6000), ignore_self: true)
      end
    end
    abi_collect(6)
    AbiRegLog.count.should be >= ABI_BLOCKS - 1
    abi_log_matches(own, SALT + 0x6000, 2_u64)
  end
end
