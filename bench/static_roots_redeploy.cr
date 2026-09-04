# Is the BSS still a root range after the binary is replaced on disk?
#
# A redeploy links a new executable over the running one. The old inode stays
# mapped, and `/proc/self/maps` renames every line of it to `… (deleted)`; the
# program notices nothing, because nothing about its memory changed. The
# static-root parser refreshes its cache every `STATIC_ROOT_REFRESH_INTERVAL`
# majors, and a parser that recognised the executable's `.data` by comparing
# the pathname to `/proc/self/exe` — resolved once, before the rename — stopped
# recognising it at the first refresh after the deploy. With `.data` gone, the
# BSS adjacency test had nothing to be adjacent to, the root set collapsed to
# zero bytes, and everything held only by a class variable was swept.
#
# The roots now come from the executable's program headers via
# `dl_iterate_phdr`, read once at `GC.init`; nothing about them changes when
# the file is replaced. This harness does the redeploy to itself: it deletes
# its own binary, runs collections, and asks whether an array held only by a
# class variable is still whole.
#
# The child arm runs from a copy of the binary, so the file it deletes is its
# own and not the one the parent is about to report through.
#
#   crystal build -Dgc_none bench/static_roots_redeploy.cr -o bin/static_roots_redeploy
#   bin/static_roots_redeploy

require "../src/gcry"

{% unless flag?(:gc_none) %}
  {% raise "static_roots_redeploy requires -Dgc_none (gcry as process GC)" %}
{% end %}

{% unless flag?(:linux) %}
  {% raise "static_roots_redeploy is about /proc/self/maps; Linux only" %}
{% end %}

ENTRIES   = 1000
ROUNDS    =   20
DELETE_AT =    3

# The only reference to these strings is a class variable — like Kemal's
# `@@only_routes_tree`, which is where production noticed.
class Registry
  @@tree = Array(String).new

  def self.fill : Nil
    ENTRIES.times { |i| @@tree << "route-#{i}-" * 8 }
  end

  # Nil when whole, else the first index whose string is gone.
  def self.first_damage : Int32?
    @@tree.each_with_index do |s, i|
      return i unless s.starts_with?("route-#{i}-")
    end
    nil
  end
end

unless ARGV.includes?("--child")
  exe = Process.executable_path.not_nil!
  copy = "#{exe}.redeploy-child"
  File.copy(exe, copy)
  File.chmod(copy, 0o755)

  puts "=== static roots across a redeploy ==="
  captured = IO::Memory.new
  status = Process.run(copy, ["--child"], output: captured, error: captured)
  File.delete(copy) if File.exists?(copy)
  text = captured.to_s
  verdict = text.lines.find(&.starts_with?("child ")) || "(no verdict line)"
  puts "child: exit=#{status.exit_code?.inspect} #{verdict}"
  text.lines.select(&.starts_with?("gcry:")).each { |l| puts "  #{l}" }

  failures = [] of String
  failures << "the child did not exit cleanly (#{status.exit_code?.inspect})" unless status.success?
  failures << "the child never reported its verdict" unless text.includes?("child ok")
  failures << "the class-variable array lost entries after the binary was replaced" if text.includes?("damage=")
  failures << "the parse lost the executable's mappings (bss_lost > 0)" if text.includes?("bss_lost=") && !text.includes?("bss_lost=0 ")
  failures << "the child never confirmed the binary was gone" unless text.includes?("deleted=true")

  if failures.empty?
    puts
    puts "ok — the executable's .data and BSS stay root ranges after the file is replaced"
    exit 0
  else
    puts
    failures.each { |f| STDERR.puts "FAIL: #{f}" }
    exit 1
  end
end

Registry.fill
exe = Process.executable_path.not_nil!
deleted = false
damage = nil.as(Int32?)

ROUNDS.times do |round|
  junk = Array(String).new
  20_000.times { |i| junk << "junk#{i}" * 4 }
  if round == DELETE_AT
    File.delete(exe)
    deleted = !File.exists?(exe)
  end
  GC.collect
  damage ||= Registry.first_damage
end

puts "child deleted=#{deleted} bss_lost=#{Gcry::Platform.static_root_bss_lost} " \
     "root_bytes=#{Gcry::Platform.static_root_bytes}" \
     "#{damage ? " damage=#{damage}" : ""}"
puts(damage ? "child FAIL" : "child ok")
exit(damage ? 1 : 0)
