#!/usr/bin/env python3
# Diagnostic only: patch.py SRC_ROOT — every root word that first-marks a block
# during a major is printed (GCRY_M1_DUMP=1): collection, source, slot, value,
# block base, payload, first word, stack sp and bottom.
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
r = root / 'src/gcry/roots.cr'
t = r.read_text()
t = t.replace('{% if flag?(:gcry_hl_assert) %} @@hl_slot = cursor.address {% end %}', '@@hl_slot = cursor.address')
t = t.replace('''    {% if flag?(:gcry_hl_assert) %}
      # Address of the word most recently yielded by a scan loop (diagnostics).
      class_property hl_slot : UInt64 = 0_u64
    {% end %}''', '''    class_property hl_slot : UInt64 = 0_u64''')
assert '@@hl_slot = cursor.address' in t and 'class_property hl_slot' in t
r.write_text(t)
m = root / 'src/gcry/collect_mark.cr'
t = m.read_text()
old = '      mark_impl(pointer, gate_type_id: gate, base_only: !@allow_interior_pointers, source: source)\n    end\n'
assert t.count(old) == 1
new = '''      if @m1_dump && source != RootSource::Heap && (found = find_block_with_chunk(pointer))
        h, c = found
        if block_allocated?(c, h) && !block_marked_in?(c, h)
          slot = Roots.hl_slot
          mark_impl(pointer, gate_type_id: gate, base_only: !@allow_interior_pointers, source: source)
          if block_marked_in?(c, h)
            u = user_of(c, h)
            LibC.printf("M1SEED c=%llu src=%d slot=%llx val=%llx base=%llx size=%llu w0=%llx atomic=%d sp=%llx bottom=%llx\\n",
              @collections, source.value, slot, pointer.address, u.address, block_payload(c, h),
              u.as(UInt64*).value, atomic_of(c, h) ? 1 : 0, Roots.hardware_stack_pointer.address, @stack_bottom.address)
          end
          if @m1_chain_at == @collections.to_i64
            @m1_chain_at = -1_i64
            fp = 0_u64
            asm("mov $0, x29" : "=r"(fp))
            LibC.printf("M1CHAIN entry_sp=%llx\n", @collect_entry_sp)
            while fp != 0_u64 && fp < @stack_bottom.address
              LibC.printf("M1FRAME fp=%llx ret=%llx\n", fp, Pointer(UInt64).new(fp + 8).value)
              fp = Pointer(UInt64).new(fp).value
            end
          end
          return
        end
      end
''' + old
t = t.replace(old, new)
t = t.replace('    private def mark_root_candidate(', '    @m1_dump : Bool = !LibC.getenv("GCRY_M1_DUMP").null?\n    @m1_chain_at : Int64 = LibC.getenv("GCRY_M1_CHAIN").null? ? -1_i64 : 6_i64\n\n    private def mark_root_candidate(', 1)
m.write_text(t)
