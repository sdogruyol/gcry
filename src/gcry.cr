# gcry — a Crystal garbage collector
#
# Alternative to bdwgc. Integrate like ysbaddaden/gc (immix):
#   require "gcry"  and  crystal build -Dgc_none
#
# See DESIGN.md and docs/INTEGRATION.md.
module Gcry
  VERSION = "0.1.0"
end

# Phase 4+: reopen ::GC here under flag?(:gc_none) and forward to Gcry::*.
