# Does a crash say what gcry knows about the address it died on?
#
# The 2026-08-10 soak left `Invalid memory access at 0x7f1700000149` and nothing
# else. Every fact that would have narrowed it was in the collector's tables at
# that moment — in the heap span or not, which chunk, used block or free one,
# what sat at its start — and none of it was asked for. `GCRY_SEGV_REPORT=1`
# asks, prints, and hands the signal back to Crystal's handler, which reports as
# it always did.
#
# A crash reporter can only be tested by crashing, so each arm is a **child
# process** that faults on purpose; the parent reads its stderr and checks the
# diagnosis names the right shape. The arms are the readings the 2026-08-10 value
# left open — the whole point is that they produce *different* text:
#
#   poison       dereference gcry's freed-block pattern → must say use-after-free
#                and name the knob, with no heap lookup at all.
#   offset-poison  dereference the *tagged* poison plus 760 bytes, which is what
#                a crash looks like when libc indexes a poisoned pointer before
#                reading it. The tag survives the arithmetic, so a reader that
#                trusts it decodes the wrong block — this arm requires the
#                report to recover the base instead.
#   free-block   dereference a pointer *into* a block that was freed → must say
#                the address is in a FREE block.
#   used-block   a bad offset inside a live block → must say USED, so the two
#                cannot be confused.
#   outside      an address far from the heap → must say outside the span, which
#                rules a swept object out rather than leaving it open.
#   --control    the same faults with the knob off: no gcry line at all, and
#                Crystal's own message unchanged. This is what shows the reporter
#                adds lines and removes none.
#
#   crystal build -Dgc_none bench/segv_report.cr -o bin/segv_report
#   bin/segv_report
#   bin/segv_report --control
#
# `--child=<arm>` is the crashing half; the parent re-executes itself with it.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "segv_report requires -Dgc_none (gcry as process GC)" %}
{% end %}

POISON = 0xDEADF2EEDEADF2EE_u64

# Each returns an address to dereference. Kept in a method so the pointer does
# not sit in the parent's frame.
@[NoInline]
def crash_address(arm : String) : UInt64
  case arm
  when "poison"
    POISON
  when "offset-poison"
    # The shape a real crash takes when libc indexes a poisoned pointer before
    # dereferencing it: `pthread_getattr_np` reading `struct pthread` at +0x418,
    # Darwin at +760. The value still carries `0xDEAD` in its top bits, so a
    # reader that only checks the tag decodes an address that is not the freed
    # block — measured, it named a block five slots along and called it an
    # explicit free. The report must recover the base instead.
    ptr = GC.malloc(1024)
    ptr.as(UInt64*).value = 0_u64
    STDERR.puts "planted block 0x#{ptr.address.to_s(16)}"
    GC.free(ptr)
    Pointer(UInt64).new(ptr.address).value + 760
  when "reissued-poison"
    # The same poison, read after the block has been **handed out again**.
    # `SWEPT` is set beside `FREE` by the sweep and cleared when the block is
    # reissued, so on a reissued block the flags describe the reissue and not
    # the free that wrote the poison. Reading them anyway produced a false
    # "explicit free" three times, the last against a block the dying-type
    # audit had watched the sweep condemn one collection earlier. The report
    # must decline the verdict here, not guess it.
    ptr = GC.malloc(1024)
    ptr.as(UInt64*).value = 0_u64
    STDERR.puts "planted block 0x#{ptr.address.to_s(16)}"
    GC.free(ptr)
    # Read the tagged poison out before anything can overwrite the payload.
    poison = Pointer(UInt64).new(ptr.address).value
    heap = Gcry.default_heap
    tries = 0
    while heap.debug_block_info(Pointer(Void).new(ptr.address))[:free] && tries < 64
      GC.malloc(1024)
      tries += 1
    end
    if heap.debug_block_info(Pointer(Void).new(ptr.address))[:free]
      # Say so rather than fault: an arm that could not build its own condition
      # must fail loudly, not pass on a report about a still-free block.
      STDERR.puts "could not get the block reissued in #{tries} allocations"
      exit 0
    end
    STDERR.puts "reissued after #{tries} allocation(s)"
    poison
  when "free-block"
    # Freed, then read through a pointer into the middle of it. Poison is off
    # for this arm so the *block state* is what the report has to notice.
    ptr = GC.malloc(256)
    GC.free(ptr)
    ptr.address + 64
  when "used-block"
    # Live, and the address is inside it — the report must not call this free.
    ptr = GC.malloc(256)
    ptr.as(UInt64*).value = 0x1234_u64
    ptr.address + 32
  else
    # Canonical (below 2^47) and far from anything gcry maps, so the kernel
    # reports it in si_addr — a *non-canonical* address would fault as #GP with
    # si_addr 0 and test the wrong branch.
    0x0000_5ead_beef_0000_u64
  end
