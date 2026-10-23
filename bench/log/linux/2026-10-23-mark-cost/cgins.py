#!/usr/bin/env python3
"""cgins.py OUT BINARY FUNC_SUBSTR: per-instruction Ir (self cost) of one function
from a callgrind --dump-instr=yes output, printed beside objdump's disassembly."""
import sys, re, subprocess, collections

out, binary, want = sys.argv[1], sys.argv[2], sys.argv[3]
names = {}
cur_fn = None
in_call = False
costs = collections.Counter()
last = [0, 0]
positions = None


def num(tok, i):
    if tok == '*':
        return last[i]
    if tok[0] in '+-':
        return last[i] + int(tok, 0)
    return int(tok, 0)


for ln in open(out):
    ln = ln.rstrip('\n')
    if ln.startswith('positions:'):
        positions = ln.split()[1:]
        continue
    m = re.match(r'^(c?fn)=\((\d+)\)(?: (.*))?$', ln)
    if m:
        kind, idx, name = m.groups()
        if name:
            names[idx] = name
        if kind == 'fn':
            cur_fn = names[idx]
        continue
    if ln.startswith('calls='):
        in_call = True
        continue
    if not ln or not (ln[0].isdigit() or ln[0] in '+-*'):
        continue
    parts = ln.split()
    a = num(parts[0], 0)
    l = num(parts[1], 1) if len(positions) > 1 else 0
    last[0] = a
    if len(positions) > 1:
        last[1] = l
    if in_call:
        in_call = False  # inclusive cost of a call: skip
        continue
    if cur_fn and want in cur_fn:
        costs[a] += int(parts[len(positions)]) if len(parts) > len(positions) else 0

if not costs:
    sys.exit('no costs')
lo, hi = min(costs), max(costs) + 16
dis = subprocess.run(['objdump', '-d', '--no-show-raw-insn', f'--start-address={lo}', f'--stop-address={hi}', binary],
                     capture_output=True, text=True).stdout
total = sum(costs.values())
print(f'total Ir {total:,}')
for dl in dis.splitlines():
    m = re.match(r'\s+([0-9a-f]+):\s+(.*)', dl)
    if not m:
        continue
    o = int(m.group(1), 16)
    print(f'{costs.get(o, 0):14,} {o:x}: {m.group(2)[:80]}')
