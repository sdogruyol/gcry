require "./spec_helper"

# A release that bumps `shard.yml` and forgets `Gcry::VERSION` ships a build that
# misreports itself, and every field report taken against it is mislabelled.
#
# Both 0.21.2 and 0.21.3 did exactly that. The constant still read `"0.21.1"`
# after two releases, and `samples/hello.cr` printed it — `hello from gcry
# 0.21.1` — on every run anyone made, for two weeks, without the mismatch
# reaching anyone's attention. A one-line assertion is cheaper than the next
# crash report that names the wrong build.
describe "Gcry::VERSION" do
  it "matches the version in shard.yml" do
    shard = File.read(File.join(__DIR__, "..", "shard.yml"))
    line = shard.lines.find(&.starts_with?("version:"))
    line.should_not be_nil
    line.not_nil!.split(':', 2)[1].strip.should eq Gcry::VERSION
  end
end
