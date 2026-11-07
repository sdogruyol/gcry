# Diagnostic only (Reg21c): every root candidate and every mark write that
# lands in one of regression 21's eight control blocks, with the scan range
# it came from, the slot(s) holding it, the stack that slot belongs to, and a
# raw call stack (symbolised offline with addr2line).
module D21
  MASK = 0x5555_5555_5555_5555_u64
  N    =                        64
  D    =                        22
  @@ctl = StaticArray(UInt64, 8).new(0_u64) # masked user addresses
  @@c0 = 0_u64
  class_property? armed = false
  @@n = 0
  # per record
  @@kind = StaticArray(UInt8, N).new(0_u8) # 1 root cand, 2 bitmap mark, 3 header mark
  @@ci = StaticArray(Int32, N).new(0)
  @@col = StaticArray(UInt64, N).new(0_u64)
  @@src = StaticArray(Int32, N).new(-1)
  @@cand = StaticArray(UInt64, N).new(0_u64)
  @@own = StaticArray(UInt64, N).new(0_u64)
  @@rlo = StaticArray(UInt64, N).new(0_u64)
  @@rhi = StaticArray(UInt64, N).new(0_u64)
  @@slot = StaticArray(UInt64, N).new(0_u64)
  @@nslots = StaticArray(Int32, N).new(0)
  # owner of the range: fiber object id, its stack [lo,hi), its saved top, flags
  @@ofib = StaticArray(UInt64, N).new(0_u64)
  @@oslo = StaticArray(UInt64, N).new(0_u64)
  @@oshi = StaticArray(UInt64, N).new(0_u64)
  @@otop = StaticArray(UInt64, N).new(0_u64)
  @@orun = StaticArray(Int32, N).new(-1)
  @@othr = StaticArray(Int32, N).new(-1)   # thread index whose current fiber it is
  @@thrmap = StaticArray(Int32, N).new(-1) # thread index whose pthread mapping holds the slot
  @@thr_sp = StaticArray(UInt64, N).new(0_u64)
  @@ip = StaticArray(UInt64, 1408).new(0_u64)
  @@depth = StaticArray(Int32, N).new(0)
  @@uw_k = 0
  @@uw_d = 0
  @@rng_lo = 0_u64
  @@rng_hi = 0_u64
  @@last_cand = 0_u64
  @@last_src = -1
  @@last_slot = 0_u64
  @@collector_thread = 0_u64
  @@roots_seen = 0_u64
  @@marks_seen = 0_u64

  def self.arm(controls : Array(UInt64)) : Nil
    8.times { |i| @@ctl[i] = controls[i] }
    @@cl_armed = true
    @@c0 = Gcry.default_heap.collections
    @@n = 0
    @@armed = true
  end

  def self.disarm : Nil
    @@armed = false
  end

  def self.col : UInt64
    c = Gcry.default_heap.collections &- @@c0
    c > 3 ? 3_u64 : c
  end

  # block index: [user - header, user + 256): the 256 bytes the spec asked for
  def self.block_index_of(addr : UInt64) : Int32
    8.times do |i|
      u = @@ctl[i] ^ MASK
      return i if addr >= u &- Gcry::BlockHeader::SIZE.to_u64 && addr < u &+ 256
    end
    -1
  end

  def self.range_enter(lo : UInt64, hi : UInt64) : Nil
    @@rng_lo = lo
    @@rng_hi = hi
  end

  def self.range_leave : Nil
    @@rng_lo = 0_u64
    @@rng_hi = 0_u64
  end

  def self.uw_d : Int32
    @@uw_d
  end

  def self.uw_d=(v : Int32) : Int32
    @@uw_d = v
  end

  def self.uw_store(d : Int32, ip : UInt64) : Nil
    @@ip[@@uw_k * D + d] = ip
  end

  private def self.unwind(k : Int32) : Nil
    @@uw_k = k
    @@uw_d = 0
    fn = ->(context : LibUnwind::Context, data : Void*) do
      d = D21.uw_d
      if d < D
        D21.uw_store(d, LibUnwind.get_ip(context).to_u64)
        D21.uw_d = d + 1
      end
      LibUnwind::ReasonCode::NO_REASON
    end
    LibUnwind.backtrace(fn, Pointer(Void).null)
    @@depth[k] = @@uw_d
  end

  private def self.owner(k : Int32, slot : UInt64) : Nil
    return if slot == 0
    Fiber.unsafe_each do |f|
      st = f.@stack
      lo = st.pointer.address
      hi = st.bottom.address
      next unless slot >= lo && slot < hi
      @@ofib[k] = f.object_id
      @@oslo[k] = lo
      @@oshi[k] = hi
      @@otop[k] = f.@context.stack_top.address
      @@orun[k] = f.running? ? 1 : 0
      ti = 0
      Thread.unsafe_each do |t|
        @@othr[k] = ti if t.@current_fiber == f
        ti += 1
      end
      break
    end
    ti = 0
    Thread.unsafe_each do |t|
      if b = Gcry::Platform.snapshotted_stack_bounds(t.to_unsafe)
        if slot >= b[0].address && slot < b[1].address
          @@thrmap[k] = ti
          if sp = Gcry::Platform.thread_sp(t.to_unsafe)
            @@thr_sp[k] = sp.address
          end
        end
      end
      ti += 1
    end
  end

  def self.root_hit(cand : UInt64, source : Int32) : Nil
    @@roots_seen &+= 1
    i = block_index_of(cand)
    @@last_cand = 0_u64
    return if i < 0
    @@last_cand = cand
    @@last_src = source
    k = @@n
    return if k >= N
    @@n = k + 1
    @@kind[k] = 1_u8
    @@ci[k] = i
    @@col[k] = col
    @@src[k] = source
    @@cand[k] = cand
    @@own[k] = Gcry::Roots.hardware_stack_pointer.address
    lo = @@rng_lo
    hi = @@rng_hi
    @@rlo[k] = lo
    @@rhi[k] = hi
    if lo != 0 && hi > lo
      a = (lo + 7) & ~7_u64
      ns = 0
      while a + 8 <= hi
        if Pointer(UInt64).new(a).value == cand
          @@slot[k] = a if ns == 0
          ns += 1
        end
        a += 8
      end
      @@nslots[k] = ns
    end
    owner(k, @@slot[k] != 0 ? @@slot[k] : lo)
    unwind(k)
  end

  def self.mark_hit(kind : UInt8, user : UInt64) : Nil
    @@marks_seen &+= 1
    i = block_index_of(user)
    return if i < 0
    k = @@n
    return if k >= N
    @@n = k + 1
    @@kind[k] = kind
    @@ci[k] = i
    @@col[k] = col
    @@src[k] = @@last_cand != 0 ? @@last_src : -1
    @@cand[k] = @@last_cand
    @@own[k] = Gcry::Roots.hardware_stack_pointer.address
    unwind(k)
  end

  @[NoInline]
  def self.report(controls : Array(UInt64), live : Proc(UInt64, Bool)) : Nil
    @@armed = false
    snap(1, controls)
    n = controls.count { |h| live.call(h) }
    moved = Gcry::Platform.current_thread_id != BoehmAbiLog.initial_thread
    threads = 0
    Thread.unsafe_each { threads += 1 }
    base = 0_u64
    info = LibC::DlInfo.new
    fp = ->D21.disarm
    if LibC.dladdr(fp.pointer, pointerof(info)) != 0
      base = info.dli_fbase.address
    end
    STDERR.puts "D21 live=#{n} cols=#{Gcry.default_heap.collections &- @@c0} moved=#{moved} threads=#{threads} records=#{@@n} roots_seen=#{@@roots_seen} marks_seen=#{@@marks_seen} base=0x#{base.to_s(16)} own_thread=#{Gcry::Platform.current_thread_id} initial=#{BoehmAbiLog.initial_thread} main_stackbottom=0x#{BoehmAbiLog.initial_stackbottom.address.to_s(16)}"
    8.times { |i| STDERR.puts "D21 control #{i} user=0x#{(controls[i] ^ MASK).to_s(16)} live=#{live.call(controls[i])}" }
    ti = 0
    Thread.unsafe_each do |t|
      b = Gcry::Platform.snapshotted_stack_bounds(t.to_unsafe)
      f = t.@current_fiber
      STDERR.puts "D21 thread #{ti} name=#{t.name.inspect} map=#{b ? "0x#{b[0].address.to_s(16)}..0x#{b[1].address.to_s(16)}" : "nil"} cur_fiber=#{f ? "#{f.name.inspect} 0x#{f.object_id.to_s(16)} stack=0x#{f.@stack.pointer.address.to_s(16)}..0x#{f.@stack.bottom.address.to_s(16)}" : "nil"}"
      ti += 1
    end
    Fiber.unsafe_each do |f|
      STDERR.puts "D21 fiber #{f.name.inspect} 0x#{f.object_id.to_s(16)} stack=0x#{f.@stack.pointer.address.to_s(16)}..0x#{f.@stack.bottom.address.to_s(16)} top=0x#{f.@context.stack_top.address.to_s(16)} running=#{f.running?} dead=#{f.dead?}"
    end
    @@n.times do |k|
      ips = String.build do |s|
        @@depth[k].times { |d| s << " 0x" << (@@ip[k * D + d] &- base &- 1).to_s(16) }
      end
      STDERR.puts "D21 rec #{k} kind=#{@@kind[k]} ctl=#{@@ci[k]} c#{@@col[k]} src=#{@@src[k]} cand=0x#{@@cand[k].to_s(16)} own_sp=0x#{@@own[k].to_s(16)} range=0x#{@@rlo[k].to_s(16)}..0x#{@@rhi[k].to_s(16)} slot=0x#{@@slot[k].to_s(16)} nslots=#{@@nslots[k]} slot_below_own=#{@@slot[k] != 0 && @@slot[k] < @@own[k] ? (@@own[k] &- @@slot[k]) : 0} ofib=0x#{@@ofib[k].to_s(16)} ostack=0x#{@@oslo[k].to_s(16)}..0x#{@@oshi[k].to_s(16)} otop=0x#{@@otop[k].to_s(16)} orun=#{@@orun[k]} othr=#{@@othr[k]} thrmap=#{@@thrmap[k]} thr_sp=0x#{@@thr_sp[k].to_s(16)}"
      STDERR.puts "D21 rec #{k} offs:#{ips}"
    end
    report2(base)
    Gcry.default_heap.d21_sets(controls[0] ^ MASK)
    D21.fb_report
  end
