# Are the static roots resolved by `GC.init`, or by the first stopped world?
#
# `scan_static_roots` runs inside the pause. On Darwin the range cache was
# populated from there — `ensure_static_root_cache` walks dyld's image 0 and
# `push_range` calls `LibC.realloc` — so the first collection took dyld's data
# structures and the malloc arena while every other thread was suspended at an
# arbitrary point. That is a deadlock shape rather than a wrong-answer one: a
# thread suspended inside `malloc` holds the lock the `realloc` wants. Linux
# moved the walk into `GC.init`; Darwin could not follow, because doing so
# crashed before `main` (CI 33900305015).
#
# That crash is now attributed: two of `darwin_roots.cr`'s class variables had
# initialisers Crystal wraps in `__crystal_once`, and `__crystal_once` reaches
# `Fiber.current` -> `Thread.new` -> `Fiber.new` -> `Fiber.@@fibers.push` while
# `Fiber.init` has not run. `bench/darwin_static_root_once.cr` is the arm for
# the mechanism; this one is the arm for the *effect*.
#
# Arms:
#
#   default    the resolve must already have happened when user code starts,
#              and no collection may have run yet. `resolves>=1` with
#              `collections==0` is the gate: it separates "GC.init walked dyld"
#              from "the first pause walked dyld", which are indistinguishable
#              from any later vantage point. Measured on Apple M2 Pro /
#              Darwin 25.6.0 / Crystal 1.21.0: resolves=1 collections=0.
#
#   --lazy     `GCRY_STATIC_ROOT_LAZY=1` skips the eager call, restoring the
#              ordering that shipped. Must read `resolves=0` at the same point
#              and reach 1 only after a collection — i.e. the walk happened
#              inside the pause. **This is the red arm.**
#
# Both arms also require a graph rooted only through a class variable to
# survive collections with its checksum intact, and `static_root_bytes` to be
# non-zero. Those do not discriminate — they pass either way — and saying so
# is the point: they are here so that "fixing" the ordering by dropping the
# root range altogether cannot read green.
#
#   crystal build -Dgc_none bench/darwin_static_root_init.cr -o bin/darwin_static_root_init
#   bin/darwin_static_root_init
#   GCRY_STATIC_ROOT_LAZY=1 bin/darwin_static_root_init --lazy

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "darwin_static_root_init requires -Dgc_none (gcry as process GC)" %}
{% end %}

# Local variables, not constants, and that is the whole point of the file: a
# constant initialiser is `once`-guarded and therefore runs at its first
# *read*, not here. These have to be the first executable statements in user
# code, because the question is what the counters say before anything else
# happens.
resolves_at_start = Gcry::Platform.static_root_resolves
bytes_at_start = Gcry::Platform.static_root_bytes
collections_at_start = Gcry.default_heap.not_nil!.collections

# The graph the roots have to keep. Reachable only through `Holder.@@head`, so
# losing the static root range makes the whole chain unreachable.
class Node
  property nxt : Node?
  property tag : UInt64
  property fill : Slice(UInt64)

  def initialize(@tag : UInt64)
    @nxt = nil
    @fill = Slice(UInt64).new(24) { |i| @tag &* (i.to_u64 &+ 1) }
  end

  def sum : UInt64
    s = @tag
    @fill.each { |w| s = (s &* 31) &+ w }
    s
  end
end

class Holder
  # `nil` is a simple literal, so this one is not `once`-guarded either — but
  # it does not have to be: nothing reads it before `init_runtime`.
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

  # Folded in traversal order, so build and re-check agree by construction.
  def self.checksum : UInt64
    total = 1_u64
    n = 0
    node = @@head
    while node
      total = (total &* 131) &+ node.sum
      n += 1
      node = node.nxt
    end
    (total &* 1_000_003) &+ n.to_u64
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

NODES = 512

lazy_arm = ARGV.includes?("--lazy")
heap = Gcry.default_heap.not_nil!
failures = [] of String

puts "darwin_static_root_init: arm=#{lazy_arm ? "--lazy (GCRY_STATIC_ROOT_LAZY=1)" : "default"}"
puts "  at start of user code: resolves=#{resolves_at_start} " \
     "collections=#{collections_at_start} static_root_bytes=#{bytes_at_start}"

# Harness precondition. If startup collected, "resolves at start" no longer
# separates the two orderings and a green here would mean nothing.
if collections_at_start != 0
  failures << "harness: #{collections_at_start} collections ran before user code, so " \
              "`resolves` at start cannot tell an eager resolve from a lazy one"
end

if lazy_arm
  unless ENV["GCRY_STATIC_ROOT_LAZY"]? == "1"
    failures << "harness: --lazy without GCRY_STATIC_ROOT_LAZY=1 — the arm measures nothing"
  end
  if resolves_at_start != 0
    failures << "--lazy: resolves=#{resolves_at_start} at start of user code, expected 0. " \
                "The knob is supposed to restore the pre-2026-09-04 ordering, and did not"
  end
  if bytes_at_start != 0
    failures << "--lazy: static_root_bytes=#{bytes_at_start} with nothing resolved yet"
  end
else
  if resolves_at_start == 0
    failures << "default: resolves=0 at start of user code — the first walk of the " \
                "static roots is still happening inside the first stopped world, " \
                "where it takes dyld and the malloc arena with every thread suspended"
  end
  if bytes_at_start == 0
    failures << "default: static_root_bytes=0 after an eager resolve — the walk ran " \
                "and found nothing, so no class variable is a root"
  end
end

Holder.build(NODES)
built = Holder.count
expected = Holder.checksum

heap.collect
after_one = Gcry::Platform.static_root_resolves

3.times { heap.collect }
resolves_after = Gcry::Platform.static_root_resolves
bytes_after = Gcry::Platform.static_root_bytes
got = Holder.checksum
survived = Holder.count

puts "  after 4 collections: resolves=#{resolves_after} (#{after_one} after the first) " \
     "static_root_bytes=#{bytes_after}"
puts "  live graph: built=#{built} survived=#{survived} checksum_match=#{got == expected}"

if lazy_arm
  if after_one == 0
    failures << "--lazy: still resolves=0 after a collection — `scan_static_roots` did " \
                "not resolve the cache either, so the knob broke the roots rather " \
                "than delaying them"
  end
else
  if resolves_after != resolves_at_start
    failures << "default: resolves went #{resolves_at_start} -> #{resolves_after} across " \
                "collections — the eager resolve is not being cached, so the pause " \
                "still pays for the walk"
  end
end

if survived != built
  failures << "live graph: #{built} nodes built, #{survived} reachable after 4 collections"
end
if got != expected
  failures << "live graph: checksum #{got} != #{expected} — a node rooted only through " \
              "a class variable was reclaimed or overwritten"
end
if bytes_after == 0
  failures << "static_root_bytes=0 after 4 collections — the root set is empty"
end

if failures.empty?
  puts "ok — #{lazy_arm ? "the red arm reads lazy" : "GC.init resolved the static roots before any collection"}"
  exit 0
end

failures.each { |f| STDERR.puts "FAIL: #{f}" }
exit 1
