require "./spec_helper"

# Minimal LLVM stackmap v3 blob:
#   1 function @ 0x1000, stack=64, 1 record
#   record: id=1, offset=0x20 → PC 0x1020, 2 locations:
#     Indirect [RBP-8] size 8
#     Register RAX size 8
private def synthetic_stackmap_v3 : Bytes
  io = IO::Memory.new
  # Header
  io.write_byte 3_u8
  io.write_byte 0_u8
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 1_u32, IO::ByteFormat::LittleEndian # NumFunctions
  io.write_bytes 0_u32, IO::ByteFormat::LittleEndian # NumConstants
  io.write_bytes 1_u32, IO::ByteFormat::LittleEndian # NumRecords
  # StkSizeRecord
  io.write_bytes 0x1000_u64, IO::ByteFormat::LittleEndian
  io.write_bytes 64_u64, IO::ByteFormat::LittleEndian
  io.write_bytes 1_u64, IO::ByteFormat::LittleEndian
  # StkMapRecord
  io.write_bytes 1_u64, IO::ByteFormat::LittleEndian # id
  io.write_bytes 0x20_u32, IO::ByteFormat::LittleEndian
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian  # flags
  io.write_bytes 2_u16, IO::ByteFormat::LittleEndian  # nloc
  # Loc 0: Indirect, size 8, reg RBP=6, offset -8
  io.write_byte 3_u8
  io.write_byte 0_u8
  io.write_bytes 8_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 6_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian
  io.write_bytes -8_i32, IO::ByteFormat::LittleEndian
  # Loc 1: Register, size 8, reg RAX=0
  io.write_byte 1_u8
  io.write_byte 0_u8
  io.write_bytes 8_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 0_i32, IO::ByteFormat::LittleEndian
  # align to 8 (32 bytes of locs → already aligned), padding + liveouts
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian
  io.write_bytes 0_u16, IO::ByteFormat::LittleEndian # NumLiveOuts
  # align8 trailing
  io.to_slice.dup
end

