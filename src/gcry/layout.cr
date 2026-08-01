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

require "json"

module Gcry
  module Layout
    # Keep tables modest: multi-MiB `uninitialized` StaticArrays live in the
    # process image and are walked by static-root scan. On Linux (blacklist on)
    # that volume of ambient words was enough to UAF under process_spec STW
    # (Fiber Monitor / ENV RWLock). Opt-in GCRY_AUTO_LAYOUTS / GCRY_SCAN_CAPS
    # that need >4k entries should move to LibC-backed storage, not BSS.
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
    # Unrounded instance_sizeof: cap conservative word-scan so size-class slack
    # (padding past the real object) is not treated as pointers.
    @@scan_caps = uninitialized StaticArray(UInt32, MAX_ENTRIES)
    @@n_scan = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@n_noscan = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@offsets = uninitialized StaticArray(UInt16, OFFSET_SLOTS) # scan then noscan packed
    @@kind = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@hash_entries_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_indices_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_pow2_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_entry_stride = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_key_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_key_bytes = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_value_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_value_mode = uninitialized StaticArray(UInt8, MAX_ENTRIES)
    @@hash_value_bytes = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    # Crystal Hash: live entry range is @size + @deleted_count (NOT entries_capacity).
    # Walking capacity after realloc reads uninitialized slots → false marks / UAF.
    @@hash_size_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_deleted_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    # @block is Proc? (16 bytes on 64-bit): word-scan, don't treat as a single pointer.
    @@hash_block_off = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@hash_block_bytes = uninitialized StaticArray(UInt16, MAX_ENTRIES)
    @@index = uninitialized StaticArray(Int32, INDEX_SIZE) # 0 = empty; else entry_index + 1
    @@count = uninitialized Int32
    @@enabled = uninitialized Bool
    @@booted = uninitialized Bool
    # Number of types skipped by register_all_from_reference_subclasses because
    # they matched an @unsafe_layouts prefix (Cry, Crystal::*, LibC::*). Pure
    # observability — these types fall back to conservative word-scan at mark
    # time (no crash; just less precise).
    @@unsafe_skips = uninitialized UInt64

    private def self.ensure_booted : Nil
      return if @@booted
      @@count = 0
      @@enabled = true
      @@unsafe_skips = 0_u64
      INDEX_SIZE.times { |i| @@index[i] = 0 }
      @@booted = true
    end

    # Compile-time prefix blacklist. Types whose ivar layout Crystal guarantees
    # to keep stable across versions (built-in stdlib) get precise offsets via
    # the macro walk below; types in these prefixes ("Cry", "Crystal::",
    # "LibC::") change shape across versions or carry platform-specific
    # conditional fields that the macro cannot see. Skip them — they keep
    # conservative scanning, which is safe.
    UNSAFE_PREFIXES = {"Cry", "Crystal::", "LibC::"}

    def self.unsafe_skips_count : UInt64
      @@unsafe_skips
    end

    struct Entry
      getter scan_offsets : Slice(UInt16)
      getter noscan_offsets : Slice(UInt16)
      getter alloc_size : UInt32
      getter scan_cap : UInt32
      getter kind : UInt8
      getter hash_entries_off : UInt16
      getter hash_indices_off : UInt16
      getter hash_pow2_off : UInt16
      getter hash_entry_stride : UInt16
      getter hash_key_off : UInt16
      getter hash_key_bytes : UInt16
      getter hash_value_off : UInt16
      getter hash_value_mode : UInt8
      getter hash_value_bytes : UInt16
      getter hash_size_off : UInt16
      getter hash_deleted_off : UInt16
      getter hash_block_off : UInt16
      getter hash_block_bytes : UInt16

      def initialize(@scan_offsets : Slice(UInt16), @noscan_offsets : Slice(UInt16),
                     @alloc_size : UInt32, @scan_cap : UInt32, @kind : UInt8,
                     @hash_entries_off : UInt16, @hash_indices_off : UInt16,
                     @hash_pow2_off : UInt16, @hash_entry_stride : UInt16,
                     @hash_key_off : UInt16, @hash_key_bytes : UInt16,
                     @hash_value_off : UInt16,
                     @hash_value_mode : UInt8, @hash_value_bytes : UInt16,
                     @hash_size_off : UInt16, @hash_deleted_off : UInt16,
                     @hash_block_off : UInt16, @hash_block_bytes : UInt16)
      end

      def hash? : Bool
        @kind == KIND_HASH
      end

      # Pointer-field / hash table walk available.
      def precise_fields? : Bool
        hash? || @scan_offsets.size > 0 || @noscan_offsets.size > 0
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
        @@scan_caps[i],
        @@kind[i],
        @@hash_entries_off[i],
        @@hash_indices_off[i],
        @@hash_pow2_off[i],
        @@hash_entry_stride[i],
        @@hash_key_off[i],
        @@hash_key_bytes[i],
        @@hash_value_off[i],
        @@hash_value_mode[i],
        @@hash_value_bytes[i],
        @@hash_size_off[i],
        @@hash_deleted_off[i],
        @@hash_block_off[i],
        @@hash_block_bytes[i],
      )
    end

    def self.offsets_for(type_id : Int32) : Slice(UInt16)?
      entry_for(type_id).try(&.scan_offsets)
    end

    # Install pointer-field byte offsets (tests). *alloc_size* 0 → no size gate.
    def self.install(type_id : Int32, offsets : Array(UInt16), alloc_size : UInt32 = 0_u32, scan_cap : UInt32 = 0_u32) : Nil
      install_full(type_id, offsets.to_unsafe, offsets.size, Pointer(UInt16).null, 0, alloc_size, scan_cap,
        KIND_PLAIN, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, VALUE_MODE_NONE, 0_u16,
        0_u16, 0_u16, 0_u16, 0_u16)
    end

    # Size-class slack cap only (no pointer offsets). Conservative scan stops at *scan_cap*.
    def self.install_scan_cap(type_id : Int32, alloc_size : UInt32, scan_cap : UInt32) : Nil
      install_full(type_id, Pointer(UInt16).null, 0, Pointer(UInt16).null, 0, alloc_size, scan_cap,
        KIND_PLAIN, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, VALUE_MODE_NONE, 0_u16,
        0_u16, 0_u16, 0_u16, 0_u16)
    end

    def self.install_full(type_id : Int32,
                          scan_ptr : UInt16*, n_scan : Int32,
                          noscan_ptr : UInt16*, n_noscan : Int32,
                          alloc_size : UInt32,
                          scan_cap : UInt32,
                          kind : UInt8,
                          hash_entries_off : UInt16, hash_indices_off : UInt16,
                          hash_pow2_off : UInt16, hash_entry_stride : UInt16,
                          hash_key_off : UInt16, hash_key_bytes : UInt16,
                          hash_value_off : UInt16,
                          hash_value_mode : UInt8, hash_value_bytes : UInt16,
                          hash_size_off : UInt16 = 0_u16, hash_deleted_off : UInt16 = 0_u16,
                          hash_block_off : UInt16 = 0_u16, hash_block_bytes : UInt16 = 0_u16) : Nil
      ensure_booted
      total = n_scan + n_noscan
      # Allow: precise offsets, hash walk, leaf (alloc only), or scan-cap-only.
      return if total <= 0 && kind == KIND_PLAIN && alloc_size == 0 && scan_cap == 0
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
      @@scan_caps[i] = scan_cap
      @@n_scan[i] = n_scan.to_u8
      @@n_noscan[i] = n_noscan.to_u8
      @@kind[i] = kind
      @@hash_entries_off[i] = hash_entries_off
      @@hash_indices_off[i] = hash_indices_off
      @@hash_pow2_off[i] = hash_pow2_off
      @@hash_entry_stride[i] = hash_entry_stride
      @@hash_key_off[i] = hash_key_off
      @@hash_key_bytes[i] = hash_key_bytes
      @@hash_value_off[i] = hash_value_off
      @@hash_value_mode[i] = hash_value_mode
      @@hash_value_bytes[i] = hash_value_bytes
      @@hash_size_off[i] = hash_size_off
      @@hash_deleted_off[i] = hash_deleted_off
      @@hash_block_off[i] = hash_block_off
      @@hash_block_bytes[i] = hash_block_bytes

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
    # Pointer(T) → noscan only when `!T.has_inner_pointers?` (value buffer).
    #
    # Unsound for precise offsets (fall back to scan_cap):
    #   - mixed value|reference unions (not pointer-sized at offsetof)
    #   - embedded structs / StaticArray (may hide nested References)
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
        {% force_scan_cap = false %}
        {% for ivar in T.instance_vars %}
          {% t = ivar.type %}
          {% if t.union? %}
            {% union_safe = true %}
            {% for ut in t.union_types %}
              {% unless ut == Nil || ut < Reference || ut <= Pointer %}
                {% union_safe = false %}
              {% end %}
            {% end %}
            # Struct|Nil (e.g. Exception::CallStack, IO::EncodingOptions) has no
            # Reference arm — still unsound for precise single-word offsets.
            {% unless union_safe %}
              {% force_scan_cap = true %}
            {% end %}
          {% end %}
          # Embedded struct / StaticArray may contain References at non-ivar offsets.
          {% if !(t < Reference) && !(t <= Pointer) && !t.union? %}
            {% if (t < Value && t.instance_vars.size > 0) || t <= StaticArray %}
              {% force_scan_cap = true %}
            {% end %}
          {% end %}
          {% is_ptr = t <= Pointer || t < Reference %}
          {% is_noscan = false %}
          {% if t <= Pointer %}
            {% elem = t.type_vars[0] %}
            # Noscan only for true value payloads. JSON::Any / Slice / nested
            # Pointers have_inner_pointers? — must scan or Array(JSON::Any) UAFs.
            {% unless elem.has_inner_pointers? %}
              {% is_noscan = true %}
            {% end %}
          {% elsif !is_ptr && t.union? %}
            {% union_safe = true %}
            {% for ut in t.union_types %}
              {% unless ut == Nil || ut < Reference || ut <= Pointer %}
                {% union_safe = false %}
              {% end %}
            {% end %}
            {% if union_safe %}
              {% for ut in t.union_types %}
                {% if ut <= Pointer || ut < Reference %}
                  {% is_ptr = true %}
                {% end %}
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

        bytes = instance_sizeof({{T}}).to_u64
        rounded, _ = SizeClasses.fit(bytes)
        scan_cap = bytes.to_u32

        {% if force_scan_cap %}
          install_scan_cap({{T}}.crystal_instance_type_id, rounded.to_u32, scan_cap)
        {% elsif scan_count + noscan_count > 0 %}
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
              {% unless elem.has_inner_pointers? %}
                {% is_noscan = true %}
              {% end %}
            {% elsif !is_ptr && t.union? %}
              {% union_safe = true %}
              {% for ut in t.union_types %}
                {% unless ut == Nil || ut < Reference || ut <= Pointer %}
                  {% union_safe = false %}
                {% end %}
              {% end %}
              {% if union_safe %}
                {% for ut in t.union_types %}
                  {% if ut <= Pointer || ut < Reference %}
                    {% is_ptr = true %}
                  {% end %}
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
          install_full({{T}}.crystal_instance_type_id,
            scan.to_unsafe, {{scan_count}},
            noscan.to_unsafe, {{noscan_count}},
            rounded.to_u32, scan_cap, KIND_PLAIN,
            0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, 0_u16, VALUE_MODE_NONE, 0_u16,
            0_u16, 0_u16, 0_u16, 0_u16)
        {% else %}
          # No direct pointer ivars — still scan_cap (not leaf): hidden refs via
          # unusual ivar shapes have caused UAF with empty precise bodies.
          install_scan_cap({{T}}.crystal_instance_type_id, rounded.to_u32, scan_cap)
        {% end %}
      {% end %}
      {% end %}
    end

    # Register a Hash(K,V) with entry-table walking + noscan @indices/@entries blob.
    def self.register_hash(key_type : K.class, value_type : V.class) forall K, V
      {% begin %}
        # @block is Proc? (multi-word) — word-scanned via hash_block_*; not a single ptr.
        # Both @indices and @entries are noscan blobs: keep them alive, walk Entry
        # slots for key/value. Grey-scanning @entries re-marks capacity garbage
        # past entries_size (false retention / thr collapse) — do not.
        scan = StaticArray(UInt16, 1).new(0)
        noscan = StaticArray(UInt16, 2).new(0)
        n_scan = 0
        n_noscan = 0

        noscan[n_noscan] = UInt16.new(offsetof(Hash({{K}}, {{V}}), @indices))
        n_noscan += 1
        noscan[n_noscan] = UInt16.new(offsetof(Hash({{K}}, {{V}}), @entries))
        n_noscan += 1

        {% if K < Reference %}
          key_off = UInt16.new(offsetof(Hash::Entry({{K}}, {{V}}), @key))
          key_bytes = 0_u16
        {% elsif K.has_inner_pointers? %}
          # Struct / union key with nested refs — word-scan the key slot.
          key_off = UInt16.new(offsetof(Hash::Entry({{K}}, {{V}}), @key))
          key_bytes = UInt16.new(sizeof({{K}}))
        {% else %}
          key_off = 0_u16
          key_bytes = 0_u16
        {% end %}

        {% if V < Reference %}
          value_mode = VALUE_MODE_REF
          value_off = UInt16.new(offsetof(Hash::Entry({{K}}, {{V}}), @value))
          value_bytes = 0_u16
        {% elsif V.has_inner_pointers? %}
          # JSON::Any, String|Array(String), etc.
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
          rounded.to_u32, bytes.to_u32, KIND_HASH,
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @entries)),
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @indices)),
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @indices_size_pow2)),
          UInt16.new(sizeof(Hash::Entry({{K}}, {{V}}))),
          key_off, key_bytes, value_off, value_mode, value_bytes,
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @size)),
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @deleted_count)),
          UInt16.new(offsetof(Hash({{K}}, {{V}}), @block)),
          UInt16.new(sizeof((Hash({{K}}, {{V}}), {{K}} -> {{V}})?)))
      {% end %}
    end

    # Set(T) is Hash(T, Nil) — register the backing map.
    def self.register_set(elem_type : T.class) forall T
      register_hash(elem_type, Nil)
    end

    def self.register_builtins : Nil
      # Primitive arrays — @buffer is noscan (value payload).
      register(Array(Int8))
      register(Array(UInt8))
      register(Array(Int16))
      register(Array(UInt16))
      register(Array(Int32))
      register(Array(UInt32))
      register(Array(Int64))
      register(Array(UInt64))
      register(Array(Float32))
      register(Array(Float64))
      register(Array(Bool))
      register(Array(Char))

      # Reference-element arrays — @buffer is scanned (pointer table).
      register(Array(String))
      register(Array(Exception))
      register(Array(JSON::Any))
      register(Array(Array(String)))
      register(Array(Array(Int32)))
      register(Array(Array(UInt8)))
      register(Array(Hash(String, String)))
      register(Array(IO::Memory))

      register_hash(String, String)
      register_hash(String, Int32)
      register_hash(String, Int64)
      register_hash(String, UInt32)
      register_hash(String, UInt64)
      register_hash(String, Float32)
      register_hash(String, Float64)
      register_hash(String, Bool)
      register_hash(Int32, Int32)
      register_hash(Int32, String)
      register_hash(Int64, String)
      register_hash(UInt64, String)
      register_hash(String, Array(String))
      register_hash(String, Array(Int32))
      register_hash(String, Array(UInt8))
      register_hash(String, Hash(String, String))
      # Set(T) is Hash(T, Nil) under the hood.
      register_hash(String, Nil)
      register_hash(Int32, Nil)
      register_hash(Int64, Nil)
      register_hash(UInt64, Nil)
      # JSON APIs (stdlib; VALUE_MODE_WORDS for JSON::Any values).
      register_hash(String, JSON::Any)
      register_hash(Int32, JSON::Any)

      register(Exception)
      register(IO::Memory)
      # JSON / HTTP hot path — @buffer is Pointer(UInt8) (malloc_atomic, noscan).
      register(String::Builder)

      register(Deque(String))
      register(Deque(Int32))
      register(Deque(Int64))
      register(Deque(UInt8))
      register(Deque(UInt64))
      register(Deque(Array(String)))
    end

    # Size-class slack caps for every concrete Reference (no pointer offsets).
    # Always-on and sound: only shortens conservative word-scan past instance_sizeof.
    # Do not install "leaf" empties here — misclassified value-only types UAF under HTTP.
    def self.register_scan_caps : Nil
      {% begin %}
        {% for t in Reference.all_subclasses %}
          {% skip = t.abstract? || t.private? || (t.stringify.includes?("::") && t.stringify.includes?("(")) %}
          {% for tv in t.type_vars %}
            {% unless tv.is_a?(TypeNode) && !tv.abstract? %}
              {% skip = true %}
            {% end %}
          {% end %}
          {% unless skip || t <= Hash %}
            bytes = instance_sizeof({{t}}).to_u64
            rounded, _ = SizeClasses.fit(bytes)
            install_scan_cap({{t}}.crystal_instance_type_id, rounded.to_u32, bytes.to_u32)
          {% end %}
        {% end %}
      {% end %}
    end

    # Auto-register precise layouts for every concrete Reference subclass in the
    # program. Must be a method (instance_vars are unavailable at top-level macro).
    # Hash instantiations use register_hash; unbound generics are skipped.
    # Mixed value|ref unions install scan_cap only (see register).
    def self.register_all_from_reference_subclasses : Nil
      ensure_booted
      {% begin %}
        {% for t in Reference.all_subclasses %}
          # Skip nested Foo::Bar(T) names (macro hygiene). This also skips
          # Hash(HTTP::Headers::Key, …) — those stay conservative. Precise
          # Hash registration for nested key types was unsound with soft-dirty
          # minors under release Kemal (nursery keys in old @entries).
          {% skip = t.abstract? || t.private? || (t.stringify.includes?("::") && t.stringify.includes?("(")) %}
          {% name = t.stringify %}
          {% for prefix in UNSAFE_PREFIXES %}
            {% if name.starts_with?(prefix) %}
              {% skip = true %}
            {% end %}
          {% end %}
          {% for tv in t.type_vars %}
            # Only concrete TypeNode args are instantiable (skip MacroId, Int, 256, …).
            {% unless tv.is_a?(TypeNode) && !tv.abstract? %}
              {% skip = true %}
            {% end %}
          {% end %}
          {% unless skip %}
            {% if t <= Hash %}
              {% if t.type_vars.size == 2 %}
                register_hash({{t.type_vars[0]}}, {{t.type_vars[1]}})
              {% else %}
                @@unsafe_skips += 1_u64
              {% end %}
            {% else %}
              register({{t}})
            {% end %}
          {% else %}
            @@unsafe_skips += 1_u64
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

  def self.register_set(elem_type : T.class) forall T
    Layout.register_set(elem_type)
  end

  # Register layouts for all concrete Reference subclasses visible to the compiler.
  def self.register_layouts : Nil
    Layout.register_all_from_reference_subclasses
  end
end
