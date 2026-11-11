#!/usr/bin/env bash
# Tally loop.sh output per label: runs, fired, missed, nonzero exits; for the
# instrumented builds how many stops' wait never spun and whether every miss
# is one of them; for the fixed arm how many runs showed a drop and a resend.
awk '
{
  b = $1; n[b]++; f[b] += $3
  if ($4 != "rc=0") bad[b]++
  spun = -1; dr = -1; rs = -1
  for (i = 5; i <= NF; i++) {
    if ($i ~ /^spun=/) { split($i, a, "="); spun = a[2] }
    if ($i ~ /^dropped=/) { split($i, a, "="); dr = a[2] }
    if ($i ~ /^resends=/) { split($i, a, "="); rs = a[2] }
  }
  if (spun >= 0) probed[b]++
  if (spun == 0) s0[b]++
  if ($3 == 0 && spun == 0) m0[b]++
  if ($3 == 1 && spun == 0) f0[b]++
  if (dr > 0 && rs > 0) dropres[b]++
}
END {
  for (b in n) {
    printf "%-12s runs=%d fired=%d missed=%d rc!=0=%d", b, n[b], f[b], n[b] - f[b], bad[b] + 0
    if (probed[b]) printf " never_spun=%d missed&never_spun=%d fired&never_spun=%d", s0[b] + 0, m0[b] + 0, f0[b] + 0
    printf " dropped&resent=%d\n", dropres[b] + 0
  }
}' "$@" | sort
