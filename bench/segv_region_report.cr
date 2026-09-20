require "../src/gcry"

# Does the crash report say what the faulting address *is*?
#
# When an address is outside gcry's span the report's three readings say what
# it is not: not a gcry allocation, and — depending on whether the collector is
# inside the pthread stack-bounds query — whether a swept object is excluded.
# On 2026-09-19 the churn gate's poisoned arm faulted at `0x55816aff0` on a CI
# runner, 1 of 24, and that was the entire sighting: an address, and the fact
# that gcry never allocated it
# (`bench/log/linux/2026-09-19-churn-out-of-span-sighting/FINDINGS.md`). No
# region, no permissions, no size, nothing to compare against the next one.
#
# The kernel knows. `Platform.each_map_region` walks every mapping with its
# name, allocation-free, so the report names the mapping the address is in —
# and how far below its top it sits, which is how a region "gcry can name as
# nothing" was recognised as a stack in 2026-08-27.
#
# Three shipped arms, and the numbers are checked rather than the words:
#
#   * **mapped** — fault inside an anonymous `PROT_NONE` mapping, placed well
#     away from the heap. The report must name a range that actually contains
#     the faulting address, with the right size and the right distance below
#     the top.
#   * **file** — the same through a file-backed mapping, which must be named by
#     path rather than as anonymous.
#   * **wild** — an address in no mapping at all. The report must say so rather
#     than name the nearest region, because "stale pointer into a live mapping"
#     and "wild pointer" are different defects.
#
# A fourth arm constructs the red direction per run. Until 2026-09-20 the only
# way this gate came out red was a hand edit of `report_faulting_region`.
# `GCRY_DISABLE_REGION_REPORT=1` skips that line, so the same three faults
# print "never a gcry allocation" and nothing about the mapping — which is
# what the 2026-09-19 churn sighting carried. The parent forks those children
# under the knob and requires each *not* to name the mapping; dropping the
# knob reddens the gate rather than hiding it.
module SegvRegionReport
  HINT      = 0x2a00_0000_0000_u64
  FILE_HINT = 0x2b00_0000_0000_u64
  SIZE      = 1 << 20
  OFFSET    =               0x1234
  WILD      = 0x3000_0000_0000_u64

  record Sighting, addr : UInt64, lo : UInt64, hi : UInt64, perms : String, size : UInt64,
    below_top : UInt64, name : String

  def self.child(arm : String) : Int32
    # Inside the platform guard: `Gcry::SegvReport` does not exist on Windows,
    # and an unguarded reference to it in a harness is how six Windows jobs
    # broke on 2026-09-16 (`Gcry::PoisonHolders` three days before that). This
    # file is in `make windows-typecheck` for the same reason.
    {% if flag?(:linux) %}
      Gcry::SegvReport.install
      case arm
      when "mapped"
        block = Gcry::OS.mmap(Pointer(Void).new(HINT), LibC::SizeT.new(SIZE), 0,
          Gcry::OS::MAP_PRIVATE | Gcry::OS::MAP_ANONYMOUS, -1, 0)
        return 2 if Gcry.mmap_failed?(block)
        target = (block.as(UInt8*) + OFFSET).as(UInt64*)
        puts "probe: 0x#{target.address.to_s(16)} size=#{SIZE}"
        STDOUT.flush
        puts target.value
      when "file"
        # A named mapping, and `PROT_NONE` so touching it faults. The report has
        # to copy the pathname out of the walker's buffer to print it.
        fd = LibC.open("/proc/self/exe".to_unsafe.as(LibC::Char*), 0)
        return 2 if fd < 0
        block = Gcry::OS.mmap(Pointer(Void).new(FILE_HINT), LibC::SizeT.new(SIZE), 0,
          Gcry::OS::MAP_PRIVATE, fd, 0)
        return 2 if Gcry.mmap_failed?(block)
        target = (block.as(UInt8*) + OFFSET).as(UInt64*)
        puts "probe: 0x#{target.address.to_s(16)} size=#{SIZE}"
        STDOUT.flush
        puts target.value
      when "wild"
        puts "probe: 0x#{WILD.to_s(16)} size=0"
        STDOUT.flush
        puts Pointer(UInt64).new(WILD).value
      end
    {% end %}
    0
  end

  # `gcry: that address is in a mapping [0xLO, 0xHI) rw-p, N bytes, 0xD below its top, NAME`
  def self.parse(addr : UInt64, output : String) : Sighting?
    line = output.lines.find(&.includes?("that address is in a mapping"))
    return nil unless line
    m = line.match(/\[0x([0-9a-f]+), 0x([0-9a-f]+)\) (\S+), (\d+) bytes, 0x([0-9a-f]+) below its top, (.+)$/)
    return nil unless m
    Sighting.new(addr: addr,
      lo: m[1].to_u64(16), hi: m[2].to_u64(16), perms: m[3].rstrip(','),
      size: m[4].to_u64, below_top: m[5].to_u64(16), name: m[6].strip)
  end

  def self.run(exe : String, arm : String, env : Hash(String, String) = {} of String => String) : Tuple(String, String)
    sink = IO::Memory.new
    errors = IO::Memory.new
    Process.run(exe, [arm], env: env, output: sink, error: errors)
    {sink.to_s, errors.to_s}
  end

  def self.probe_address(stdout : String) : Tuple(UInt64, UInt64)?
    line = stdout.lines.find(&.starts_with?("probe: "))
    return nil unless line
    m = line.match(/probe: 0x([0-9a-f]+) size=(\d+)/)
    return nil unless m
    {m[1].to_u64(16), m[2].to_u64}
  end

  def self.main : Int32
    if arm = ARGV[0]?
      return child(arm) if %w[mapped file wild].includes?(arm)
    end

    {% unless flag?(:linux) %}
      puts "=== does the crash report name the mapping it faulted in? ==="
      puts "skipped — `each_map_region` walks /proc/self/maps, so this gate is Linux-only."
      puts "The report says the mapping could not be read on platforms without the walker."
      return 0
    {% end %}

    exe = Process.executable_path || PROGRAM_NAME
    failures = 0
    puts "=== does the crash report name the mapping it faulted in? ==="
    puts ""

    {"mapped", "file"}.each do |arm|
      stdout, stderr = run(exe, arm)
      probe = probe_address(stdout)
      unless probe
        puts "  #{arm}: FAIL — the child never reached its fault (#{stdout.lines.last? || "no output"})"
        failures += 1
        next
      end
      addr, size = probe
      sighting = parse(addr, stderr)
      unless sighting
        puts "  #{arm}: FAIL — no mapping named for 0x#{addr.to_s(16)}"
        stderr.lines.select(&.starts_with?("gcry:")).first(2).each { |l| puts "      #{l.strip}" }
        failures += 1
        next
      end

      ok = true
      unless sighting.lo <= addr && addr < sighting.hi
        puts "  #{arm}: FAIL — 0x#{addr.to_s(16)} is not inside the range it named " \
             "[0x#{sighting.lo.to_s(16)}, 0x#{sighting.hi.to_s(16)})"
        ok = false
      end
      unless sighting.size == sighting.hi - sighting.lo && sighting.size == size
        puts "  #{arm}: FAIL — size #{sighting.size} is neither the range's #{sighting.hi - sighting.lo} " \
             "nor the mapping's #{size}"
        ok = false
      end
      unless sighting.below_top == sighting.hi - addr
        puts "  #{arm}: FAIL — 0x#{sighting.below_top.to_s(16)} below the top, but the range says " \
             "0x#{(sighting.hi - addr).to_s(16)}"
        ok = false
      end
      named = arm == "file" ? sighting.name.includes?("/") : sighting.name == "anonymous"
      unless named
        puts "  #{arm}: FAIL — named #{sighting.name.inspect}, which is not what a " \
             "#{arm == "file" ? "file-backed" : "anonymous"} mapping is"
        ok = false
      end

      failures += 1 unless ok
      next unless ok
      puts "  #{arm}: 0x#{addr.to_s(16)} in [0x#{sighting.lo.to_s(16)}, 0x#{sighting.hi.to_s(16)}) " \
           "#{sighting.perms}, #{sighting.size} bytes, 0x#{sighting.below_top.to_s(16)} below its top, " \
           "#{sighting.name}"
    end

    stdout, stderr = run(exe, "wild")
    probe = probe_address(stdout)
    if probe && (line = stderr.lines.find(&.includes?("no mapping holds that address")))
      puts "  wild:   0x#{probe[0].to_s(16)} — #{line.strip.sub("gcry: ", "")}"
    else
      puts "  wild:   FAIL — an address in no mapping must be reported as such, not named"
      stderr.lines.select(&.starts_with?("gcry:")).first(2).each { |l| puts "      #{l.strip}" }
      failures += 1
    end
    puts ""

    # The red direction. The shipped arms above require the mapping line; this
    # arm requires its absence under the knob that skips it. A child that still
    # names the mapping means the skip is gone and a hand edit is the only way
    # this gate can fail again.
    disabled = {"GCRY_DISABLE_REGION_REPORT" => "1"}
    puts "  under GCRY_DISABLE_REGION_REPORT=1 (the pre-fix report):"
    {"mapped", "file"}.each do |arm|
      stdout, stderr = run(exe, arm, disabled)
      probe = probe_address(stdout)
      unless probe
        puts "    #{arm}: FAIL — the child never reached its fault"
        failures += 1
        next
      end
      sighting = parse(probe[0], stderr)
      if sighting
        puts "    #{arm}: FAIL — still named [0x#{sighting.lo.to_s(16)}, 0x#{sighting.hi.to_s(16)}) #{sighting.name} — the knob no longer drops the mapping line"
        failures += 1
      else
        puts "    #{arm}: unnamed (0x#{probe[0].to_s(16)})"
      end
    end
    stdout, stderr = run(exe, "wild", disabled)
    probe = probe_address(stdout)
    if probe.nil?
      puts "    wild:   FAIL — the child never reached its fault"
      failures += 1
    elsif stderr.lines.any?(&.includes?("no mapping holds that address"))
      puts "    wild:   FAIL — still reported as wild — the knob no longer drops the mapping line"
      failures += 1
    else
      puts "    wild:   unnamed (0x#{probe[0].to_s(16)})"
    end
    puts ""

    if failures == 0
      puts "ok — a fault outside the span names the mapping that holds it, with a range that"
      puts "     contains the address, the mapping's own size, the distance below its top and"
      puts "     the pathname when it has one; an address in no mapping is reported as wild"
      puts "     rather than attributed to the nearest region. GCRY_DISABLE_REGION_REPORT=1"
      puts "     drops that line on the same three faults, which is the pre-fix report"
      puts "     (src/gcry/segv_report.cr)."
      0
    else
      puts "FAIL: #{failures} arm(s). Without this the only thing a sighting outside the span"
      puts "      carries is an address — which is what cost the 2026-09-19 churn sighting"
      puts "      (bench/log/linux/2026-09-19-churn-out-of-span-sighting/FINDINGS.md)."
      1
    end
  end
end

exit SegvRegionReport.main
