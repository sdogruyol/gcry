66 observations (19 binaries) on 4 CPU models

| R² | p (permutation) | groups | functions (first 4 by name) |
|---:|---:|---:|---|
| 0.51 | 0.000 | 4 | 15: `*Char#to_s<IO+>:Nil`, `*HTTP::Server::Response#write_headers:Bool`, `*HTTP::parse_header<Slice(UInt8)>:Tuple(String, String)`, `*Hash(HTTP::Headers::Key, Array(String) | String)@Hash(K, V)` |
| 0.44 | 0.252 | 9 | 1: `*Gcry::Heap#run_collection_body<Bool, Bool, Nil, Bool, Bool,` |
| 0.35 | 0.486 | 8 | 1: `*Gcry::Heap#start_world:Nil` |
| 0.28 | 0.053 | 4 | 7: `*Array(JSON::Builder::ArrayState | JSON::Builder::DocumentEn`, `*HTTP::Server::Response#content_type=<String>:String`, `*JSON::Builder#end_object:Nil`, `*JSON::Builder#end_scalar<Bool>:(JSON::Builder::ArrayState |` |
| 0.28 | 0.074 | 4 | 1: `*Gcry::Heap#malloc_atomic<UInt64>:Pointer(Void)` |
| 0.26 | 0.099 | 4 | 3: `*Gcry::Heap#bitmap_pool_candidate?<Pointer(Gcry::ChunkHeader`, `*Gcry::Heap#scan_all_fiber_roots:Nil`, `*Gcry::Platform::stack_low_water<UInt64, UInt64>:UInt64` |
| 0.26 | 0.104 | 4 | 1: `*Int32@Int#to_s:String` |
| 0.25 | 0.848 | 8 | 1: `*Gcry::Heap#stop_world_quiescing_roots:Nil` |
| 0.24 | 0.137 | 4 | 1: `*Gcry::Heap#mark_impl_unlocked<Pointer(Void), Bool, Bool, Gc` |
| 0.16 | 0.396 | 4 | 2: `*Crystal::System::File::info?<String, Bool>:(File::Info | Ni`, `*Gcry::Heap#scan_edges_inline<Pointer(UInt64), UInt64, Bool,` |
| 0.16 | 0.534 | 4 | 2: `*Gcry::Heap#owns_user_pointer_in?<Pointer(Void), Pointer(Gcr`, `*Gcry::SizeClasses::payload<Int32>:UInt32` |
| 0.15 | 0.592 | 4 | 3: `*Char#whitespace?:Bool`, `*Char::Reader#next_char:Char`, `*String#single_byte_optimizable?:Bool` |
| 0.14 | 0.505 | 4 | 3: `*GC::realloc_impl<Pointer(Void), UInt64>:Pointer(Void)`, `*Gcry::Heap#chunk_search_unlocked<UInt64>:(Pointer(Gcry::Chu`, `*String::Builder#increase_capacity_by<Int32>:(Pointer(UInt8)` |
| 0.11 | 0.693 | 4 | 3: `*Gcry::Heap#scan_static_ranges:UInt64`, `*Path#absolute?:Bool`, `*String#byte_slice?<Int32, Int32>:(String | Nil)` |
| 0.11 | 0.725 | 4 | 12: `*Char#to_s<String::Builder>:Nil`, `*Crystal::System::Thread::current_thread:Thread`, `*GC::malloc_atomic<UInt64>:Pointer(Void)`, `*Gcry::Heap#malloc<UInt64>:Pointer(Void)` |
| 0.10 | 0.133 | 2 | 1: `__crystal_malloc64` |
| 0.10 | 0.781 | 4 | 13: `*HTTP::Request::parse_request_line<Slice(UInt8)>:(HTTP::Requ`, `*HTTP::Server::RequestProcessor#process<IO+, IO+>:Nil`, `*HTTP::StaticFileHandler+@HTTP::StaticFileHandler#call<HTTP:`, `*Hash(String, Kemal::LRUCache::Node(String, Radix::Result(Ke` |

`*JSON::Builder::Escape#write<Slice(UInt8)>:Nil`: R² by granularity: mod 16 0.00, mod 32 0.06, mod 64 0.51, mod 128 0.63, mod 4096 0.76

