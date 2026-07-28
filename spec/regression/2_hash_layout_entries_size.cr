# Regression test for Hash layout walk using entries_capacity vs entries_size.
#
# Fixed in v0.12.0: precise scan_hash_object iterated (1 << indices_size_pow2) / 2
# slots. After realloc, slots past @size + @deleted_count are uninitialized;
# non-zero garbage @hash words caused false marks / mutator UAF.
# See CHANGELOG v0.12.0 Fixed.
#
# Trigger: create a Hash, insert many entries, force realloc, then verify
# that GC doesn't mark garbage slots (no segfault/corruption).

require "../../src/gcry"
require "spec"

describe "Regression: Hash layout scan_cap / entries_size" do
  it "survives hash realloc without false marks" do
    # Create a hash that forces internal realloc several times
    h = {} of Int32 => String
    1_000.times { |i| h[i] = "v#{i}" }

    # Access to keep alive
    h[0].should eq("v0")

    # Multiple GC cycles to exercise mark/sweep
    5.times { GC.collect }

    # Verify hash contents survive
    h[500].should eq("v500")
    h.size.should eq(1_000)
  end
end
