# Optional precise object scanning via type_id → pointer-field byte offsets.
# Unknown type_ids (or size-class mismatch) fall back to conservative word-scan.
#
# Storage is StaticArray-backed (no Hash/Array class vars): register_builtins runs
# inside GC.init before Fiber is up — Crystal `once`/collections SIGSEGV there.
#
# Pointer ivars split into:
#   - scan offsets: mark_candidate (object will be scanned)
#   - noscan offsets: mark only (keep alive, do not scan contents) — critical for
#     Hash @indices and Array(value) @buffer, which are integer tables.

module Gcry
  module Layout
    MAX_ENTRIES  = 4096
    MAX_OFFSETS  =   32
    OFFSET_SLOTS = MAX_ENTRIES * MAX_OFFSETS
    # Open-addressing index (entry index + 1; 0 = empty). Power of two.
    INDEX_SIZE = 8192
    INDEX_MASK = INDEX_SIZE - 1

    KIND_PLAIN = 0_u8
    KIND_HASH  = 1_u8

    VALUE_MODE_NONE  = 0_u8
    VALUE_MODE_REF   = 1_u8 # value is a Reference pointer in the entry
    VALUE_MODE_WORDS = 2_u8 # value is a struct; mark pointer-sized words (e.g. JSON::Any)

    # `uninitialized` — no Crystal `once` (`.new` class-var init needs Fiber; GC.init is too early).
    @@type_ids = uninitialized StaticArray(Int32, MAX_ENTRIES)
    @@alloc_sizes = uninitialized StaticArray(UInt32, MAX_ENTRIES)
    @@n_scan = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@n_noscan = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@offsets = uninitialized StaticArray(UInt16, OFFSET_SLOTS) # scan then noscan packed
    @@kind = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@hash_entries_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_indices_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_pow2_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_entry_stride = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_key_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_value_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_value_mode = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@hash_value_bytes = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@index = uninitialized StaticArray(Int32, INDEX_SIZE) # 0 = empty; else entry_index + 1
    @@count = uninitialized Int32
    @@enabled = uninitialized Bool
    @@booted = uninitialized Bool

    private def self.ensure_booted : Nil
      return if @@booted
      @@count = 0
      @@enabled = true
      INDEX_SIZE.times { |i| @@index[i] = 0 }
      @@booted = true
    end

    struct Entry
      getter scan_offsets : Slice(UInt16)
      getter noscan_offsets : Slice(UInt16)
      getter alloc_size : UInt32
      getter kind : UInt8
      getter hash_entries_off : UInt16
      getter hash_indices_off : UInt16
      getter hash_pow2_off : UInt16
      getter hash_entry_stride : UInt16
      getter hash_key_off : UInt16
      getter hash_value_off : UInt16
      getter hash_value_mode : UInt8
      getter hash_value_bytes : UInt16

      def initialize(@scan_offsets : Slice(UInt16), @noscan_offsets : Slice(UInt16),
                     @alloc_size : UInt32, @kind : UInt8,
                     @hash_entries_off : UInt16, @hash_indices_off : UInt16,
                     @hash_pow2_off : UInt16, @hash_entry_stride : UInt16,
                     @hash_key_off : UInt16, @hash_value_off : UInt16,
                     @hash_value_mode : UInt8, @hash_value_bytes : UInt16)
      end

      def hash? : Bool
        @kind == KIND_HASH
      end
    end

    def self.enabled? : Bool
      ensure_booted
      @@enabled
    end

    def self.enabled=(value : Bool) : Bool
      ensure_booted
      @@enabled = value
    end

    def self.clear : Nil
      ensure_booted
      @@count = 0
      INDEX_SIZE.times { |i| @@index[i] = 0 }
    end

    def self.size : Int32
      ensure_booted
      @@count
    end

    private def self.index_slot(type_id : Int32) : Int32
      # Multiplicative hash → open-address slot (wrapping; avoid Int32 overflow).
      ((type_id.to_i64! * -1640531527_i64) & INDEX_MASK).to_i32
    end

    private def self.find_entry_index(type_id : Int32) : Int32
      i = index_slot(type_id)
      probes = 0
      while probes < INDEX_SIZE
        slot = @@index[i]
        return -1 if slot == 0
        ei = slot - 1
        return ei if @@type_ids[ei] == type_id
        i = (i + 1) & INDEX_MASK
        probes += 1
      end
      -1
    end

    private def self.index_insert(type_id : Int32, entry_index : Int32) : Nil
      i = index_slot(type_id)
      probes = 0
      while probes < INDEX_SIZE
        slot = @@index[i]
        if slot == 0 || @@type_ids[slot - 1] == type_id
          @@index[i] = entry_index + 1
          return
        end
        i = (i + 1) & INDEX_MASK
        probes += 1
      end
      raise "Gcry::Layout index full"
    end

    def self.entry_for(type_id : Int32) : Entry?
      ensure_booted
      return nil unless @@enabled
      ei = find_entry_index(type_id)
      return nil if ei < 0
      entry_at(ei)
    end

    private def self.entry_at(i : Int32) : Entry
      n_scan = @@n_scan[i].to_i32
      n_noscan = @@n_noscan[i].to_i32
      base = i * MAX_OFFSETS
      Entry.new(
        Slice.new(@@offsets.to_unsafe + base, n_scan),
        Slice.new(@@offsets.to_unsafe + base + n_scan, n_noscan),
        @@alloc_sizes[i],
        @@kind[i],
        @@hash_entries_off[i],
        @@hash_indices_off[i],
        @@hash_pow2_off[i],
        @@hash_entry_stride[i],
        @@hash_key_off[i],
        @@hash_value_off[i],
        @@hash_value_mode[i],
        @@hash_value_bytes[i],
      )
    end

    def self.offsets_for(type_id : Int32) : Slice(UInt16)?
      entry_for(type_id).try(&.scan_offsets)
    end

    # Install pointer-field byte offsets (tests). *alloc_size* 0 → no size gate.
    def self.install(type_id : Int32, offsets : Array(UInt16), alloc_size : UInt32 = 0_u32) : Nil
      install_full(type_id, offsets.to_unsafe, offsets.size, Pointer(UInt16).null, 0, alloc_size,
        KIND_PLAIN, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, VALUE_MODE_NONE, 0_u16)
    end

    def self.install_full(type_id : Int32,
                          scan_ptr : UInt16*, n_scan : Int32,
                          noscan_ptr : UInt16*, n_noscan : Int32,
                          alloc_size : UInt32,
                          kind : UInt8,
                          hash_entries_off : UInt16, hash_indices_off : UInt16,
                          hash_pow2_off : UInt16, hash_entry_stride : UInt16,
                          hash_key_off : UInt16, hash_value_off : UInt16,
                          hash_value_mode : UInt8, hash_value_bytes : UInt16) : Nil
      ensure_booted
      total = n_scan + n_noscan
      return if total <= 0 && kind == KIND_PLAIN
      raise "Gcry::Layout full (#{MAX_ENTRIES})" if @@count >= MAX_ENTRIES
      raise "Gcry::Layout too many offsets (#{total} > #{MAX_OFFSETS})" if total > MAX_OFFSETS

      i = find_entry_index(type_id)
      if i < 0
        i = @@count
        @@count += 1
        index_insert(type_id, i)
      end

      @@type_ids[i] = type_id
      @@alloc_sizes[i] = alloc_size
      @@n_scan[i] = n_scan.to_u8
      @@n_noscan[i] = n_noscan.to_u8
      @@kind[i] = kind
      @@hash_entries_off[i] = hash_entries_off
      @@hash_indices_off[i] = hash_indices_off
      @@hash_pow2_off[i] = hash_pow2_off
      @@hash_entry_stride[i] = hash_entry_stride
      @@hash_key_off[i] = hash_key_off
      @@hash_value_off[i] = hash_value_off
      @@hash_value_mode[i] = hash_value_mode
      @@hash_value_bytes[i] = hash_value_bytes

      base = i * MAX_OFFSETS
      j = 0
      while j < n_scan
        @@offsets[base + j] = scan_ptr[j]
        j += 1
      end
      j = 0
      while j < n_noscan
        @@offsets[base + n_scan + j] = noscan_ptr[j]
        j += 1
      end
    end

    # Register pointer ivars of *type* using compile-time layout.
    # Pointer(T) to a non-Reference T → noscan (value buffer).
    def self.register(type : T.class) forall T
      {% if T.private? %}
        # Skip — cannot reference private constants from this shard.
      {% else %}
      {% unless T < Reference %}
        {% raise "Gcry.register_layout requires a Reference class, got #{T}" %}
      {% end %}
      {% begin %}
        {% scan_count = 0 %}
        {% noscan_count = 0 %}
        {% for ivar in T.instance_vars %}
          {% t = ivar.type %}
          {% is_ptr = t <= Pointer || t < Reference %}
          {% is_noscan = false %}
          {% if t <= Pointer %}
            {% elem = t.type_vars[0] %}
            {% if !(elem < Reference) && !(elem <= Pointer) %}
              {% is_noscan = true %}
            {% end %}
          {% elsif !is_ptr && t.union? %}
            {% for ut in t.union_types %}
              {% if ut <= Pointer || ut < Reference %}
                {% is_ptr = true %}
              {% end %}
            {% end %}
          {% end %}
          {% if is_ptr %}
            {% if is_noscan %}
              {% noscan_count += 1 %}
            {% else %}
              {% scan_count += 1 %}
            {% end %}
          {% end %}
        {% end %}
        {% if scan_count + noscan_count > 0 %}
          scan = StaticArray(UInt16, {{scan_count == 0 ? 1 : scan_count}}).new(0)
          noscan = StaticArray(UInt16, {{noscan_count == 0 ? 1 : noscan_count}}).new(0)
          si = 0
          ni = 0
          {% for ivar in T.instance_vars %}
            {% t = ivar.type %}
            {% is_ptr = t <= Pointer || t < Reference %}
            {% is_noscan = false %}
            {% if t <= Pointer %}
              {% elem = t.type_vars[0] %}
              {% if !(elem < Reference) && !(elem <= Pointer) %}
                {% is_noscan = true %}
              {% end %}
            {% elsif !is_ptr && t.union? %}
              {% for ut in t.union_types %}
                {% if ut <= Pointer || ut < Reference %}
                  {% is_ptr = true %}
                {% end %}
              {% end %}
            {% end %}
            {% if is_ptr %}
              {% if is_noscan %}
                noscan[ni] = UInt16.new(offsetof({{T}}, @{{ivar.name}}))
                ni += 1
              {% else %}
                scan[si] = UInt16.new(offsetof({{T}}, @{{ivar.name}}))
                si += 1
              {% end %}
            {% end %}
          {% end %}
          bytes = instance_sizeof({{T}}).to_u64
          rounded, _ = SizeClasses.fit(bytes)
          install_full({{T}}.crystal_instance_type_id,
            scan.to_unsafe, {{scan_count}},
            noscan.to_unsafe, {{noscan_count}},
            rounded.to_u32, KIND_PLAIN,
            0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, VALUE_MODE_NONE, 0_u16)
        {% end %}
      {% end %}
      {% end %}
    end

    # Register a Hash(K,V) with entry-table walking + noscan @indices/@entries blob.
    def self.register_hash(key_type : K.class, value_type : V.class) forall K, V
      {% begin %}
        scan = StaticArray(UInt16, 2).new(0)
        noscan = StaticArray(UInt16, 2).new(0)
        n_scan = 0
        n_noscan = 0

        scan[n_scan] = UInt16.new(offsetof(Hash({{K}}, {{V}}), @block))
        n_scan += 1

        noscan[n_noscan] = UInt16.new(offsetof(Hash({{K}}, {{V}}), @indices))
        n_noscan += 1
        noscan[n_noscan] = UInt16.new(offsetof(Hash({{K}}, {{V}}), @entries))
        n_noscan += 1

        {% if K < Reference %}
          key_off = UInt16.new(offsetof(Hash::Entry({{K}}, {{V}}), @key))
        {% else %}
          key_off = 0_u16
        {% end %}

        {% if V < Reference %}
          value_mode = VALUE_MODE_REF
          value_off = UInt16.new(offsetof(Hash::Entry({{K}}, {{V}}), @value))
          value_bytes = 0_u16
        {% elsif V.stringify == "JSON::Any" %}
          value_mode = VALUE_MODE_WORDS
          value_off = UInt16.new(offsetof(Hash::Entry({{K}}, {{V}}), @value))
          value_bytes = UInt16.new(sizeof({{V}}))
        {% else %}
          value_mode = VALUE_MODE_NONE
          value_off = 0_u16
          value_bytes = 0_u16
        {% end %}

        bytes = instance_sizeof(Hash({{K}}, {{V}})).to_u64
        rounded, _ = SizeClasses.fit(bytes)
        install_full(Hash({{K}}, {{V}}).crystal_instance_type_id,
          scan.to_unsafe, n_scan,
          noscan.to_unsafe, n_noscan,
          rounded.to_u32, KIND_HASH,
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @entries)),
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @indices)),
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @indices_size_pow2)),
          UInt16.new(sizeof(Hash::Entry({{K}}, {{V}}))),
          key_off, value_off, value_mode, value_bytes)
      {% end %}
    end

    def self.register_builtins : Nil
      register(Array(UInt8))
      register(Array(Int32))
      register(Array(Int64))
      register(Array(UInt32))
      register(Array(UInt64))
      register(Array(Float32))
      register(Array(Float64))
      register(Array(Bool))
      register(Array(Char))
      register(Array(String))
      register(Array(Array(String)))
      register(Array(Array(Int32)))
      register(Array(Hash(String, String)))

      register_hash(String, String)
      register_hash(String, Int32)
      register_hash(String, Int64)
      register_hash(String, Float64)
      register_hash(String, Bool)
      register_hash(Int32, Int32)
      register_hash(Int32, String)
      register_hash(String, Array(String))
      register_hash(String, Hash(String, String))
      register_hash(String, Array(Int32))

      register(Exception)
      register(Deque(String))
      register(Deque(Int32))
    end

    # Auto-register precise layouts for every concrete Reference subclass in the
    # program. Must be a method (instance_vars are unavailable at top-level macro).
    # Hash instantiations use register_hash; unbound generics are skipped.
    def self.register_all_from_reference_subclasses : Nil
      {% begin %}
        {% for t in Reference.all_subclasses %}
          {% skip = t.abstract? || t.private? || (t.stringify.includes?("::") && t.stringify.includes?("(")) %}
          {% for tv in t.type_vars %}
            {% if tv.is_a?(MacroId) %}
              {% skip = true %}
            {% end %}
          {% end %}
          {% unless skip %}
            {% if t <= Hash %}
              {% if t.type_vars.size == 2 %}
                register_hash({{t.type_vars[0]}}, {{t.type_vars[1]}})
              {% end %}
            {% else %}
              register({{t}})
            {% end %}
          {% end %}
        {% end %}
      {% end %}
    end
  end

  def self.register_layout(type : T.class) forall T
    {% if T.stringify.starts_with?("Hash(") %}
      {% raise "Use Gcry.register_hash(K, V) for Hash types (entry-precise scan)" %}
    {% end %}
    Layout.register(type)
  end

  def self.register_hash(key_type : K.class, value_type : V.class) forall K, V
    Layout.register_hash(key_type, value_type)
  end

  # Register layouts for all concrete Reference subclasses visible to the compiler.
  def self.register_layouts : Nil
    Layout.register_all_from_reference_subclasses
  end
end
