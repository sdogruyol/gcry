# Do `mach_vm_page_query`'s disposition bits mean what the low-water skip needs?
#
# Linux took an 8.06 → 3.60 ms EC4 pause from the parked-fiber low-water skip and
# macOS takes none of it, because the skip rests on a primitive Darwin does not
# have. The claim it needs is narrow and unforgiving:
#
#   **a page the query calls skippable has never held a written word.**
#
# `mincore(2)` cannot support that claim on either platform: it answers
# *resident*, so a page that was written and later evicted reads absent, and
# skipping it loses a pointer. Linux uses `/proc/self/pagemap` — bit 63 present,
# bit 62 swapped — and treats "neither" as never-faulted. Darwin's candidate is
# `mach_vm_page_query`, whose disposition includes both `PRESENT` and
# `PAGED_OUT`. Whether those two bits actually cover the written-then-evicted
# case is the open question, and it is the reason no Darwin implementation has
# been written: an unsound skip drops roots silently, which is the one failure
# mode this collector cannot detect after the fact.
#
# This probe is the experiment, not the implementation. It carries the candidate
# predicate it is testing (`skippable?`) so a Darwin run validates the exact
# logic that would be lifted into `src/gcry/platform/darwin_pagemap.cr`.
#
# Arms:
#
#   untouched   a freshly mapped, never-written region must report skippable
#               for every page. If it does not, the skip buys nothing — but it
#               is also the harmless direction.
#
#   written     one byte per page, still resident: every page must report
#               **not** skippable. **This is the gate.** A false "skippable"
#               here is a dropped root.
#
#   zero-proof  the property the whole thing rests on, checked over every page
#               of a region touched in a sparse pattern: a page the predicate
#               calls skippable must read back all zeros. This is the port of
#               `spec/stack_low_water_spec.cr`'s claim ("never reports above a
#               written word") in the form that can be checked exhaustively.
#               **Also the gate.**
#
#   reclaimed   written, then `MADV_FREE_REUSABLE` — the advice gcry's own
#               Darwin sweep uses. Whatever the disposition says, the page must
#               read back zero, because that is what makes skipping it sound.
#
#   paged-out   the dangerous case, and the one that may not be manufacturable:
#               written, then evicted with its contents intact. If it can be
#               forced, the page must report **not** skippable *and* read back
#               the byte that was written. If it cannot be forced, the arm
#               reports INCONCLUSIVE and the verdict withholds the bits —
#               a probe that cannot produce the case must not claim it passed.
#
#   crystal build bench/darwin_page_query.cr -o bin/darwin_page_query
#   bin/darwin_page_query
#   bin/darwin_page_query --pressure=2048   # MiB of churn to provoke compression

{% if flag?(:darwin) %}
  lib LibMachVM
    alias Port = UInt32
    alias KernReturn = Int32

    $mach_task_self_ : Port

    fun mach_vm_page_query(
      target_map : Port,
      offset : UInt64,
      disposition : Int32*,
      ref_count : Int32*,
    ) : KernReturn
  end

  lib LibC
    # Darwin spells it MAP_ANON; the Linux name is what the rest of the tree
    # uses, so alias it here the same way `src/gcry/block.cr` does.
    MAP_ANONYMOUS      = MAP_ANON
    MADV_FREE_REUSABLE = 7
    MADV_FREE_REUSE    = 8
    fun madvise(addr : Void*, len : SizeT, advice : Int) : Int
  end
{% end %}

