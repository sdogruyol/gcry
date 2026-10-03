import os, re, subprocess, sys, sys as _s
trials = int(sys.argv[1]) if len(sys.argv) > 1 else 5
benches = "Binarytrees Brainfuck Brainfuck2 Knuckeotide RegexDna Revcomp Threadring Matmul JsonGenerate JsonParseSerializable JsonParsePull Primes JsonParsePure".split()
scale = 1024 if _s.platform == "darwin" else 1  # ru_maxrss: bytes on macOS, KiB on Linux
for t in range(1, trials + 1):
    for b in benches:
        arms = ["boehm", "gcry"] if t % 2 else ["gcry", "boehm"]
        for arm in arms:
            p = subprocess.Popen([f"bin/cm-{arm}.exe", b], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out = p.stdout.read().decode(errors="replace")
            _, status, ru = os.wait4(p.pid, 0)
            m = re.findall(rf"^{b}:.*? in ([0-9.]+)s", out, re.M)
            secs = float(m[-1]) if m else -1
            print(f"ROW {t} {b} {arm} {secs} {ru.ru_maxrss // scale} rc={status}", flush=True)
