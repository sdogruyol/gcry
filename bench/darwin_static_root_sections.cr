# Which Mach-O sections is Darwin's static root scan losing?
#
# Linux derives the static roots by construction: every writable `PT_LOAD` of
# the executable, minus the `PT_GNU_RELRO` window (`platform/linux_roots.cr`).
# A linker that adds a section or renames one is covered without anyone
# noticing. Darwin used a **name allow-list** — `__data`, `__bss`, `__common`,
# with `__const` explicitly refused — so the same linker change silently drops
# a root class, and a dropped root class collects a live object.
#
# The obvious parity rule is "every section in a `__DATA*` segment whose
# `initprot` carries VM_PROT_WRITE, minus TLS". That rule is **wrong**, and
# this probe is what says so: `__DATA_CONST` is `initprot=0x3` (READ|WRITE)
# and would be admitted, but its segment carries `SG_READ_ONLY` (0x10) and
# dyld mprotects it read-only once the fixups are applied. It is the Mach-O
# `PT_GNU_RELRO`, and admitting it scans ~17 KiB of pointer-dense literal pool
# that the mutator cannot write, i.e. pure false retention. The rule that
# actually matches Linux is writable **minus SG_READ_ONLY** minus TLS.
#
# Arms:
#
#   census      every segment and section of image 0, with its `initprot`, its
#               segment flags, the protection `mach_vm_region` reports at
#               runtime, and its verdict under the old allow-list and the new
#               derived rule. Descriptive; it is what the two rules are read
#               off. `--explain` prints the full table.
#
#   lost-root   for every section the *old* rule refused, count the words that
#               the heap says are live objects, stash them XOR'd so this probe
#               is not itself the root, collect, and re-ask. A word still
#               pointing at an address the heap has reclaimed is a root the old
#               rule lost. **This is the gate.** It runs against both rules, so
#               it reports what each one loses rather than asserting the new
#               one is perfect.
#
#   writable    every section the new rule admits must be writable *now*, as
#               `mach_vm_region` sees it. This is what stops the rule from
#               drifting back to `initprot` alone: `__DATA_CONST` passes on
#               `initprot` and fails here.
#
# `--no-data-const` is not a flag of this program — it is a *link* option, and
# the case matters because it moves `__const` and `__got` into a plain writable
# `__DATA`. Build the probe both ways:
#
#   crystal build -Dgc_none bench/darwin_static_root_sections.cr -o bin/darwin_static_root_sections
#   bin/darwin_static_root_sections
#   crystal build -Dgc_none --link-flags=-Wl,-no_data_const \
#     bench/darwin_static_root_sections.cr -o bin/darwin_static_root_sections_ndc
#   bin/darwin_static_root_sections_ndc

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "darwin_static_root_sections requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% if flag?(:darwin) %}
  # No `lib` of its own for the dyld side: `Gcry::Platform::LibDyld` already
  # binds `_dyld_get_image_header` with these exact structs, and a second
  # binding of the same C symbol with a different `MachHeader64` is a
  # "fun redefinition with different signature" error. Reading through the
  # collector's own declarations is also the stronger arrangement — a probe
  # that transcribed the structs a second time could agree with itself and
  # still disagree with the scan it is auditing.
  alias LibProbe = Gcry::Platform::LibDyld

  lib LibMachVM
    alias Port = UInt32
    alias KernReturn = Int32

    $mach_task_self_ : Port

    # <mach/mach_vm.h>. `info` is a vm_region_basic_info_data_64_t, which is
    # ten 32-bit words; the count is passed and returned so a wrong constant
    # shows up as a failed call rather than as a confident wrong answer.
    fun mach_vm_region(
      target_task : Port,
      address : UInt64*,
      size : UInt64*,
      flavor : Int32,
      info : Int32*,
      info_count : UInt32*,
      object_name : Port*,
    ) : KernReturn
  end

  module Probe
    LC_SEGMENT_64 =       0x19_u32
    MH_MAGIC_64   = 0xfeedfacf_u32

    # <mach-o/loader.h>
    SG_READ_ONLY = 0x10_u32

    # <mach/vm_prot.h>
    VM_PROT_READ    = 0x1
    VM_PROT_WRITE   = 0x2
    VM_PROT_EXECUTE = 0x4

    # <mach/vm_region.h>
    VM_REGION_BASIC_INFO_64       =      9
    VM_REGION_BASIC_INFO_COUNT_64 = 10_u32

    SECTION_TYPE_MASK = 0xff_u32
    TLS_TYPES         = {0x11_u32, 0x12_u32, 0x13_u32, 0x14_u32, 0x15_u32}

    record Sect,
      seg : String,
      name : String,
      addr : UInt64,
      size : UInt64,
      sect_flags : UInt32,
      seg_initprot : Int32,
      seg_flags : UInt32 do
      def tls? : Bool
        TLS_TYPES.includes?(sect_flags & SECTION_TYPE_MASK)
      end

      def seg_writable? : Bool
        (seg_initprot & VM_PROT_WRITE) != 0
      end

      def seg_read_only? : Bool
        (seg_flags & SG_READ_ONLY) != 0
      end

      def data_segment? : Bool
        seg.starts_with?("__DATA")
      end

      # What shipped until 2026-09-04.
      def old_rule? : Bool
        return false unless data_segment?
        return false if tls?
        name == "__data" || name == "__bss" || name == "__common"
      end

      # Derived by construction, the way Linux does it.
      def new_rule? : Bool
        data_segment? && seg_writable? && !seg_read_only? && !tls?
      end

      # The rule the ROADMAP proposed before this probe ran. Kept so the table
      # shows what it would have admitted.
      def initprot_only_rule? : Bool
        data_segment? && seg_writable? && !tls?
      end
    end

    def self.cstr(arr : StaticArray(UInt8, 16)) : String
      n = 0
      while n < 16 && arr[n] != 0
        n += 1
      end
      String.new(arr.to_unsafe, n)
    end

    def self.sections : Array(Sect)
      list = [] of Sect
      mh = LibProbe._dyld_get_image_header(0_u32)
      return list if mh.null? || mh.value.magic != MH_MAGIC_64
      slide = LibProbe._dyld_get_image_vmaddr_slide(0_u32).to_u64!
      p = Pointer(UInt8).new(mh.address + sizeof(LibProbe::MachHeader64))
      cmd_i = 0_u32
      while cmd_i < mh.value.ncmds
        lc = p.as(LibProbe::LoadCommand*)
        if lc.value.cmd == LC_SEGMENT_64
          seg = p.as(LibProbe::SegmentCommand64*)
          segname = cstr(seg.value.segname)
          sect = Pointer(LibProbe::Section64).new(p.address + sizeof(LibProbe::SegmentCommand64))
          j = 0_u32
          while j < seg.value.nsects
            s = (sect + j).value
            list << Sect.new(
              seg: segname,
              name: cstr(s.sectname),
              addr: s.addr &+ slide,
              size: s.size,
              sect_flags: s.flags,
              seg_initprot: seg.value.initprot,
              seg_flags: seg.value.flags,
            )
            j += 1
          end
        end
        p += lc.value.cmdsize
        cmd_i += 1
      end
      list
    end

    # Protection `mach_vm_region` reports for the region containing `addr`.
    # Returns nil if the call failed, which is reported rather than assumed.
    def self.runtime_prot(addr : UInt64) : Int32?
      address = addr
      size = 0_u64
      info = uninitialized Int32[16]
      count = VM_REGION_BASIC_INFO_COUNT_64
      object_name = 0_u32
      kr = LibMachVM.mach_vm_region(
        LibMachVM.mach_task_self_,
        pointerof(address),
        pointerof(size),
        VM_REGION_BASIC_INFO_64,
        info.to_unsafe,
        pointerof(count),
        pointerof(object_name),
      )
      return nil unless kr == 0
      # The region found must actually contain the address; mach_vm_region
      # returns the next region at or above it.
      return nil unless address <= addr && addr < address &+ size
      info[0]
    end

    def self.prot_s(p : Int32?) : String
      return "?" unless p
      s = String.build do |io|
        io << ((p & VM_PROT_READ) != 0 ? "r" : "-")
        io << ((p & VM_PROT_WRITE) != 0 ? "w" : "-")
        io << ((p & VM_PROT_EXECUTE) != 0 ? "x" : "-")
      end
      s
    end
  end

  # Any odd constant. The point is that `addr ^ KEY` is not a heap pointer, so
  # the stash below cannot itself retain what it is measuring — the same reason
  # `bench/greg_roots.cr` xors.
  KEY = 0x9E37_79B9_7F4A_7C15_u64

  # A word in a static section is only interesting if it points at a live heap
  # object *and* the object is not reachable any other way. The second half is
  # what a collection answers.
  record Candidate, sect : String, slot : UInt64, xored : UInt64

  def scan_for_heap_words(heap : Gcry::Heap, s : Probe::Sect) : Array(Candidate)
    found = [] of Candidate
    return found if s.size < 8
    lo = s.addr
    hi = s.addr &+ (s.size & ~7_u64)
    w = lo
    while w < hi
      v = Pointer(UInt64).new(w).value
      if v > 0x1000 && heap.live?(Pointer(Void).new(v))
        found << Candidate.new(sect: "#{s.seg}.#{s.name}", slot: w, xored: v ^ KEY)
      end
      w &+= 8
    end
    found
  end

  # 1.6 MiB of zerofill, which the linker puts in `__DATA.__common` alongside
  # every other class variable. It is here for one reason: `__common` on a
  # plain gcry binary is ~470 KiB, under the 1 MiB `GCRY_STATIC_BSS_CAP`
  # threshold, so without the pad the cap has nothing to refuse and the
  # control arm below cannot lose a root class on purpose.
  class Pad
    @@words = uninitialized StaticArray(UInt64, 200_000)

    def self.touch : UInt64
      @@words[0] = @@words[0] &+ 1
      @@words[0]
    end
  end

  # A graph whose only root is a class variable, i.e. a word in `__common`.
  # The default arm needs `__common` to actually hold heap pointers before
  # "which sections hold heap pointers" is a meaningful question, and the
  # control arm needs something that dies when `__common` stops being scanned.
  class Rooted
    @@head : Node? = nil

    def self.build(n : Int32) : Nil
      head = nil
      n.times do |i|
        node = Node.new(0x9E37_79B9_7F4A_7C15_u64 &* (i.to_u64 &+ 1))
        node.nxt = head
        head = node
      end
      @@head = head
    end

    def self.count : Int32
      n = 0
      node = @@head
      while node
        n += 1
        node = node.nxt
      end
      n
    end
  end

  class Node
    property nxt : Node?
    property tag : UInt64
    property fill : Slice(UInt64)

    def initialize(@tag : UInt64)
      @nxt = nil
      @fill = Slice(UInt64).new(16) { |i| @tag &* (i.to_u64 &+ 1) }
    end
  end

  NODES = 2048

  explain = ARGV.includes?("--explain")
  control = ARGV.includes?("--control")
  heap = Gcry.default_heap.not_nil!
  failures = [] of String
  sects = Probe.sections

  # Build the graph before anything is scanned: `__common` has to actually
  # hold heap pointers before "which sections hold heap pointers" is a
  # question with an answer.
  Pad.touch
  Rooted.build(NODES)
  rooted_built = Rooted.count

  puts "=== darwin static root sections: image 0 census ==="
  if sects.empty?
    STDERR.puts "FAIL: dyld image 0 yielded no LC_SEGMENT_64 sections"
    exit 1
  end

  printf("%-14s %-16s %10s  %-8s %-8s %-5s  %-3s %-3s %-3s %s\n",
    "segment", "section", "size", "initprot", "segflags", "vm", "old", "new", "ip", "note")
  sects.each do |s|
    next unless explain || s.data_segment?
    prot = Probe.runtime_prot(s.addr)
    note = [] of String
    note << "TLS" if s.tls?
    note << "SG_READ_ONLY" if s.seg_read_only?
    printf("%-14s %-16s %10d  0x%06x 0x%06x %-5s  %-3s %-3s %-3s %s\n",
      s.seg, s.name, s.size, s.seg_initprot, s.seg_flags, Probe.prot_s(prot),
      s.old_rule? ? "yes" : "no", s.new_rule? ? "yes" : "no",
      s.initprot_only_rule? ? "yes" : "no", note.join(","))
  end

  old_bytes = sects.select(&.old_rule?).sum(&.size)
  new_bytes = sects.select(&.new_rule?).sum(&.size)
  ip_bytes = sects.select(&.initprot_only_rule?).sum(&.size)
  puts
  puts "root bytes: old_rule=#{old_bytes} new_rule=#{new_bytes} initprot_only_rule=#{ip_bytes}"
  puts "gcry reports static_root_bytes=#{Gcry::Platform.static_root_bytes}"

  # --- selection arm ------------------------------------------------------
  # The one assertion that makes this file a gate on the *collector* rather
  # than on its own copy of the rule: `Sect#new_rule?` is implemented here,
  # so every arm below would stay green if `platform/darwin_roots.cr` went
  # back to the allow-list. This is what catches that, and each revert is
  # caught by a different link — which is why the Makefile runs both:
  #
  #   * going back to the name allow-list is caught under `-no_data_const`,
  #     where the derived rule takes `__const`/`__got` and the allow-list does
  #     not (a 19456-byte gap on this toolchain);
  #   * going to `initprot` alone — the rule the ROADMAP proposed — is caught
  #     on the default link, where it would take `__DATA_CONST`'s two sections
  #     that dyld has already made read-only.
  #
  # Skipped in the control child, whose whole point is that
  # `GCRY_STATIC_BSS_CAP=1` has dropped a section the rule would take.
  unless control
    reported = Gcry::Platform.static_root_bytes
    if reported != new_bytes
      hint = if reported == old_bytes
               " — that is exactly the name allow-list's total, so the derived rule has been reverted"
             elsif reported == ip_bytes
               " — that is exactly the initprot-only total, so the SG_READ_ONLY term has been dropped and #{ip_bytes - new_bytes} bytes of read-only memory are being word-scanned"
             else
               ""
             end
      failures << "selection: the collector reports static_root_bytes=#{reported} where " \
                  "the derived rule (writable __DATA*, not SG_READ_ONLY, not TLS) selects " \
                  "#{new_bytes}#{hint}"
    end
  end

  # --- writable arm -------------------------------------------------------
  # Everything the new rule admits must be writable as the kernel sees it now.
  sects.select(&.new_rule?).each do |s|
    prot = Probe.runtime_prot(s.addr)
    if prot.nil?
      failures << "writable: mach_vm_region failed for #{s.seg}.#{s.name} at " \
                  "0x#{s.addr.to_s(16)} — cannot confirm the rule admits only writable memory"
    elsif (prot & Probe::VM_PROT_WRITE) == 0
      failures << "writable: the new rule admits #{s.seg}.#{s.name}, which the kernel " \
                  "reports as #{Probe.prot_s(prot)} — a section the mutator cannot write " \
                  "holds no root the linker did not put there, so scanning it is pure " \
                  "false retention"
    end
  end
  # And the read-only-after-fixup segment must actually be read-only, or the
  # SG_READ_ONLY term in the rule is unjustified.
  ro = sects.select { |s| s.data_segment? && s.seg_read_only? }
  ro.each do |s|
    prot = Probe.runtime_prot(s.addr)
    if prot && (prot & Probe::VM_PROT_WRITE) != 0
      failures << "SG_READ_ONLY: #{s.seg}.#{s.name} carries SG_READ_ONLY but the kernel " \
                  "reports #{Probe.prot_s(prot)} — the term this rule subtracts does not " \
                  "mean what it is being read to mean"
    end
  end
  if ro.empty?
    puts "note: no SG_READ_ONLY __DATA* segment in this binary (a -no_data_const link) — " \
         "the subtraction is untested here and the __const/__got sections below are " \
         "genuinely writable"
  end

  # --- lost-root arm ------------------------------------------------------
  # Sections a rule refused, scanned for words the heap owns.
  refused_old = sects.select { |s| s.data_segment? && !s.old_rule? }
  refused_new = sects.select { |s| s.data_segment? && !s.new_rule? }
  # The control arm asks the opposite question: with `__common` refused by the
  # size cap, the sections the *collector* is no longer scanning are exactly
  # the ones that were load-bearing, so that is where the detector must fire.
  capped = sects.select { |s| s.new_rule? && s.size >= 1024_u64 * 1024 }

  cands_old = refused_old.flat_map { |s| scan_for_heap_words(heap, s) }
  cands_new = refused_new.flat_map { |s| scan_for_heap_words(heap, s) }
  cands_cap = control ? capped.flat_map { |s| scan_for_heap_words(heap, s) } : [] of Candidate
  puts
  puts "heap-owned words in sections the OLD rule refused: #{cands_old.size}"
  cands_old.group_by(&.sect).each { |k, v| puts "  #{k}: #{v.size}" }
  puts "heap-owned words in sections the NEW rule refuses: #{cands_new.size}"
  cands_new.group_by(&.sect).each { |k, v| puts "  #{k}: #{v.size}" }
  if control
    puts "heap-owned words in sections GCRY_STATIC_BSS_CAP dropped: #{cands_cap.size}"
    cands_cap.group_by(&.sect).each { |k, v| puts "  #{k}: #{v.size}" }
    # Machine-readable and printed *before* the collections, because those may
    # be the last thing this process does: its own class variables are no
    # longer a root range.
    puts "control-scan: dropped_words=#{cands_cap.size} " \
         "root_bytes=#{Gcry::Platform.static_root_bytes} " \
         "capped_sections=#{capped.size}"
    STDOUT.flush
  end

  # Collect with the candidates held only XOR'd, then ask which died while the
  # section still points at them. That is the lost root, stated as an
  # observation rather than as an inference from the section's name.
  4.times { heap.collect }

  def report_lost(label : String, cands : Array(Candidate), heap : Gcry::Heap) : Array(String)
    lost = [] of String
    cands.each do |c|
      addr = c.xored ^ KEY
      still = Pointer(UInt64).new(c.slot).value
      next unless still == addr
      next if heap.live?(Pointer(Void).new(addr))
      lost << "#{label}: #{c.sect} slot 0x#{c.slot.to_s(16)} still holds 0x#{addr.to_s(16)}, " \
              "which the heap has reclaimed"
    end
    lost
  end

  lost_old = report_lost("old rule", cands_old, heap)
  lost_new = report_lost("new rule", cands_new, heap)
  lost_cap = report_lost("bss cap", cands_cap, heap)
  rooted_after = Rooted.count

  if control
    # One line, printed as early as the answer exists: this process is running
    # with its own class variables unrooted and may not survive to say more.
    puts "control: lost=#{lost_cap.size} rooted_survived=#{rooted_after}/#{rooted_built} " \
         "root_bytes=#{Gcry::Platform.static_root_bytes}"
    STDOUT.flush
    exit(lost_cap.size > 0 || rooted_after != rooted_built ? 0 : 1)
  end

  puts
  puts "reclaimed-while-referenced after 4 collections: old_rule=#{lost_old.size} " \
       "new_rule=#{lost_new.size}"
  lost_old.first(8).each { |l| puts "  #{l}" }
  lost_new.first(8).each { |l| puts "  #{l}" }
  puts "class-var-rooted graph: built=#{rooted_built} survived=#{rooted_after}"

  # The gate: the rule the collector ships must lose nothing, and the graph
  # whose only root is a class variable must survive.
  lost_new.each { |l| failures << l }
  if rooted_after != rooted_built
    failures << "the graph rooted only through a class variable went " \
                "#{rooted_built} -> #{rooted_after} nodes: __common is not a root range"
  end

  # --- control arm --------------------------------------------------------
  # `lost_new == 0` is worth nothing until the detector is shown to fire, and
  # it can only fire when a root class is genuinely dropped. `bss_size_cap`
  # drops `__common`, which the 1.6 MiB `Pad` above pushes over the
  # threshold. Run as a child: the arm is a process whose own statics are
  # unrooted, so it may die before it reports, and dying without ever
  # claiming the graph survived is itself the evidence — the same reasoning
  # `bench/static_bss_roots.cr` uses for its capped arm.
  puts
  puts "--- control: GCRY_STATIC_BSS_CAP=1 (a root class dropped on purpose) ---"
  child_out = IO::Memory.new
  child_err = IO::Memory.new
  status = Process.run(
    Process.executable_path.not_nil!,
    ["--control"],
    env: {"GCRY_STATIC_BSS_CAP" => "1"},
    output: child_out,
    error: child_err,
  )
  out_s = child_out.to_s
  scan_line = out_s.each_line.find { |l| l.starts_with?("control-scan: ") }
  verdict_line = out_s.each_line.find { |l| l.starts_with?("control: ") }
  puts "  child exit=#{status.exit_code} exited_normally=#{status.normal_exit?}"
  puts "  #{scan_line || "(no control-scan line — the child died before it could scan)"}"
  puts "  #{verdict_line || "(no control verdict line — the child did not survive its own collections)"}"
  child_err.to_s.each_line.first(2).each { |l| puts "  child stderr: #{l}" }

  dropped_words = scan_line.try(&.[](/dropped_words=(\d+)/, 1)).try(&.to_i)
  capped_bytes = scan_line.try(&.[](/root_bytes=(\d+)/, 1)).try(&.to_u64)

  if scan_line.nil?
    failures << "control: the child never reported a scan, so the cap arm measured " \
                "nothing and the green arms above rest on an unexercised detector"
  else
    if capped_bytes && capped_bytes >= new_bytes
      failures << "control: GCRY_STATIC_BSS_CAP=1 left static_root_bytes at " \
                  "#{capped_bytes} against the uncapped #{new_bytes} — the knob " \
                  "refused nothing, so no root class was dropped"
    end
    if dropped_words == 0
      failures << "control: the section the cap dropped held no heap-owned word, so " \
                  "the scan cannot see a root even where one certainly is — the " \
                  "detector has no power and the green arms above prove nothing"
    end
  end
  # Surviving the drop *intact* is the one outcome that would mean the dropped
  # section was not load-bearing after all.
  if verdict_line
    lost_n = verdict_line[/lost=(\d+)/, 1]?.try(&.to_i) || 0
    surv = verdict_line[/rooted_survived=(\d+)\/(\d+)/, 1]?.try(&.to_i)
    total = verdict_line[/rooted_survived=(\d+)\/(\d+)/, 2]?.try(&.to_i)
    if lost_n == 0 && surv == total
      failures << "control: with __common refused, nothing was reclaimed while still " \
                  "referenced and the class-var graph survived intact — dropping the " \
                  "section changed nothing, so the detector is not being exercised"
    end
  end

  puts
  if failures.empty?
    ro_note = ro.empty? ? "-no_data_const link (no SG_READ_ONLY segment)" : "default link"
    died = verdict_line.nil?
    puts "VERDICT: on this #{ro_note} the derived rule selects #{new_bytes} bytes against " \
         "the allow-list's #{old_bytes} (delta #{new_bytes - old_bytes}), and the " \
         "initprot-only rule proposed in the ROADMAP would have taken #{ip_bytes} — " \
         "#{ip_bytes - new_bytes} bytes of it read-only at runtime. No refused section " \
         "held a word the heap reclaimed. The control arm is what makes that " \
         "non-vacuous: with the same section refused by GCRY_STATIC_BSS_CAP the scan " \
         "found #{dropped_words} heap-owned words in it and the child " \
         "#{died ? "did not survive its own collections" : "reported them reclaimed"}."
    exit 0
  end

  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
{% else %}
  puts "=== darwin static root sections ==="
  puts "SKIP — Darwin only. Linux derives the same set from the executable's writable"
  puts "PT_LOADs minus PT_GNU_RELRO (src/gcry/platform/linux_roots.cr), which is the"
  puts "rule this probe exists to reproduce on Mach-O."
  exit 0
{% end %}
