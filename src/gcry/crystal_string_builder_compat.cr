# Crystal stdlib `String::Builder` (1.21.0, and master as of 2026-10-05) lets
# the content fill its buffer exactly — `increase_capacity_by` accepts
# `new_bytesize <= @capacity`, growth is `Math.pw2ceil(new_bytesize)` — and
# `to_s` then writes the terminator at `@buffer[@capacity]`, one byte past the
# allocation.
#
# Boehm masks this: it adds a byte to every request for interior pointers
# (`GC_malloc_atomic(128)` is a 144-byte object), so the store lands in slack.
# gcry size classes are exact (128 → 128), so it lands on the next block, and
# that block's first write replaces the NUL. The compiler built with gcry made
# 116-byte mangled names (12-byte header + 116 = 128) followed by a `String`
# (type id 1): LLVM read them up to the next NUL, declared `…\01` functions,
# and the link failed.
#
# Grow by the terminator's byte when the content fills the buffer, before the
# stdlib writes it. Shard-only workaround until Crystal reserves that byte.
# `process_spec/regression/22_string_builder_terminator_spec.cr`.
class String::Builder
  def to_s : String
    if !@finished && real_bytesize >= @capacity
      resize_to_capacity(real_bytesize + 1)
    end
    previous_def
  end
end
