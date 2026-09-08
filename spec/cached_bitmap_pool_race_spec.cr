require "./spec_helper"
require "../bench/bounded_child"

describe "cached bitmap pool probes" do
  it "survives a concurrent trim between index lookup and candidate inspection" do
    executable = File.tempfile("cached-bitmap-pool-race")
    executable.close
    begin
      # The scheduled race uses real threads and guarded mappings. Keep it in
      # a bounded child so a stale header read or deadlock fails this example.
      build = BoundedChild.run(ENV["CRYSTAL"]? || "crystal",
        ["build", File.expand_path("../bench/chunk_search_race.cr", __DIR__),
         "-o", executable.path, "--error-trace"], timeout: 120.seconds)
      build.ok.should be_true, build.output

      result = BoundedChild.run(executable.path, ["--child", "cached-pool"],
        timeout: 10.seconds)
      result.ok.should be_true, result.output
      result.output.should contain("cached-pool: search survived concurrent trim")
    ensure
      executable.delete
    end
  end
end