| CPU | address mod 64 | mean effect vs v0.36.0 | n | arms (effect) |
|---|---:|---:|---:|---|
| 7763 | 0 | +1.1% | 9 | prepad48 -1.0, prepad2096 +1.0, baseprepad16 -0.3, fa51 +2.3, pad48 +1.4, basepad16 -0.8, fa51 +2.4, pad48 +1.8, basepad16 +2.7 |
| 7763 | 16 | -0.7% | 5 | base +0.0, prepad0 -1.2, baseprepad32 -2.5, base +0.0, base +0.0 |
| 7763 | 32 | -1.7% | 13 | prepad16 -2.2, baseprepad48 -4.6, baseprepad2096 -3.8, tip -1.8, a975 -0.6, pad16 -0.6, basepad48 -2.8, prepad16 -1.1, tip -0.7, a975 -1.2, pad16 -0.3, basepad48 -0.5, prepad16 -1.8 |
| 7763 | 48 | -0.2% | 5 | var +0.1, prepad32 -2.0, baseprepad0 -1.7, var +1.1, var +1.6 |
| 8573C | 0 | -0.6% | 3 | fa51 -2.2, pad48 +0.5, basepad16 -0.2 |
| 8573C | 16 | +0.0% | 1 | base +0.0 |
| 8573C | 32 | -3.2% | 5 | tip -4.1, a975 -3.7, pad16 -3.7, basepad48 -3.7, prepad16 -0.8 |
| 8573C | 48 | -1.4% | 1 | var -1.4 |
| 9V45 | 0 | -0.8% | 3 | prepad48 -0.8, prepad2096 -1.0, baseprepad16 -0.5 |
| 9V45 | 16 | -0.5% | 3 | base +0.0, prepad0 -0.4, baseprepad32 -1.3 |
| 9V45 | 32 | -2.9% | 3 | prepad16 -2.7, baseprepad48 -3.6, baseprepad2096 -2.5 |
| 9V45 | 48 | -1.4% | 3 | var -1.4, prepad32 -2.2, baseprepad0 -0.7 |
| 9V74 | 0 | +0.8% | 3 | prepad48 +1.7, prepad2096 +0.9, baseprepad16 -0.1 |
| 9V74 | 16 | +0.7% | 3 | base +0.0, prepad0 +0.9, baseprepad32 +1.3 |
| 9V74 | 32 | -0.8% | 3 | prepad16 -1.1, baseprepad48 -1.1, baseprepad2096 -0.3 |
| 9V74 | 48 | +1.1% | 3 | var +1.5, prepad32 +0.6, baseprepad0 +1.2 |

`*Gcry::Heap#malloc_atomic<UInt64>:Pointer(Void)`: R² by granularity: mod 16 0.00, mod 32 0.09, mod 64 0.28, mod 128 0.46, mod 4096 0.74

| CPU | address mod 64 | mean effect vs v0.36.0 | n | arms (effect) |
|---|---:|---:|---:|---|
| 7763 | 0 | +0.1% | 7 | base +0.0, prepad0 -1.2, baseprepad32 -2.5, base +0.0, fa51 +2.3, base +0.0, fa51 +2.4 |
| 7763 | 16 | -1.5% | 13 | prepad16 -2.2, baseprepad48 -4.6, baseprepad2096 -3.8, tip -1.8, a975 -0.6, basepad16 -0.8, basepad48 -2.8, prepad16 -1.1, tip -0.7, a975 -1.2, basepad16 +2.7, basepad48 -0.5, prepad16 -1.8 |
| 7763 | 32 | -0.2% | 5 | var +0.1, prepad32 -2.0, baseprepad0 -1.7, var +1.1, var +1.6 |
| 7763 | 48 | +0.3% | 7 | prepad48 -1.0, prepad2096 +1.0, baseprepad16 -0.3, pad16 -0.6, pad48 +1.4, pad16 -0.3, pad48 +1.8 |
| 8573C | 0 | -1.1% | 2 | base +0.0, fa51 -2.2 |
| 8573C | 16 | -2.5% | 5 | tip -4.1, a975 -3.7, basepad16 -0.2, basepad48 -3.7, prepad16 -0.8 |
| 8573C | 32 | -1.4% | 1 | var -1.4 |
| 8573C | 48 | -1.6% | 2 | pad16 -3.7, pad48 +0.5 |
| 9V45 | 0 | -0.5% | 3 | base +0.0, prepad0 -0.4, baseprepad32 -1.3 |
| 9V45 | 16 | -2.9% | 3 | prepad16 -2.7, baseprepad48 -3.6, baseprepad2096 -2.5 |
| 9V45 | 32 | -1.4% | 3 | var -1.4, prepad32 -2.2, baseprepad0 -0.7 |
| 9V45 | 48 | -0.8% | 3 | prepad48 -0.8, prepad2096 -1.0, baseprepad16 -0.5 |
| 9V74 | 0 | +0.7% | 3 | base +0.0, prepad0 +0.9, baseprepad32 +1.3 |
| 9V74 | 16 | -0.8% | 3 | prepad16 -1.1, baseprepad48 -1.1, baseprepad2096 -0.3 |
| 9V74 | 32 | +1.1% | 3 | var +1.5, prepad32 +0.6, baseprepad0 +1.2 |
| 9V74 | 48 | +0.8% | 3 | prepad48 +1.7, prepad2096 +0.9, baseprepad16 -0.1 |
