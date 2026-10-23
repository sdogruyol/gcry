#!/usr/bin/env python3
# One line per kept log of the probe (or of CI): which run_one phase the run was
# in (the last "STW-MT workers=N" header), how many collections the dying-type
# audit reported before its three-report limit, whether a watchdog line was
# printed, and from the `sample` capture: each named thread's innermost
# interesting frame, the threads spinning in `Parallel::Scheduler#resume` at
# scheduler.cr:97, and whether any collector frame (stop_world /
# run_collection / Gcry::Heap#collect / pthread_mach_thread_np) is present.
#
#   classify_stalls.py <log>...
import re, sys

for path in sys.argv[1:]:
    text = open(path, errors='replace').read()
    phase = re.findall(r'STW-MT workers=(\d+)', text)
    audits = len(re.findall(r'dying-type audit', text))
    stalled = 'STALLED: still running' in text
    upstream = 'STALL CLASSIFIED' in text
    dead = re.findall(r'ERROR: (after collect #\d+: root \d+ DEAD)', text)
    watchdog = 'STOP-THE-WORLD STALLED' in text
    # `sample` call graph: a thread header is "    <n> Thread_<id>[: name]".
    threads = re.split(r'\n    \d+ (Thread_\d+[^\n]*)', text)
    spinning, waiting = [], []
    for i in range(1, len(threads), 2):
        name = threads[i].split('DispatchQueue')[0].strip()
        body = threads[i + 1]
        if 'scheduler.cr:97' in body:
            via = 'send' if 'Channel#send' in body or '#send<' in body else ('receive' if '#receive' in body else '?')
            spinning.append(f'{name.split(": ")[-1]}({via})')
        elif 'kevent' in body and 'Thread_' in name and 'main-thread' in threads[i]:
            waiting.append('main:kevent')
    collector = bool(re.search(r'stop_world|run_collection|Gcry::Heap#collect|pthread_mach_thread_np', text))
    print(f"{path}: workers={phase[-1] if phase else '?'} audits={audits} stalled={stalled} "
          f"upstream={upstream} watchdog={watchdog} collector_frame={collector} "
          f"spinning@97={','.join(spinning) or '-'} {' '.join(waiting)} {' '.join(dead)}")
