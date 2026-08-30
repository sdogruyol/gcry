# A `Hash(String, String)` handing back a null value.
#
# **This harness does not reproduce the defect, and should not be trusted to.**
# It crashed once, 1 of 8, with the production signature, and then 0 of 112
# across every arm that followed — plain, `SEGV_REPORT`, `RELEASE_LEDGER`, with
# and without `Gcry.register_hash(String, JSON::Any)`. One crash in 120 is not
# a rate, and the claim that it reproduced production was withdrawn.
#
# What did reproduce is the application itself, under a load whose routes
# answer 200 and take URL parameters — six runs, six deaths, against a Boehm
# build that survived the same load doing three times the work
# (`bench/log/linux/2026-08-24-acikturkiye-live-string-uaf/FINDINGS.md`).
# The file stays so the next person does not rebuild it and read its silence
# as an answer.
#
# acikturkiye faulted in production at `address 0x0`, in `String#empty?` reached
# from Kemal's `unescape_url_param`:
#
#     private def unescape_url_param(value : String)
#       value.empty? ? value : URI.decode(value)
#
#     private def parse_url
#       @url.each { |key, value| @url[key] = unescape_url_param(value) }
#     end
#
# `@url` is a `Hash(String, String)`. A null arriving out of `each` means a
# value slot that no longer holds the String it was given — the shape of an
# object collected while live, or of a page released under one.
#
# **2026-08-27:** a second production sighting at the same frame, this time at
# `0x4` — `@bytesize` of a null String, same shape — on 0.21.1, built
# `-Dpreview_mt -Dexecution_context`. The chunk-index insert defect fixed that
# day (`bench/log/linux/2026-08-27-thread-list-tripwire/FINDINGS.md`) produces
# exactly this: a mutator suspended mid-`index_insert_locked` hid the
# highest-addressed chunk from the collection's index reads, and every object
# in the hidden chunk lost its mark at once, whoever pointed at it. Whether it
# was *this* crash only production hours can say — a 30-minute local
# `wrk -t4 -c64` on the parameterised route did not reproduce on 0.21.1
# (268k requests clean), so the field rate is below what half an hour
# resolves. 0.21.2 carries the fix.
#
# **2026-08-29: a third sighting, and it closes the question the second one
# left open — the wrong way.** A different application (invidious, reported by
# fixju) on **0.21.3**, which carries the chunk-index fix, faulted at the same
# frame and the same address as the first: `0x0` in `String#empty?`
# (`string.cr:3015`), reached from `Routes::Feeds.rss_channel` — a route whose
# first two acts are `env.params.url["ucid"]` and
# `env.params.query["params"]?`, the same `Hash(String, String)` lookups
# Kemal's `unescape_url_param` walks.
#
# So the inference in the 0.21.2 release notes — "the fixed defect produces
# exactly that shape, so 0.21.2 is the build production should be on" — is
# **refuted for this frame**. It was labelled an inference at the time and the
# label was right. Two applications, three sightings, and the fix that was
# supposed to explain it is in the build that crashed.
#
# What the third sighting adds is the address. `0x0` is not a stale pointer
# into reused memory — a reused block holds somebody's data, not zeros. A value
# slot reading exactly zero is a page that has been handed back to the kernel
# and faulted in fresh, which points at the *release* paths rather than at the
# mark: empty-chunk release (Linux process default retains **nothing** —
# `GCRY_EMPTY_CHUNK_RETAIN=0`, `GCRY_LARGE_CACHE=0`), the dormant madvise, or
# the page-release walk. `GCRY_POISON_FREED=1` separates the two readings in
# one restart: a block that was freed and reused reads `0xdeadf2ee…` and faults
# non-canonically, a zeroed page still reads `0x0`.
#
# The app registers a *different* instantiation with gcry:
#
#     Gcry.register_hash(String, JSON::Any)
#
# `register_hash` marks that Hash's `@indices` and `@entries` noscan and walks
# its entries with recorded offsets instead. `Hash(String, String)` is not
# registered and keeps the conservative treatment. This asks whether registering
# one instantiation can cost another its values.
#
#   registered   the app's `register_hash(String, JSON::Any)` is made
#   plain        it is not
#
# Both arms must keep every value. A difference between them points at the
# registration; a failure in both points at the Hash path generally.
#
#   crystal build -Dgc_none bench/url_params_hash.cr -o bin/url_params_hash
#   bin/url_params_hash
require "../src/gcry"
require "json"
require "./bounded_child"