module DarwinPageQuery
  # Transcribed from <mach/vm_region.h>. The point of this probe is that they are
  # *transcribed*, not verified: every arm below prints the raw disposition it
  # observed, so a wrong constant shows up as a nonsense reading rather than as a
  # confident wrong answer.
  PRESENT     = 0x001
  FICTITIOUS  = 0x002
  REF         = 0x004
  DIRTY       = 0x008
  PAGED_OUT   = 0x010
  COPIED      = 0x020
  SPECULATIVE = 0x040
  EXTERNAL    = 0x080

  # The candidate predicate, written exactly as the collector would use it: a
  # page is skippable only if the kernel says it is neither resident nor paged
  # out. Anything else — including a disposition the query could not produce —
  # is scanned, which is the pre-existing behaviour and cannot lose a root.
  def self.skippable?(disposition : Int32) : Bool
    (disposition & (PRESENT | PAGED_OUT)) == 0
  end

  def self.describe(disposition : Int32) : String
    return "none" if disposition == 0
    names = [] of String
    names << "PRESENT" if (disposition & PRESENT) != 0
    names << "FICTITIOUS" if (disposition & FICTITIOUS) != 0
    names << "REF" if (disposition & REF) != 0
    names << "DIRTY" if (disposition & DIRTY) != 0
    names << "PAGED_OUT" if (disposition & PAGED_OUT) != 0
    names << "COPIED" if (disposition & COPIED) != 0
    names << "SPECULATIVE" if (disposition & SPECULATIVE) != 0
    names << "EXTERNAL" if (disposition & EXTERNAL) != 0
    rest = disposition & ~(PRESENT | FICTITIOUS | REF | DIRTY | PAGED_OUT | COPIED | SPECULATIVE | EXTERNAL)
    names << "0x#{rest.to_s(16)}" if rest != 0
    names.join("|")
  end
end

