require "../../src/gcry"
require "spec"

# gcry issue #14: Crystal's `Crystal::System::Process.prepare_args` allocated
# `args.size` argv slots and no terminating NULL, which POSIX `execve` needs
# (`argv[argc] == NULL`). Boehm hid it, `GC_malloc(16)` handing back a larger
# zeroed granule; gcry's exact classes put the next block's first word there
# and `Process.run` failed with EFAULT. `src/gcry/crystal_process_compat.cr`
# has allocated the slot since; Crystal 1.22.0 does it itself
# (crystal-lang/crystal#17184), and the compat reopen now applies only below
# that version. This file holds both halves of that gate: on a compiler older
# than 1.22.0 it fails without the reopen, and on 1.22.0 or later it passes
# with the stdlib's own method.
#
# `process_gc_spec.cr`'s "argv NULL terminator" example runs real commands,
# which only fail when the word after the allocation happens to be non-NULL.
# This asks the collector instead: the terminator slot must lie inside argv's
# own block (`Gcry.usable_size`) and be NULL. One to eight arguments, so the
# allocation (8 bytes a slot) ends exactly on a size class at least once: 16,
# 32, 48 and 64 bytes are all gcry classes, and there a missing slot is
# outside the block and fails the size check whatever happens to follow.
{% if flag?(:unix) %}
  describe "execve argv under gcry's exact size classes" do
    it "keeps the NULL terminator inside argv's own block" do
      (1..8).each do |n|
        args = Array.new(n) { |i| "arg#{i}" }
        _, argv = Crystal::System::Process.prepare_args(args)
        needed = ((n + 1) * sizeof(LibC::Char*)).to_u64
        Gcry.usable_size(argv.as(Void*)).should be >= needed, failure_message: "#{n} args: argv block holds #{Gcry.usable_size(argv.as(Void*))} bytes, needs #{needed}"
        argv[n].null?.should be_true, failure_message: "#{n} args: argv[#{n}] is not NULL"
      end
    end
  end
{% end %}