{% unless flag?(:gc_none) %}
  {% raise "url_params_hash requires -Dgc_none (gcry as process GC)" %}
{% end %}

WORKERS =    4
ROUNDS  =  150
PARAMS  =   12
CHURN   = 3000

class Verdict
  @@nil_values = Atomic(Int32).new(0)
  @@wrong = Atomic(Int32).new(0)

  def self.nil_value!
    @@nil_values.add(1)
  end

  def self.wrong!
    @@wrong.add(1)
  end

  def self.line : String
    "nil_values #{@@nil_values.get} wrong #{@@wrong.get}"
  end

  def self.bad? : Bool
    @@nil_values.get + @@wrong.get > 0
  end
end

if ARGV.includes?("--child")
  if ENV["URL_PARAMS_REGISTER"]? == "1"
    # Exactly what acikturkiye does at boot.
    Gcry.register_hash(String, JSON::Any)
    Gcry.register_layout(Array(JSON::Any))
  end

  threads = [] of Thread
  WORKERS.times do |w|
    threads << Thread.new do
      ROUNDS.times do |r|
        # A parsed URL param set, the way Kemal builds it.
        url = Hash(String, String).new
        PARAMS.times do |i|
          url["k#{w}_#{r}_#{i}"] = "v#{w}_#{r}_#{i}_#{"x" * (i * 3)}"
        end

        # Garbage between the build and the read, so a collection lands in
        # between — which is where the production crash sits.
        CHURN.times do
          j = Bytes.new(128)
          j[0] = 1_u8
        end

        # Kemal's `parse_url`: iterate and rewrite every value in place.
        url.each do |key, value|
          if value.nil?
            Verdict.nil_value!
            next
          end
          Verdict.wrong! unless value.starts_with?("v")
          url[key] = value.empty? ? value : value
        end

        # And read them back once more, the way a handler would.
        url.each_value do |value|
          if value.nil?
            Verdict.nil_value!
          elsif !value.starts_with?("v")
            Verdict.wrong!
          end
        end
      end
    end
  end
  threads.each(&.join)

  heap = Gcry.default_heap
  puts "child: #{Verdict.line} collections #{heap.collections}"
  exit(Verdict.bad? ? 1 : 0)
end

# ── Parent ───────────────────────────────────────────────────────────────────
exe = Process.executable_path.not_nil!
attempts = (ENV["URL_PARAMS_ATTEMPTS"]?.try(&.to_i?) || 8)

puts "=== Hash(String, String) values across collections ==="
puts "#{WORKERS} workers × #{ROUNDS} rounds × #{PARAMS} params, #{CHURN} dropped between build and read"
puts "#{attempts} attempts per arm"
puts ""

def run(exe : String, env, attempts : Int32) : {Int32, String?}
  bad = 0
  first = nil
  attempts.times do
    r = BoundedChild.run(exe, ["--child"], env, 300.seconds)
    unless r.ok
      bad += 1
      first ||= r.output.lines.find { |l| l.includes?("child:") || l.includes?("Invalid memory") }
    end
  end
  {bad, first}
end

reg_bad, reg_note = run(exe, {"URL_PARAMS_REGISTER" => "1"}, attempts)
puts "  registered (as the app does): #{reg_bad} of #{attempts}#{reg_note ? "\n     #{reg_note.strip}" : ""}"

plain_bad, plain_note = run(exe, {} of String => String, attempts)
puts "  plain:                        #{plain_bad} of #{attempts}#{plain_note ? "\n     #{plain_note.strip}" : ""}"
puts ""

if reg_bad == 0 && plain_bad == 0
  puts "ok — every value survived in both arms"
  exit 0
else
  STDERR.puts "FAIL: a Hash(String, String) lost values (registered #{reg_bad}, plain #{plain_bad} of #{attempts})"
  exit 1
end