end

class Gcry::Heap
  private def mark_root_candidate(pointer : Void*, source : RootSource = RootSource::Stack) : Nil
    D21.root_hit(pointer.address, source.value) if D21.armed?
    previous_def
  end

  private def chunk_set_mark(chunk : ChunkHeader*, ordinal : UInt64) : Nil
    if D21.armed?
      stride = @block_bytes[chunk.value.size_class.to_i32]
      h = ChunkHeader.data_start(chunk).address &+ ordinal &* stride
      D21.mark_hit(2_u8, h &+ BlockHeader::SIZE.to_u64)
    end
    previous_def
  end
end

struct Gcry::BlockHeader
  def self.set_mark(header : BlockHeader*) : Nil
    D21.mark_hit(3_u8, header.address &+ SIZE) if D21.armed?
    previous_def
  end

  private def self.cas_mark_gen(flags : UInt32*) : Nil
    D21.mark_hit(4_u8, flags.address &- offsetof(BlockHeader, @flags) &+ SIZE) if D21.armed?
    previous_def
  end
end

module Gcry::Roots
  def self.scan_range(low : Void*, high : Void*, safe : Bool = false, & : Void* ->) : Nil
    if D21.armed?
      D21.range_enter(low.address, high.address)
      previous_def(low, high, safe) { |c| yield c }
      D21.range_leave
    else
      previous_def(low, high, safe) { |c| yield c }
    end
  end
