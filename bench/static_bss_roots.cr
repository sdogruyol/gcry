# Is a Crystal program's BSS a root range, whatever size it is?
#
# `/proc/self/maps` shows a program's BSS as an anonymous RW mapping that begins
# exactly where the executable's file-backed RW `.data` ended. gcry finds it by
# that adjacency (`src/gcry/platform/linux_roots.cr`), and until 2026-08-22 it
# also required the region to be **smaller than 1 MiB** — so a program with more
# static data than that had its whole BSS refused as a root range, and every
# class variable and constant slot holding a heap reference was swept.
#
# It is not a subtle failure. In 20 lines: an 8 MiB static class variable, one
# `GC.malloc` stored into it, two collections, and the process dies inside
# `IO#encoder` because `STDERR` — a constant, living in that BSS — was
# collected. That the crash is loud is luck: what the collector did was free a
# reachable object.
#
# The second threshold is `Roots::MAX_SCAN_BYTES`. A range longer than 64 MiB
# used to be refused by `scan_range` with nothing counted, so lifting the 1 MiB
# cap alone would only have moved the hole. Static ranges now go through
# `scan_range_chunked`.
#
# The arms run as **child processes**, because the one that restores the cap is
# running with its own statics collected and may not survive to say so: it has
# reached its verdict and died before printing it, and whether it gets that far
# changes with codegen. So the parent judges, and "died without ever claiming
# the block was live" counts as the block dying — which is what it is.
#
#   default        the block stored in the BSS must survive two collections.
#   --huge         the same, with a BSS larger than `MAX_SCAN_BYTES`, which can
#                  only pass if the chunked scan works.
#   GCRY_STATIC_BSS_CAP=1
#                  restores the 1 MiB cap. The block must **die** — without
#                  this arm, "it survived" says nothing about why.
#
#   crystal build -Dgc_none bench/static_bss_roots.cr -o bin/static_bss_roots
#   bin/static_bss_roots
#   GCRY_STATIC_BSS_CAP=1 bin/static_bss_roots --cap

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "static_bss_roots requires -Dgc_none (gcry as process GC)" %}
{% end %}

# 8 MiB of BSS, or 96 MiB for the arm that has to clear `MAX_SCAN_BYTES`.
{% if flag?(:static_bss_huge) %}
  WORDS = 12_000_000
{% else %}
  WORDS = 1_000_000
{% end %}

BLOCK_SIZE =  96_u64
FILL       = 0xC7_u8

# A class variable, because that is where the defect lives: Crystal puts it in
# the BSS, and the only reference to the block will be the slot inside it.
class StaticHolder
  @@slots = uninitialized StaticArray(UInt64, WORDS)

  def self.put(i : Int32, value : UInt64) : Nil
    @@slots[i] = value
  end

  def self.get(i : Int32) : UInt64
    @@slots[i]
  end
end

SLOT = WORDS - 3

# The block's address is never returned as itself: the caller keeps the masked
# form, so no frame of the harness can be what keeps it alive. Same device as
# `bench/greg_roots.cr`.
KEY = 0x5A5A_A5A5_5A5A_A5A5_u64

@[NoInline]
def stash_in_bss : UInt64
  block = GC.malloc(BLOCK_SIZE)
  bytes = block.as(UInt8*)
  i = 0_u64
  while i < BLOCK_SIZE
    bytes[i] = FILL
    i += 1
  end
  StaticHolder.put(SLOT, block.address)
  block.address ^ KEY
end

@[NoInline]
def wipe_stack : Nil
  buf = uninitialized UInt8[16384]
  i = 0
  while i < 16384
    buf.to_unsafe[i] = 0x11_u8
    i += 1
  end
  Gcry::Trace.enabled? && puts(buf.to_unsafe[0])
end

# The BSS is the anonymous RW mapping that starts where the executable's
# file-backed RW mapping ended. Measured rather than assumed: an arm that never
# crossed the threshold would pass for a reason that has nothing to do with the
# fix.
def measure_bss_bytes : UInt64
  exe = Process.executable_path
  return 0_u64 unless exe
  prev_hi = 0_u64
  prev_file_rw = false
  File.each_line("/proc/self/maps") do |line|
    parts = line.split(' ', remove_empty: true)
    next if parts.size < 5
    range = parts[0].split('-')
    next if range.size != 2
    lo = range[0].to_u64(16)
    hi = range[1].to_u64(16)
    perms = parts[1]
    path = parts.size >= 6 ? parts[5] : ""

    if path.empty? && perms.starts_with?("rw") && prev_file_rw && lo == prev_hi
      return hi - lo
    end

    prev_hi = hi
    prev_file_rw = perms.starts_with?("rw") && path == exe
  end
  0_u64
end

# A private copy of stderr, taken before anything can be collected and held in
# an `Int32` local. In the arm that restores the cap, `STDERR`'s own
# `IO::FileDescriptor` is collected and **finalized**, which closes fd 2 — so
# the verdict cannot go out through fd 2, and a `write(2)` to it returns EBADF
# in silence. That is also what "Closed stream (IO::Error)" was in the first
# reproduction of this defect.
lib LibDup
  fun dup(fd : LibC::Int) : LibC::Int
end

REPORT_FD = LibDup.dup(2)

