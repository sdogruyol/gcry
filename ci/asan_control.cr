require "../src/gcry"

# Must fail under ASan. A clean exit means the gate is not instrumenting loads.
pointer = LibC.malloc(16).as(UInt8*)
LibC.free(pointer)
puts pointer.value
