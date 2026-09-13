# Does the crash report name a released range that sits outside the heap span?
#
# `GCRY_UNMAP_GUARD=1` keeps a released chunk mapped as `PROT_NONE` and records
# its identity — base, size, release path, collection, the first user word, how
# many blocks were still allocated — precisely so a fault into it reads as "this
# is the memory gcry gave back" instead of "some address".
#
# The report asked that question only *after* `in_heap_span?`, and a released
# chunk **shrinks the span**: release the topmost chunk and its address is above
# `heap_span_hi` from then on. So the faults the guard exists to name fell into
# the out-of-span branch and were reported as
#
#   outside gcry's heap span [...] — never a gcry allocation, so a swept object
#   is not the explanation
#
# which excludes the mechanism by name. Seen on 2026-09-13 under load, twice in
# a row, on `make thread-churn-uaf`'s guarded arm: SIGSEGV 3.8 MB above the span
# end, with the guard engaged and the ledger holding the answer.
#
# This is the control for that. Two arms, both faulting into a range gcry
# released, and the report must name the release in both:
#
#   bin/released_range_report    # fault into a chunk gcry released, under the guard
#
# The child faults on purpose; the parent reads its report.
#
# One arm, and the missing one is worth writing down: a *synthetic* release
# outside the span could not be built here. Three attempts failed for three
# different reasons, each of them a fact about this collector. A burst of
# size-class chunks releases chunks that live ones bracket, so the span covers
# them from both sides. A large object is released to the **large cache**, not
# to the kernel, and the adaptive retain policy resets the retain budget each
# major, so `large_cache_retain = 0` does not survive. And a harness that
# *remembers the address* to poke it keeps the object alive by doing so: a
# `UInt64` in a live stack slot is indistinguishable from a pointer to a
# conservative scan, which is why the first attempts reported `guard slots
# used: 0` — the harness was rooting the thing it wanted released, and masking
# the value did not help because the allocation path holds it too.
#
# So the out-of-span half is defended by the code path this arm shares with it
# — one helper, asked from both branches — and by the sighting that produced it,
# which will now print the named line instead of excluding the mechanism.

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "released_range_report requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Size-class chunks, not a large object: a 3 MB `GC.malloc` goes to the large
# cache and is retained rather than released, so the first version of this
# harness never faulted at all. Empty size-class chunks *are* released on Linux
# by default, and that is the path the churn gate faults on.
PER_CHUNK = 8 * 1024
COUNT     = 512
# Its own mmap, above everything mapped so far.
BIG = 3 * 1024 * 1024

