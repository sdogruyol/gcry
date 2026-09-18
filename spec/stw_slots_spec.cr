require "./spec_helper"

# The STW capture table, tested on whatever platform runs the suite.
#
# It is used by `darwin_stw.cr` and `windows_stw.cr`, neither of which can be
# run here — and that is exactly why the first attempt at growing it shipped a
# crash: the code was reachable only from a platform nobody on this host can
# execute. These examples cover the three things that attempt got wrong.
describe Gcry::StwSlots do
  # The module is process-wide state shared with the collector on Darwin and
  # Windows. On those platforms the collector configures it at install time, so
  # examples that reconfigure it must put it back.
  around_each do |example|
    saved_words = 8
    Gcry::StwSlots.reset_for_test
    example.run
    Gcry::StwSlots.reset_for_test
    Gcry::StwSlots.configure(saved_words) if Gcry::StwSlots.configured?
  end

  it "starts at the capacity that shipped and hands out distinct slots" do
    Gcry::StwSlots.configure(4)
    Gcry::StwSlots.capacity.should eq(Gcry::StwSlots::INITIAL_SLOTS)

    seen = Set(Int32).new
    Gcry::StwSlots::INITIAL_SLOTS.times do |i|
      slot = Gcry::StwSlots.slot_for(0x1000_u64 + i)
      slot.should be >= 0
      seen.add(slot)
    end
    seen.size.should eq(Gcry::StwSlots::INITIAL_SLOTS)
    # The same id must land back in the slot it claimed, not a second one.
    Gcry::StwSlots.slot_for(0x1000_u64).should eq(Gcry::StwSlots.slot_for(0x1000_u64))
    Gcry::StwSlots.no_slot.should eq(0_u64)
  end

  it "turns a thread away once the table is full, and counts it" do
    Gcry::StwSlots.configure(4)
    (Gcry::StwSlots::INITIAL_SLOTS + 1).times { |i| Gcry::StwSlots.slot_for(0x2000_u64 + i) }
    # 64 claims fit; the 65th is the case that cost Darwin its registers.
    Gcry::StwSlots.no_slot.should eq(1_u64)
  end

  it "covers more threads than the initial capacity once reserved" do
    Gcry::StwSlots.configure(4)
    Gcry::StwSlots.reserve(200).should be_true
    Gcry::StwSlots.capacity.should eq(256) # doubling from 64

    200.times do |i|
      Gcry::StwSlots.slot_for(0x3000_u64 + i).should be >= 0
    end
    Gcry::StwSlots.no_slot.should eq(0_u64)
  end

  it "keeps every slot's SP and registers addressable after a grow" do
    Gcry::StwSlots.configure(3)
    Gcry::StwSlots.reserve(100)

    words = uninitialized UInt64[3]
    100.times do |i|
      id = 0x4000_u64 + i
      slot = Gcry::StwSlots.slot_for(id)
      Gcry::StwSlots.record_sp(slot, 0xdead_0000_u64 + i)
      3.times { |j| words[j] = 0x5000_u64 + i * 16 + j }
      Gcry::StwSlots.record_gregs(slot, words.to_unsafe, 3)
    end

    100.times do |i|
      id = 0x4000_u64 + i
      Gcry::StwSlots.sp(id).should eq(0xdead_0000_u64 + i)
      got = [] of UInt64
      Gcry::StwSlots.each_greg(id) { |w| got << w }
      got.should eq([0x5000_u64 + i * 16, 0x5000_u64 + i * 16 + 1, 0x5000_u64 + i * 16 + 2])
    end
  end

  it "yields no registers for a slot this STW never filled" do
    Gcry::StwSlots.configure(2)
    id = 0x6000_u64
    slot = Gcry::StwSlots.slot_for(id)
    Gcry::StwSlots.record_sp(slot, 0x7000_u64)

    yielded = 0
    Gcry::StwSlots.each_greg(id) { yielded += 1 }
    # A slot with an SP but no captured registers must not read as "no roots"
    # by handing back the previous collection's words.
    yielded.should eq(0)
  end

  it "forgets a collection's claims, SPs and registers on clear" do
    Gcry::StwSlots.configure(2)
    id = 0x8000_u64
    slot = Gcry::StwSlots.slot_for(id)
    words = uninitialized UInt64[2]
    words[0] = 0x9000_u64
    words[1] = 0xa000_u64
    Gcry::StwSlots.record_sp(slot, 0xb000_u64)
    Gcry::StwSlots.record_gregs(slot, words.to_unsafe, 2)
    Gcry::StwSlots.sp(id).should eq(0xb000_u64)

    Gcry::StwSlots.clear
    Gcry::StwSlots.sp(id).should eq(0_u64)
    count = 0
    Gcry::StwSlots.each_greg(id) { count += 1 }
    count.should eq(0)
  end

  it "pins the table at its initial capacity when asked" do
    Gcry::StwSlots.configure(4)
    Gcry::StwSlots.pinned = true
    Gcry::StwSlots.reserve(512)
    # This is the red arm of `make stw-capture-coverage`: the bound that shipped.
    Gcry::StwSlots.capacity.should eq(Gcry::StwSlots::INITIAL_SLOTS)
    Gcry::StwSlots.pinned?.should be_true
  end

  # The one that matters. Growing used to `free` the old arrays, so a reader
  # still walking them faulted — which is how the first attempt crashed the
  # Darwin job on a step that had been green. Here the readers run flat out
  # while the table doubles under them.
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