end

def run_child(arm : String) : NoReturn
  # The reporter arms itself on the first collection (Crystal overwrites any
  # handler installed at GC.init), so take one before faulting.
  GC.collect
  addr = crash_address(arm)
  # For the two heap arms the address is real memory; force an actual fault by
  # reading through a pointer the compiler cannot fold away.
  if arm == "free-block" || arm == "used-block"
    # These are mapped, so a read will not fault — report on demand instead of
    # crashing, which is the same code path minus the signal.
    heap = Gcry.default_heap
    info = heap.debug_block_info(Pointer(Void).new(addr))
    STDERR.puts "gcry: SEGV at 0x#{addr.to_s(16)} — " \
                "#{info[:found] ? (info[:free] ? "in a FREE block" : "in a USED block") : "in no live chunk"}" \
                ", size #{info[:size]}, offset #{info[:offset]} into it"
    exit 0
  end
  Pointer(UInt64).new(addr).value = 1_u64
  exit 0
end

ARGV.each do |arg|
  if arg =~ /--child=(.+)/
    run_child($1)
  end
end

control = ARGV.includes?("--control")
puts "=== SIGSEGV report ==="
puts "mode: #{control ? "control (GCRY_SEGV_REPORT unset; no gcry line may appear)" : "hold (report on)"}"

exe = Process.executable_path.not_nil!
failures = [] of String

ARMS = {
  "poison" => {"freed-block poison", true},
  # The expectation is filled in from what the child planted — see below. A
  # fixed string here would pass on a report that recovered the *wrong* base,
  # which is exactly the bug this arm exists for.
  "offset-poison" => {"", true},
  # No fixed expectation: the arm asserts on what must *not* be there as well,
  # below.
  "reissued-poison" => {"they describe the reissue, not the free", true},
  "free-block"      => {"in a FREE block", false},
  "used-block"      => {"in a USED block", false},
  "outside"         => {"outside gcry's heap span", true},
}

ARMS.each do |arm, (expect, needs_signal)|
  env = {"GCRY_SEGV_REPORT" => control ? "0" : "1"}
  env["GCRY_POISON_FREED"] = "1" if arm == "poison"
  # The tag is what makes a block recoverable at all.
  env["GCRY_POISON_TAG"] = "1" if arm == "offset-poison" || arm == "reissued-poison"
  captured = IO::Memory.new
  Process.run(exe, ["--child=#{arm}"], env: env, output: captured, error: captured)
  text = captured.to_s
  if arm == "offset-poison"
    planted = text.lines.find(&.starts_with?("planted block "))
    unless planted
      failures << "#{arm}: the child did not report what it planted"
      next
    end
    expect = "bytes into the block at #{planted.split(' ')[2]}"
  end
  saw = text.includes?(expect)
  gcry_line = text.includes?("gcry: SIGSEGV") || text.includes?("gcry: SIGBUS")
  puts "#{arm}: #{saw ? "named" : "NOT named"} (#{expect.inspect})"

  if arm == "reissued-poison" && !control
    if text.includes?("could not get the block reissued")
      failures << "reissued-poison: the arm could not reissue the block, so it tested nothing"
    end
    if text.includes?("freed by an explicit free") || text.includes?("freed by the SWEEP")
      failures << "reissued-poison: the report named a free path from a reissued block's flags, " \
                  "which describe the reissue and not the free"
    end
  end

  if control && needs_signal
    # The two signal arms are the ones the knob gates; the other two report on
    # demand and are unaffected by it.
    if gcry_line
      failures << "#{arm}: the knob is off but gcry still reported on the signal"
    end
  elsif !saw
    failures << "#{arm}: the report did not name #{expect.inspect}. What it said:\n#{text.lines.first(6).join("\n")}"
  end
end

if failures.empty?
  puts
  if control
    puts "ok — with the knob off no gcry line appears on a fault, so the other run's diagnosis " \
         "is attributable to the reporter"
  else
    puts "ok — each fault shape is named for what it is: poison, a FREE block, a USED block, " \
         "and an address gcry never mapped"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
