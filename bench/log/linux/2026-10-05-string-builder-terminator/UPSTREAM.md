# Upstream draft: `String::Builder#to_s` writes one byte past its buffer

Prepared 2026-10-14 against crystal-lang/crystal master `39f3f4d` (1.22.0).
Not filed. `crystal-string-builder-terminator.patch` in this directory is the
fix alone; `crystal-string-builder-terminator-pr.patch` is the PR (fix + spec).

## Issue

**Title:** `String::Builder#to_s` writes the trailing zero byte past the buffer

`String::Builder` grows its buffer to hold the header and the content
(`increase_capacity_by`: `new_bytesize = real_bytesize + count`), but `to_s`
then stores a zero byte at `@buffer[real_bytesize]` before shrinking. When the
content fills a grown buffer exactly, that store lands one byte past the
allocation. The smallest case on 64-bit targets is 116 bytes of content:
12-byte header + 116 = 128, a power of two, so the buffer grows to exactly 128
and the terminator goes to byte 128.

```crystal
builder = String::Builder.new
116.times { builder << 'x' }
builder.capacity                        # => 128
String::HEADER_SIZE + builder.bytesize  # => 128: no room for to_s's zero byte
```

Boehm hides it: it adds a byte to every allocation, so the store lands in
slack. Under an allocator without slack it corrupts the next block or faults.
`builder_overflow.cr` (this directory) replaces `GC.malloc*` with an
allocator whose blocks end at a `PROT_NONE` page and gets `SIGSEGV` at 116
bytes on stock Crystal (`crystal run -Dgc_none builder_overflow.cr`).

Found while running the compiler on gcry, a Crystal GC whose size classes have
no slack: the compiler handed LLVM 116-byte mangled names whose terminator had
been overwritten by the next block's first word, and LLVM read past them.

`String::Builder.new` already reserves the byte (`capacity += HEADER_SIZE + 1`);
only growth forgets it.

## PR

**Title:** Fix `String::Builder` to keep room for the trailing zero byte

Counts the terminator `to_s` writes in `increase_capacity_by`, as
`initialize` already does. Fixes #<issue>.

The spec checks the invariant directly (`capacity > HEADER_SIZE + bytesize`
after every write, for 0..300 bytes), so it fails on the stock allocator
too, where the overflow itself is invisible.

Verified on `39f3f4d` with the 1.21.0 compiler:
- `spec/std/string_builder_spec.cr`: 8 examples, 0 failures; without the fix
  the new example fails.
- `spec/std/string_spec.cr` + `spec/std/io/memory_spec.cr`: 1136 examples,
  0 failures, 1 pending.
