# Prints the SIMD tier this host can actually execute. `make kernels-broken`
# uses it to refuse a run on a scalar-only host, where breaking the vector
# clones would change nothing and the positive control could not fire.
require "../src/gcry/cpu"

print Gcry::Cpu.tier_name(Gcry::Cpu.detect)
