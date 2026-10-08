# Idle mark helpers and a list-shaped heap

Host: QEMU x86-64 guest, 12 vCPUs, runs pinned to `taskset -c 8-11` (4 CPUs,
so the default is 2 mark workers), Crystal 1.21.0. Base is `a4c0dbd`
(readiness).

## The defect

`bench/mark_list_heap.cr` builds one 3 M-node singly linked list, 24-byte
nodes, above the 32 MiB live floor. That gives the mark nothing to divide.
On base (`list-heap.txt`):

- Every helper polled the empty shared stack for the whole mark. CPU per
  second of collecting was 2.05 cores with 2 workers and 4.00 with 4,
  against 1.05 serial.
- The pause was longer than serial: 37.5 / 40.1 ms against 31.6.

Callgrind on 300 000 nodes shows the master's own parallel path cost 54
instructions per scanned object more than the serial drain:

- `Heap.mark_worker`, the out-of-line accessor Crystal emits for a
  `@[ThreadLocal]`, was called twice per object;
- the local drain made a `memcpy` call per node;
- the push did index arithmetic.

## Changes

1. Idle markers park, and only the right events wake them.
   - In a cycle, a marker that has found the shared stack empty for 50 µs
     parks. On Linux it waits on the existing `@mark_wake` futex; elsewhere
     it sleeps 100 µs → 1 ms.
   - Wake-ups:
     - a flush that leaves more than `MARK_POP_BATCH` entries;
     - a large payload's rest entry, if no marker is spinning;
     - the end of the cycle;
     - the batch end that leaves no work held and an empty stack, for a
       parked master (Linux only).
   - Termination detection is untouched.
2. The scan path is handed the worker's shard as a struct.
   - Its push buffer is now base/top/limit, and it holds the scanned-bytes
     count.
   - The serial copy of the path reaches the parallel push only through the
     out-of-line `push_to_own_shard`.

## Results

`list-heap.txt`, 15 trials:

| arm | pause | CPU per second of collecting |
|---|---|---|
| serial | 30.3 ms | 1.05 |
| 2 workers | 31.9 ms | 1.07 |
| 4 workers | 31.1 ms | 1.11 |

Min pauses were 26.0 / 25.7 / 26.0 ms. Callgrind: 2 workers now cost 0.35%
more instructions than serial, and serial costs 1.5% less than base.

crystal-metric, 9 interleaved trials, five arms: base and new at the default
and at `GCRY_PARALLEL_MARK=4`, plus Boehm.

- `ab-cm-1.txt` waked a parked marker for every rest entry. That cost
  JsonGenerate +4.6% and Revcomp +7.8% against base (a syscall per 64 KiB
  piece).
- `ab-cm-2.txt` skips that wake while a marker is spinning. JsonGenerate is
  then −0.4%, Revcomp −0.6%, JsonParsePure −3.9%, and the other rows are
  within ±1%.
- Primes is open: +8.7% (`ab-cm-2`) and +2.6% (`ab-cm-1`) at two workers,
  with overlapping ranges.

## Gates

- `process_spec/regression/33_idle_mark_helpers_park_spec.cr` on base: ratio
  4.0 against a bound of 1.6.
- `10_monitor_wait_cpu_spec` now marks serially. With its old
  `workers + 0.4` bound and parked helpers, a Monitor forced to spin
  (`WAIT_SPINS = Int32::MAX`) passed it. Under the serial pin it fails at a
  ratio of 1.94.
