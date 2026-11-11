# Diagnostic copy of process_spec/regression/1_live_objects_dormant_spec.cr.
# Prints per-collection live/finalizer counts and, at the baseline, snapshots
# the main stack [sp, bottom) and the callee-saved registers. After the
# post-free collections it names every snapshot word that pointed at a block
# allocated at the baseline and reclaimed since, and every finalizer entry
# that went inside the window.
require "../../Reg1/dwt2/src/gcry"
require "spec"

lib LibC
  fun dprintf(fd : Int, fmt : Char*, ...) : Int
end

module D1
  MASK    = 0x5a5a_5a5a_5a5a_5a5a_u64
  MAXW    = 1 << 20
  MAXF    = 4096
  @@words = Pointer(UInt64).null # masked values
  @@hdrs = Pointer(UInt64).null  # masked header of the block the word hit, 0 if none
  @@tids = Pointer(Int32).null
  @@nwords = 0
  @@lo = 0_u64
  @@frame = 0_u64
  @@fin = Pointer(UInt64).null
  @@fin_tid = Pointer(Int32).null
  @@nfin = 0
  @@on = false
  @@cycle = 0
  @@stk = Pointer(UInt64).null
  @@nstk = 0
  STK_CAP = 65536

  def self.note_stack(kind : UInt64, addr : UInt64, size : UInt64) : Nil
    @@stk = LibC.malloc(STK_CAP * 32).as(UInt64*) if @@stk.null?
    i = @@nstk
    return if i >= STK_CAP
    @@nstk = i + 1
    e = @@stk + i * 4
    e[0] = kind; e[1] = addr; e[2] = size
    e[3] = (h = Gcry.default_heap?) ? h.collections : 0_u64
  end

  def self.proc_sps : Nil
    Dir.each_child("/proc/self/task") do |tid|
      comm = File.read("/proc/self/task/#{tid}/comm").strip rescue "?"
      sc = File.read("/proc/self/task/#{tid}/syscall").strip rescue "?"
      LibC.dprintf(2, "D1 TASK %s %s syscall=%s\n", tid.to_unsafe, comm.to_unsafe, sc.to_unsafe)
    end
  end

  def self.log(tag : String, heap) : Nil
    m = Gcry.metrics(heap)
    LibC.dprintf(2, "D1 c%d %s live=%llu cols=%llu fin=%d t=%llu\n", @@cycle, tag.to_unsafe, m.live_objects.to_u64, heap.collections.to_u64, heap.@finalizers.entry_count, Gcry::Clock.monotonic_ns / 1_000_000)
  end

  def self.start(cycle : Int32) : Nil
    @@cycle = cycle
    Gcry::Reg1Diag.n = 0
    Gcry::Reg1Diag.dropped = 0
    Gcry::Reg1Diag.on = true
    if @@words.null?
      @@words = LibC.malloc(MAXW * 8).as(UInt64*)
      @@hdrs = LibC.malloc(MAXW * 8).as(UInt64*)
      @@tids = LibC.malloc(MAXW * 4).as(Int32*)
      @@fin = LibC.malloc(MAXF * 8).as(UInt64*)
      @@fin_tid = LibC.malloc(MAXF * 4).as(Int32*)
    end
  end

  # Called from drift_cycle with the address of one of its locals.
  @[NoInline]
  def self.snapshot(heap, frame : UInt64) : Nil
    regs = uninitialized UInt64[6]
    r0 = r1 = r2 = r3 = r4 = r5 = 0_u64
    asm("movq %rbx, $0" : "=r"(r0))
    asm("movq %r12, $0" : "=r"(r1))
    asm("movq %r13, $0" : "=r"(r2))
    asm("movq %r14, $0" : "=r"(r3))
    asm("movq %r15, $0" : "=r"(r4))
    asm("movq %rbp, $0" : "=r"(r5))
    regs[0] = r0; regs[1] = r1; regs[2] = r2; regs[3] = r3; regs[4] = r4; regs[5] = r5
    @@frame = frame
    sp = 0_u64
    asm("movq %rsp, $0" : "=r"(sp))
    stack = Fiber.current.@stack
    hi = stack.bottom.address
    lo = sp & ~7_u64
    @@lo = lo
    n = 0
    # Six register pseudo-words first, then the stack.
    6.times do |k|
      record(heap, n, regs[k])
      n += 1
    end
    p = lo
    while p < hi && n < MAXW
      record(heap, n, Pointer(UInt64).new(p).value)
      n += 1
      p += 8
    end
    @@nwords = n
    k = 0
    f = heap.@finalizers
    while k < f.entry_count && k < MAXF
      o = f.entry_object_at(k).address
      @@fin[k] = o ^ MASK
      @@fin_tid[k] = Pointer(Int32).new(o).value
      k += 1
    end
    @@nfin = k
    @@on = true
  end

  private def self.record(heap, n : Int32, v : UInt64) : Nil
    @@words[n] = v ^ MASK
    @@hdrs[n] = 0_u64
    @@tids[n] = 0
    return if v < 4096
    found = heap.find_object_with_chunk(Pointer(Void).new(v))
    return unless found
    h, c = found
    user = heap.user_of(c, h).address
    @@hdrs[n] = h.address ^ MASK
    @@tids[n] = Pointer(Int32).new(user).value
  end

  # Root records (first marks) whose block is gone now.
  def self.roots_report(heap) : Nil
    n = Gcry::Reg1Diag.n
    LibC.dprintf(2, "D1 c%d ROOTS records=%d dropped=%d\n", @@cycle, n, Gcry::Reg1Diag.dropped)
    stack = Fiber.current.@stack
    slo = stack.pointer.address
    shi = stack.bottom.address
    printed = 0
    i = 0
    while i < n
      r = Gcry::Reg1Diag.recs + i * 6
      val = r[3]
      hdr = r[4]
      now = heap.find_object_with_chunk(Pointer(Void).new(val))
      unless now && now[0].address == hdr
        if printed < 400
          slot = r[2]
          where = (slot >= slo && slot < shi) ? "mainstack" : "other"
          cur = (slot > 4096 && where == "mainstack") ? Pointer(UInt64).new(slot).value : 0_u64
          if where != "mainstack"
            Thread.unsafe_each do |t|
              if mf = t.@main_fiber
                if slot >= mf.@stack.pointer.address && slot < mf.@stack.bottom.address
                  where = t.@name || "?"
                  shi2 = mf.@stack.bottom.address
                  cur = Pointer(UInt64).new(slot).value
                  LibC.dprintf(2, "D1 c%d ROOT-THREAD %s slot=bottom%+lld\n", @@cycle, where.to_unsafe, slot.to_i64 - shi2.to_i64)
                end
              end
            end
          end
          if where == "other"
            Fiber.unsafe_each do |fb|
              if slot >= fb.@stack.pointer.address && slot < fb.@stack.bottom.address
                LibC.dprintf(2, "D1 c%d ROOT-FIBER %s running=%d slot=bottom%+lld stack_top=0x%llx\n", @@cycle, (fb.name || "?").to_unsafe, fb.running? ? 1 : 0, slot.to_i64 - fb.@stack.bottom.address.to_i64, fb.@context.stack_top.address)
              end
            end
          end
          LibC.dprintf(2, "D1 c%d ROOT col=%llu src=%llu slot=0x%llx (%s, bottom%+lld) val=0x%llx hdr=0x%llx chunk=0x%llx cur=0x%llx\n",
            @@cycle, r[0], r[1], slot, where.to_unsafe, slot.to_i64 - shi.to_i64, val, hdr, r[5], cur)
          j = 0
          while j < @@nstk
            e = @@stk + j * 4
            if val >= e[1] && val <= e[1] + e[2]
              LibC.dprintf(2, "D1 c%d   val in fiber stack #%d [0x%llx,+0x%llx] %s at collection %llu\n", @@cycle, j, e[1], e[2], e[0] == 1 ? "allocated".to_unsafe : "freed".to_unsafe, e[3])
            end
            j += 1
          end
        end
        printed += 1
      end
      i += 1
    end
    LibC.dprintf(2, "D1 c%d ROOTS gone=%d main stack [0x%llx,0x%llx) stack events=%d\n", @@cycle, printed, slo, shi, @@nstk)
    proc_sps
    # The mappings, for the slot addresses above.
    File.each_line("/proc/self/maps") { |l| LibC.dprintf(2, "D1 MAP %s\n", l.to_unsafe) } if printed > 0
    Thread.unsafe_each do |t|
      lo = hi = clo = chi = 0_u64
      if mf = t.@main_fiber
        lo = mf.@stack.pointer.address; hi = mf.@stack.bottom.address
      end
      if cf = t.@current_fiber
        clo = cf.@stack.pointer.address; chi = cf.@stack.bottom.address
      end
      LibC.dprintf(2, "D1 THREAD %s main=[0x%llx,0x%llx) current=[0x%llx,0x%llx)\n", (t.@name || "?").to_unsafe, lo, hi, clo, chi)
    end
  end

  def self.type_name(tid : Int32) : String
    {% begin %}
      case tid
      {% for t in Reference.all_subclasses %}
        {% if t.type_vars.empty? && !t.abstract? && !t.private? %}
          when {{t}}.crystal_instance_type_id then {{t.stringify}}
        {% end %}
      {% end %}
      else "?"
      end
    {% end %}
  end

  @@n_pre2 = 0
  @@n_pre3 = 0
  @@memfd = -1

  def self.mark_pre(k : Int32) : Nil
    @@n_pre2 = Gcry::Reg1Diag.n if k == 2
    @@n_pre3 = Gcry::Reg1Diag.n if k == 3
  end

  # Reads a word through /proc/self/mem, so an unmapped slot reads as absent.
  private def self.peek(addr : UInt64) : UInt64?
    @@memfd = LibC.open("/proc/self/mem", LibC::O_RDONLY) if @@memfd < 0
    v = 0_u64
    n = LibC.pread(@@memfd, pointerof(v).as(Void*), 8, addr.to_i64)
    n == 8 ? v : nil
  end

  private def self.where(slot : UInt64) : String
    return "reg" if slot == 1
    return "noslot" if slot == 0
    s = Fiber.current.@stack
    return "mainstack bottom#{slot.to_i64 - s.bottom.address.to_i64}" if slot >= s.pointer.address && slot < s.bottom.address
    Thread.unsafe_each do |t|
      if mf = t.@main_fiber
        if slot >= mf.@stack.pointer.address && slot < mf.@stack.bottom.address
          return "thread #{t.@name || "?"} bottom#{slot.to_i64 - mf.@stack.bottom.address.to_i64}"
        end
      end
    end
    r = "other"
    Fiber.unsafe_each do |fb|
      if slot >= fb.@stack.pointer.address && slot < fb.@stack.bottom.address
        r = "fiber #{fb.name || "?"} dead=#{fb.dead?} bottom#{slot.to_i64 - fb.@stack.bottom.address.to_i64}"
      end
    end
    r
  end

  # Root slots that first-marked a block in the last pre-baseline collection
  # and hold something else after the window: the places a word can let go
  # of a graph inside it.
  def self.sites_report(heap) : Nil
    i = @@n_pre2
    lines = [] of String
    while i < @@n_pre3
      r = Gcry::Reg1Diag.recs + i * 6
      slot = r[2]
      if slot > 1
        cur = peek(slot)
        if cur != r[3]
          now = heap.find_object_with_chunk(Pointer(Void).new(r[3]))
          alive = now && now[0].address == r[4]
          lines << "D1 c#{@@cycle} SITE src=#{r[1]} slot=0x#{slot.to_s(16)} #{where(slot)} val=0x#{r[3].to_s(16)} cur=#{cur ? "0x" + cur.to_s(16) : "unmapped"} block_alive=#{alive ? 1 : 0}"
        end
      end
      i += 1
    end
    lines.each { |l| LibC.dprintf(2, "%s\n", l.to_unsafe) }
    LibC.dprintf(2, "D1 c%d SITES pre3_records=%d changed=%d\n", @@cycle, @@n_pre3 - @@n_pre2, lines.size)
  end

  def self.report(heap, drift : Int64) : Nil
    return unless @@on
    @@on = false
    Gcry::Reg1Diag.on = false
    roots_report(heap) if drift <= -100 || ENV["D1_FORCE"]? == "1"
    sites_report(heap) if @@cycle == 1 || @@cycle == 3
    LibC.dprintf(2, "D1 c%d report drift=%lld words=%d frame=0x%llx lo=0x%llx\n", @@cycle, drift, @@nwords, @@frame, @@lo)
    hits = 0
    i = 0
    while i < @@nwords
      h = @@hdrs[i]
      if h != 0
        v = @@words[i] ^ MASK
        now = heap.find_object_with_chunk(Pointer(Void).new(v))
        unless now && now[0].address == (h ^ MASK)
          hits += 1
          if i < 6
            LibC.dprintf(2, "D1 c%d GONE reg%d val=0x%llx tid=%d\n", @@cycle, i, v, @@tids[i])
          else
            at = @@lo + (i - 6).to_u64 * 8
            cur = Pointer(UInt64).new(at).value
            LibC.dprintf(2, "D1 c%d GONE stack 0x%llx (frame%+lld) val=0x%llx now=0x%llx tid=%d\n", @@cycle, at, at.to_i64 - @@frame.to_i64, v, cur, @@tids[i])
          end
        end
      end
      i += 1
    end
    k = 0
    f = heap.@finalizers
    gone_f = 0
    while k < @@nfin
      o = @@fin[k] ^ MASK
      still = false
      j = 0
      while j < f.entry_count
        if f.entry_object_at(j).address == o
          still = true
          break
        end
        j += 1
      end
      unless still
        gone_f += 1
        LibC.dprintf(2, "D1 c%d FIN gone 0x%llx tid=%d\n", @@cycle, o, @@fin_tid[k])
      end
      k += 1
    end
    LibC.dprintf(2, "D1 c%d summary gone_words=%d gone_fin=%d\n", @@cycle, hits, gone_f)
    if drift.abs >= 100
      # Names last: building a String allocates.
      i = 0
      while i < @@nwords
        h = @@hdrs[i]
        if h != 0
          v = @@words[i] ^ MASK
          now = heap.find_object_with_chunk(Pointer(Void).new(v))
          unless now && now[0].address == (h ^ MASK)
            LibC.dprintf(2, "D1 c%d GONE-NAME #%d tid=%d %s\n", @@cycle, i, @@tids[i], type_name(@@tids[i]).to_unsafe)
          end
        end
        i += 1
      end
      k = 0
      while k < @@nfin
        LibC.dprintf(2, "D1 c%d FIN-NAME 0x%llx %s\n", @@cycle, @@fin[k] ^ MASK, type_name(@@fin_tid[k]).to_unsafe)
        k += 1
      end
    end
  end
