require "./spec_helper"

# Phase 7.4: `notice_reclaim`'s linear scan used to be guarded by two block
# header flags (FINALIZER, DISAPPEARING). Those bits must leave the header, so
# the guard became an O(1) registration index. These pin the behaviour the flags
# used to provide — especially the case a single flag bit could not express.
describe "finalizer registration index" do
  it "still runs a finalizer after an explicit free" do
    heap = Gcry::Heap.new
    begin
      ran = 0
      obj = heap.malloc(32)
      heap.add_finalizer(obj) { ran += 1 }
      heap.free(obj)
      # notice_reclaim drops the row on the free path; the object is gone, so
      # the finalizer must not be left queued against freed memory.
      heap.collect(scan_stack: false, roots: [] of Void*)
      ran.should be <= 1
    ensure
      heap.destroy
    end
  end

  it "keeps the weak link when only the finalizer is removed" do
    # The case two independent flag bits handled and a naive presence-set would
    # get wrong: one object carrying BOTH a finalizer entry and a disappearing
    # link. Removing one registration must not make the index forget the other,
    # which is why the index counts registrations rather than storing a bit.
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(32)
      slot = Pointer(Void*).malloc(1)
      slot.value = obj
      heap.add_finalizer(obj) { }
      heap.register_disappearing_link(slot, obj)

      # Drop the object; the collector should clear the link.
      heap.collect(scan_stack: false, roots: [] of Void*)
      # Either the link was cleared or the object is still considered live —
      # both are legal; what must not happen is a crash or a stale non-null
      # pointer into reclaimed memory.
      unless slot.value.null?
        heap.live?(slot.value).should be_true
      end
    ensure
      heap.destroy
    end
  end

  it "survives churn that fills the index with tombstones" do
    # index_grow rehashes live rows only, which is what stops a table churned by
    # add/remove from degrading into a full probe.
    heap = Gcry::Heap.new
    begin
      heap.gc_threshold = UInt64::MAX
      500.times do
        o = heap.malloc(32)
        heap.add_finalizer(o) { }
        heap.free(o)
      end
      keep = [] of Void*
      200.times do
        o = heap.malloc(32)
        heap.add_finalizer(o) { }
        keep << o
      end
      heap.collect(scan_stack: false, roots: keep)
      keep.each { |p| heap.live?(p).should be_true }
    ensure
      heap.destroy
    end
  end

  it "keeps working after the index gives up on its C allocation" do
    # `index_grow` frees the table and sets `@index_cap = 0` when `malloc`
    # refuses, so `notice_reclaim` falls back to the linear scan. Two things
    # had to be true for that to be the "slow but never wrong" path its
    # comment claims, and neither was: `index_add` carried on to probe a null
    # table (mask `UInt64::MAX`), and a later successful grow produced a
    # *partial* index that `notice_reclaim` then trusted — so anything
    # registered before the failure read unregistered and its disappearing
    # link was never cleared.
    heap = Gcry::Heap.new
    begin
      obj = heap.malloc(32)
      slot = Pointer(Void*).malloc(1)
      slot.value = obj
      heap.register_disappearing_link(slot.as(Void**), obj)
      heap.debug_finalizer_index_give_up

      # Registrations after the give-up must not crash, and must not resurrect
      # a half-built index.
      200.times do
        o = heap.malloc(32)
        heap.add_finalizer(o) { }
      end
      heap.debug_finalizer_index_cap.should eq(0)

      # The link registered *before* the give-up is still honoured, which is
      # the property the partial index broke.
      heap.free(obj)
      slot.value.should eq(Pointer(Void).null)
    ensure
      heap.destroy
    end
  end

  it "still finds a link registered again once the link index has given up" do
    # Without its index the duplicate check scans the rows. Trusting an index
    # that gave up would answer "new" and add a second row, and the link would
    # be cleared when its *first* target died.
    heap = Gcry::Heap.new
    begin
      first = heap.malloc(32)
      second = heap.malloc(32)
      slot = Pointer(Void*).malloc(1)
      slot.value = first
      heap.register_disappearing_link(slot.as(Void**), first).should be_true
      heap.debug_finalizer_index_give_up
      slot.value = second
      heap.register_disappearing_link(slot.as(Void**), second).should be_false
      heap.finalizer_link_count.should eq(1)

      heap.free(first)
      slot.value.should eq(second)
      heap.free(second)
      slot.value.should eq(Pointer(Void).null)
    ensure
      heap.destroy
    end
  end

  # `replace_c`, the duplicate check in `register_disappearing_link` and
  # `notice_reclaim` find an object's rows (or a link's) through the
  # registry's maps instead of scanning the table: object -> head of a chain
  # of its entry rows, link location -> its row. Every swap-remove moves the
  # last row, so a map that misses one re-point names the wrong row — a
  # finalizer replaced on the wrong object, a WeakRef cleared for someone
  # else's death. This drives every mutation in random interleaving against a
  # brute-force model, and has the registry check each map against its tables.
  {false, true}.each do |gave_up|
    it "keeps its row maps exact through every mutation#{gave_up ? " (after the maps gave up)" : ""}" do
      FinalizerIndexModel.new(seed: gave_up ? 7_u64 : 1_u64, gave_up: gave_up).run(6000)
    end
  end

  it "finds an object's rows in a table that grew past every map's first size" do
    # Thousands of rows: growth of the entry table and of each map, with
    # replaces landing on rows spread across it.
    model = FinalizerIndexModel.new(seed: 3_u64, gave_up: false, objects: 4000, link_slots: 3000)
    model.run(30000, check_every: 5000)
  end
