require "c/fcntl"
require "c/unistd"

module Gcry
  # Non-allocating static root discovery for Linux.
  #
  # Ranges are cached in LibC memory after the first scan. Refresh is cheap to
  # skip when maps are stable (typical for long-running servers).
  module Platform
    struct RootRange
      property low : UInt64
      property high : UInt64

      def initialize(@low : UInt64, @high : UInt64)
      end
    end

    @@ranges : RootRange* = Pointer(RootRange).null
    @@range_count = 0
    @@range_cap = 0
    @@maps_generation = 0_u32
    @@cached_generation = UInt32::MAX

    # Adjacency state while parsing /proc/self/maps (address-ordered).
    @@parse_prev_hi = 0_u64
    @@parse_prev_file_rw = false

    # Bump when dlopen/mmap of new libraries is expected; also after our own
    # munmap so cached ranges never point at unmapped pages. Collect bumps
    # occasionally so caches do not go forever stale.
    def self.invalidate_static_root_cache : Nil
      @@maps_generation &+= 1
    end

    def self.scan_static_roots(& : Void*, Void* ->) : Nil
      {% if flag?(:linux) %}
        ensure_static_root_cache
        i = 0
        while i < @@range_count
          r = (@@ranges + i).value
          yield Pointer(Void).new(r.low), Pointer(Void).new(r.high)
          i += 1
        end
      {% end %}
    end

    # The largest root coverage any parse has produced, and the number of
    # parses that came back with less than that.
    #
    # `/proc/self/maps` is read in 8 KiB pieces and the file is not a snapshot:
    # the kernel regenerates it as it is read, so a mapping that changes
    # between two `read`s can shift entries under the reader and drop a line.
    # Every mutator in a program under gcry maps and unmaps constantly, and the
    # entry that matters most is the executable's file-backed RW mapping —
    # lose that one line and `try_yield_adjacent_bss` refuses the BSS that
    # follows it, so for that collection **every class variable stops being a
    # root**. That is not a degraded scan, it is a missed root, and what it
    # collects is whatever is held only in a global.
    #
    # A parse that comes back smaller than one that came before is the signal.
    @@max_range_bytes = 0_u64
    @@static_root_shrinks = 0_u64
    # The adjacency-BSS range the first parse found. The executable is never
    # unmapped, so a later parse that does not produce this range again has
    # lost it to the read, not to the program.
    @@bss_lo = 0_u64
    @@bss_hi = 0_u64
    @@bss_seen_this_parse = false
    @@static_root_bss_lost = 0_u64

    def self.static_root_bss_lost : UInt64
      @@static_root_bss_lost
    end

    def self.static_root_shrinks : UInt64
      @@static_root_shrinks
    end

    def self.static_root_bytes : UInt64
      total = 0_u64
      i = 0
      while i < @@range_count
        r = (@@ranges + i).value
        total += r.high - r.low
        i += 1
      end
      total
    end

    private def self.ensure_static_root_cache : Nil
      return if @@cached_generation == @@maps_generation && @@range_count > 0

      @@range_count = 0
      @@parse_prev_hi = 0_u64
      @@parse_prev_file_rw = false
      @@bss_seen_this_parse = false
      scan_proc_maps do |low, high|
        push_range(low.address, high.address)
      end
      @@cached_generation = @@maps_generation

      if @@bss_lo != 0 && !@@bss_seen_this_parse
        @@static_root_bss_lost &+= 1
        if @@static_root_bss_lost == 1
          buf = uninitialized UInt8[224]
          len = 0
          len = RawOut.append(buf.to_unsafe, len,
            "gcry: the static-root parse lost the executable's BSS range 0x")
          len = RawOut.append_hex(buf.to_unsafe, len, @@bss_lo)
          len = RawOut.append(buf.to_unsafe, len,
            " — for this collection no class variable is a root\n")
          RawOut.flush(buf.to_unsafe, len)
        end
      end

      total = static_root_bytes
      if total < @@max_range_bytes
        @@static_root_shrinks &+= 1
      else
        @@max_range_bytes = total
      end
    end

    @@bss_size_cap = false

    private def self.push_range(lo : UInt64, hi : UInt64) : Nil
      return if hi <= lo
      if @@range_count >= @@range_cap
        new_cap = @@range_cap == 0 ? 32 : @@range_cap * 2
        bytes = (sizeof(RootRange) * new_cap).to_u64
        ptr = LibC.realloc(@@ranges.as(Void*), LibC::SizeT.new(bytes)).as(RootRange*)
        raise OutOfMemoryError.new("static root cache realloc failed") if ptr.null?
        @@ranges = ptr
        @@range_cap = new_cap
      end
      (@@ranges + @@range_count).value = RootRange.new(lo, hi)
      @@range_count += 1
    end

    private def self.scan_proc_maps(& : Void*, Void* ->) : Nil
      fd = LibC.open("/proc/self/maps", LibC::O_RDONLY)
      return if fd < 0

      begin
        buf = uninitialized UInt8[8192]
        base = buf.to_unsafe
        leftover = 0
        loop do
          n = LibC.read(fd, (base + leftover).as(Void*), LibC::SizeT.new(buf.size - leftover))
          break if n <= 0

          total = leftover + n.to_i32
          start = 0
          i = 0
          while i < total
            if base[i] == 0x0a_u8
              parse_maps_line(base + start, i - start) { |lo, hi| yield lo, hi }
              start = i + 1
            end
            i += 1
          end

          leftover = total - start
          if leftover > 0 && start > 0
            j = 0
            while j < leftover
              base[j] = base[start + j]
              j += 1
            end
          elsif leftover == total
            leftover = 0
          end
        end
      ensure
        LibC.close(fd)
      end
    end

    private def self.parse_maps_line(line : UInt8*, len : Int32, & : Void*, Void* ->) : Nil
      return if len < 20

      dash = index_of(line, len, '-'.ord.to_u8)
      return unless dash

      rest = len - dash - 1
      space = index_of(line + dash + 1, rest, ' '.ord.to_u8)
      return unless space
      space_abs = dash + 1 + space

      lo = parse_hex(line, dash)
      hi = parse_hex(line + dash + 1, space_abs - dash - 1)
      return if lo == 0 || hi <= lo

      return if space_abs + 4 >= len
      perms = line + space_abs + 1
      # Need readable private data. Writable BSS holds class vars; RELRO .data.rel.ro
      # is r-- after relocation and may still hold heap pointers.
      return unless perms[0] == 'r'.ord.to_u8
      return if perms[2] == 'x'.ord.to_u8 # skip code

      path = pathname_start(line, len)
      size = hi - lo

      if path < 0
        # ELF BSS zero-fill: anonymous RW pages contiguous with the previous
        # file-backed RW mapping (typically after .data). Do NOT treat every
        # anonymous VMA as a root — gcry's own large objects are anonymous too,
        # and caching one and scanning it after `munmap` is a SIGSEGV. What
        # separates them is adjacency to the executable's `.data`, not size;
        # see `try_yield_adjacent_bss`.
        try_yield_adjacent_bss(lo, hi, perms, size) { |a, b| yield a, b }
        return
      end

      # Kernel-named VMAs ([stack], [anon:...], [heap], …). Linux 6.x labels
      # many anon regions; treating them as file-backed scanned whole arenas /
      # stacks (SIGBUS on guard holes). Same path as pathname-less anon.
      if line[path] == '['.ord.to_u8
        try_yield_adjacent_bss(lo, hi, perms, size) { |a, b| yield a, b }
        return
      end

      # Only the main executable's data is a root. Any other file-backed RW
      # mapping is the program's own — a `.so`, or a data file it `mmap`ed —
      # and caching one means scanning it after the program `mremap`s or
      # `munmap`s it (issue #29: MAP_PRIVATE file grown past EOF → SIGBUS).
      unless main_executable_path?(line + path, len - path)
        @@parse_prev_file_rw = false
        return
      end

      writable = perms[1] == 'w'.ord.to_u8
      # Always scan rw-p (.data). Skip large RELRO r--p on fat Crystal binaries
      # (multi‑MiB word scans); class vars that hold heap refs are writable.
      unless writable
        if size >= 64_u64 * 1024
          @@parse_prev_file_rw = false
          return
        end
      end

      yield Pointer(Void).new(lo), Pointer(Void).new(hi)
      @@parse_prev_hi = hi
      @@parse_prev_file_rw = writable
    end

    # Contiguous RW anon after a file-backed RW .data (ELF BSS).
    #
    # There used to be a `size < 1 MiB` condition here and it was a silent
    # correctness hole: a Crystal program whose BSS is larger than that had its
    # **whole** BSS refused as a root range, so every class variable and every
    # constant slot holding a heap reference became invisible to the mark and
    # was swept. Reproduced in 20 lines on 2026-08-22 — an 8 MiB static class
    # variable, one `GC.malloc`, two collections, and the process dies in
    # `IO#encoder` because `STDERR` itself was collected. The threshold sat
    # between a 400 KiB and an 800 KiB array, which is the BSS crossing 1 MiB
    # with Crystal's own statics in it.
    #
    # The condition was also inverted with respect to its own stated reason.
    # The comment it was written under says gcry's large objects are anonymous
    # and **under** 1 MiB, and that caching one and scanning it after `munmap`
    # is a SIGSEGV — but `< 1 MiB` *accepts* exactly that size band and rejects
    # the sizes a gcry large object cannot have.
    #
    # What actually keeps gcry's own mappings out is the adjacency test, and it
    # is strict: the region must begin exactly where a file-backed RW mapping of
    # the main executable ended (shared libraries are filtered out before this
    # point). An `mmap` with no hint does not land there. The second line of
    # defence is `each_static_range_excluding_heap`, which subtracts gcry's
    # chunks from every range this yields, and which exists for precisely the
    # case the size cap was aimed at.
    #
    # `GCRY_STATIC_BSS_CAP=1` restores the cap, which is how the gate shows the
    # collected object.
    private def self.try_yield_adjacent_bss(lo : UInt64, hi : UInt64, perms : UInt8*, size : UInt64, & : Void*, Void* ->) : Nil
      if @@parse_prev_file_rw &&
         lo == @@parse_prev_hi &&
         perms[1] == 'w'.ord.to_u8 &&
         (!@@bss_size_cap || size < 1_u64 * 1024 * 1024)
        if @@bss_lo == 0
          @@bss_lo = lo
          @@bss_hi = hi
        end
        @@bss_seen_this_parse = true if lo == @@bss_lo
        yield Pointer(Void).new(lo), Pointer(Void).new(hi)
      end
      @@parse_prev_file_rw = false
    end

    # Research only: refuse a BSS larger than 1 MiB, as this parser did before
    # 2026-08-22.
    def self.bss_size_cap=(value : Bool) : Bool
      @@bss_size_cap = value
    end

    # `/proc/self/exe` resolved once; the executable is never re-linked.
    @@exe_path = uninitialized UInt8[4096]
    @@exe_len = -1

    private def self.main_executable_path?(path : UInt8*, len : Int32) : Bool
      if @@exe_len < 0
        n = LibC.readlink("/proc/self/exe", @@exe_path.to_unsafe.as(LibC::Char*), LibC::SizeT.new(@@exe_path.size))
        @@exe_len = n < 0 ? 0 : n.to_i32
      end
      return false if @@exe_len == 0
      # Trim the trailing newline and anything after " (deleted)".
      e = len
      while e > 0 && (path[e - 1] == 0x0a_u8 || path[e - 1] == 0x20_u8 || path[e - 1] == 0x0d_u8)
        e -= 1
      end
      return false unless e == @@exe_len
      i = 0
      while i < e
        return false if path[i] != @@exe_path.to_unsafe[i]
        i += 1
      end
      true
    end

    private def self.pathname_start(line : UInt8*, len : Int32) : Int32
      i = 0
      fields = 0
      while i < len
        while i < len && line[i] == 0x20_u8
          i += 1
        end
        break if i >= len || line[i] == 0x0a_u8
        fields += 1
        if fields == 6
          return i
        end
        while i < len && line[i] != 0x20_u8 && line[i] != 0x0a_u8
          i += 1
        end
      end
      -1
    end

    private def self.index_of(ptr : UInt8*, len : Int32, byte : UInt8) : Int32?
      i = 0
      while i < len
        return i if ptr[i] == byte
        i += 1
      end
      nil
    end

    private def self.parse_hex(ptr : UInt8*, len : Int32) : UInt64
      value = 0_u64
      i = 0
      while i < len
        c = ptr[i]
        break if c == ' '.ord.to_u8
        value <<= 4
        if c >= '0'.ord.to_u8 && c <= '9'.ord.to_u8
          value |= (c - '0'.ord.to_u8).to_u64
        elsif c >= 'a'.ord.to_u8 && c <= 'f'.ord.to_u8
          value |= (c - 'a'.ord.to_u8 + 10).to_u64
        elsif c >= 'A'.ord.to_u8 && c <= 'F'.ord.to_u8
          value |= (c - 'A'.ord.to_u8 + 10).to_u64
        else
          break
        end
        i += 1
      end
      value
    end

    private def self.includes_name?(line : UInt8*, len : Int32, name : String) : Bool
      return false if name.bytesize > len
      limit = len - name.bytesize
      i = 0
      while i <= limit
        match = true
        j = 0
        while j < name.bytesize
          if line[i + j] != name.to_unsafe[j]
            match = false
            break
          end
          j += 1
        end
        return true if match
        i += 1
      end
      false
    end
  end
end