@[NoInline]
def run_child(in_span : Bool) : NoReturn
  # The reporter installs from the first collection, not from `GC.init`.
  GC.collect

  # Addresses as integers, in an atomic array: gcry never scans it, so nothing
  # here keeps the blocks alive after the references are dropped.
  addrs = Array(UInt64).new(COUNT, 0_u64)
  refs = Array(Pointer(Void)).new(COUNT, Pointer(Void).null)
  heap0 = Gcry.default_heap.not_nil!
  if in_span
    COUNT.times do |i|
      p = GC.malloc(PER_CHUNK)
      refs[i] = p
      addrs[i] = p.address
    end
  else
    # One large object instead of a burst of size-class chunks, because the
    # out-of-span arm needs the released range to be the *top* mapping and to
    # stay the top: a large object gets its own mmap, which the kernel places
    # above everything mapped so far, and releasing it drops `heap_span_hi`
    # below it. The size-class burst could not produce that — its chunks sit
    # among live ones, and the span covered them from both sides.
    #
    # The large cache would otherwise retain the chunk on a freelist instead of
    # releasing it, which is why the first version of this harness never
    # faulted at all: the memory was still mapped and writable.
    heap0.large_cache_retain = 0_u64
    big = GC.malloc(BIG)
    refs[0] = big
    addrs[0] = big.address
    # Both copies, and the local matters most: a pointer left in a live stack
    # slot is a root under a conservative scan, so the chunk never dies and the
    # guard records nothing. The first version of this arm left `big` set and
    # reported `guard slots used: 0` — the harness was rooting the thing it
    # wanted released.
    refs[0] = Pointer(Void).null
    big = Pointer(Void).null
  end
  COUNT.times { |i| refs[i] = Pointer(Void).null }

  # The first sweep frees the blocks, the second releases the chunks they
  # emptied — and under the guard the addresses stay reserved as PROT_NONE.
  GC.collect
  GC.collect

  heap = Gcry.default_heap.not_nil!

  # Nothing below this line may allocate until the poke, and that is the whole
  # difficulty of the out-of-span arm: `heap_span_hi` is the top of the *live*
  # chunks, the guard keeps the released range's address reserved so no new
  # chunk can reuse it, and therefore any allocation after the release maps
  # above the range and puts it back inside the span. Even a `puts` does it.
  # So the selection reads the span, walks the recorded addresses and asks the
  # ledger — tuples and integers, no heap — and pokes immediately. The arm
  # reports through the exit code instead of printing: 2 means it found nothing
  # on the side it wanted, which is inconclusive rather than passing.
  lo, hi = heap.heap_span_lo, heap.heap_span_hi
  pick = 0_u64
  i = 0
  while i < COUNT
    a = addrs[i]
    i += 1
    next if a == 0
    next unless heap.guarded_release_at(a)
    next if (a >= lo && a < hi) != in_span
    pick = a
    break
  end

  if pick == 0
    STDERR.puts "INCONCLUSIVE no guarded release #{in_span ? "inside" : "outside"} the span"
    STDERR.puts "span [0x#{lo.to_s(16)}, 0x#{hi.to_s(16)})"
    shown = 0
    addrs.each do |a|
      next if a == 0
      g = heap.guarded_release_at(a)
      STDERR.puts "  addr 0x#{a.to_s(16)} guarded=#{!g.nil?} inside=#{a >= lo && a < hi}"
      shown += 1
      break if shown >= 4
    end
    STDERR.puts "  guard slots used: #{heap.guard_slots_used}, guard on: #{heap.unmap_guard?}"
    exit 2
  end
  Pointer(UInt64).new(pick + 64).value = 1_u64
  exit 0
end

ARGV.each do |arg|
  run_child(arg == "--child-in-span") if arg.starts_with?("--child")
end

exe = Process.executable_path.not_nil!
failures = [] of String
puts "=== does the report name a released range outside the span? ==="

{"guarded release" => "--child-in-span"}.each do |name, flag|
  captured = IO::Memory.new
  Process.run(exe, [flag],
    env: {"GCRY_UNMAP_GUARD" => "1", "GCRY_SEGV_REPORT" => "1"},
    output: captured, error: captured)
  text = captured.to_s
  if text.includes?("INCONCLUSIVE")
    failures << "#{name}: the workload produced no guarded release on that side of the span, so " \
                "this arm tested nothing. What it said:\n" + text.lines.first(6).join("\n")
    puts "#{name}: INCONCLUSIVE"
    next
  end
  named = text.includes?("gcry RELEASED")
  excluded = text.includes?("never a gcry allocation, so a swept object is not the explanation")
  out_of_span = text.includes?("in_span=false")
  puts "#{name}: #{named ? "named the release" : "did NOT name it"}" \
       "#{out_of_span ? " (address outside the span)" : " (address inside the span)"}"
  next if named
  failures << "#{name}: the report did not name the released range" +
              (excluded ? " and excluded a swept object by name" : "") +
              ". What it said:\n" + text.lines.select(&.starts_with?("gcry:")).first(4).join("\n")
end

puts
if failures.empty?
  puts "ok — a fault in a range gcry released is named as such: base, size, release path,"
  puts "the collection it happened at, the first user word and how many blocks were still"
  puts "allocated. Both branches of the report ask one helper for that, which is the fix:"
  puts "the out-of-span branch never asked, and releasing a chunk is exactly what moves"
  puts "its address out of the span."
  exit 0
end
failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
