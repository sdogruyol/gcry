require "./spec_helper"

# The STW capture table, tested on whatever platform runs the suite.
#
# It is used by `darwin_stw.cr` and `windows_stw.cr`, neither of which can be
# run here — and that is exactly why the first attempt at growing it shipped a
# crash: the code was reachable only from a platform nobody on this host can
# execute.
#
# **Every example builds its own `Table`, and that is load-bearing.** The first
# version of this file reconfigured the process-wide one. On Linux that is dead
# state, because this platform keeps its own table — but on Windows it is the
# table the collector is using, and `configure(4)` there left the next capture
# recording 4 of a thread's 80 register words (76 register roots dropped per
# thread, measured), while the full-table example below made a real thread's
# claim fail. The suite wedged and all six Windows jobs burned their 20-minute
# budget (run `35369782659`). A test that mutates live collector state is not a
# test of it.
describe Gcry::StwSlots::Table do
  it "starts at the capacity that shipped and hands out distinct slots" do
    table = Gcry::StwSlots::Table.new
    table.configure(4)
    table.capacity.should eq(Gcry::StwSlots::INITIAL_SLOTS)

    seen = Set(Int32).new
    Gcry::StwSlots::INITIAL_SLOTS.times do |i|
      slot = table.slot_for(0x1000_u64 + i)
      slot.should be >= 0
      seen.add(slot)
    end
    seen.size.should eq(Gcry::StwSlots::INITIAL_SLOTS)
    # The same id must land back in the slot it claimed, not a second one.
    table.slot_for(0x1000_u64).should eq(table.slot_for(0x1000_u64))
    table.no_slot.should eq(0_u64)
  end

  it "turns a thread away once the table is full, and counts it" do
    table = Gcry::StwSlots::Table.new
    table.configure(4)
    (Gcry::StwSlots::INITIAL_SLOTS + 1).times { |i| table.slot_for(0x2000_u64 + i) }
    # 64 claims fit; the 65th is the case that cost Darwin its registers.
    table.no_slot.should eq(1_u64)
  end

  it "covers more threads than the initial capacity once reserved" do
    table = Gcry::StwSlots::Table.new
    table.configure(4)
    table.reserve(200).should be_true
    table.capacity.should eq(256) # doubling from 64

    200.times do |i|
      table.slot_for(0x3000_u64 + i).should be >= 0
    end
    table.no_slot.should eq(0_u64)
  end

  it "keeps every slot's SP and registers addressable after a grow" do
    table = Gcry::StwSlots::Table.new
    table.configure(3)
    table.reserve(100)

    words = uninitialized UInt64[3]
    100.times do |i|
      id = 0x4000_u64 + i
      slot = table.slot_for(id)
      table.record_sp(slot, 0xdead_0000_u64 + i)
      3.times { |j| words[j] = 0x5000_u64 + i * 16 + j }
      table.record_gregs(slot, words.to_unsafe, 3)
    end

    100.times do |i|
      id = 0x4000_u64 + i
      table.sp(id).should eq(0xdead_0000_u64 + i)
      got = [] of UInt64
      table.each_greg(id) { |w| got << w }
      got.should eq([0x5000_u64 + i * 16, 0x5000_u64 + i * 16 + 1, 0x5000_u64 + i * 16 + 2])
    end
  end

  it "yields no registers for a slot this STW never filled" do
    table = Gcry::StwSlots::Table.new
    table.configure(2)
    id = 0x6000_u64
    slot = table.slot_for(id)
    table.record_sp(slot, 0x7000_u64)

    yielded = 0
    table.each_greg(id) { yielded += 1 }
    # A slot with an SP but no captured registers must not read as "no roots"
    # by handing back the previous collection's words.
    yielded.should eq(0)
  end

  it "forgets a collection's claims, SPs and registers on clear" do
    table = Gcry::StwSlots::Table.new
    table.configure(2)
    id = 0x8000_u64
    slot = table.slot_for(id)
    words = uninitialized UInt64[2]
    words[0] = 0x9000_u64
    words[1] = 0xa000_u64
    table.record_sp(slot, 0xb000_u64)
    table.record_gregs(slot, words.to_unsafe, 2)
    table.sp(id).should eq(0xb000_u64)

    table.clear
    table.sp(id).should eq(0_u64)
    count = 0
    table.each_greg(id) { count += 1 }
    count.should eq(0)
  end

  it "pins the table at its initial capacity when asked" do
    table = Gcry::StwSlots::Table.new
    table.configure(4)
    table.pinned = true
    table.reserve(512)
    # This is the red arm of `make stw-capture-coverage`: the bound that shipped.
    table.capacity.should eq(Gcry::StwSlots::INITIAL_SLOTS)
    table.pinned?.should be_true
  end

  it "keeps captures from the collector's table out of a test's" do
    # The regression the Windows wedge was: one table for everyone. A `Table` a
    # spec builds must not be reachable from `Gcry::StwSlots`, whose instance
    # the collector configured at install time and reads inside the stopped
    # world.
    table = Gcry::StwSlots::Table.new
    table.configure(1)
    id = 0xfeed_u64
    slot = table.slot_for(id)
    words = uninitialized UInt64[1]
    words[0] = 0xcafe_u64
    table.record_sp(slot, 0xbeef_u64)
    table.record_gregs(slot, words.to_unsafe, 1)

    table.sp(id).should eq(0xbeef_u64)
    Gcry::StwSlots.sp(id).should eq(0_u64)
    Gcry::StwSlots.each_greg(id) { raise "the collector's table saw a test's capture" }
  end

  # The property this table exists for — a reader walking the old block while a
  # grow replaces it — is not here, and deliberately. It needs threads reading
  # flat out, a block big enough that the allocator unmaps it instead of
  # recycling it, and a crash as the observable; every example above passes with
  # the predecessor freed, because nothing is reading it. It is a gate with a
  # deadline instead: `make stw-slots-grow-race`, where the shipped table
  # carries its readers 3/3 and `GCRY_STW_SLOTS_FREE_OLD=1` kills them 3/3.
  #
  # The first attempt put that busy loop in this file. `crystal spec` runs it on
  # every platform, and on the two-vCPU Windows runner four flat-out readers held
  # the spec binary for the job's entire 20-minute budget, where it was killed as
  # an orphan process (run `35361339084`). A spec suite is not the place for a
  # race that needs to starve a machine to be visible.
end
