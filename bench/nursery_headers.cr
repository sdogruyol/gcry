# Nursery + old HTTP::Headers Hash regression (Phase 4 / process GC).
#
# OverflowError/SEGV in HTTP keep-alive Hash lookup when minor GC swept nursery
# String keys that lived only inside an old Hash.@entries blob. Auto-layouts
# skip `Hash(HTTP::Headers::Key, …)` (`src/gcry/layout.cr`); precise
# registration is the walk that keeps those keys, and a KIND_HASH layout that
# noscans @entries without walking them is the pre-fix shape.
#
# Until 2026-09-20 this was a hollow CI step on the compile default:
# `Heap#nursery_enabled=` is a no-op without `-Dgcry_block_headers`, so
# `minor_collect` returned immediately and the keys were string literals
# sitting on the stack. Both arms would have stayed green through a broken
# walk. The green arm now requires a live nursery, a hash layout that walks
# keys, and a nursery-allocated name reachable only through the Hash
# (class-var pin, minor without a stack scan). `--disabled` installs the
# noscan-without-walk layout and requires that name to vanish.
#
# Build: crystal build -Dgc_none -Dgcry_block_headers bench/nursery_headers.cr -o bin/nursery_headers
# Run:   ./bin/nursery_headers
#        ./bin/nursery_headers --disabled
#
# Dropping `-Dgcry_block_headers` from the green arm: exit 64 (nursery never
# on). Dropping the zeroed key/value walk from `--disabled`: exit 64 (the
# layout still walks). Either way the gate goes red rather than hiding.

{% unless flag?(:gc_none) %}
  {% raise "nursery_headers requires -Dgc_none (gcry as process GC)" %}
{% end %}

require "http"
require "../src/gcry"

alias HeaderValue = String | Array(String)
alias HeaderHash = Hash(HTTP::Headers::Key, HeaderValue)

HEAP     = Gcry.default_heap.not_nil!
DISABLED = ARGV.includes?("--disabled")

# Stack residue kept the young name alive on CI (`X-Nurs-*` survived
# `--disabled`). A class var is a static root, so the minor can skip the
# stack and the Hash walk is the only path to the nursery key.
class Pin
  class_property headers : HTTP::Headers?
end

def install_broken_hash_layout : Nil
  scan = StaticArray(UInt16, 1).new(0)
  noscan = StaticArray(UInt16, 2).new(0)
  noscan[0] = UInt16.new(offsetof(HeaderHash, @indices))
  noscan[1] = UInt16.new(offsetof(HeaderHash, @entries))
  bytes = instance_sizeof(HeaderHash).to_u64
  rounded, _ = Gcry::SizeClasses.fit(bytes)
  Gcry::Layout.install_full(
    HeaderHash.crystal_instance_type_id,
    scan.to_unsafe, 0,
    noscan.to_unsafe, 2,
    rounded.to_u32, bytes.to_u32, Gcry::Layout::KIND_HASH,
    UInt16.new(offsetof(HeaderHash, @entries)),
    UInt16.new(offsetof(HeaderHash, @indices)),
    UInt16.new(offsetof(HeaderHash, @indices_size_pow2)),
    UInt16.new(sizeof(Hash::Entry(HTTP::Headers::Key, HeaderValue))),
    0_u16, 0_u16, # key_off, key_bytes — the pre-fix miss
    0_u16, Gcry::Layout::VALUE_MODE_NONE, 0_u16,
    UInt16.new(offsetof(HeaderHash, @size)),
    UInt16.new(offsetof(HeaderHash, @deleted_count)),
    UInt16.new(offsetof(HeaderHash, @block)),
    UInt16.new(sizeof((HeaderHash, HTTP::Headers::Key -> HeaderValue)?))
  )
end

@[NoInline]
def plant_young_header(headers : HTTP::Headers) : Nil
  name = String.build { |io| io << "X-Nurs-" << Random.rand(1_000_000) }
  val = String.build { |io| io << "young-" << Random.rand(1_000_000) }
  headers[name] = val
end

def header_names(headers : HTTP::Headers) : Array(String)
  names = [] of String
  headers.each { |k, _| names << k }
  names
end

old_soft = HEAP.soft_dirty_max_pct
old_nursery = HEAP.nursery_enabled

begin
  HEAP.nursery_enabled = true
  HEAP.soft_dirty_max_pct = 0 # force scan_object_for_nursery fallback

  unless HEAP.nursery_enabled
    STDERR.puts "nursery_headers: nursery did not enable (headerless compile default, or GCRY_DISABLE_NURSERY). Build with -Dgcry_block_headers."
    exit 64
  end
  unless HEAP.layout_precise
    STDERR.puts "nursery_headers: layout_precise is off; this arm is the Hash walk, not conservative chase."
    exit 64
  end

  if DISABLED
    install_broken_hash_layout
  else
    Gcry.register_hash(HTTP::Headers::Key, HeaderValue)
  end

  entry = Gcry::Layout.entry_for(HeaderHash.crystal_instance_type_id)
  unless entry && entry.hash?
    STDERR.puts "nursery_headers: Hash(HTTP::Headers::Key, …) has no KIND_HASH layout"
    exit 64
  end
  walks_keys = entry.hash_key_off != 0 || entry.hash_key_bytes != 0
  walks_values = entry.hash_value_mode != Gcry::Layout::VALUE_MODE_NONE
  if DISABLED
    if walks_keys || walks_values
      STDERR.puts "--disabled needs a KIND_HASH layout that does not walk keys or values: without that this arm would require the young name to vanish while the walk is still marking it."
      exit 64
    end
  else
    unless walks_keys
      STDERR.puts "nursery_headers: Hash layout does not walk keys; green would pass on conservative chase."
      exit 64
    end
  end

  headers = HTTP::Headers.new
  Pin.headers = headers
  headers["Connection"] = "keep-alive"
  GC.collect
  plant_young_header(headers)
  HEAP.clear_stack(1_u64 << 20)
  # Stack off: the pin is a static root, the Hash is old, the young name
  # lives only in @entries. A leftover word on this frame is not a root.
  HEAP.minor_collect(scan_stack: false)
  GC.collect

  begin
    unless headers["Connection"] == "keep-alive"
      STDERR.puts "nursery_headers: Connection lost"
      exit 1
    end
    young = header_names(headers).find { |k| k.starts_with?("X-Nurs-") }
    if DISABLED
      if young
        STDERR.puts "nursery_headers --disabled: young key survived a noscan-without-walk layout: #{young}"
        exit 1
      end
    else
      unless young
        STDERR.puts "nursery_headers: X-Nurs-* lost after minor"
        exit 1
      end
      unless HTTP.keep_alive?(HTTP::Request.new("GET", "/", headers))
        STDERR.puts "nursery_headers: keep_alive? false"
        exit 1
      end
    end
  rescue ex
    if DISABLED
      # A dangling Hash entry is the pre-fix SEGV/OverflowError. That is a red
      # arm hit, not a harness bug.
      STDERR.puts "nursery_headers --disabled: #{ex.class}: #{ex.message}"
    else
      STDERR.puts "nursery_headers: #{ex.class}: #{ex.message}"
      exit 1
    end
  end
ensure
  HEAP.soft_dirty_max_pct = old_soft
  HEAP.nursery_enabled = old_nursery
end

puts DISABLED ? "nursery_headers disabled ok" : "nursery_headers ok"
