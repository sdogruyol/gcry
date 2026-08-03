# LLVM `.llvm_stackmaps` (format v3) loader + PC→location lookup.
# See docs/STACK_MAPS.md. Used only when Heap#precise_stack_roots is set.

require "c/unistd"
require "c/fcntl"

module Gcry
  module StackMaps
    VERSION_SUPPORTED = 3_u8

    # Location encodings (LLVM StackMaps.html).
    LOC_REGISTER      = 1_u8
    LOC_DIRECT        = 2_u8
    LOC_INDIRECT      = 3_u8
    LOC_CONSTANT      = 4_u8
    LOC_CONSTANT_INDEX = 5_u8

    struct Loc
      getter kind : UInt8
      getter size : UInt16
      getter reg : UInt16
      getter offset : Int32

      def initialize(@kind : UInt8, @size : UInt16, @reg : UInt16, @offset : Int32)
      end
    end

    # Sorted PC table + flat location store (libc malloc — immortal w.r.t. gcry).
    @@loaded = false
    @@load_attempted = false
    @@nrecords = 0
    @@nlocs = 0
    @@pcs = Pointer(UInt64).null
    @@loc_off = Pointer(UInt32).null
    @@loc_n = Pointer(UInt16).null
    @@locs = Pointer(Loc).null
    @@constants = Pointer(UInt64).null
    @@nconstants = 0
    @@pc_min = 0_u64
    @@pc_max = 0_u64
    # Return address may sit a few bytes past the stackmap PC (call size).
    NEAR_DELTA = 32_u64
    # Cap FP chain length — deep / corrupt chains dominated soak pause.
    MAX_FP_FRAMES = 128
    # Hybrid mutator walk: must climb past GC/stdlib frames (often map-less)
    # before Crystal call-site rets appear. Cap below exclusive's full walk
    # to limit STW pause; 32 clears stackmap-smoke on tip+EC.
    HYBRID_MAX_FP_FRAMES = 32
    # Lookups that found a record / roots yielded (observability).
    @@hits = 0_u64
    @@roots_yielded = 0_u64
    @@lookups = 0_u64
    @@near_hits = 0_u64

    def self.loaded? : Bool
      @@loaded
    end

    def self.record_count : Int32
      @@nrecords
    end

    def self.location_count : Int32
      @@nlocs
    end

    def self.hits : UInt64
      @@hits
    end

    def self.roots_yielded : UInt64
      @@roots_yielded
    end

    def self.lookups : UInt64
      @@lookups
    end

    def self.near_hits : UInt64
      @@near_hits
    end

    # Parse *data* (full `.llvm_stackmaps` bytes). Replaces any prior table.
    # Returns true on success.
    def self.load_bytes(data : Bytes) : Bool
      return false if data.size < 16

      ver = data[0]
      return false unless ver == VERSION_SUPPORTED

      num_fn = read_u32(data, 4)
      num_const = read_u32(data, 8)
      num_rec = read_u32(data, 12)
      return false if num_rec == 0 || num_rec > 2_000_000

      off = 16
      fn_addrs = Pointer(UInt64).null
      fn_rec_counts = Pointer(UInt64).null
      begin
        fn_addrs = LibC.malloc(num_fn * 8).as(UInt64*)
        fn_rec_counts = LibC.malloc(num_fn * 8).as(UInt64*)
        return false if fn_addrs.null? || fn_rec_counts.null?

        i = 0
        while i < num_fn
          return false if off + 24 > data.size
          fn_addrs[i] = read_u64(data, off)
          # stack size at off+8 — unused for lookup
          fn_rec_counts[i] = read_u64(data, off + 16)
          off += 24
          i += 1
        end

        return false if off + num_const * 8 > data.size
        constants = Pointer(UInt64).null
        if num_const > 0
          constants = LibC.malloc(num_const * 8).as(UInt64*)
          return false if constants.null?
          i = 0
          while i < num_const
            constants[i] = read_u64(data, off)
            off += 8
            i += 1
          end
        end

        # First pass: count locations + validate.
        pass_off = off
        total_locs = 0
        r = 0
        while r < num_rec
          return false if pass_off + 16 > data.size
          _pid = read_u64(data, pass_off)
          _ioff = read_u32(data, pass_off + 8)
          nloc = read_u16(data, pass_off + 14)
          pass_off += 16
          return false if pass_off + nloc * 12 > data.size
          total_locs += nloc
          pass_off += nloc * 12
          pass_off = align8(pass_off)
          return false if pass_off + 4 > data.size
          nlive = read_u16(data, pass_off + 2)
          pass_off += 4 + nlive * 4
          pass_off = align8(pass_off)
          r += 1
        end

        pcs = LibC.malloc(num_rec * 8).as(UInt64*)
        loc_off = LibC.malloc(num_rec * 4).as(UInt32*)
        loc_n = LibC.malloc(num_rec * 2).as(UInt16*)
        locs = LibC.malloc(total_locs * sizeof(Loc)).as(Loc*)
        return false if pcs.null? || loc_off.null? || loc_n.null? || locs.null?

        # Expand function records: records are grouped per function in order.
        fn_i = 0
        fn_left = fn_i < num_fn ? fn_rec_counts[fn_i] : 0_u64
        fn_base = fn_i < num_fn ? fn_addrs[fn_i] : 0_u64

        loc_cursor = 0
        r = 0
        while r < num_rec
          while fn_left == 0 && fn_i + 1 < num_fn
            fn_i += 1
            fn_left = fn_rec_counts[fn_i]
            fn_base = fn_addrs[fn_i]
          end

          pid = read_u64(data, off)
          ioff = read_u32(data, off + 8)
          nloc = read_u16(data, off + 14)
          off += 16
          # pid unused; silence
          _ = pid

          pcs[r] = fn_base &+ ioff.to_u64
          loc_off[r] = loc_cursor.to_u32
          loc_n[r] = nloc

          j = 0
          while j < nloc
            kind = data[off]
            size = read_u16(data, off + 2)
            reg = read_u16(data, off + 4)
            ofs = read_i32(data, off + 8)
            locs[loc_cursor] = Loc.new(kind, size, reg, ofs)
            loc_cursor += 1
            off += 12
            j += 1
          end
          off = align8(off)
          nlive = read_u16(data, off + 2)
          off += 4 + nlive * 4
          off = align8(off)

          fn_left -= 1 if fn_left > 0
          r += 1
        end

        # Sort by PC (LLVM order is per-function; binary search needs global order).
        sort_records(pcs, loc_off, loc_n, num_rec.to_i32)

        free_table
        @@pcs = pcs
        @@loc_off = loc_off
        @@loc_n = loc_n
        @@locs = locs
        @@nrecords = num_rec.to_i32
        @@nlocs = total_locs
        @@constants = constants
        @@nconstants = num_const.to_i32
        if @@nrecords > 0
          @@pc_min = pcs[0]
          @@pc_max = pcs[@@nrecords - 1]
        else
          @@pc_min = 0_u64
          @@pc_max = 0_u64
        end
        @@loaded = true
        @@hits = 0_u64
        @@roots_yielded = 0_u64
        @@lookups = 0_u64
        @@near_hits = 0_u64
        true
      ensure
        LibC.free(fn_addrs.as(Void*)) unless fn_addrs.null?
        LibC.free(fn_rec_counts.as(Void*)) unless fn_rec_counts.null?
      end
    end

    # Load `.llvm_stackmaps` from the main executable (Linux ELF).
    def self.load_from_exe : Bool
      {% unless flag?(:linux) %}
        return false
      {% end %}
      path = "/proc/self/exe"
      bytes = read_elf_section(path, ".llvm_stackmaps")
      return false unless bytes
      load_bytes(bytes)
    end

    # Idempotent: try once per process.
    def self.ensure_loaded : Bool
      return @@loaded if @@load_attempted
      @@load_attempted = true
      load_from_exe
    end

    # Reset load gate (tests).
    def self.reset_for_testing : Nil
      free_table
      @@loaded = false
      @@load_attempted = false
      @@pc_min = 0_u64
      @@pc_max = 0_u64
      @@hits = 0_u64
      @@roots_yielded = 0_u64
      @@lookups = 0_u64
      @@near_hits = 0_u64
    end

    # Binary search for an exact PC record.
    def self.find_index(pc : UInt64) : Int32
      return -1 unless @@loaded
      lo = 0
      hi = @@nrecords
      while lo < hi
        mid = lo + (hi - lo) // 2
        v = @@pcs[mid]
        if v < pc
          lo = mid + 1
        elsif v > pc
          hi = mid
        else
          return mid
        end
      end
      -1
    end

    # Largest stackmap PC with `pc - map_pc <= NEAR_DELTA` (one binary search).
    # Matches return addresses that sit a few bytes past the stackmap point.
    def self.find_index_near(pc : UInt64) : Int32
      return -1 unless @@loaded && @@nrecords > 0
      return -1 if pc < @@pc_min || pc > @@pc_max &+ NEAR_DELTA
      @@lookups += 1

      # upper_bound: first index with pcs[i] > pc
      lo = 0
      hi = @@nrecords
      while lo < hi
        mid = lo + (hi - lo) // 2
        if @@pcs[mid] <= pc
          lo = mid + 1
        else
          hi = mid
        end
      end
      return -1 if lo == 0
      idx = lo - 1
      map_pc = @@pcs[idx]
      return -1 if pc < map_pc || (pc - map_pc) > NEAR_DELTA
      @@near_hits += 1
      idx
    end

    # Yield each location at *pc* (exact). Returns true if a record exists.
    def self.each_location_at(pc : UInt64, & : Loc ->) : Bool
      idx = find_index(pc)
      return false if idx < 0
      @@hits += 1
      yield_locs(idx) { |loc| yield loc }
      true
    end

    # Yield locations for the stackmap nearest at-or-below *pc* within NEAR_DELTA.
    def self.each_location_near(pc : UInt64, & : Loc ->) : Bool
      idx = find_index_near(pc)
      return false if idx < 0
      @@hits += 1
      yield_locs(idx) { |loc| yield loc }
      true
    end

    private def self.yield_locs(idx : Int32, & : Loc ->) : Nil
      base = @@loc_off[idx]
      n = @@loc_n[idx]
      i = 0
      while i < n
        yield @@locs[base + i]
        i += 1
      end
    end

    # Resolve locations at *pc* to pointer-sized roots.
    # *gregs* is glibc x86_64 mcontext order (REG_R8=0 … REG_RIP=16); may be null
    # when only RBP/RSP-relative Direct/Indirect are needed (frame walk).
    # *stack_lo*/*stack_hi* (optional): when a Register value points into the
    # stack, treat it as an alloca slot and load the word (Crystal emit passes
    # alloca addresses; LLVM often encodes them as Register, not Direct).
    # Multi-word Direct/Indirect (union/proc allocas, loc.size > 8): yield every
    # aligned word in the slot.
    def self.each_root_at(pc : UInt64, rsp : UInt64, rbp : UInt64,
                          gregs : Pointer(UInt64), ngregs : Int32,
                          stack_lo : UInt64 = 0_u64, stack_hi : UInt64 = 0_u64,
                          & : Void* ->) : Bool
      found = false
      each_location_at(pc) do |loc|
        found = true
        each_resolved_root(loc, rsp, rbp, gregs, ngregs, stack_lo, stack_hi) do |ptr|
          @@roots_yielded += 1
          yield ptr
        end
      end
      found
    end

    # Like each_root_at but accepts return addresses a few bytes past the map PC.
    def self.each_root_near(pc : UInt64, rsp : UInt64, rbp : UInt64,
                            gregs : Pointer(UInt64), ngregs : Int32,
                            stack_lo : UInt64 = 0_u64, stack_hi : UInt64 = 0_u64,
                            & : Void* ->) : Bool
      found = false
      each_location_near(pc) do |loc|
        found = true
        each_resolved_root(loc, rsp, rbp, gregs, ngregs, stack_lo, stack_hi) do |ptr|
          @@roots_yielded += 1
          yield ptr
        end
      end
      found
    end

    private def self.each_resolved_root(loc : Loc, rsp : UInt64, rbp : UInt64,
                                        gregs : Pointer(UInt64), ngregs : Int32,
                                        stack_lo : UInt64, stack_hi : UInt64,
                                        & : Void* ->) : Nil
      # Multi-word stack slot (union / proc / tuple alloca).
      if (loc.kind == LOC_DIRECT || loc.kind == LOC_INDIRECT) && loc.size > 8
        base = reg_value(loc.reg, rsp, rbp, gregs, ngregs)
        return unless base
        addr = add_offset(base, loc.offset)
        nwords = (loc.size.to_i32 // 8).clamp(1, 32)
        i = 0
        while i < nwords
          waddr = addr &+ (i * 8)
          if stack_lo < stack_hi
            break if waddr < stack_lo || waddr &+ 8 > stack_hi
          end
          if ptr = load_word(waddr)
            yield ptr unless ptr.null?
          end
          i += 1
        end
        return
      end

      if ptr = resolve_loc(loc, rsp, rbp, gregs, ngregs, stack_lo, stack_hi)
        yield ptr unless ptr.null?
      end
    end

    # Walk x86_64 frame-pointer chain; resolve locations with RBP=fp.
    # Register GP locations need gregs (nil here) — only RBP/RSP-relative and
    # stack-slot Register values are useful. *stack_lo*/*stack_hi* bound the
    # readable stack (grows down: lo=SP side, hi=bottom).
    # *max_frames* caps climb (hybrid uses HYBRID_MAX_FP_FRAMES).
    def self.each_root_fp_walk(rsp : UInt64, rbp : UInt64,
                               stack_lo : UInt64, stack_hi : UInt64,
                               max_frames : Int32 = MAX_FP_FRAMES,
                               & : Void* ->) : Nil
      return unless @@loaded
      {% unless flag?(:x86_64) %}
        return
      {% end %}

      fp = rbp
      guard = 0
      limit = max_frames > 0 ? max_frames : MAX_FP_FRAMES
      while fp >= stack_lo && fp + 16 <= stack_hi && guard < limit
        ret = Pointer(UInt64).new(fp + 8).value
        each_root_near(ret, fp &+ 16, fp, Pointer(UInt64).null, 0, stack_lo, stack_hi) do |root|
          yield root
        end
        next_fp = Pointer(UInt64).new(fp).value
        break if next_fp <= fp
        break if next_fp < stack_lo || next_fp >= stack_hi
        fp = next_fp
        guard += 1
      end
    end

    # DWARF reg → value. Uses *rsp*/*rbp* overrides; GP via glibc gregs map.
    def self.reg_value(dwarf_reg : UInt16, rsp : UInt64, rbp : UInt64,
                       gregs : Pointer(UInt64), ngregs : Int32) : UInt64?
      case dwarf_reg
      when 6 then rbp
      when 7 then rsp
      else
        return nil if gregs.null? || ngregs <= 0
        {% if flag?(:x86_64) %}
          gi = dwarf_to_glibc_greg(dwarf_reg)
          return nil if gi < 0 || gi >= ngregs
          gregs[gi]
        {% else %}
          nil
        {% end %}
      end
    end

    def self.resolve_loc(loc : Loc, rsp : UInt64, rbp : UInt64,
                         gregs : Pointer(UInt64), ngregs : Int32,
                         stack_lo : UInt64 = 0_u64, stack_hi : UInt64 = 0_u64) : Void*?
      case loc.kind
      when LOC_REGISTER
        v = reg_value(loc.reg, rsp, rbp, gregs, ngregs)
        return nil unless v
        # Alloca address in a reg → load slot; else the reg holds the root.
        if stack_lo < stack_hi && v >= stack_lo && v < stack_hi && (v & 7) == 0
          return load_word(v)
        end
        Pointer(Void).new(v)
      when LOC_DIRECT
        # Live value is the address (alloca / frame index). For pointer slots
        # the heap root is the word stored there.
        base = reg_value(loc.reg, rsp, rbp, gregs, ngregs)
        return nil unless base
        load_word(add_offset(base, loc.offset))
      when LOC_INDIRECT
        base = reg_value(loc.reg, rsp, rbp, gregs, ngregs)
        return nil unless base
        load_word(add_offset(base, loc.offset))
      when LOC_CONSTANT
        return nil if loc.offset == 0
        Pointer(Void).new(add_offset(0_u64, loc.offset))
      when LOC_CONSTANT_INDEX
        return nil if loc.offset < 0 || loc.offset >= @@nconstants
        v = @@constants[loc.offset]
        return nil if v == 0
        Pointer(Void).new(v)
      else
        nil
      end
    end

    private def self.add_offset(base : UInt64, offset : Int32) : UInt64
      (base.to_i64 + offset.to_i64).to_u64!
    end

    # --- ELF section read (Linux) ------------------------------------------------

    private def self.read_elf_section(path : String, name : String) : Bytes?
      file = File.open(path, "r")
      begin
        magic = Bytes.new(4)
        return nil unless file.read(magic) == 4
        return nil unless magic[0] == 0x7f && magic[1] == 'E'.ord && magic[2] == 'L'.ord && magic[3] == 'F'.ord

        file.seek(0)
        ehdr = Bytes.new(64)
        return nil unless file.read(ehdr) == 64
        return nil unless ehdr[4] == 2 # ELFCLASS64
        return nil unless ehdr[5] == 1 # little endian

        shoff = read_u64(ehdr, 40)
        shentsize = read_u16(ehdr, 58).to_i32
        shnum = read_u16(ehdr, 60).to_i32
        shstrndx = read_u16(ehdr, 62).to_i32
        return nil if shentsize < 64 || shnum <= 0 || shstrndx >= shnum

        shstr = Bytes.new(shentsize)
        file.seek(shoff + shstrndx * shentsize)
        return nil unless file.read(shstr) == shentsize
        str_off = read_u64(shstr, 24)
        str_size = read_u64(shstr, 32)
        return nil if str_size > 16_u64 * 1024 * 1024

        strtab = Bytes.new(str_size)
        file.seek(str_off)
        return nil unless file.read(strtab) == str_size.to_i32

        i = 0
        while i < shnum
          sh = Bytes.new(shentsize)
          file.seek(shoff + i * shentsize)
          return nil unless file.read(sh) == shentsize
          name_off = read_u32(sh, 0)
          sec_name = cstr_at(strtab, name_off)
          if sec_name == name
            off = read_u64(sh, 24)
            size = read_u64(sh, 32)
            return nil if size == 0 || size > 64_u64 * 1024 * 1024
            buf = Bytes.new(size)
            file.seek(off)
            return nil unless file.read(buf) == size.to_i32
            return buf
          end
          i += 1
        end
        nil
      ensure
        file.close
      end
    rescue
      nil
    end

    private def self.cstr_at(buf : Bytes, off : UInt32) : String
      return "" if off.to_i64 >= buf.size
      i = off.to_i32
      while i < buf.size && buf[i] != 0
        i += 1
      end
      String.new(buf[off.to_i32, i - off.to_i32])
    end

    private def self.load_word(addr : UInt64) : Void*?
      return nil if addr == 0 || (addr & 7) != 0
      Pointer(Void).new(Pointer(UInt64).new(addr).value)
    end

    private def self.free_table : Nil
      LibC.free(@@pcs.as(Void*)) unless @@pcs.null?
      LibC.free(@@loc_off.as(Void*)) unless @@loc_off.null?
      LibC.free(@@loc_n.as(Void*)) unless @@loc_n.null?
      LibC.free(@@locs.as(Void*)) unless @@locs.null?
      LibC.free(@@constants.as(Void*)) unless @@constants.null?
      @@pcs = Pointer(UInt64).null
      @@loc_off = Pointer(UInt32).null
      @@loc_n = Pointer(UInt16).null
      @@locs = Pointer(Loc).null
      @@constants = Pointer(UInt64).null
      @@nrecords = 0
      @@nlocs = 0
      @@nconstants = 0
      @@loaded = false
    end

    private def self.sort_records(pcs : UInt64*, loc_off : UInt32*, loc_n : UInt16*, n : Int32) : Nil
      # Insertion sort is fine for tests; for ~10k use heapsort/quick.
      return if n <= 1
      quicksort_records(pcs, loc_off, loc_n, 0, n - 1)
    end

    private def self.quicksort_records(pcs : UInt64*, loc_off : UInt32*, loc_n : UInt16*,
                                       lo : Int32, hi : Int32) : Nil
      return if lo >= hi
      pivot = pcs[lo + (hi - lo) // 2]
      i = lo
      j = hi
      while i <= j
        while pcs[i] < pivot
          i += 1
        end
        while pcs[j] > pivot
          j -= 1
        end
        if i <= j
          pcs[i], pcs[j] = pcs[j], pcs[i]
          loc_off[i], loc_off[j] = loc_off[j], loc_off[i]
          loc_n[i], loc_n[j] = loc_n[j], loc_n[i]
          i += 1
          j -= 1
        end
      end
      quicksort_records(pcs, loc_off, loc_n, lo, j)
      quicksort_records(pcs, loc_off, loc_n, i, hi)
    end

    # DWARF regnum → glibc x86_64 gregs[] index (REG_*).
    private def self.dwarf_to_glibc_greg(dwarf : UInt16) : Int32
      case dwarf
      when 0  then 13 # rax
      when 1  then 12 # rdx
      when 2  then 14 # rcx
      when 3  then 11 # rbx
      when 4  then 9  # rsi
      when 5  then 8  # rdi
      when 6  then 10 # rbp
      when 7  then 15 # rsp
      when 8  then 0  # r8
      when 9  then 1  # r9
      when 10 then 2  # r10
      when 11 then 3  # r11
      when 12 then 4  # r12
      when 13 then 5  # r13
      when 14 then 6  # r14
      when 15 then 7  # r15
      when 16 then 16 # rip
      else -1
      end
    end

    private def self.align8(off : Int32) : Int32
      (off + 7) & ~7
    end

    private def self.read_u16(data : Bytes, off : Int32) : UInt16
      data[off].to_u16 | (data[off + 1].to_u16 << 8)
    end

    private def self.read_u32(data : Bytes, off : Int32) : UInt32
      data[off].to_u32 |
        (data[off + 1].to_u32 << 8) |
        (data[off + 2].to_u32 << 16) |
        (data[off + 3].to_u32 << 24)
    end

    private def self.read_i32(data : Bytes, off : Int32) : Int32
      read_u32(data, off).to_i32!
    end

    private def self.read_u64(data : Bytes, off : Int32) : UInt64
      read_u32(data, off).to_u64 | (read_u32(data, off + 4).to_u64 << 32)
    end
  end
end
