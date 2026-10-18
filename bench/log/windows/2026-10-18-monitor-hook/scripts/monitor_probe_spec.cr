# PROBE ONLY (branch probe/win-monitor-hook): after every example of the
# parent run, wait up to 1 s for the Monitor to start two more passes of its
# loop; print once when it stops doing so, and once when it starts again.
require "../src/gcry"
require "spec"
require "../bench/monitor_probe_lib"

module MonProbeSpec
  @@stalled = false
  @@n = 0
  @@enabled = !ARGV.includes?("-e")

  def self.after(desc : String) : Nil
    return unless @@enabled
    @@n += 1
    c0 = MonProbe.transfers
    deadline = Time.instant + 1.second
    until MonProbe.transfers > c0 + 1
      if Time.instant > deadline
        unless @@stalled
          @@stalled = true
          STDERR.puts "\nMONPROBE stalled after example ##{@@n} '#{desc}': #{MonProbe.counters}"
          MonProbe.dump_monitor
        end
        return
      end
      sleep 2.milliseconds
    end
    if @@stalled
      @@stalled = false
      STDERR.puts "\nMONPROBE running again after example ##{@@n} '#{desc}': #{MonProbe.counters}"
    end
    if desc.includes?("is scanned while a collection runs")
      STDERR.puts "\nMONPROBE after 76: #{MonProbe.counters}"
    end
  end

  def self.before(desc : String) : Nil
    return unless @@enabled
    if desc.includes?("is scanned while a collection runs")
      STDERR.puts "\nMONPROBE before 76 (example ##{@@n + 1}): #{MonProbe.counters}"
      MonProbe.dump_monitor
    end
  end
end

Spec.around_each do |example|
  desc = example.example.description
  MonProbeSpec.before(desc)
  example.run
  MonProbeSpec.after(desc)
end