end

module Crystal::System::Fiber
  def self.allocate_stack(stack_size, protect) : Void*
    p = previous_def
    D1.note_stack(1_u64, p.address, stack_size.to_u64)
    p
  end

  def self.free_stack(stack : Void*, stack_size) : Nil
    D1.note_stack(2_u64, stack.address, stack_size.to_u64)
    previous_def
  end
end

private record Cycle, count : Int32, drift : Int64 do
  def to_s(io : IO) : Nil
    io << "count=" << count << " drift=" << drift
  end
end

@[NoInline]
private def drift_scrub : Nil
  buf = uninitialized StaticArray(UInt8, 65536)
  buf.to_unsafe.clear(buf.size)
  asm("" :: "r"(buf.to_unsafe) : "memory" : "volatile")
end

private def drift_cycle(heap, count : Int32, cyc : Int32) : Cycle
  ptrs = Array(Pointer(Void)).new(count)
  D1.start(cyc)
  drift_scrub
  4.times { |k| GC.collect; D1.mark_pre(k); D1.log({"pre0", "pre1", "pre2", "pre3"}[k], heap) }
  anchor = 0_u64
  D1.snapshot(heap, pointerof(anchor).address)
  GC.disable
  begin
    baseline = Gcry.metrics(heap).live_objects
    count.times { ptrs << GC.malloc_atomic(32) }
    Gcry.metrics(heap).live_objects.should be >= baseline + count
  ensure
    GC.enable
  end

  ptrs.each { |p| GC.free(p) }
  ptrs.clear

  D1.log("freed", heap)
  4.times { |k| GC.collect; D1.log({"post0", "post1", "post2", "post3"}[k], heap) }

  drift = Gcry.metrics(heap).live_objects.to_i64 - baseline.to_i64
  D1.report(heap, drift)
  Cycle.new(count, drift)
end

describe "Regression: live_objects counter drift on dormant chunks" do
  it "returns live_objects to its baseline after full free + collect" do
    heap = Gcry.default_heap
    drift_scrub
    big = drift_cycle(heap, 10_000, 1)
    drift_scrub
    small = drift_cycle(heap, 1_000, 2)
    detail = "#{big} | #{small}"
    # Reg1b: more windows at the same suite position, to sample timed events
    # (Monitor passes, sleeping fibers) that could land in cycle 1's window.
    extra = (ENV["D1_EXTRA"]? || "40").to_i
    worst = 0_i64
    extra.times do |k|
      drift_scrub
      c = drift_cycle(heap, 10_000, 3 + k)
      worst = c.drift if c.drift < worst
    end
    LibC.dprintf(2, "D1 extra=%d worst=%lld\n", extra, worst)
    big.drift.abs.should(be < 500, detail)
    small.drift.abs.should(be < 500, detail)
    (big.drift - small.drift).abs.should(be < 500, detail)
    worst.abs.should(be < 100, "extra worst=#{worst}")
  end
end
