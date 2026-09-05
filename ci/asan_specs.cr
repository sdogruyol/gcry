# Real ASan coverage for libc-owned cursor metadata. Collector stack capture
# and conservative root scans need separate sanitizer integration; the full
# ordinary spec suite remains a separate required check.
require "../spec/cursor_cache_lifetime_spec"