end

# v2: occupancy. Claims (and premark completions) of a word that covers a
# control, with their call stack; and each control's occ / exact / claim
# state read first thing after the collections, before anything allocates.
module D21
  CN = 24
  @@cl_n = 0
  @@cl_kind = StaticArray(UInt8, CN).new(0_u8)
  @@cl_col = StaticArray(UInt64, CN).new(0_u64)
  @@cl_mask = StaticArray(UInt64, CN).new(0_u64)
  @@cl_ctl = StaticArray(UInt8, CN).new(0_u8) # bit per control covered
  @@cl_thr = StaticArray(UInt64, CN).new(0_u64)
  @@cl_collecting = StaticArray(UInt8, CN).new(0_u8)
  @@cl_ip = StaticArray(UInt64, 528).new(0_u64)
  @@cl_depth = StaticArray(Int32, CN).new(0)
  @@cl_phase = StaticArray(UInt8, CN).new(0_u8)
  @@phase = 0_u8
  @@count0 = -1

  def self.count0 : Int32
    @@count0
  end

  def self.counted(n : Int32) : Nil
    @@count0 = n
    @@phase = 1_u8
  end

  @@claims_seen = 0_u64
  # stage 0 right after the three collections, 1 at the count in report,
  # 2 and 3 after collections 1 and 2
  @@st = StaticArray(UInt64, 32).new(0_u64)
  @@ctr = StaticArray(UInt64, 32).new(0_u64)
  class_property? cl_armed = false

  def self.claim_hit(kind : UInt8, data_start : UInt64, stride : UInt64, word : Int32, mask : UInt64, collecting : Bool) : Nil
    @@claims_seen &+= 1
    bits = 0_u8
    8.times do |i|
      h = (@@ctl[i] ^ MASK) &- Gcry::BlockHeader::SIZE.to_u64
      next unless h >= data_start
      ord = (h &- data_start) // stride
      next unless (ord >> 6) == word.to_u64
      bits |= (1_u8 << i) if (mask >> (ord & 63)) & 1 != 0
    end
    return if bits == 0
    k = @@cl_n
    return if k >= CN
    @@cl_n = k + 1
    @@cl_kind[k] = kind
    @@cl_col[k] = col
    @@cl_mask[k] = mask
    @@cl_ctl[k] = bits
    @@cl_thr[k] = Gcry::Platform.current_thread_id.to_u64
    @@cl_collecting[k] = collecting ? 1_u8 : 0_u8
    @@cl_phase[k] = @@phase
    @@uw_d = 0
    fn = ->(context : LibUnwind::Context, data : Void*) do
      d = D21.uw_d
      if d < 22
        D21.cl_store(d, LibUnwind.get_ip(context).to_u64)
        D21.uw_d = d + 1
      end
      LibUnwind::ReasonCode::NO_REASON
    end
    @@uw_k = k
    LibUnwind.backtrace(fn, Pointer(Void).null)
    @@cl_depth[k] = @@uw_d
  end

  def self.cl_store(d : Int32, ip : UInt64) : Nil
    @@cl_ip[@@uw_k * 22 + d] = ip
  end

  # bits: 1 occ, 2 exact, 4 chunk cursor, 8 in claim mask, 16 marked, 32 base==p,
  # 64 chunk pinned, 128 chunk dormant; bits 8..11 the set holding the chunk
  # (1 own, 2 other live, 3 fallback, 4 oom, 5 no-hit live, 6 other state),
  # bits 12..18 the slot index, bit 20 slot mid-allocation (in_flight)
  def self.snap(stage : Int32, controls : Array(UInt64)) : Nil
    heap = Gcry.default_heap
    8.times { |i| @@st[stage * 8 + i] = heap.d21_bits(controls[i] ^ MASK) }
    @@ctr[stage * 4] = heap.collections
    @@ctr[stage * 4 + 1] = heap.sweep_cursor_pinned
    @@ctr[stage * 4 + 2] = heap.collect_reentrant_skips
    @@ctr[stage * 4 + 3] = heap.d21_lazy
  end

  def self.report2(base : UInt64) : Nil
    @@cl_armed = false
    8.times { |i| STDERR.puts "D21 ctl #{i} c1=0x#{@@st[16 + i].to_s(16)} c2=0x#{@@st[24 + i].to_s(16)} after_collect=0x#{@@st[i].to_s(16)} at_report=0x#{@@st[8 + i].to_s(16)}" }
    {2, 3, 0, 1}.each { |s| STDERR.puts "D21 stage #{s} collections=#{@@ctr[s * 4]} sweep_cursor_pinned=#{@@ctr[s * 4 + 1]} reentrant_skips=#{@@ctr[s * 4 + 2]} lazy=#{@@ctr[s * 4 + 3]}" }
    STDERR.puts "D21 count_right_after_collect=#{@@count0} claims_seen=#{@@claims_seen} claims_on_controls=#{@@cl_n}"
    @@cl_n.times do |k|
      ips = String.build do |s|
        @@cl_depth[k].times { |d| s << " 0x" << (@@cl_ip[k * 22 + d] &- base &- 1).to_s(16) }
      end
      STDERR.puts "D21 claim #{k} kind=#{@@cl_kind[k]} c#{@@cl_col[k]} ctl=0b#{@@cl_ctl[k].to_s(2)} mask=0x#{@@cl_mask[k].to_s(16)} thread=#{@@cl_thr[k]} phase=#{@@cl_phase[k]} collecting=#{@@cl_collecting[k]} offs:#{ips}"
    end
  end
