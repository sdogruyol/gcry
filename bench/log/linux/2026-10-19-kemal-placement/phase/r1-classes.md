
### 4 groups; 26565 Ir/request in its 17 hot functions
groups: {base, baseprepad32, prepad0}; {baseprepad0, prepad32, var}; {baseprepad16, prepad2096, prepad48}; {baseprepad2096, baseprepad48, prepad16}
- 9V74: R² 0.71 (adj. 0.60), widest group 1.4 pts
- 9V45: R² 0.79 (adj. 0.71), widest group 1.3 pts
- 7763: R² 0.69 (adj. 0.58), widest group 2.8 pts
  -  10128 `*JSON::Builder::Escape#write<Slice(UInt8)>:Nil`
  -   6159 `*Char#to_s<IO+>:Nil`
  -   3221 `*Gcry::Heap#malloc_atomic<UInt64>:Pointer(Void)`
  -   1502 `*Hash(HTTP::Headers::Key, Array(String) | String)@Hash(K, V)#key_hash<HTTP::Headers::Key>:UInt32`
  -   1056 `*Socket+@IO::Buffered#write<Slice(UInt8)>:Nil`
  -    989 `*Hash(HTTP::Headers::Key, Array(String) | String)@Hash(K, V)#find_entry<HTTP::Headers::Key>:(Hash::E`
  -    864 `*Int32@Int#to_s<IO+>:Nil`
  -    546 `*IO+@IO#write_string<Slice(UInt8)>:Nil`
  -    506 `*Hash(HTTP::Headers::Key, Array(String) | String)@Hash(K, V)#[]=<HTTP::Headers::Key, String>:String`
  -    381 `*HTTP::parse_header<Slice(UInt8)>:Tuple(String, String)`
  -    363 `*HTTP::Server::Response#write_headers:Bool`
  -    302 `*Hash(HTTP::Headers::Key, Array(String) | String)@Hash(K, V)#entry_matches?<Hash::Entry(HTTP::Header`

### 4 groups; 16734 Ir/request in its 13 hot functions
groups: {base, baseprepad32, prepad16}; {baseprepad0, prepad2096, prepad48}; {baseprepad16, prepad0}; {baseprepad2096, baseprepad48, prepad32, var}
- 9V74: R² 0.55 (adj. 0.38), widest group 1.8 pts
- 9V45: R² 0.51 (adj. 0.32), widest group 2.6 pts
- 7763: R² 0.17 (adj. -0.15), widest group 4.6 pts
  -   4357 `*String::Builder#increase_capacity_by<Int32>:(Pointer(UInt8) | Nil)`
  -   3328 `*JSON::Builder#end_scalar<Bool>:(JSON::Builder::ArrayState | JSON::Builder::DocumentEndState | JSON:`
  -   3010 `*JSON::Builder#start_scalar<Bool>:Nil`
  -   2549 `*GC::realloc_impl<Pointer(Void), UInt64>:Pointer(Void)`
  -   1850 `*JSON::Builder#string<String>:Nil`
  -    410 `*JSON::Builder#end_object:Nil`
  -    300 `*JSON::Builder#start_object:Nil`
  -    290 `*HTTP::Server::Response#content_type=<String>:String`
  -    226 `*Array(JSON::Builder::ArrayState | JSON::Builder::DocumentEndState | JSON::Builder::DocumentStartSta`
  -    120 `*Gcry::Heap#chunk_search_unlocked<UInt64>:(Pointer(Gcry::ChunkHeader) | Nil)`
  -    111 `*Gcry::Heap#scan_static_ranges:UInt64`
  -    106 `*String#byte_slice?<Int32, Int32>:(String | Nil)`