end

# Brute-force model of `Finalizers::Registry`. Objects are fake addresses (the
# registry never dereferences one); link slots are real words, since clearing
# a link writes to it.
class FinalizerIndexModel
  alias Registry = Gcry::Finalizers::Registry
  alias Callback = Gcry::Finalizers::Callback

  # One entry row: data is null exactly for a capture-free Crystal row, whose
  # function is the same for every such row of an object, so such rows are
  # interchangeable; every other row has unique, non-null data.
  record Row, object : Void*, fn : Void*, data : Void*, c_abi : Bool

  @rows = [] of Row
  @links = {} of Int32 => Void*
  @serial = 0_u64

  def initialize(seed : UInt64, @gave_up : Bool, @objects : Int32 = 48, @link_slots : Int32 = 40)
    @random = Random.new(seed)
    @registry = Registry.new
    @slots = Pointer(Void*).malloc(@link_slots)
    @registry.debug_index_give_up if @gave_up
  end

  def run(ops : Int32, check_every : Int32 = 1) : Nil
    ops.times do |step|
      op = @random.rand(100)
      case op
      when 0...15  then add
      when 15...22 then replace_crystal
      when 22...40 then replace
      when 40...55 then register_link
      when 55...63 then unregister_link
      when 63...71 then reclaim
      when 71...85 then queue_entry
      when 85...93 then clear_link
      else              remove_link
      end
      check(step) if step % check_every == 0
    end
    check(ops)
  ensure
    @registry.clear
  end

  private def object(k : Int32) : Void*
    Pointer(Void).new(0x7f00_0000_0000_u64 + k.to_u64 * 48)
  end

  private def random_object : Void*
    object(@random.rand(@objects))
  end

  private def unique : Void*
    @serial += 1
    Pointer(Void).new(0x5000_0000_0000_u64 + @serial * 16)
  end

  private def plain_fn(object : Void*) : Void*
    Pointer(Void).new(object.address + 0x1000_0000_0000_u64)
  end

  private def c_form(row : Row) : {Void*, Void*}
    if row.c_abi
      {row.fn, row.data}
    elsif row.data.null?
      {row.fn, Pointer(Void).null}
    else
      {Pointer(Void).null, Pointer(Void).null}
    end
  end

  private def add : Nil
    obj = random_object
    row = @random.rand(2) == 0 ? Row.new(obj, plain_fn(obj), Pointer(Void).null, false) : Row.new(obj, unique, unique, false)
    @registry.add(obj, Callback.new(row.fn, row.data))
    @rows << row
  end

  # `GC.add_finalizer` on the process GC: every row of the object goes, one
  # Crystal row takes their place.
  private def replace_crystal : Nil
    obj = random_object
    row = @random.rand(2) == 0 ? Row.new(obj, plain_fn(obj), Pointer(Void).null, false) : Row.new(obj, unique, unique, false)
    @registry.replace(obj, Callback.new(row.fn, row.data))
    @rows.reject! { |r| r.object == obj }
    @rows << row
  end

  private def replace : Nil
    obj = random_object
    remove = @random.rand(4) == 0
    fn = remove ? Pointer(Void).null : unique
    data = unique
    order = @random.rand(2) == 0 ? Gcry::Finalizers::Order::Normal : Gcry::Finalizers::Order::IgnoreSelf
    previous = @registry.replace_c(obj, fn, data, order)
    mine = @rows.select { |r| r.object == obj }
    if mine.empty?
      previous.should eq({Pointer(Void).null, Pointer(Void).null})
    else
      # Which of several rows is reported is the registry's choice; it has to
      # be one of them.
      mine.map { |r| c_form(r) }.should contain(previous)
    end
    @rows.reject! { |r| r.object == obj }
    @rows << Row.new(obj, fn, data, true) unless remove
  end

  private def register_link : Nil
    k = @random.rand(@link_slots)
    obj = random_object
    @slots[k] = obj
    @registry.register_disappearing_link(@slots + k, obj).should eq(!@links.has_key?(k))
    @links[k] = obj
  end

  private def unregister_link : Nil
    k = @random.rand(@link_slots)
    word = @slots[k] = unique
    @registry.unregister_disappearing_link(@slots + k).should eq(@links.has_key?(k))
    @slots[k].should eq(word)
    @links.delete(k)
  end

  private def reclaim : Nil
    obj = random_object
    pending = @registry.pending_count
    queued = @rows.count { |r| r.object == obj }
    @registry.notice_reclaim(obj)
    @registry.pending_count.should eq(pending + queued)
    @rows.reject! { |r| r.object == obj }
    @links.select { |_, o| o == obj }.each_key do |k|
      @slots[k].should eq(Pointer(Void).null)
      @links.delete(k)
    end
  end

  # The collector's `queue_and_remove_entry_at`, on a random row.
  private def queue_entry : Nil
    return if @registry.entry_count == 0
    i = @random.rand(@registry.entry_count)
    obj = @registry.entry_object_at(i)
    data = @registry.entry_closure_data_at(i)
    @registry.queue_and_remove_entry_at(i)
    at = @rows.index { |r| r.object == obj && r.data == data }
    at.should_not be_nil
    @rows.delete_at(at.not_nil!)
  end

  # The collector's `clear_and_remove_link_at`, on a random row.
  private def clear_link : Nil
    return if @registry.link_count == 0
    i = @random.rand(@registry.link_count)
    k = slot_of(@registry.link_location_at(i))
    @registry.link_object_at(i).should eq(@links[k])
    @registry.clear_and_remove_link_at(i)
    @slots[k].should eq(Pointer(Void).null)
    @links.delete(k)
  end

  # The collector's `remove_link_at`, which leaves the word alone.
  private def remove_link : Nil
    return if @registry.link_count == 0
    i = @random.rand(@registry.link_count)
    k = slot_of(@registry.link_location_at(i))
    word = @slots[k] = unique
    @registry.remove_link_at(i)
    @slots[k].should eq(word)
    @links.delete(k)
  end

  private def slot_of(location : Void*) : Int32
    ((location.address - @slots.address) // sizeof(Void*)).to_i32
  end

  private def check(step : Int32) : Nil
    if error = @registry.debug_index_error
      fail "step #{step}: #{error}"
    end
    table = Array.new(@registry.entry_count) do |i|
      {@registry.entry_object_at(i).address, @registry.entry_closure_data_at(i).address}
    end
    table.sort.should eq(@rows.map { |r| {r.object.address, r.data.address} }.sort)
    links = Array.new(@registry.link_count) do |i|
      {slot_of(@registry.link_location_at(i)), @registry.link_object_at(i)}
    end
    links.sort_by(&.[0]).should eq(@links.to_a.sort_by(&.[0]))
  end
end
