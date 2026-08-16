# When a use-after-free names the block it read out of, who still points at it?
#
# `GCRY_POISON_TAG=1` gets as far as naming the block. The open fiber-creation
# UAF (`bench/nested_spawn_uaf.cr`,
# `bench/log/linux/2026-08-15-nested-spawn-uaf/FINDINGS.md`) stopped exactly
# there: the block is a `Deque(Fiber::Stack)` buffer abandoned at a resize, gcry
# freed it correctly, and *something* still reads it — held indefinitely, since a
# bounded grace on the root does not help. `GCRY_POISON_HOLDERS=1` searches the
# root set, the live heap and the fiber stacks for that address at fault time and
# names what it finds (`src/gcry/poison_holders.cr`).
#
# A search that reports nothing looks exactly like one that ran and found the
# heap clean, so this plants holders it knows the address of and checks the
# report names *those*. Each arm is a child process that faults on purpose;
# the parent reads its stderr.
#
#   heap-holder      a live block holds the freed block's address at a known
#                    offset → the report must name that block, by address.
#   stack-holder     the address is on the stack and nowhere in the heap → the
#                    report must name a stack slot.
#   no-heap-holder   nothing in the heap holds it → the heap section must say
#                    **0**. This is the arm that fails if the walk matches the
#                    freed block on itself, or counts FREE blocks: those would
#                    make every search report a holder and none of them mean it.
#   --control        the knob off: no holder line at all, and the rest of the
#                    crash report unchanged. The search adds lines; it removes
#                    none.
#
#   crystal build -Dgc_none bench/poison_holders.cr -o bin/poison_holders
#   bin/poison_holders
#   bin/poison_holders --control
#
# `--child=<arm>` is the crashing half; the parent re-executes itself with it.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "poison_holders requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Offset in the planted holder where the stale pointer is written. Not 0: a
# holder that keeps the pointer in its first word would also be found by a walk
# that only ever looks at block starts, and that is not the walk being tested.
HOLDER_OFFSET = 16

@[NoInline]
def run_child(arm : String) : NoReturn
  # The reporter installs from the first collection — Crystal's own handler
  # discards anything installed at `GC.init` — so take one before planting.
  GC.collect

  # The holder must be allocated *before* the block it points at is freed, and
  # must stay live across the fault. A plain local keeps it rooted on the stack.
  holder = GC.malloc(64)
  block = GC.malloc(256)

  case arm
  when "heap-holder"
    (holder.as(UInt8*) + HOLDER_OFFSET).as(UInt64*).value = block.address
    STDERR.puts "planted holder 0x#{holder.address.to_s(16)} at +#{HOLDER_OFFSET} -> block 0x#{block.address.to_s(16)}"
  when "stack-holder", "no-heap-holder"
    # Nothing in the heap points at it. The two arms differ only in what they
    # assert: one that a stack slot is named, the other that the heap count is 0.
    STDERR.puts "planted no heap holder, block 0x#{block.address.to_s(16)}"
  end

  GC.free(block)

  # Read the freed block's first word — the tagged poison, carrying the block's
  # own address — and dereference it. That is the real shape: non-canonical, so
  # the kernel reports `si_addr` 0 and the poison is found in a register.
  poison = Pointer(UInt64).new(block.address).value
  Pointer(UInt64).new(poison).value = 1_u64
  # Keep the holder alive past the fault so the search can find it.
  Gcry::Roots.keep_alive(holder)
  exit 0
end

ARGV.each do |arg|
  if arg =~ /--child=(.+)/
    run_child($1)
  end
end

control = ARGV.includes?("--control")
puts "=== use-after-free holders ==="
puts "mode: #{control ? "control (GCRY_POISON_HOLDERS unset; no holder line may appear)" : "hold (search on)"}"

exe = Process.executable_path.not_nil!
failures = [] of String

["heap-holder", "stack-holder", "no-heap-holder"].each do |arm|
  env = control ? {"GCRY_SEGV_REPORT" => "1", "GCRY_POISON_TAG" => "1"} : {"GCRY_POISON_HOLDERS" => "1"}
  captured = IO::Memory.new
  Process.run(exe, ["--child=#{arm}"], env: env, output: captured, error: captured)
  text = captured.to_s

  if control
    if text.includes?("holders —")
      failures << "#{arm}: the knob is off but the search still ran"
    else
      puts "#{arm}: no holder line, as required"
    end
    next
  end

  unless text.includes?("gcry: holders — looking for words pointing into")
    failures << "#{arm}: the search did not run at all. What it said:\n#{text.lines.first(8).join("\n")}"
    next
  end

  case arm
  when "heap-holder"
    planted = text.lines.find(&.starts_with?("planted holder "))
    unless planted
      failures << "#{arm}: the child did not report what it planted"
      next
    end
    addr = planted.split(' ')[2]
    named = text.includes?("holders — heap: block #{addr} ")
    puts "#{arm}: #{named ? "named" : "NOT named"} the planted holder at #{addr}"
    unless named
      failures << "#{arm}: the heap search did not name #{addr}. What it said:\n" +
                  text.lines.select(&.includes?("holders")).join("\n")
    end
  when "stack-holder"
    named = text.includes?("holders — stack: ")
    puts "#{arm}: #{named ? "named" : "NOT named"} a stack slot"
    unless named
      failures << "#{arm}: nothing was found on any stack, though the faulting frame holds it. " \
                  "What it said:\n" + text.lines.select(&.includes?("holders")).join("\n")
    end
  when "no-heap-holder"
    clean = text.includes?("holders — heap: 0 word(s)")
    puts "#{arm}: heap section #{clean ? "reports 0, as required" : "reported a holder that was never planted"}"
    unless clean
      failures << "#{arm}: the heap search found something with nothing planted — it is matching the " \
                  "freed block on itself, or walking FREE blocks. What it said:\n" +
                  text.lines.select(&.includes?("holders")).join("\n")
    end
  end
end

if failures.empty?
  puts
  if control
    puts "ok — with the knob off no holder line appears, so the other run's holders are attributable " \
         "to the search and not to something the crash report always said"
  else
    puts "ok — a planted heap holder is named by address, a stack-only holder is found on the stack, " \
         "and a block nobody holds reports zero"
  end
  exit 0
else
  puts
  failures.each { |f| STDERR.puts "FAIL: #{f}" }
  exit 1
end