### 4 groups; 14977 Ir/request in its 28 hot functions
groups: {base, baseprepad32, prepad32, var}; {baseprepad0, prepad0}; {baseprepad16, prepad16}; {baseprepad2096, baseprepad48, prepad2096, prepad48}
- 9V74: R² 0.06 (adj. -0.29), widest group 3.0 pts
- 9V45: R² 0.26 (adj. -0.02), widest group 3.1 pts
- 7763: R² 0.21 (adj. -0.09), widest group 4.7 pts
  -   3886 `*String::Builder#write_byte<UInt8>:Nil`
  -   3580 `*Gcry::Heap#malloc<UInt64>:Pointer(Void)`
  -   1334 `*Int32@Int#to_s<String::Builder>:Nil`
  -    872 `*String::interpolation<String, Int32, String, Int32>:String`
  -    565 `~procProc(HTTP::Server::Context, String)@src/server.cr:112`
  -    459 `*GC::malloc_atomic<UInt64>:Pointer(Void)`
  -    456 `*Gcry::Heap::tls_cursor_cache`
  -    371 `*Kemal::InitHandler#call<HTTP::Server::Context>:Nil`
  -    358 `*Crystal::System::File::info?<String, Bool>:(File::Info | Nil)`
  -    336 `*String#*<Int32>:String`
  -    330 `*String::Builder#to_s':String`
  -    330 `*HTTP::StaticFileHandler+@HTTP::StaticFileHandler#call<HTTP::Server::Context>:Nil`

### 4 groups; 2124 Ir/request in its 9 hot functions
groups: {base, baseprepad32, prepad2096, prepad48}; {baseprepad0, prepad16}; {baseprepad16, prepad32, var}; {baseprepad2096, baseprepad48, prepad0}
- 9V74: R² 0.56 (adj. 0.39), widest group 1.9 pts
- 9V45: R² 0.29 (adj. 0.03), widest group 3.4 pts
- 7763: R² 0.72 (adj. 0.61), widest group 2.6 pts
  -    678 `*Gcry::Heap#mark_impl_unlocked<Pointer(Void), Bool, Bool, Gcry::Heap::RootSource>:Nil`
  -    612 `*Gcry::Heap#owns_user_pointer_in?<Pointer(Void), Pointer(Gcry::BlockHeader), Pointer(Gcry::ChunkHead`
  -    183 `*Gcry::Heap#scan_all_fiber_roots:Nil`
  -    153 `*String#single_byte_optimizable?:Bool`
  -    133 `*Gcry::Platform::stack_low_water<UInt64, UInt64>:UInt64`
  -    121 `*Gcry::SizeClasses::payload<Int32>:UInt32`
  -     90 `*Char::Reader#next_char:Char`
  -     84 `*Char#whitespace?:Bool`
  -     70 `*Gcry::Heap#bitmap_pool_candidate?<Pointer(Gcry::ChunkHeader), Int32, Bool>:Bool`

### 2 groups; 510 Ir/request in its 1 hot functions
groups: {base, var}; {baseprepad0, baseprepad16, baseprepad2096, baseprepad32, baseprepad48, prepad0, prepad16, prepad2096, prepad32, prepad48}
- 9V74: R² 0.01 (adj. -0.09), widest group 3.0 pts
- 9V45: R² 0.13 (adj. 0.04), widest group 3.4 pts
- 7763: R² 0.26 (adj. 0.19), widest group 4.7 pts
  -    510 `__crystal_malloc64`

### 8 groups; 408 Ir/request in its 3 hot functions
groups: {base, baseprepad32}; {baseprepad0}; {baseprepad16}; {baseprepad2096, baseprepad48}; {prepad0}; {prepad16}; {prepad2096, prepad48}; {prepad32, var}
- 9V74: R² 0.88 (adj. 0.67), widest group 1.1 pts
- 9V45: R² 0.86 (adj. 0.61), widest group 1.2 pts
- 7763: R² 0.86 (adj. 0.62), widest group 2.0 pts
  -    168 `*Gcry::Heap#stop_world_quiescing_roots:Nil`
  -    132 `*Gcry::Heap#start_world:Nil`
  -    108 `*Gcry::Heap#run_collection_body<Bool, Bool, Nil, Bool, Bool, Bool>:Nil`
