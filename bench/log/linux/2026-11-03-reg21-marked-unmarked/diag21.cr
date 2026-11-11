# Diagnostic only (probe/ci21): which root source reaches regression 21's
# control blocks in its three collections, the blocks' header and chunk state
# at allocation and after each collection, and what holds them after.
module Diag21
  MASK21 = 0x5555_5555_5555_5555_u64
  # Masked control addresses; masked so this static array roots nothing.
  @@ctl = StaticArray(UInt64, 8).new(0_u64)
  # Per collection (0..3, 3 = later) and control: bit per RootSource value.
  @@src = StaticArray(UInt32, 32).new(0_u32)
  @@hits = StaticArray(UInt64, 8).new(0_u64)
  # Per stage (0 = allocation, 1..3 = after each collection) and control:
  # block header flags, chunk flags, allocated, heap mark generation.
  @@hflags = StaticArray(UInt32, 32).new(0_u32)
  @@cflags = StaticArray(UInt32, 32).new(0_u32)
  @@alloc = StaticArray(UInt8, 32).new(0_u8)
  @@gen = StaticArray(UInt8, 32).new(0_u8)
  @@acoll = StaticArray(UInt64, 8).new(0_u64)
  @@acollecting = StaticArray(UInt8, 8).new(0_u8)
  @@athread = StaticArray(UInt64, 8).new(0_u64)
  # Per stage: collections, declined freelist sweeps.
  @@scols = StaticArray(UInt64, 4).new(0_u64)
  @@sdecl = StaticArray(UInt64, 4).new(0_u64)
  @@nalloc = 0
  # Per collection and control: RootSource bits of every mark_impl call that
  # landed in the control, whether it read marked after, the first scanned
  # parent (masked), and the collection whose sweep reclaimed it.
  @@msrc = StaticArray(UInt32, 32).new(0_u32)
  @@mafter = StaticArray(UInt8, 32).new(0_u8)
  @@parent = StaticArray(UInt64, 8).new(0_u64)
  @@parent_col = StaticArray(UInt64, 8).new(0_u64)
  @@reclaimed = StaticArray(UInt64, 8).new(0_u64)
  @@cur_parent = 0_u64
  # Per collection and control: the sweep saw its chunk (bit0), on grid (1),
  # inside the walk (2), FREE (3), uninitialised (4), marked (5), major (6),
  # discover path (7).
  @@sweep = StaticArray(UInt32, 32).new(0_u32)
  # Barrier rescan marks of a control: holder word address (masked), the
  # word's value (masked), nursery_only, the collection.
  @@bholder = StaticArray(UInt64, 16).new(0_u64)
  @@bvalue = StaticArray(UInt64, 16).new(0_u64)
  @@bcol = StaticArray(UInt64, 16).new(0_u64)
  @@bctl = StaticArray(Int32, 16).new(0)
  @@bn = 0
  @@state = ""
  @@c0 = 0_u64
  class_property? armed = false

  # In the control's fiber, right after its malloc: masked, so nothing roots it.
  def self.at_alloc(p : Void*) : Nil
    i = @@nalloc
    return if i >= 8
    @@nalloc = i + 1
    heap = Gcry.default_heap
    @@acoll[i] = heap.collections
    @@acollecting[i] = heap.collecting? ? 1_u8 : 0_u8
    {% if flag?(:linux) || flag?(:darwin) %}
      @@athread[i] = Gcry::Platform.current_thread_id.to_u64
    {% end %}
    heap.diag21_state(p, 0, i)
  end

  def self.record(stage : Int32, i : Int32, hflags : UInt32, cflags : UInt32, alloc : Bool, gen : UInt8) : Nil
    @@hflags[stage * 8 + i] = hflags
    @@cflags[stage * 8 + i] = cflags
    @@alloc[stage * 8 + i] = alloc ? 1_u8 : 0_u8
    @@gen[stage * 8 + i] = gen
  end

  def self.arm(controls : Array(UInt64)) : Nil
    8.times do |i|
      @@ctl[i] = controls[i]
      @@hits[i] = 0_u64
    end
    32.times { |i| @@src[i] = 0_u32 }
    @@c0 = Gcry.default_heap.collections
    @@state = Gcry.default_heap.diag21_heap_state
    @@bn = 0
    @@armed = true
  end

  @[NoInline]
  def self.collect3(controls : Array(UInt64)) : Nil
    heap = Gcry.default_heap
    3.times do |c|
      LibGC.collect
      @@scols[c + 1] = heap.collections
      @@sdecl[c + 1] = heap.diag21_declined
      8.times { |i| heap.diag21_state(Pointer(Void).new(controls[i] ^ MASK21), c + 1, i) }
    end
  end

  def self.control_address(i : Int32) : UInt64
    @@ctl[i] ^ MASK21
  end

  def self.index_of(addr : UInt64) : Int32
    8.times do |i|
      base = @@ctl[i] ^ MASK21
      return i if addr >= base && addr < base &+ 256
    end
    -1
  end

  def self.col : Int32
    c = Gcry.default_heap.collections &- @@c0
    c > 3 ? 3 : c.to_i32
  end

  def self.enter_parent(entry : UInt64) : Nil
    @@cur_parent = entry ^ MASK21
  end

  def self.leave_parent : Nil
    @@cur_parent = 0_u64
  end

  def self.note_mark(i : Int32, source : Int32, marked : Bool) : Nil
    c = col
    @@msrc[c * 8 + i] |= (1_u32 << source)
    @@mafter[c * 8 + i] = 1_u8 if marked
    if source == 3 && @@parent[i] == 0
      @@parent[i] = @@cur_parent
      @@parent_col[i] = c.to_u64
    end
  end

  def self.note_barrier(i : Int32, holder : UInt64, value : UInt64) : Nil
    k = @@bn
    return if k >= 16
    @@bn = k + 1
    @@bholder[k] = holder ^ MASK21
    @@bvalue[k] = value ^ MASK21
    @@bcol[k] = col.to_u64
    @@bctl[k] = i
  end

  def self.state=(s : String) : String
    @@state = s
  end

  def self.note_sweep(i : Int32, bits : UInt32) : Nil
    @@sweep[col * 8 + i] |= bits
  end

  def self.note_reclaim(i : Int32) : Nil
    @@reclaimed[i] = col.to_u64 if @@reclaimed[i] == 0
  end

  def self.parent_of(i : Int32) : UInt64
    @@parent[i]
  end

  def self.note(addr : UInt64, source : Int32) : Nil
    8.times do |i|
      base = @@ctl[i] ^ MASK21
      next unless addr >= base && addr < base &+ 256
      col = Gcry.default_heap.collections &- @@c0
      col = 3_u64 if col > 3
      @@src[col * 8 + i] |= (1_u32 << source)
      @@hits[i] &+= 1
    end
  end

  @[NoInline]
  def self.report(controls : Array(UInt64), live : Proc(UInt64, Bool)) : Nil
    @@armed = false
    heap = Gcry.default_heap
    n = controls.count { |h| live.call(h) }
    moved = {% if flag?(:linux) || flag?(:darwin) %}Gcry::Platform.current_thread_id != BoehmAbiLog.initial_thread{% else %}false{% end %}
    threads = 0
    Thread.unsafe_each { threads += 1 }
    STDERR.puts "DIAG21 live=#{n} cols=#{heap.collections &- @@c0} moved=#{moved} enabled=#{heap.enabled?} threads=#{threads} ranges=#{Gcry::CAbi.root_range_count} nursery=#{heap.nursery_enabled} stage_cols=#{@@scols.to_a} declined=#{@@sdecl.to_a}"
    8.times do |i|
      st = String.build do |s|
        4.times do |g|
          k = g * 8 + i
          s << " s" << g << "=[h=0x" << @@hflags[k].to_s(16) << " c=0x" << @@cflags[k].to_s(16) << " a=" << @@alloc[k] << " gen=" << @@gen[k] << "]"
        end
      end
      srcs = String.build do |s|
        4.times { |c| s << " c" << c << "=0b" << @@src[c * 8 + i].to_s(2) }
      end
      msrc = String.build do |s|
        4.times { |c| s << " m" << c << "=0b" << @@msrc[c * 8 + i].to_s(2) << "/" << @@mafter[c * 8 + i] }
      end
      par = @@parent[i] == 0 ? "none" : "0x#{(@@parent[i] ^ MASK21).to_s(16)}@c#{@@parent_col[i]}"
      sw = String.build do |s|
        4.times { |c| s << " w" << c << "=0b" << @@sweep[c * 8 + i].to_s(2) }
      end
      STDERR.puts "DIAG21 control #{i} reclaimed_c=#{@@reclaimed[i]} parent=#{par}#{msrc}#{sw} #{heap.diag21_chunk(controls[i] ^ MASK21)}"
      STDERR.puts "DIAG21 control #{i} at 0x#{(controls[i] ^ MASK21).to_s(16)} live=#{live.call(controls[i])} alloc_col=#{@@acoll[i]} alloc_collecting=#{@@acollecting[i]} alloc_thread=#{@@athread[i]} hits=#{@@hits[i]}#{srcs}#{st}"
    end
    STDERR.puts "DIAG21 heap at arm: #{@@state}"
    @@bn.times do |k|
      STDERR.puts "DIAG21 barrier rescan marked control #{@@bctl[k]} in c#{@@bcol[k]}: word at 0x#{(@@bholder[k] ^ MASK21).to_s(16)} = 0x#{(@@bvalue[k] ^ MASK21).to_s(16)} #{heap.diag21_holder(@@bholder[k] ^ MASK21)}"
    end
    report_marks
    report_pthread
    return if n <= 1
    8.times do |i|
      next unless live.call(controls[i])
      heap.diag21_audit(controls[i] ^ MASK21)
      if (pm = @@parent[i]) != 0
        heap.diag21_describe(pm ^ MASK21)
      end
    end
  end
