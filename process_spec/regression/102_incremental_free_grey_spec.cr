require "../../src/gcry"
require "spec"

# `GC.free` of a block an incremental cycle (`GCRY_INCREMENTAL=1`,
# `collect_a_little`) has marked and not yet scanned: grey, its entry on the
# mark stack, which the free does not touch. The slice that popped the entry
# scanned whatever was at its address by then:
#
# - *unmapped*: a 4 MiB block, its chunk unmapped by the free's cache trim.
#   On the header layout `scan_object` read the entry's header before any
#   chunk lookup and the slice died on unmapped memory (SIGSEGV at the
#   header); headerless resolved the chunk first and skipped it.
# - *cached*: a 40 000-byte block, its chunk kept in the large cache. Its dead
#   payload was traced, and an object Z only it had pointed to was kept
#   through the cycle.
# - *small*: a 16 000-byte size-class block, the same.
#
# The incremental drain (`Heap#mark_loop_budget`) now resolves each entry
# first and scans it only if it still names an allocated block's start in a
# chunk of its kind; the stop-the-world mark is untouched.
#
# The construction, deterministic: the block G is held by a class variable,
# with Z (64 bytes, atomic) stored a word into a page of G's payload past its
# first, so the free's own writes leave that page clean under the barrier.
# `collect_a_little(0)` runs the begin stop and a slice of no work: G is
# marked and its entry still on the mark stack (checked), Z unmarked
# (checked; a false root marking Z runs that cycle out and builds again, at
# most three times). Then the class variable is cleared, G freed (and for
# *unmapped* the cache trimmed; its address checked in no chunk and in no
# mapping of `/proc/self/maps` — when something has mapped it again, about
# 1 run in 2 000, that cycle is run out and the window built again, at most
# three times; *cached*'s chunk checked still indexed), and the cycle runs
# out, without the lost-barrier full collection (which clears the mark
# stack and would pass any arm). Nothing allocates between the last check
# and the slices; another thread can still map the address meanwhile (an
# 8 MiB anonymous mapping, about 1 run in 1 500), and when the control arm
# survives with G's address mapped it builds the window again, at most three
# times.
#
# The fixed arm must count the entry skipped
# (`Heap.inc_stale_entries_skipped`) and, for *cached* and *small*, find Z
# swept. The control arm (`Heap.inc_scan_checks_entries = false`, the code
# before) must find Z kept; for *unmapped* it must die of SIGSEGV at G's
# header on the header layout, and headerless, where the code before was
# already safe, prints the skip mark. Each arm in a process of its own. The
# cycle runs on the mprotect barrier, as regressions 85, 91, 95 and 100 do:
# Linux only; elsewhere the child prints `FREEGREY102_SKIP_MARK` and the
# parent asks for no mark.
# `bench/log/linux/2026-11-03-incremental-free-grey/FINDINGS.md`.

private FREEGREY102_SKIP_MARK    = "freegrey102: this heap cannot reach the window, skipped"
private FREEGREY102_FIXED_MARK   = "freegrey102: the freed block's entry was skipped"
private FREEGREY102_CONTROL_MARK = "freegrey102: the control arm scanned the freed block"
private FREEGREY102_POP_MARK     = "freegrey102: G grey, its header at 0x"

private FREEGREY102_WINDOWS = {"unmapped", "cached", "small"}

private class FreeGrey102Roots
  class_property block : Void* = Pointer(Void).null
  # Blocks of an attempt a false root spoiled, held so the next is elsewhere.
  class_property spares = [] of Void*
  class_property sink = 0_u64
end

class Gcry::MarkStack
  def freegrey102_holds?(header : UInt64) : Bool
    entries = @base.as(UInt64*)
    @size.times { |i| return true if entries[i] & Gcry::Heap::MARK_ENTRY_ADDR_MASK == header }
    false
  end
end

class Gcry::Heap
  # The header address of the allocated block at *pointer*, or 0.
  def freegrey102_header(pointer : Void*) : UInt64
    found = find_object_with_chunk(pointer)
    found ? found[0].address : 0_u64
  end

  # Whether the mark has reached the object at *pointer*; nil when it is not
  # an allocated block.
  def freegrey102_marked?(pointer : Void*) : Bool?
    header = find_object(pointer)
    return nil unless header
    heap_marked?(header)
  end

  def freegrey102_on_mark_stack?(header : UInt64) : Bool
    @mark_stack.freegrey102_holds?(header)
  end
end

private def freegrey102_say(text : String) : Nil
  STDOUT.puts text
  STDOUT.flush
end

private def freegrey102_bytes(window : String) : Int32
  case window
  when "unmapped" then 4 * 1024 * 1024
  when "cached"   then 40_000
  else                 16_000
  end
end