end

class Gcry::Heap
  def d21_bits(u : UInt64) : UInt64
    found = find_block_with_chunk(Pointer(Void).new(u))
    return 0xFFFF_u64 unless found
    header, chunk = found
    b = 0_u64
    b |= 1 if block_allocated?(chunk, header)
    b |= 2 if block_allocated_exact?(chunk, header)
    if ChunkHeader.cursor?(chunk)
      b |= 4
      w, m = cursor_claim(chunk)
      ord = chunk_block_ordinal(chunk, header.address)
      b |= 8 if w.to_u64 == (ord >> 6) && (m >> (ord & 63)) & 1 != 0
    end
    b |= 16 if block_marked_in?(chunk, header)
    b |= 32 if CAbi.base(Pointer(Void).new(u)).address == u
    b |= 64 if ChunkHeader.pinned?(chunk)
    b |= 128 if ChunkHeader.dormant?(chunk)
    slot = ChunkHeader.atomic?(chunk) ? chunk.value.size_class.to_i32 + SIZE_CLASS_COUNT : chunk.value.size_class.to_i32
    own = cursor_set_cached
    each_cursor_set do |set|
      s = CursorSet.slot(set, slot)
      next unless s.value.chunk == chunk
      kind = if set == own
               1
             elsif set == @fallback_cursor_set
               3
             elsif set == @oom_reserve_set
               4
             elsif set.value.state != CursorSet::STATE_LIVE
               6
             elsif set.value.no_hit_path != 0_u8
               5
             else
               2
             end
      b |= kind.to_u64 << 8
      b |= slot.to_u64 << 12
      b |= 1_u64 << 20 unless s.value.in_flight.null?
    end
    b
  end

  def d21_lazy : UInt64
    (@lazy_sweep_pending ? 1_u64 : 0_u64) | (@world_stopped ? 2_u64 : 0_u64)
  end

  private def cursor_claim_word(s : CursorSlot*, chunk : ChunkHeader*, word : Int32,
                                mask : UInt64, index : Int32) : Nil
    D21.claim_hit(1_u8, ChunkHeader.data_start(chunk).address, @block_bytes[index], word, mask, @collecting) if D21.cl_armed?
    previous_def
  end

  private def cursor_premark_claim(s : CursorSlot*, chunk : ChunkHeader*) : Nil
    if D21.cl_armed?
      ci = chunk.value.size_class.to_i32
      D21.claim_hit(2_u8, ChunkHeader.data_start(chunk).address, @block_bytes[ci], s.value.word, s.value.free_mask, @collecting)
    end
    previous_def
  end