describe Gcry::StackMaps do
  it "parses v3 records into PC → locations" do
    Gcry::StackMaps.reset_for_testing
    Gcry::StackMaps.load_bytes(synthetic_stackmap_v3).should be_true
    Gcry::StackMaps.loaded?.should be_true
    Gcry::StackMaps.record_count.should eq(1)
    Gcry::StackMaps.location_count.should eq(2)
    Gcry::StackMaps.find_index(0x1020_u64).should eq(0)
    Gcry::StackMaps.find_index(0x9999_u64).should eq(-1)

    kinds = [] of UInt8
    Gcry::StackMaps.each_location_at(0x1020_u64) { |loc| kinds << loc.kind }
    kinds.should eq([Gcry::StackMaps::LOC_INDIRECT, Gcry::StackMaps::LOC_REGISTER])
  ensure
    Gcry::StackMaps.reset_for_testing
  end

  it "resolves Indirect + Register with RBP/gregs" do
    Gcry::StackMaps.reset_for_testing
    Gcry::StackMaps.load_bytes(synthetic_stackmap_v3).should be_true

    # Stack slot at rbp-8 holds a fake heap-looking pointer.
    slot = Pointer(UInt64).malloc(1)
    slot.value = 0xdead_beef_0000_u64
    rbp = slot.address + 8 # so rbp-8 == slot
    rsp = rbp

    # glibc gregs: index 13 = rax
    gregs = Pointer(UInt64).malloc(17)
    17.times { |i| gregs[i] = 0 }
    gregs[13] = 0xcafe_0000_u64

    roots = [] of UInt64
    Gcry::StackMaps.each_root_at(0x1020_u64, rsp, rbp, gregs, 17) do |p|
      roots << p.address
    end
    roots.should contain(0xdead_beef_0000_u64)
    roots.should contain(0xcafe_0000_u64)
  ensure
    Gcry::StackMaps.reset_for_testing
  end

  it "treats Register values in the stack range as alloca slots" do
    Gcry::StackMaps.reset_for_testing
    Gcry::StackMaps.load_bytes(synthetic_stackmap_v3).should be_true

    slot = Pointer(UInt64).malloc(1)
    slot.value = 0x1111_2222_3333_u64
    # glibc gregs[13] = rax holds the slot address (LLVM Register of alloca).
    gregs = Pointer(UInt64).malloc(17)
    17.times { |i| gregs[i] = 0 }
    gregs[13] = slot.address
    lo = slot.address
    hi = slot.address + 16

    roots = [] of UInt64
    Gcry::StackMaps.each_root_at(0x1020_u64, lo, lo, gregs, 17, lo, hi) do |p|
      roots << p.address
    end
    roots.should contain(0x1111_2222_3333_u64)
  ensure
    Gcry::StackMaps.reset_for_testing
  end

  it "find_index_near matches return addresses past the map PC" do
    Gcry::StackMaps.reset_for_testing
    Gcry::StackMaps.load_bytes(synthetic_stackmap_v3).should be_true
    # Map at 0x1020; ret a few bytes later (typical after call).
    Gcry::StackMaps.find_index_near(0x1020_u64).should eq(0)
    Gcry::StackMaps.find_index_near(0x1025_u64).should eq(0)
    Gcry::StackMaps.find_index_near(0x1020_u64 + 33).should eq(-1)
    Gcry::StackMaps.find_index_near(0x9999_u64).should eq(-1)
  ensure
    Gcry::StackMaps.reset_for_testing
  end

  it "fill_parked_sysv_gregs maps spill slots into glibc gregs order" do
    # Fake spill block: r15..rdi then ret
    buf = StaticArray(UInt64, 8).new(0_u64)
    buf[0] = 0x15_u64
    buf[1] = 0x14_u64
    buf[2] = 0x13_u64
    buf[3] = 0x12_u64
    buf[4] = 0xb_u64  # rbp
    buf[5] = 0x3_u64  # rbx
    buf[6] = 0xd1_u64 # rdi
    buf[7] = 0xdead_u64 # rip/ret
    top = buf.to_unsafe.address
    gregs = StaticArray(UInt64, Gcry::StackMaps::PARKED_SYSV_NGREGS).new(0_u64)
    Gcry::StackMaps.fill_parked_sysv_gregs(top, gregs.to_unsafe)
    gregs[7].should eq(0x15_u64)  # r15
    gregs[6].should eq(0x14_u64)  # r14
    gregs[5].should eq(0x13_u64)  # r13
    gregs[4].should eq(0x12_u64)  # r12
    gregs[10].should eq(0xb_u64) # rbp
    gregs[11].should eq(0x3_u64)  # rbx
    gregs[8].should eq(0xd1_u64)  # rdi
    gregs[16].should eq(0xdead_u64)
    gregs[15].should eq(top &+ 64) # caller RSP
  end

  it "each_root_parked_sysv skips FP walk when RBP is not on-stack (makecontext)" do
    Gcry::StackMaps.reset_for_testing
    Gcry::StackMaps.load_bytes(synthetic_stackmap_v3).should be_true

    # 8 spill words + padding so top+64 is in-range; RBP slot left 0.
    buf = StaticArray(UInt64, 16).new(0_u64)
    buf[6] = 0xaaaa_bbbb_cccc_u64 # rdi / Fiber*
    buf[7] = 0x1020_u64           # rip near a map PC (would match if walked)
    top = buf.to_unsafe.address
    lo = top
    hi = top &+ (16 * 8)

    roots = [] of UInt64
    Gcry::StackMaps.each_root_parked_sysv(top, lo, hi, 8) do |p|
      roots << p.address
    end
    # Spill yields (7 regs) only — no near/fp when RBP=0. Ret at +56 is not
    # a spill-slot yield; map Indirect[RBP-8] must not appear.
    roots.should eq([0xaaaa_bbbb_cccc_u64])
  ensure
    Gcry::StackMaps.reset_for_testing
  end
end
