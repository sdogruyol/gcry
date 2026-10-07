{% skip_file if flag?(:win32) %}

require "../../src/gcry"
require "spec"
require "file_utils"

# Parallel mark guards its shared mark stack with `Crystal::SpinLock`, which
# compiles to nothing under `-Dwithout_mt` off Windows. Parallel mark was on
# by default there anyway until 2026-10-07: helpers pushed and popped the
# stack unlocked, could lose entries, and the sweep freed live objects. Such
# a build now marks serially, whatever `GCRY_PARALLEL_MARK` or
# `Heap#parallel_mark_workers=` asks. This suite is not built with the flag,
# so a child program is. It sits two levels under the repository root, since
# `require` takes relative paths, not absolute ones.
module WithoutMtSerialMarkSpec
  CHILD = <<-'CR'
    require "../../src/gcry"
    heap = Gcry.default_heap
    puts "env=#{heap.parallel_mark_workers}"
    heap.parallel_mark_workers = 4
    puts "set=#{heap.parallel_mark_workers}"
    CR
end

describe "-Dwithout_mt parallel mark" do
  it "marks serially by default, under GCRY_PARALLEL_MARK and when set" do
    dir = File.join(File.expand_path("../..", __DIR__), "bin", "gcry-38-#{Random.new.hex(4)}")
    Dir.mkdir_p(dir)
    begin
      src = File.join(dir, "child.cr")
      exe = File.join(dir, "child")
      File.write(src, WithoutMtSerialMarkSpec::CHILD)
      captured = IO::Memory.new
      status = Process.run(ENV["CRYSTAL"]? || "crystal", ["build", "-Dgc_none", "-Dwithout_mt", src, "-o", exe],
        output: captured, error: captured)
      fail captured.to_s unless status.success?
      [nil, "4"].each do |pm|
        stdout = IO::Memory.new
        err = IO::Memory.new
        env = {"GCRY_PARALLEL_MARK" => pm}
        status = Process.run(exe, env: env, output: stdout, error: err)
        fail err.to_s unless status.success?
        stdout.to_s.should eq("env=1\nset=1\n")
        err.to_s.should contain("GCRY_PARALLEL_MARK is ignored") if pm
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