end

# v3: every cursor set and the chunk in each slot, with its flags; at the
# report (allocates, so last).
class Gcry::Heap
  def d21_sets(ctl_user : UInt64) : Nil
    cf = find_block_with_chunk(Pointer(Void).new(ctl_user))
    cchunk = cf ? cf[1].address : 0_u64
    STDERR.puts "D21 sets: count=#{@cursor_set_count} fallback=0x#{@fallback_cursor_set.address.to_s(16)} oom=0x#{@oom_reserve_set.address.to_s(16)} own=0x#{cursor_set_cached.address.to_s(16)} ctl_chunk=0x#{cchunk.to_s(16)}"
    each_cursor_set do |set|
      i = 0
      while i < POOL_SLOTS
        s = CursorSet.slot(set, i)
        c = s.value.chunk
        unless c.null? && s.value.in_flight.null?
          STDERR.puts "D21 set 0x#{set.address.to_s(16)} owner=#{set.value.owner} state=#{set.value.state} nohit=#{set.value.no_hit_path} slot=#{i} chunk=0x#{c.address.to_s(16)} pinned=#{c.null? ? "-" : ChunkHeader.pinned?(c)} cursor=#{c.null? ? "-" : ChunkHeader.cursor?(c)} mask=0x#{s.value.free_mask.to_s(16)} word=#{s.value.word} in_flight=0x#{s.value.in_flight.address.to_s(16)}#{c.address == cchunk ? " CONTROLS" : ""}"
        end
        i += 1
      end
    end
    n = 0
    each_chunk do |c|
      next if ChunkHeader.large?(c)
      next unless ChunkHeader.pinned?(c)
      STDERR.puts "D21 pinned chunk 0x#{c.address.to_s(16)} class=#{c.value.size_class} atomic=#{ChunkHeader.atomic?(c)} cursor=#{ChunkHeader.cursor?(c)}#{c.address == cchunk ? " CONTROLS" : ""}"
      n += 1
    end
    STDERR.puts "D21 pinned chunks=#{n}"
  end
