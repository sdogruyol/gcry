# Prints every `Gcry::Heap` instance variable's byte offset and type, and the
# instance size, so two revisions' data layouts can be compared field by field.
#
#   crystal build -Dgc_none heap_ivars.cr   (with `lib/gcry` → the revision)
require "gcry"

# Inside a def: `instance_vars` is only known once types are.
def dump_heap_ivars
  {% for ivar in Gcry::Heap.instance_vars %}
    puts "#{offsetof(Gcry::Heap, @{{ivar.name.id}})}\t{{ivar.name.id}}\t{{ivar.type.id}}"
  {% end %}
  puts "#{instance_sizeof(Gcry::Heap)}\tinstance_sizeof"
end

dump_heap_ivars
