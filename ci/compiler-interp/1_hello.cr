# `crystal i` smoke: the interpreted prelude's `GC.init` goes through gcry's
# `GC_init` / `GC_set_handle_fork` / `GC_set_start_callback` / `GC_set_warn_proc`.
words = %w(gcry interpreted hello)
puts words.map(&.upcase).join(" ")
h = {"a" => 1, "b" => 2}
h["c"] = h.values.sum
puts h
