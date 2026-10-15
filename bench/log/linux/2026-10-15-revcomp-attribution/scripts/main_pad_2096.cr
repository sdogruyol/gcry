# Placement probe: main.cr plus one never-inlined function whose body is 2096
# bytes of nops, called once before anything else so codegen emits it ahead of
# the code generated after it, which moves by 2096 bytes. Semantics unchanged.
@[NoInline]
def __placement_pad
  asm(".skip 2096, 0x90" :::: "volatile")
end

__placement_pad

{% if flag?(:gc_none) %}
  require "gcry"
{% end %}

require "./metric"