# The parent judges; see the note at the top.
unless ARGV.includes?("--child")
  exe = Process.executable_path.not_nil!
  failures = [] of String
  huge_arm = {{ flag?(:static_bss_huge) ? true : false }}

  puts "=== static BSS roots ==="
  puts "mode: parent (#{huge_arm ? "huge" : "default"} binary, two child arms)"

  [{"default", {} of String => String}, {"cap", {"GCRY_STATIC_BSS_CAP" => "1"}}].each do |(arm, env)|
    args = arm == "cap" ? ["--child", "--cap"] : ["--child"]
    captured = IO::Memory.new
    status = Process.run(exe, args, env: env, output: captured, error: captured)
    text = captured.to_s
    said_live = text.includes?("live=true")
    said_dead = text.includes?("live=false")
    puts "#{arm}: exit=#{status.exit_code?.inspect} #{text.lines.find(&.starts_with?("block ")) || "(no verdict line)"}"

    if arm == "default"
      failures << "default: the child did not exit cleanly (#{status.exit_code?.inspect})" unless status.success?
      failures << "default: a block held only by the BSS did not survive — the BSS is not a root range" unless said_live
      failures << "default: a range was skipped for being oversize; the static scan is meant to chunk" if text.includes?("oversize_skips=0") == false
    else
      # Either it said the block died, or it died before it could say. Both are
      # the cap collecting a reachable object; what must never happen is the
      # block surviving.
      failures << "cap: the 1 MiB cap is restored and the block survived anyway — the other arm's " \
                  "survival cannot be credited to the BSS being scanned" if said_live
      unless said_dead || !status.success?
        failures << "cap: the child neither reported the block dying nor failed, so this arm " \
                    "observed nothing"
      end
    end

    unless text.includes?("BSS mapping")
      failures << "#{arm}: the child never reported its BSS size, so its threshold was never checked"
    end
    failures << "#{arm}: the BSS never crossed the threshold this arm is about" if text.includes?("BSS TOO SMALL")
  end

  if failures.empty?
    puts
    puts "ok — the BSS is a root range at this size, and refusing it collects a reachable block"
    exit 0
  else
    puts
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    exit 1
  end
end

cap = ARGV.includes?("--cap")
huge = {{ flag?(:static_bss_huge) ? true : false }}
mode = cap ? "cap (GCRY_STATIC_BSS_CAP=1, the old 1 MiB refusal)" : "default (BSS is a root range)"

puts "=== static BSS roots ==="
puts "mode: #{mode}"

bss = measure_bss_bytes
puts "static array #{WORDS * 8} bytes; BSS mapping #{bss} bytes#{huge ? " (huge arm)" : ""}"
# Printed before anything can be collected, so the parent sees it even if this
# process does not survive its own collection.
if bss <= 1_u64 * 1024 * 1024 || (huge && bss <= Gcry::Roots::MAX_SCAN_BYTES)
  puts "BSS TOO SMALL for this arm"
end
STDOUT.flush

hidden = stash_in_bss
wipe_stack

# Held in a local across the collections on purpose. `Gcry.default_heap` is
# itself reached through a class variable, i.e. through the BSS, so in the arm
# that restores the cap the collector frees its own `Heap` object and the first
# call through it after the collection faults. Keeping it on the stack roots
# the collector, not the block under test.
heap = Gcry.default_heap

# Two, so a single collection's timing cannot be the explanation.
GC.collect
GC.collect

block = Pointer(Void).new(hidden ^ KEY)
alive = heap.live?(block)
slot_holds_it = StaticHolder.get(SLOT) == block.address
# Only when it is still live. In the arm that restores the cap the block is not
# merely freed — its chunk goes back to the OS, and reading the payload to check
# it faults: `Cannot access memory at address 0x7ffff7b7feb8`, which is the
# clearest statement of what the defect does that this harness can make.
intact = alive
if alive
  bytes = block.as(UInt8*)
  i = 0_u64
  while i < BLOCK_SIZE
    if bytes[i] != FILL
      intact = false
      break
    end
    i += 1
  end
end

# Everything from here on is allocation-free, and it has to be. With the cap
# restored the collection just freed the harness's own statics — `STDERR`
# included — so a `puts` here does not report a failure, it segfaults on the
# object it is trying to print through. The verdict goes out through
# `RawOut`/`write(2)` and the process leaves through `LibC._exit`, so this arm
# reports rather than dies.
buf = uninitialized UInt8[Gcry::RawOut::LIMIT]
p = buf.to_unsafe
len = Gcry::RawOut.append(p, 0, "block 0x")
len = Gcry::RawOut.append_hex(p, len, block.address)
len = Gcry::RawOut.append(p, len, " live=")
len = Gcry::RawOut.append(p, len, alive ? "true" : "false")
len = Gcry::RawOut.append(p, len, " intact=")
len = Gcry::RawOut.append(p, len, intact ? "true" : "false")
len = Gcry::RawOut.append(p, len, " slot_holds_it=")
len = Gcry::RawOut.append(p, len, slot_holds_it ? "true" : "false")
len = Gcry::RawOut.append(p, len, " oversize_skips=")
len = Gcry::RawOut.append_u64(p, len, Gcry::Roots.oversize_skips)
len = Gcry::RawOut.append(p, len, "\n")
LibC.write(REPORT_FD, p, LibC::SizeT.new(len))

# The BSS has to be over the threshold or neither result is about the defect,
# and the huge arm has to be over `MAX_SCAN_BYTES` or it never reached the
# chunked path.
ok = slot_holds_it
ok &&= alive && intact unless cap

len = Gcry::RawOut.append(p, 0, ok ? "child ok\n" : "child FAIL — see the line above\n")
LibC.write(REPORT_FD, p, LibC::SizeT.new(len))
LibC._exit(ok ? 0 : 1)
