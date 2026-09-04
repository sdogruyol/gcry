require "c/fcntl"
require "c/unistd"

module Gcry
  # Non-allocating static root discovery for Linux.
  #
  # The root ranges are the executable's own RW mappings — its file-backed
  # `.data` and the anonymous BSS after it — found in `/proc/self/maps` by
  # address: each is the mapping that holds one of two anchor words placed in
  # those sections by the linker. No pathname is compared, so a `.so`, a data
  # file the program `mmap`ed (issue #29) and the executable itself renamed to
  # `… (deleted)` by a redeploy are all rejected the same way.
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
    # entries that matter most are the executable's two — lose either and for
    # that collection **every class variable stops being a root**. That is not
    # a degraded scan, it is a missed root, and what it collects is whatever is
    # held only in a global. So a parse that comes back without both anchors
    # is read again (`PARSE_ATTEMPTS`) before the collection proceeds.
    #
    # A parse that comes back smaller than one that came before is the signal.
    @@max_range_bytes = 0_u64
    @@static_root_shrinks = 0_u64

    # Two words whose addresses name the executable's own RW mappings.
    #
    # A class variable with a non-zero literal initialiser is emitted as an
    # initialised global and the linker puts it in `.data`, which the kernel
    # maps file-backed from the executable; a zero-initialised one goes to
    # `.bss`, which is the anonymous zero-fill mapping after it. So the mapping
    # holding `@@cached_generation` (`UInt32::MAX`) *is* the executable's
    # `.data` and the one holding `@@range_count` (`0`) *is* its BSS — by
    # address, with no pathname to compare, no `/proc/self/exe` to resolve and
    # no line order to trust.
    #
    # These two and not dedicated words, because both are loaded and stored on
    # every refresh: a global that is never written is one LLVM may mark
    # constant and move to `.rodata`, and one that is never read it may drop
    # the stores to. Neither can happen to the cache's own state. Verified on
    # Crystal 1.21 / LLVM 22 with `nm`, debug and `--release`: `d` and `b`.
    private def self.data_anchor : UInt64
      pointerof(@@cached_generation).address
    end

    private def self.bss_anchor : UInt64
      pointerof(@@range_count).address
    end

    # The BSS range the first parse found, for `static_root_coverage`.
    @@bss_lo = 0_u64
    @@bss_hi = 0_u64
    # Whether the parse in progress has yielded the mapping holding each
    # anchor. Both are in the executable, which is never unmapped, so a parse
    # that misses either one dropped a line.
    @@data_seen_this_parse = false
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

    # How many parses in a row may come back without both anchors before the
    # collection proceeds with what it has.
    PARSE_ATTEMPTS = 4

    # Parses that came back without an anchor and were run again.
    @@static_root_reparses = 0_u64

    def self.static_root_reparses : UInt64
      @@static_root_reparses
    end

    private def self.ensure_static_root_cache : Nil
      return if @@cached_generation == @@maps_generation && @@range_count > 0

      attempt = 0
      loop do
        @@range_count = 0
        @@parse_prev_hi = 0_u64
        @@parse_prev_file_rw = false
        @@data_seen_this_parse = false
        @@bss_seen_this_parse = false
        scan_proc_maps do |low, high|
          push_range(low.address, high.address)
        end
        attempt += 1
        break if (@@data_seen_this_parse && @@bss_seen_this_parse) || attempt >= PARSE_ATTEMPTS
        # The anchors are in the executable and the executable is never
        # unmapped, so a parse without one dropped a line — the file is not a
        # snapshot and a mapping changing under the read shifts entries. Read
        # it again rather than run a collection with no class variable rooted.
        @@static_root_reparses &+= 1
      end
      @@cached_generation = @@maps_generation

      unless @@data_seen_this_parse && @@bss_seen_this_parse
        @@static_root_bss_lost &+= 1
        if @@static_root_bss_lost == 1
          buf = uninitialized UInt8[224]
          len = 0
          len = RawOut.append(buf.to_unsafe, len,
            "gcry: the static-root parse found no mapping holding the executable's ")
          len = RawOut.append(buf.to_unsafe, len, @@data_seen_this_parse ? "BSS" : "data")
          len = RawOut.append(buf.to_unsafe, len,
            " after ")
          len = RawOut.append_u64(buf.to_unsafe, len, attempt.to_u64)
          len = RawOut.append(buf.to_unsafe, len,
            " reads — for this collection no class variable is a root\n")
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
      # Readable, non-code. The mark wants only memory a mutator can write a
      # heap pointer into; anything r-- cannot hold one.
      return unless perms[0] == 'r'.ord.to_u8
      return if perms[2] == 'x'.ord.to_u8

      path = pathname_start(line, len)
      size = hi - lo

      # Anonymous, or kernel-named ([heap], [stack], [anon:…] — Linux 6.x
      # labels many anon regions). The BSS is one of these; the harness, the
      # thread stacks and gcry's own chunks are the rest, and caching one of
      # those and scanning it after `munmap` is a SIGSEGV.
      if path < 0 || line[path] == '['.ord.to_u8
        try_yield_static_anon(lo, hi, perms, size) { |a, b| yield a, b }
        return
      end

      # File-backed. Only the executable's own RW segment is a root, and it is
      # identified by address: it is the one mapping that holds `data_anchor`.
      # Nothing here reads the pathname — a `.so`, a data file the program
      # `mmap`ed (issue #29), or the executable itself renamed to
      # `… (deleted)` by a redeploy all look the same to the parser, which is
      # the point.
      unless lo <= data_anchor && data_anchor < hi
        @@parse_prev_file_rw = false
        return
      end

      @@data_seen_this_parse = true
      # `.bss` starts mid-page, so its first words share the last page of the
      # file mapping; the anchor is covered either way.
      @@bss_seen_this_parse = true if lo <= bss_anchor && bss_anchor < hi
      yield Pointer(Void).new(lo), Pointer(Void).new(hi)
      @@parse_prev_hi = hi
      @@parse_prev_file_rw = perms[1] == 'w'.ord.to_u8
    end

    # The executable's anonymous RW pages: the BSS, and whatever the kernel has
    # merged with it.
    #
    # Two independent tests, either one accepts. The region holds
    # `bss_anchor`, which the linker put in `.bss` — that is the BSS by
    # definition, whatever it is named and wherever it sits. Or it begins
    # exactly where the executable's file-backed RW `.data` ended, which is the
    # ELF zero-fill and covers the case where the anchor's page is still inside
    # the file mapping. Both are what the old adjacency-only rule was guessing
    # at from line order.
    #
    # There used to be a `size < 1 MiB` condition here and it was a silent
    # correctness hole: a Crystal program whose BSS is larger than that had its
    # **whole** BSS refused as a root range, so every class variable and every
    # constant slot holding a heap reference became invisible to the mark and
    # was swept. Reproduced in 20 lines on 2026-08-22 — an 8 MiB static class
    # variable, one `GC.malloc`, two collections, and the process dies in
    # `IO#encoder` because `STDERR` itself was collected.
    #
    # What keeps gcry's own mappings out is that neither test admits them: an
    # `mmap` with no hint neither holds the anchor nor lands at `.data`'s end.
    # The second line of defence is `each_static_range_excluding_heap`, which
    # subtracts gcry's chunks from every range this yields — the kernel merges
    # adjacent anonymous VMAs with equal flags, so a BSS line can legitimately
    # extend over memory that is not the BSS.
    #
    # `GCRY_STATIC_BSS_CAP=1` restores the cap, which is how the gate shows the
    # collected object.
    private def self.try_yield_static_anon(lo : UInt64, hi : UInt64, perms : UInt8*, size : UInt64, & : Void*, Void* ->) : Nil
      holds_anchor = lo <= bss_anchor && bss_anchor < hi
      adjacent = @@parse_prev_file_rw && lo == @@parse_prev_hi
      @@parse_prev_file_rw = false
      return unless perms[1] == 'w'.ord.to_u8
      return unless holds_anchor || adjacent
      return if @@bss_size_cap && size >= 1_u64 * 1024 * 1024
      @@bss_seen_this_parse = true if holds_anchor
      if @@bss_lo == 0
        @@bss_lo = lo
        @@bss_hi = hi
      end
      yield Pointer(Void).new(lo), Pointer(Void).new(hi)
    end

    # Research only: refuse a BSS larger than 1 MiB, as this parser did before
    # 2026-08-22.
    def self.bss_size_cap=(value : Bool) : Bool
      @@bss_size_cap = value
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
