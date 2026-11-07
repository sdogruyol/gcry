require "gcry"

class Gcry::Heap
  def self.__dump_ivars
    {% for iv in @type.instance_vars %}
      puts "{{iv.name}} #{offsetof(Gcry::Heap, @{{iv.name}})} #{sizeof(typeof(Gcry::Heap.allocate.@{{iv.name}}))}"
    {% end %}
  end
end

puts "instance_sizeof #{instance_sizeof(Gcry::Heap)}"
Gcry::Heap.__dump_ivars