{% if flag?(:darwin) %}
  KERN_SUCCESS = 0
  # Asked, not assumed. This was `4096_u64`, and the "page size 4096" the probe
  # printed on 2026-08-15 was therefore that constant talking, not a
  # measurement — the probe never asked the host. The collector's own
  # `Platform.host_page_size` records Apple Silicon as 16 KiB, so if this runs on
  # one, every "page" counted here was a quarter of a real one: the region called
  # 256 pages would be 64, each query answered four times over, and "0 of 256
  # written pages left residency" counted 4 KiB slices. A probe built to
  # establish per-page semantics cannot have a unit the kernel does not use, and
  # cannot report an assumption in the position where a reader expects a fact.
  PAGE = begin
    sz = LibC.sysconf(LibC::SC_PAGESIZE)
    sz > 0 ? sz.to_u64 : 16384_u64
  end
  PAGES =     256
  FILL  = 0x5A_u8

  # {disposition, ok} — a query that fails is not a skippable page, and the
  # caller must treat it as "scan it".
  def query(addr : UInt64) : {Int32, Bool}
    disposition = 0
    ref_count = 0
    kr = LibMachVM.mach_vm_page_query(
      LibMachVM.mach_task_self_, addr, pointerof(disposition), pointerof(ref_count))
    {disposition, kr == KERN_SUCCESS}
  end

  def map_region(pages : Int32) : UInt64
    len = LibC::SizeT.new(pages.to_u64 * PAGE)
    map = LibC.mmap(Pointer(Void).null, len,
      LibC::PROT_READ | LibC::PROT_WRITE,
      LibC::MAP_PRIVATE | LibC::MAP_ANONYMOUS, -1, LibC::OffT.new(0))
    raise "mmap failed" if map.address == 0 || map.address == UInt64::MAX
    map.address
  end

  def page_all_zero?(addr : UInt64) : Bool
    words = Pointer(UInt64).new(addr)
    i = 0
    while i < (PAGE // 8)
      return false if words[i] != 0
      i += 1
    end
    true
  end

  pressure_mb = 0
  ARGV.each do |arg|
    if arg =~ /--pressure=(\d+)/
      pressure_mb = $1.to_i
    end
  end

  puts "=== mach_vm_page_query disposition bits ==="
  puts "page size #{PAGE} (sysconf), region #{PAGES} pages, #{PAGES.to_u64 * PAGE // 1024} KiB"
  failures = [] of String

  # ── Arm 1: untouched ────────────────────────────────────────────────────────
  base = map_region(PAGES)
  untouched_skippable = 0
  untouched_dispositions = {} of Int32 => Int32
  PAGES.times do |i|
    d, ok = query(base + i.to_u64 * PAGE)
    untouched_dispositions[d] = (untouched_dispositions[d]? || 0) + 1
    untouched_skippable += 1 if ok && DarwinPageQuery.skippable?(d)
  end
  puts
  puts "untouched: #{untouched_skippable}/#{PAGES} skippable; dispositions " +
       untouched_dispositions.map { |d, n| "#{DarwinPageQuery.describe(d)}×#{n}" }.join(", ")
  if untouched_skippable != PAGES
    failures << "#{PAGES - untouched_skippable} of #{PAGES} never-written pages did not read as " \
                "skippable — the skip would buy nothing on this platform (harmless, but the " \
                "implementation would be pointless)"
  end

  # ── Arm 2: written and resident ─────────────────────────────────────────────
  PAGES.times { |i| Pointer(UInt8).new(base + i.to_u64 * PAGE).value = FILL }
  written_skippable = [] of Int32
  written_dispositions = {} of Int32 => Int32
  PAGES.times do |i|
    d, ok = query(base + i.to_u64 * PAGE)
    written_dispositions[d] = (written_dispositions[d]? || 0) + 1
    written_skippable << i if ok && DarwinPageQuery.skippable?(d)
  end
  puts "written:   #{PAGES - written_skippable.size}/#{PAGES} not skippable; dispositions " +
       written_dispositions.map { |d, n| "#{DarwinPageQuery.describe(d)}×#{n}" }.join(", ")
  unless written_skippable.empty?
    failures << "#{written_skippable.size} pages that were written this instant read as skippable " \
                "(first at page #{written_skippable.first}) — the predicate would skip a page " \
                "holding live data, which is a dropped root"
  end

  # ── Arm 3: zero-proof over a sparse pattern ─────────────────────────────────
  # The claim the skip rests on, checked page by page: skippable ⇒ reads zero.
  sparse = map_region(PAGES)
  touched = [] of Int32
  i = 0
  while i < PAGES
    Pointer(UInt8).new(sparse + i.to_u64 * PAGE + 17).value = FILL
    touched << i
    i += 7
  end
  violations = 0
  skippable_pages = 0
  PAGES.times do |p|
    addr = sparse + p.to_u64 * PAGE
    d, ok = query(addr)
    next unless ok && DarwinPageQuery.skippable?(d)
    skippable_pages += 1
    unless page_all_zero?(addr)
      violations += 1
      failures << "page #{p} of the sparse region reads skippable but is not zero " \
                  "(disposition #{DarwinPageQuery.describe(d)})" if violations <= 3
    end
  end
  puts "zero-proof: #{skippable_pages}/#{PAGES} skippable, #{violations} of them non-zero " \
       "(#{touched.size} pages were written)"

  # ── Arm 4: reclaimed with MADV_FREE_REUSABLE ────────────────────────────────
  # The advice gcry's own Darwin sweep uses. Reporting such a page skippable is
  # sound *if* it reads zero, so that is what is checked rather than the bits.
  reclaim = map_region(PAGES)
  PAGES.times { |p| Pointer(UInt8).new(reclaim + p.to_u64 * PAGE).value = FILL }
  rc = LibC.madvise(Pointer(Void).new(reclaim), LibC::SizeT.new(PAGES.to_u64 * PAGE),
    LibC::MADV_FREE_REUSABLE)
  if rc == 0
    reclaimed_skippable = 0
    reclaimed_nonzero = 0
    reclaimed_dispositions = {} of Int32 => Int32
    PAGES.times do |p|
      addr = reclaim + p.to_u64 * PAGE
      d, ok = query(addr)
      reclaimed_dispositions[d] = (reclaimed_dispositions[d]? || 0) + 1
      next unless ok && DarwinPageQuery.skippable?(d)
      reclaimed_skippable += 1
      reclaimed_nonzero += 1 unless page_all_zero?(addr)
    end
    puts "reclaimed: #{reclaimed_skippable}/#{PAGES} skippable, #{reclaimed_nonzero} of them " \
         "non-zero; dispositions " +
         reclaimed_dispositions.map { |d, n| "#{DarwinPageQuery.describe(d)}×#{n}" }.join(", ")
    if reclaimed_nonzero > 0
      failures << "#{reclaimed_nonzero} MADV_FREE_REUSABLE pages read as skippable while still " \
                  "holding data — skipping them would lose whatever was written there"
    end
  else
    puts "reclaimed: MADV_FREE_REUSABLE refused (errno #{Errno.value}); arm skipped"
  end

  # ── Arm 5: written, then evicted with contents intact ───────────────────────
  # The case that decides whether PRESENT|PAGED_OUT is the right pair. macOS
  # compresses before it swaps, and there is no portable way to demand it, so
  # this arm reports what it could establish rather than pretending.
  evict = map_region(PAGES)
  PAGES.times { |p| Pointer(UInt8).new(evict + p.to_u64 * PAGE).value = FILL }
  ballast = [] of UInt64
  if pressure_mb > 0
    pages_per_mb = (1024 * 1024) // PAGE
    (pressure_mb.to_u64 * pages_per_mb).times do |_|
      addr = map_region(1)
      Pointer(UInt8).new(addr).value = FILL
      ballast << addr
    end
  end
  evicted_seen = 0
  evicted_skippable = 0
  evict_dispositions = {} of Int32 => Int32
  PAGES.times do |p|
    d, ok = query(evict + p.to_u64 * PAGE)
    next unless ok
    evict_dispositions[d] = (evict_dispositions[d]? || 0) + 1
    if (d & DarwinPageQuery::PAGED_OUT) != 0 || (d & DarwinPageQuery::PRESENT) == 0
      evicted_seen += 1
      evicted_skippable += 1 if DarwinPageQuery.skippable?(d)
    end
  end
  puts "paged-out: #{evicted_seen} of #{PAGES} written pages left residency" +
       (pressure_mb > 0 ? " under #{pressure_mb} MiB of pressure" : " (no pressure requested)") +
       "; dispositions " + evict_dispositions.map { |d, n| "#{DarwinPageQuery.describe(d)}×#{n}" }.join(", ")
  conclusive_eviction = evicted_seen > 0
  if conclusive_eviction && evicted_skippable > 0
    failures << "#{evicted_skippable} written pages that left residency read as **skippable** — " \
                "PRESENT|PAGED_OUT does not cover the evicted case and the skip would drop roots " \
                "under memory pressure. This is the finding that must block a Darwin low-water " \
                "implementation."
  end
  ballast.each { |a| LibC.munmap(Pointer(Void).new(a), LibC::SizeT.new(PAGE)) }

  puts
  if failures.empty?
    if conclusive_eviction
      puts "VERDICT: the bits mean what the skip needs — untouched pages are skippable, written " \
           "pages are not, every skippable page read zero, and pages that left residency were " \
           "still reported not-skippable. A Darwin low-water implementation is unblocked."
      exit 0
    else
      puts "VERDICT: INCONCLUSIVE. Everything that could be established held — untouched pages " \
           "are skippable, written pages are not, every skippable page read zero — but **no page " \
           "was made to leave residency with its contents intact**, which is the case the whole " \
           "question turns on. Re-run with --pressure=<MiB> on a host that will compress. Until " \
           "one run produces that case, the bits stay unverified and the implementation stays " \
           "blocked."
      exit 0
    end
  else
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    puts "VERDICT: the disposition bits do not support the skip as written."
    exit 1
  end
{% else %}
  puts "=== mach_vm_page_query disposition bits ==="
  puts "SKIP — Darwin only. Linux answers the same question with /proc/self/pagemap"
  puts "(bits 63 present / 62 swapped), which src/gcry/platform/linux_pagemap.cr already uses."
  exit 0
{% end %}