end

# v3b: every time a thread is handed the fallback set (table full or
# exiting), with the collection count and the set count then.
module D21
  FB = 32
  @@fb_n = 0
  @@fb_thr = StaticArray(UInt64, FB).new(0_u64)
  @@fb_col = StaticArray(UInt64, FB).new(0_u64)
  @@fb_cnt = StaticArray(Int32, FB).new(0)
  @@fb_why = StaticArray(UInt8, FB).new(0_u8)
  @@sets_max = 0

  def self.fb_hit(thr : UInt64, col : UInt64, cnt : Int32, why : UInt8) : Nil
    k = @@fb_n
    @@fb_n = k + 1
    return if k >= FB
    @@fb_thr[k] = thr
    @@fb_col[k] = col
    @@fb_cnt[k] = cnt
    @@fb_why[k] = why
  end

  def self.fb_report : Nil
    STDERR.puts "D21 fallback handouts=#{@@fb_n}"
    {@@fb_n, FB}.min.times do |k|
      STDERR.puts "D21 fallback #{k} thread=#{@@fb_thr[k]} collections=#{@@fb_col[k]} set_count=#{@@fb_cnt[k]} why=#{@@fb_why[k]}"
    end
  end
end

class Gcry::Heap
  private def cursor_set_under_lock(key : UInt64, exiting : Bool) : CursorSet*
    set = previous_def
    if !set.null? && set == @fallback_cursor_set
      D21.fb_hit(Gcry::Platform.current_thread_id.to_u64, @collections, @cursor_set_count, exiting ? 1_u8 : (@cursor_key_ok ? 0_u8 : 2_u8))
    end
    set
  end
end
