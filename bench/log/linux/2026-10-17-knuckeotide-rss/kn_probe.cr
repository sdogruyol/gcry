# Knuckeotide resident-memory probe (crystal-metric's Fasta + Knuckeotide,
# verbatim in `kn_bench.cr`, extracted by `extract.sh`).
#
# Builds against Boehm (stock) or gcry (`-Dgc_none`). It records, without
# allocating, `/proc/self/statm` (resident and file-backed pages) and the
# process's `VmHWM` at every collection's Start and End through
# `GC_set_on_collection_event` (both collectors export it), plus gcry's heap
# counters when built with gcry; at each phase boundary of the benchmark it
# prints the same and `/proc/self/smaps_rollup`. Output: one TSV line per
# event on stderr after the run (`ev` rows) and one per phase (`ph` rows).
#
#   crystal build --release kn_probe.cr -o kn-boehm
#   crystal build --release -Dgc_none kn_probe.cr -o kn-gcry
#   ./kn-gcry 2> events.tsv
{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

lib LibC
  fun clock_gettime(clk : Int32, ts : Timespec*) : Int32
end

module Probe
  CAP    = 8192
  FIELDS =   21
  @@buf = Pointer(UInt64).null
  @@n = 0
  @@t0 = 0_u64

  def self.now_ns : UInt64
    ts = uninitialized LibC::Timespec
    LibC.clock_gettime(1, pointerof(ts))
    ts.tv_sec.to_u64 &* 1_000_000_000_u64 &+ ts.tv_nsec.to_u64
  end

  # Reads a small /proc file into a stack buffer; no allocation.
  def self.read_proc(path : UInt8*, buf : UInt8*, cap : Int32) : Int32
    fd = LibC.open(path, LibC::O_RDONLY)
    return 0 if fd < 0
    n = LibC.read(fd, buf, cap - 1).to_i32
    LibC.close(fd)
    n < 0 ? 0 : n
  end

  # Parse the n-th (0-based) space-separated integer of statm.
  def self.statm_field(buf : UInt8*, len : Int32, idx : Int32) : UInt64
    i = 0
    f = 0
    v = 0_u64
    while i < len
      c = buf[i]
      if c == ' '.ord || c == '\n'.ord
        return v if f == idx
        f += 1
        v = 0_u64
      else
        v = v &* 10 &+ (c - '0'.ord).to_u64
      end
      i += 1
    end
    v
  end

  # Value (kB) of a "Key:   N kB" line of /proc/self/status.
  def self.status_kb(buf : UInt8*, len : Int32, key : String) : UInt64
    k = key.to_unsafe
    kl = key.bytesize
    i = 0
    while i + kl < len
      if (i == 0 || buf[i - 1] == '\n'.ord) && LibC.memcmp(buf + i, k, kl) == 0
        j = i + kl
        while j < len && (buf[j] < '0'.ord || buf[j] > '9'.ord)
          j += 1
        end
        v = 0_u64
        while j < len && buf[j] >= '0'.ord && buf[j] <= '9'.ord
          v = v &* 10 &+ (buf[j] - '0'.ord).to_u64
          j += 1
        end
        return v
      end
      i += 1
    end
    0_u64
  end

  def self.record(kind : UInt64) : Nil
    return if @@n >= CAP
    sb = uninitialized UInt8[2048]
    len = read_proc("/proc/self/status".to_unsafe, sb.to_unsafe, 2048)
    row = @@buf + @@n * FIELDS
    row[0] = kind
    row[1] = now_ns &- @@t0
    row[2] = status_kb(sb.to_unsafe, len, "VmRSS:")
    row[3] = status_kb(sb.to_unsafe, len, "VmHWM:")
    row[4] = status_kb(sb.to_unsafe, len, "RssAnon:")
    row[5] = status_kb(sb.to_unsafe, len, "RssFile:")
    {% if flag?(:gc_none) %}
      h = Gcry.default_heap
      row[6] = h.collections
      row[7] = h.heap_size
      row[8] = h.large_mapped_bytes
      row[9] = h.large_free_bytes
      row[10] = h.size_class_live_bytes
      row[11] = h.dormant_chunk_bytes
      row[12] = h.gc_threshold
      row[13] = h.fully_free_chunk_bytes
      row[14] = h.released_chunk_bytes
      row[15] = h.unmapped_bytes
      # The allocation since the last major (cursor sets credited), chunks
      # mapped so far, and the threshold pace.
      row[16] = h.bytes_since_gc
      row[17] = h.chunks_mapped
      row[18] = h.threshold_pace_pct
      # KN_PEAK=1: resident bytes (mincore) of every chunk, small and large,
      # and per size class × atomic for the small ones (`@@cls`, KiB).
      if @@peak
        small_res = 0_u64
        large_res = 0_u64
        cls = @@cls + @@n * 80
        80.times { |i| cls[i] = 0_u32 }
        h.each_chunk do |chunk|
          bytes = chunk.value.mapped_bytes
          res = resident(chunk.as(Void*), bytes)
          if Gcry::ChunkHeader.large?(chunk)
            large_res &+= res
          else
            small_res &+= res
            ci = chunk.value.size_class.to_i32
            if ci >= 0 && ci < 40
              slot = ci * 2 + (Gcry::ChunkHeader.atomic?(chunk) ? 1 : 0)
              cls[slot] = cls[slot] &+ (res // 1024).to_u32
            end
          end
        end
        row[19] = small_res
        row[20] = large_res
      end
    {% end %}
    @@n += 1
  end

  @@peak = false
  @@cls = Pointer(UInt32).null
  @@vec = Pointer(UInt8).null
  VEC_PAGES = 65536 # mincore vector: chunks up to 256 MiB

  # Resident bytes of [addr, addr + bytes) by mincore into a static vector.
  def self.resident(addr : Void*, bytes : UInt64) : UInt64
    pages = (bytes &+ 4095) // 4096
    pages = VEC_PAGES.to_u64 if pages > VEC_PAGES
    return 0_u64 if LibC.mincore(addr, LibC::SizeT.new(pages &* 4096), @@vec) != 0
    n = 0_u64
    pages.times { |i| n &+= 1 if (@@vec[i] & 1) != 0 }
    n &* 4096
  end

  def self.install : Nil
    @@buf = LibC.malloc(CAP * FIELDS * 8).as(UInt64*)
    @@peak = ENV["KN_PEAK"]? == "1"
    if @@peak
      @@cls = LibC.malloc(CAP * 80 * 4).as(UInt32*)
      @@vec = LibC.malloc(VEC_PAGES).as(UInt8*)
    end
    @@t0 = now_ns
    LibGC.set_on_collection_event ->(ev : LibGC::EventType) {
      case ev
      when LibGC::EventType::START then Probe.record(0_u64)
      when LibGC::EventType::END   then Probe.record(1_u64)
      end
      nil
    }
  end

  # Phase marker: an event row (kind 2 + phase index) plus smaps_rollup.
  def self.phase(idx : Int32, name : String) : Nil
    record(2_u64 + idx.to_u64)
    STDERR.puts "ph\t#{idx}\t#{name}\t#{(now_ns &- @@t0) // 1000}"
    STDERR.puts File.read("/proc/self/smaps_rollup").lines.select(/^(Rss|Pss_Anon|Pss_File|Anonymous|Private_Dirty|Swap):/).map(&.gsub(/\s+/, " ")).join(" | ")
    {% if flag?(:gc_none) %}
      STDERR.puts Gcry::Observability.json_stats
      if ENV["KN_DUMP"]? == "1"
        # Every live block of 32 KiB or more (large chunks), one per line.
        io = IO::Memory.new
        Gcry.dump_heap(io)
        io.to_s.each_line do |l|
          size = l[/"size":(\d+)/, 1].to_u64
          STDERR.puts "large\t#{idx}\t#{l}" if size >= 32768
        end
      end
      if ENV["KN_HOLDERS"]? == "1"
        # Who holds each live block of 1 MiB or more: gcry's own search over
        # the explicit roots, every live block and every stack.
        io = IO::Memory.new
        Gcry.dump_heap(io)
        io.to_s.each_line do |l|
          size = l[/"size":(\d+)/, 1].to_u64
          next unless size >= 1_048_576
          addr = l[/"addr":"0x([0-9a-f]+)"/, 1].to_u64(16)
          STDERR.puts "holders\t#{idx}\t#{l}"
          Gcry::PoisonHolders.search(Gcry.default_heap, addr, size)
        end
      end
    {% else %}
      s = GC.prof_stats
      STDERR.puts "boehm heap_size=#{s.heap_size} free=#{s.free_bytes} unmapped=#{s.unmapped_bytes} since_gc=#{s.bytes_since_gc} gc_no=#{s.gc_no} non_gc=#{s.non_gc_bytes} obtained_from_os=#{s.obtained_from_os_bytes} reclaimed_since_gc=#{s.bytes_reclaimed_since_gc}"
    {% end %}
  end

  def self.dump : Nil
    i = 0
    while i < @@n
      row = @@buf + i * FIELDS
      STDERR.print "ev"
      FIELDS.times { |f| STDERR.print "\t", row[f] }
      STDERR.print "\n"
      if @@peak
        # `cls` row: resident KiB per size class, plain then atomic.
        cls = @@cls + i * 80
        STDERR.print "cls\t", i
        80.times { |c| STDERR.print "\t", cls[c] }
        STDERR.print "\n"
      end
      i += 1
    end
  end
end

require "./kn_bench"

def checksum(v)
  hash = 5381_u32
  v.each_byte do |byte|
    hash = ((hash << 5) &+ hash) &+ byte
  end
  hash
end

Probe.install
Probe.phase(0, "start")
bench = Knuckeotide.new
Probe.phase(1, "after_init")
# `Benchmark#_run`, unrolled with markers.
GC.collect
Probe.phase(2, "after_collect")
t = Time.instant
bench.run
dt = Time.instant - t
Probe.phase(3, "after_run")
GC.collect
GC.collect
Probe.phase(4, "end")
STDERR.puts "ok=#{bench.ok?} run_s=#{dt.total_seconds}"
Probe.dump