end

class Gcry::Heap
  private def mark_root_candidate(pointer : Void*, source : RootSource = RootSource::Stack) : Nil
    if Diag21.armed?
      Diag21.note(pointer.address, source.value)
      Diag21.cur_cand = pointer.address ^ Diag21::MASK21
      Diag21.pt_hit(pointer.address, source.value)
    end
    previous_def
  end

  def diag21_state(p : Void*, stage : Int32, i : Int32) : Nil
    found = find_block_with_chunk(p)
    unless found
      Diag21.record(stage, i, 0xFFFF_FFFF_u32, 0xFFFF_FFFF_u32, false, @header_mark_gen)
      return
    end
    header, chunk = found
    hf = {% if flag?(:gcry_block_headers) %}header.value.flags{% else %}0_u32{% end %}
    Diag21.record(stage, i, hf, chunk.value.flags, block_allocated?(chunk, header), @header_mark_gen)
  end

  private def mark_impl_unlocked(pointer : Void*, gate_type_id : Bool, base_only : Bool, source : RootSource) : Nil
    previous_def
    if Diag21.armed? && (i = Diag21.index_of(pointer.address)) >= 0
      found = find_block_with_chunk(pointer)
      marked = found ? block_marked_in?(found[1], found[0]) : false
      Diag21.note_mark(i, source.value, marked)
    end
  end

  private def scan_object(entry : BlockHeader*, shard : MarkShard? = nil) : Nil
    if Diag21.armed?
      Diag21.enter_parent(entry.address)
      previous_def
      Diag21.leave_parent
    else
      previous_def
    end
  end

  private def sweep_small_blocks(chunk : ChunkHeader*, class_index : Int32,
                                 major : Bool, class_locked : Bool = false) : SmallSweepCounts
    if Diag21.armed? && class_index >= 0 && class_index < SIZE_CLASS_COUNT
      payload = SizeClasses.payload(class_index)
      block_bytes = BlockHeader::SIZE.to_u64 + payload.to_u64
      ds = ChunkHeader.data_start(chunk).address
      limit = ChunkHeader.data_end(chunk).address
      lo = chunk.address
      hi = chunk.address &+ chunk.value.mapped_bytes
      8.times do |i|
        u = Diag21.control_address(i)
        next unless u >= lo && u < hi
        h = u &- BlockHeader::SIZE.to_u64
        bits = 1_u32
        off = h &- ds
        on_grid = h >= ds && off % block_bytes == 0
        bits |= 2_u32 if on_grid
        bits |= 4_u32 if h &+ block_bytes <= limit
        header = Pointer(BlockHeader).new(h)
        bits |= 8_u32 if BlockHeader.free?(header)
        bits |= 16_u32 if header.value.size == 0 && header.value.flags == 0
        bits |= 32_u32 if on_grid && block_marked?(chunk, header, off // block_bytes)
        bits |= 64_u32 if major
        bits |= 128_u32 if major && release_empty_chunks_this_collect?
        Diag21.note_sweep(i, bits)
      end
    end
    previous_def
  end

  private def scan_range_for_barrier_pointers(low : Void*, high : Void*, nursery_only : Bool) : Nil
    unless Diag21.armed?
      previous_def
      return
    end
    word = sizeof(Void*).to_u64
    addr = (low.address + word - 1) & ~(word - 1)
    limit = high.address
    while addr + word <= limit
      cand = Pointer(Void).new(Pointer(UInt64).new(addr).value)
      if (h = find_object(cand))
        if nursery_only
          mark_candidate(cand) if BlockHeader.nursery?(h)
        else
          unless heap_marked?(h) || BlockHeader.free?(h)
            if (i = Diag21.index_of(BlockHeader.user_from(h).address)) >= 0
              Diag21.note_barrier(i, addr, cand.address)
            end
            heap_set_mark(h)
            @mark_stack.push(h)
          end
        end
      end
      addr += word
    end
  end

  def diag21_heap_state : String
    "inc_active=#{@inc_active} incremental_marking=#{@incremental_marking} incremental_auto=#{@incremental_auto} barrier=#{@barrier_backend} prefer_mprotect=#{@prefer_mprotect_barrier} collecting=#{@collecting} parallel_mark_workers=#{parallel_mark_workers}"
  end

  # What holds a barrier-rescanned word.
  def diag21_holder(addr : UInt64) : String
    found = find_block_with_chunk(Pointer(Void).new(addr))
    return "holder: no heap block" unless found
    h, c = found
    u = user_of(c, h).address
    hf = {% if flag?(:gcry_block_headers) %}h.value.flags{% else %}0_u32{% end %}
    "holder: block hdr=0x#{h.address.to_s(16)} user=0x#{u.to_s(16)} off=#{addr.to_i64 - u.to_i64} hflags=0x#{hf.to_s(16)} size=#{block_payload(c, h)} chunk=0x#{c.address.to_s(16)} class=#{c.value.size_class} cflags=0x#{c.value.flags.to_s(16)} alloc=#{block_allocated?(c, h)}"
  end

  def diag21_chunk(u : UInt64) : String
    found = find_block_with_chunk(Pointer(Void).new(u))
    return "chunk=none" unless found
    _, c = found
    listed = false
    each_chunk { |l| listed = true if l == c }
    payload = SizeClasses.payload(c.value.size_class.to_i32)
    "chunk=0x#{c.address.to_s(16)} mapped=#{c.value.mapped_bytes} data_offset=#{c.value.data_offset} class=#{c.value.size_class} payload=#{payload} data_end=0x#{ChunkHeader.data_end(c).address.to_s(16)} listed=#{listed} pending_unmap=#{pending_unmap_listed?(c)}"
  end

  private def reclaim_small(chunk : ChunkHeader*, header : BlockHeader*, payload : UInt32 = 0_u32) : Nil
    if Diag21.armed? && (i = Diag21.index_of(BlockHeader.user_from(header).address)) >= 0
      Diag21.note_reclaim(i)
    end
    previous_def
  end

  # The scanned parent: what it is and what holds it.
  def diag21_describe(entry : UInt64) : Nil
    tag = entry >> MARK_ENTRY_TAG_SHIFT
    header = Pointer(BlockHeader).new(entry & MARK_ENTRY_ADDR_MASK)
    user = BlockHeader.user_from(header)
    found = find_block_with_chunk(user)
    words = String.build do |s|
      8.times { |k| s << " 0x" << (user.as(UInt64*) + k).value.to_s(16) }
    end
    if found
      h, c = found
      STDERR.puts "DIAG21 parent entry=0x#{entry.to_s(16)} tag=#{tag} user=0x#{user.address.to_s(16)} found_user=0x#{user_of(c, h).address.to_s(16)} hflags=0x#{({% if flag?(:gcry_block_headers) %}h.value.flags{% else %}0_u32{% end %}).to_s(16)} size=#{block_payload(c, h)} cflags=0x#{c.value.flags.to_s(16)} class=#{c.value.size_class} alloc=#{block_allocated?(c, h)} marked=#{block_marked_in?(c, h)} words:#{words}"
    else
      STDERR.puts "DIAG21 parent entry=0x#{entry.to_s(16)} tag=#{tag} user=0x#{user.address.to_s(16)} not a heap block, words:#{words}"
    end
    @address_space_audit = true
    @address_space_report_limit = 40
    audit_address_space(user.address, 16_u64, "diag21 parent")
    @address_space_audit = false
  end

  def diag21_declined : UInt64
    @stop_sweep_freelist_declined
  end

  def diag21_audit(target : UInt64) : Nil
    @address_space_audit = true
    @address_space_report_limit = 40
    audit_address_space(target, 256_u64, "diag21 control")
    @address_space_audit = false
  end
end

# v6: every header mark write that lands in a control, with its raw call
# stack (symbolised offline with addr2line against the binary).
module Diag21
  @@mk_n = 0
  @@mk_ctl = StaticArray(Int32, 16).new(0)
  @@mk_col = StaticArray(UInt64, 16).new(0_u64)
  @@mk_gen = StaticArray(UInt8, 16).new(0_u8)
  @@mk_ip = StaticArray(UInt64, 384).new(0_u64)
  @@mk_depth = StaticArray(Int32, 16).new(0)
  @@mk_cand = StaticArray(UInt64, 16).new(0_u64)
  class_property cur_cand = 0_u64
  @@uw_k = 0
  @@uw_d = 0

  def self.note_set_mark(header : Gcry::BlockHeader*) : Nil
    return unless armed?
    i = index_of(Gcry::BlockHeader.user_from(header).address)
    return if i < 0
    k = @@mk_n
    return if k >= 16
    @@mk_n = k + 1
    @@mk_ctl[k] = i
    @@mk_cand[k] = @@cur_cand
    @@mk_col[k] = col.to_u64
    @@mk_gen[k] = Gcry.default_heap.header_mark_gen
    @@uw_k = k
    @@uw_d = 0
    fn = ->(context : LibUnwind::Context, data : Void*) do
      d = Diag21.uw_d
      if d < 24
        Diag21.uw_store(d, LibUnwind.get_ip(context).to_u64)
        Diag21.uw_d = d + 1
      end
      LibUnwind::ReasonCode::NO_REASON
    end
    LibUnwind.backtrace(fn, Pointer(Void).null)
    @@mk_depth[k] = @@uw_d
  end

  def self.uw_d : Int32
    @@uw_d
  end

  def self.uw_d=(v : Int32) : Int32
    @@uw_d = v
  end

  def self.uw_store(d : Int32, ip : UInt64) : Nil
    @@mk_ip[@@uw_k * 24 + d] = ip
  end

  def self.report_marks : Nil
    STDERR.puts "DIAG21 set_mark writes on controls: #{@@mk_n}"
    @@mk_n.times do |k|
      base = 0_u64
      info = LibC::DlInfo.new
      if @@mk_depth[k] > 0 && LibC.dladdr(Pointer(Void).new(@@mk_ip[k * 24]), pointerof(info)) != 0
        base = info.dli_fbase.address
      end
      ips = String.build do |s|
        @@mk_depth[k].times { |d| s << " 0x" << (@@mk_ip[k * 24 + d] &- base &- 1).to_s(16) }
      end
      STDERR.puts "DIAG21 set_mark control #{@@mk_ctl[k]} c#{@@mk_col[k]} gen=#{@@mk_gen[k]} cand=0x#{(@@mk_cand[k] ^ MASK21).to_s(16)} ctl_user=0x#{control_address(@@mk_ctl[k]).to_s(16)} base=0x#{base.to_s(16)} offs:#{ips}"
    end
  end
end

struct Gcry::BlockHeader
  def self.set_mark(header : BlockHeader*) : Nil
    Diag21.note_set_mark(header)
    previous_def
  end

  private def self.cas_mark_gen(flags : UInt32*) : Nil
    Diag21.note_set_mark(Pointer(BlockHeader).new(flags.address &- offsetof(BlockHeader, @flags)))
    previous_def
  end
end

# v7: pthread-stack scans that reach a control: the thread's mapping, its
# suspend SP, the collector's own SP, and each holding word's address.
module Diag21
  @@ps_n = 0
  @@ps_rec = StaticArray(UInt64, 128).new(0_u64)

  def self.note_pthread(low : UInt64, high : UInt64, sp : UInt64, own_sp : UInt64, holder : UInt64, value : UInt64, ctl : Int32) : Nil
    k = @@ps_n
    return if k >= 16
    @@ps_n = k + 1
    b = k * 8
    @@ps_rec[b] = low ^ MASK21
    @@ps_rec[b + 1] = high ^ MASK21
    @@ps_rec[b + 2] = sp ^ MASK21
    @@ps_rec[b + 3] = own_sp ^ MASK21
    @@ps_rec[b + 4] = holder ^ MASK21
    @@ps_rec[b + 5] = value ^ MASK21
    @@ps_rec[b + 6] = ctl.to_u64
    @@ps_rec[b + 7] = col.to_u64
  end

  def self.block_index_of(addr : UInt64) : Int32
    8.times do |i|
      base = (@@ctl[i] ^ MASK21) &- 16
      return i if addr >= base && addr < base &+ 336
    end
    -1
  end

  def self.report_pthread : Nil
    STDERR.puts "DIAG21 pthread-stack words reaching controls: #{@@ps_n} (main stack bottom 0x#{BoehmAbiLog.initial_stackbottom.address.to_s(16)})"
    @@ps_n.times do |k|
      b = k * 8
      r = ->(j : Int32) { @@ps_rec[b + j] ^ MASK21 }
      own = r.call(3)
      holder = r.call(4)
      STDERR.puts "DIAG21 pthread c#{@@ps_rec[b + 7]} control #{@@ps_rec[b + 6]}: map=[0x#{r.call(0).to_s(16)},0x#{r.call(1).to_s(16)}) thread_sp=0x#{r.call(2).to_s(16)} collector_sp=0x#{own.to_s(16)} holder=0x#{holder.to_s(16)} value=0x#{r.call(5).to_s(16)} holder_below_collector_sp=#{holder < own} depth_below=#{own.to_i64 - holder.to_i64}"
    end
  end
end

module Diag21
  @@pt_low = 0_u64
  @@pt_high = 0_u64
  @@pt_sp = 0_u64

  def self.pt_enter(low : UInt64, high : UInt64, sp : UInt64) : Nil
    lw = Gcry::Platform.stack_low_water(low, high)
    @@pt_low = lw > low && lw < high ? lw : low
    @@pt_high = high
    @@pt_sp = sp
  end

  def self.pt_leave : Nil
    @@pt_low = 0_u64
    @@pt_high = 0_u64
  end

  # A pthread-stack candidate reached a control: every slot of the mapping
  # holding it now, with the collector's SP at this moment.
  def self.pt_hit(candidate : UInt64, source : Int32) : Nil
    return unless source == 2 || @@pt_low != 0
    i = block_index_of(candidate)
    return if i < 0
    own = Gcry::Roots.hardware_stack_pointer.address
    low = @@pt_low
    high = @@pt_high
    if low == 0
      # The pthread hook did not run: search the main stack from 4 MiB below
      # the collector's SP to the main thread's stack bottom.
      high = BoehmAbiLog.initial_stackbottom.address
      return unless own < high && high - own < 64_u64 << 20
      low = (own - (4_u64 << 20)) & ~4095_u64
    end
    page = low & ~4095_u64
    found = false
    while page < high
      if Gcry::Roots.page_readable?(page)
        a = page < low ? low : page
        stop = page + 4096 < high ? page + 4096 : high
        while a + 8 <= stop
          if Pointer(UInt64).new(a).value == candidate
            note_pthread(low, high, @@pt_sp, own, a, candidate, i)
            found = true
          end
          a += 8
        end
      end
      page += 4096
    end
    note_pthread(low, high, @@pt_sp, own, 0_u64, candidate, i) unless found
  end
end

class Gcry::Heap
  private def scan_pthread_stack(pthread_bounds : {Void*, Void*}?, sp : Void*?) : Nil
    if Diag21.armed? && pthread_bounds
      Diag21.pt_enter(pthread_bounds[0].address, pthread_bounds[1].address, sp ? sp.address : 0_u64)
      previous_def
      Diag21.pt_leave
    else
      previous_def
    end
  end
end