# Allocates G, held by the class variable, and (but for *unmapped*) Z,
# stored a word into the first page wholly inside G's payload past the one
# its start is on. Returns G's and Z's addresses complemented, so no frame of
# this one keeps them.
@[NoInline]
private def freegrey102_build(window : String) : {UInt64, UInt64}
  bytes = freegrey102_bytes(window)
  g = GC.malloc(bytes).as(Void**)
  z_inv = 0_u64
  unless window == "unmapped"
    z = GC.malloc_atomic(64).as(UInt8*)
    64.times { |i| z[i] = 0x5A_u8 }
    page = (g.address &+ 4096) & ~4095_u64
    fail "no whole page inside G" if page &+ 4096 > g.address &+ bytes
    g[(page &- g.address) // 8 &+ 8] = z.as(Void*)
    z_inv = ~z.address
  end
  FreeGrey102Roots.block = g.as(Void*)
  {~g.address, z_inv}
end

# The begin stop scans this thread's stack from the collector's frames up;
# what `freegrey102_build`'s frame left there is zeroed first.
@[NoInline]
private def freegrey102_scrub_stack : Nil
  buf = uninitialized StaticArray(UInt64, 8192)
  words = buf.to_unsafe
  8192.times { |i| words[i] = 0_u64 }
  FreeGrey102Roots.sink = words[0] &+ words[8191]
end

private def freegrey102_finish(heap : Gcry::Heap) : Nil
  lost = heap.inc_barrier_lost_collections
  slices = 0
  until heap.collect_a_little(4096)
    slices += 1
    fail "the cycle did not finish in #{slices} slices" if slices > 100_000
  end
  heap.inc_barrier_lost_collections.should eq(lost)
end

# The `/proc/self/maps` line of the mapping holding *address*, if any.
private def freegrey102_mapping(address : UInt64) : String?
  File.each_line("/proc/self/maps") do |line|
    lo, hi = line.split(' ', 2)[0].split('-').map(&.to_u64(16))
    return line if address >= lo && address < hi
  end
  nil
end

private def freegrey102_heap : Gcry::Heap?
  {% if flag?(:linux) %}
    heap = Gcry.default_heap
    heap.disable
    heap.prefer_mprotect_barrier = true
    heap
  {% else %}
    nil
  {% end %}
end

# Runs one window: builds it, frees G grey, runs the cycle out. Returns the
# entries the cycle skipped, whether Z is still allocated and G's header
# address; nil after saying why it skipped.
@[NoInline]
private def freegrey102_window(heap : Gcry::Heap, window : String) : {UInt64, Bool, UInt64}?
  GC.collect
  # Nothing cached for G to be given, so it is a mapping of its own.
  heap.trim_large_cache(0_u64, defer: false)
  g_inv = z_inv = 0_u64
  header = 0_u64
  attempt = 0
  loop do
    attempt += 1
    g_inv, z_inv = freegrey102_build(window)
    freegrey102_scrub_stack
    # The begin stop and a slice of no marking: every entry it pushed waits.
    heap.collect_a_little(0) && fail "the cycle finished in its first slice"
    unless heap.incremental_in_progress? && heap.barrier_backend_name == "mprotect"
      freegrey102_say("#{FREEGREY102_SKIP_MARK}: no incremental cycle on the mprotect barrier")
      return nil
    end
    header = heap.freegrey102_header(Pointer(Void).new(~g_inv))
    fail "G is not an allocated block after the begin slice" if header == 0
    fail "G's entry is not on the mark stack: the window was not reached" unless heap.freegrey102_on_mark_stack?(header)
    unless z_inv == 0
      z_marked = heap.freegrey102_marked?(Pointer(Void).new(~z_inv))
      fail "Z is not an allocated block after the begin slice" if z_marked.nil?
      if z_marked
        # A false root reached Z in the begin stop. Run the cycle out and
        # build again, Z held so the next is elsewhere.
        fail "Z was marked in the begin slice #{attempt} times: the window was not reached" if attempt == 3
        freegrey102_say("freegrey102: a false root marked Z, attempt #{attempt} run out and built again")
        FreeGrey102Roots.spares << Pointer(Void).new(~z_inv)
        freegrey102_finish(heap)
        next
      end
    end
    # Said before the free: nothing may allocate between the check that G's
    # address is unmapped and the slice that pops its entry, or a chunk could
    # be mapped there.
    freegrey102_say("#{FREEGREY102_POP_MARK}#{header.to_s(16)}, freeing G and running the cycle out")
    FreeGrey102Roots.block = Pointer(Void).null
    g = Pointer(Void).new(~g_inv)
    GC.free(g)
    heap.find_object(g).should be_nil
    case window
    when "unmapped"
      heap.trim_large_cache(0_u64, defer: false)
      fail "G's chunk is still indexed: the window was not reached" if heap.chunk_containing_public?(g.address)
      if freegrey102_mapping(header)
        # Something mapped G's address again before the check (1 run in
        # about 2 000): no window. Run the cycle out and build again.
        fail "G's address was mapped again #{attempt} times: the window was not reached" if attempt == 3
        freegrey102_say("freegrey102: G's address was mapped again, attempt #{attempt} run out and built again")
        freegrey102_finish(heap)
        next
      end
    when "cached"
      fail "G's chunk left the cache: the window was not reached" unless heap.chunk_containing_public?(g.address)
    end
    break
  end

  skipped = Gcry::Heap.inc_stale_entries_skipped
  freegrey102_scrub_stack
  freegrey102_finish(heap)
  skipped = Gcry::Heap.inc_stale_entries_skipped &- skipped
  z_alive = z_inv != 0 && !heap.find_object(Pointer(Void).new(~z_inv)).nil?
  {skipped, z_alive, header}
end

private def freegrey102_child(window : String, fixed : Bool) : Nil
  return freegrey102_say(FREEGREY102_SKIP_MARK) unless heap = freegrey102_heap
  Gcry::Heap.inc_scan_checks_entries = false unless fixed
  skipped = 0_u64
  z_alive = false
  attempt = 0
  loop do
    attempt += 1
    result = freegrey102_window(heap, window)
    return if result.nil?
    skipped, z_alive, header = result
    {% if flag?(:gcry_block_headers) %}
      # The code before read G's header, unmapped, and died. It survives
      # when another thread mapped the address meanwhile (an 8 MiB anonymous
      # mapping, about 1 run in 1 500 here): no window. Build it again.
      if !fixed && window == "unmapped" && (mapping = freegrey102_mapping(header))
        fail "G's address was mapped before the pop #{attempt} times: the window was not reached" if attempt == 3
        freegrey102_say("freegrey102: #{mapping.strip} took G's address before the slice, attempt #{attempt} built again")
        next
      end
    {% end %}
    break
  end
  freegrey102_say("freegrey102 #{window}: entries skipped=#{skipped} Z alive=#{z_alive}")
  if fixed
    skipped.should be > 0
    z_alive.should be_false
    freegrey102_say("#{FREEGREY102_FIXED_MARK} (#{window})")
  elsif window == "unmapped"
    {% if flag?(:gcry_block_headers) %}
      fail "the control arm's slice read G's header, unmapped, and survived"
    {% else %}
      # Headerless the code before resolved the chunk first and found none.
      freegrey102_say("#{FREEGREY102_SKIP_MARK}: headerless reads no header before the chunk lookup")
    {% end %}
  else
    skipped.should eq(0)
    z_alive.should be_true
    freegrey102_say("#{FREEGREY102_CONTROL_MARK} (#{window})")
  end
end

describe "Regression: the incremental mark skips the entry of a block freed grey" do
  FREEGREY102_WINDOWS.each do |window|
    {"fixed", "control"}.each do |arm|
      it "#{window}: #{arm} arm in a process of its own" do
        captured = IO::Memory.new
        env = {"GCRY_FREEGREY102_CHILD" => "#{window}-#{arm}"} of String => String?
        env["GCRY_DEBUG_INVARIANTS"] = nil if arm == "control"
        status = Process.run(Process.executable_path.not_nil!,
          ["-e", "freegrey102 child #{window}-#{arm}"],
          env: env, output: captured, error: captured)
        text = captured.to_s
        if arm == "control" && window == "unmapped" && text.includes?(FREEGREY102_POP_MARK) &&
           !text.includes?(FREEGREY102_SKIP_MARK)
          # The code before, header layout: the slice that pops G's entry
          # reads G's header, unmapped.
          fail "child #{status.inspect}, expected to die in the pop:\n#{text}" if status.success?
          header = text.split(FREEGREY102_POP_MARK).last.split(',', 2)[0].to_u64(16)
          at = text.match(/Invalid memory access \(signal 11\) at address 0x([0-9a-f]+)/)
          fail "child #{status.inspect}, no SIGSEGV report:\n#{text}" unless at
          fault = at[1].to_u64(16)
          fail "the fault at 0x#{fault.to_s(16)} is not G's header at 0x#{header.to_s(16)}:\n#{text}" unless fault >= header && fault < header + Gcry::BlockHeader::SIZE
          next
        end
        fail "child #{status.inspect}:\n#{text}" unless status.success?
        text.should contain("1 examples, 0 failures")
        unless text.includes?(FREEGREY102_SKIP_MARK)
          text.should contain(arm == "control" ? FREEGREY102_CONTROL_MARK : FREEGREY102_FIXED_MARK)
        end
      end
    end
  end

  FREEGREY102_WINDOWS.each do |window|
    {"fixed", "control"}.each do |arm|
      it "freegrey102 child #{window}-#{arm}" do
        next unless ENV["GCRY_FREEGREY102_CHILD"]? == "#{window}-#{arm}"
        freegrey102_child(window, arm == "fixed")
      end
    end
  end
end
