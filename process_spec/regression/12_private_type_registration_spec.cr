require "../../src/gcry"
require "spec"

# `Gcry.register_layouts` and `Gcry::Layout.register_scan_caps` are macros over
# `Reference.all_subclasses` that spell every type from `src/gcry/layout.cr`.
# A type naming something private to another file does not resolve there, and
# `GC.init` compiles both calls into every program (they run only behind
# `GCRY_AUTO_LAYOUTS` / `GCRY_SCAN_CAPS`), so one such type failed the whole
# program's compile. Crystal's own `spec/std/class_spec.cr` has one:
# `private alias RecursiveNilableType = Array(RecursiveNilableType)?`.
#
# This file is the compile-time half of the gate: if the macros spell these
# types again, `process_spec` does not build.
private alias PrivateRecursive = Array(PrivateRecursive)?

private class PrivateLeaf
end

private module PrivateNamespace
  class Inner
  end
end

private def private_type_holders
  {
    [nil] of PrivateRecursive,
    [[nil] of PrivateRecursive],
    {} of String => PrivateRecursive,
    [{1, PrivateLeaf.new}],
    [{a: PrivateLeaf.new}],
    [PrivateNamespace::Inner.new],
  }
end

describe "whole-program layout registration" do
  it "compiles and skips types that name another file's private types" do
    holders = private_type_holders
    Gcry::Layout.enabled = true
    Gcry.register_layouts
    Gcry::Layout.register_scan_caps

    Gcry::Layout.entry_for(Array(PrivateRecursive).crystal_instance_type_id).should be_nil
    Gcry::Layout.entry_for(Array(Tuple(Int32, PrivateLeaf)).crystal_instance_type_id).should be_nil
    Gcry::Layout.entry_for(Array(PrivateNamespace::Inner).crystal_instance_type_id).should be_nil
    # The resolution check must not skip what this scope can spell.
    Gcry::Layout.entry_for(Array(String).crystal_instance_type_id).should_not be_nil
    holders.size.should eq(6)
  end
end
