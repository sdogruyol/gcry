require "../../src/gcry"
require "spec"

module Pollute74
  class_getter kept = [] of String
end

describe "pollute 74's class" do
  it "keeps an atomic string of 74's class to the end of the run" do
    next unless ENV["POLLUTE74"]? == "1"
    Pollute74.kept << "x" * 2900
  end
end
