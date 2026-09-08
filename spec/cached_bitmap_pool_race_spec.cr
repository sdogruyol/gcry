require "./spec_helper"
require "../bench/bounded_child"

describe "cached bitmap pool probes" do
  it "survives scheduled chunk release windows" do
    executable = File.tempfile("cached-bitmap-pool-race")
    executable.close
    begin
      # The scheduled races use real threads and guarded mappings. Keep them in
      # bounded children so stale header reads or deadlocks fail this example.
      build = BoundedChild.run(ENV["CRYSTAL"]? || "crystal",
        ["build", File.expand_path("../bench/chunk_search_race.cr", __DIR__),
         "-o", executable.path, "--error-trace"], timeout: 120.seconds)
      build.ok.should be_true, build.output

      cached = BoundedChild.run(executable.path, ["--child", "cached-pool"],
        timeout: 10.seconds)
      cached.ok.should be_true, cached.output
      cached.output.should contain("cached-pool: search survived concurrent trim")

      ["handoff-cached", "handoff-overflow", "handoff-dormant", "handoff-fresh"].each do |mode|
        ["", "atomic"].each do |kind|
          args = ["--child", mode]
          args << kind unless kind.empty?
          result = BoundedChild.run(executable.path, args, timeout: 10.seconds)
          result.ok.should be_true, "#{mode} #{kind}\n#{result.output}"
          result.output.should contain("#{mode}: cursor survived a sweep during handoff")
        end
      end
    ensure
      executable.delete
    end
  end
end
