#!/usr/bin/env python3
"""cgev.py OUT BINARY FUNC_SUBSTR: per-instruction self cost of every event
(Ir, Dr, D1mr, DLmr, ...) of one function from a callgrind --dump-instr=yes
--cache-sim=yes output, beside objdump's disassembly. Rows with no cost are
printed too, so the code reads in order."""
import sys, re, subprocess, collections

out, binary, want = sys.argv[1], sys.argv[2], sys.argv[3]
names = {}
cur_fn = None
in_call = False
costs = collections.defaultdict(lambda: None)
last = [0, 0]
positions = events = None


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
    if ln.startswith('events:'):
        events = ln.split()[1:]
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
    np_ = len(positions)
    a = num(parts[0], 0)
    if np_ > 1:
        last[1] = num(parts[1], 1)
    last[0] = a
    if in_call:
        in_call = False
        continue
    if cur_fn and want in cur_fn:
        vals = [int(x) for x in parts[np_:]] + [0] * (len(events) - len(parts[np_:]))
        c = costs[a]
        costs[a] = vals if c is None else [x + y for x, y in zip(c, vals)]

if not costs:
    sys.exit('no costs')
lo, hi = min(costs), max(costs) + 16
dis = subprocess.run(['objdump', '-d', '--no-show-raw-insn', f'--start-address={lo}', f'--stop-address={hi}', binary],
                     capture_output=True, text=True).stdout
tot = [sum(c[i] for c in costs.values()) for i in range(len(events))]
print('total ' + '  '.join(f'{e} {t:,}' for e, t in zip(events, tot)))
show = [i for i, e in enumerate(events) if e in ('Ir', 'Dr', 'Dw', 'D1mr', 'D1mw', 'DLmr', 'DLmw')]
print(' '.join(f'{events[i]:>12}' for i in show))
for dl in dis.splitlines():
    m = re.match(r'\s+([0-9a-f]+):\s+(.*)', dl)
    if not m:
        continue
    o = int(m.group(1), 16)
    c = costs.get(o) or [0] * len(events)
    print(' '.join(f'{c[i]:12,}' for i in show) + f' {o:x}: {m.group(2)[:70]}')
