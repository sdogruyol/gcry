require "../../src/gcry"
require "spec"

# `GCRY_NURSERY=0` turned the nursery on under `-Dgcry_block_headers`.
#
# The header branch of `gc_override.cr` tested only that the knob parsed, and
# `0` is truthy in Crystal, so a value asking for no nursery enabled the
# barrier-less one — the configuration HARDENING.md calls unsound (a
# checksummed-graph churn SIGSEGVs 3 of 3 with it on). The headerless branch
# already treated `0` as unset. `0` is now the documented way to say off.
#
# The knob is read once at GC boot, so each arm is a child process.

private def nursery_child(value : String) : String
  captured = IO::Memory.new
  status = Process.run(Process.executable_path.not_nil!, ["-e", "nursery-zero child"],
    env: {"GCRY_NURSERY_ZERO_CHILD" => "1", "GCRY_NURSERY" => value},
    output: captured, error: captured)
  fail "child #{status.inspect}:\n#{captured}" unless status.success?
  captured.to_s
end

describe "Regression: GCRY_NURSERY=0" do
  it "leaves the nursery off" do
    nursery_child("0").should contain("nursery_enabled=false")
  end

  # Control: the child must be able to see a nursery at all, or the arm
  # above passes on a build that never reads the knob.
  {% if flag?(:gcry_block_headers) %}
    it "a byte value still turns it on (control)" do
      nursery_child("262144").should contain("nursery_enabled=true")
    end
  {% end %}

  it "nursery-zero child" do
    next unless ENV["GCRY_NURSERY_ZERO_CHILD"]? == "1"
    puts "nursery_enabled=#{Gcry.default_heap.nursery_enabled}"
  end
end
