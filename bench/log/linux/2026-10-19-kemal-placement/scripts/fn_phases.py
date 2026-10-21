"""Each hot function's address mod 64 and layout signature, per binary.

usage: fn_phases.py OUT.json NAME=BINARY... [--hot REGEX] [--top FILE]

For every binary (`nm -n` for addresses, `objdump -d` for code), and every
function whose name matches --hot or is listed in --top (one name per line:
callgrind's exclusive-Ir ranking), records its address, its size, and a
layout signature: a hash of each instruction's mnemonic and length, with
branch targets inside the function as offsets from its start. Two builds whose
signature and address mod 64 agree lay the function out identically against
cache lines, whatever moved around it. Writes {name: {binary: [addr, size,
sig]}} to OUT.json.
"""
import hashlib, json, re, subprocess, sys


def nm(binary):
    out = []
    for line in subprocess.run(["nm", "-n", binary], capture_output=True, text=True).stdout.splitlines():
        p = line.split(" ", 2)
        if len(p) == 3 and p[1] in "tTwW" and re.fullmatch(r"[0-9a-f]{16}", p[0]):
            out.append((int(p[0], 16), p[2]))
    return out


def signature(binary, start, end):
    dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", f"--start-address={start}",
                          f"--stop-address={end}", binary], capture_output=True, text=True).stdout
    h = hashlib.sha1()
    addrs = []
    for line in dis.splitlines():
        m = re.match(r"\s+([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
        if m:
            addrs.append((int(m.group(1), 16), m.group(2), m.group(3)))
    for i, (a, mn, ops) in enumerate(addrs):
        ln = (addrs[i + 1][0] if i + 1 < len(addrs) else end) - a
        t = re.match(r"([0-9a-f]+) <", ops)
        tgt = ""
        if t and start <= int(t.group(1), 16) < end:
            tgt = str(int(t.group(1), 16) - start)
        h.update(f"{mn}/{ln}/{tgt};".encode())
    return h.hexdigest()[:8]


def main():
    args = sys.argv[1:]
    out = args.pop(0)
    hot, top = None, set()
    if "--hot" in args:
        i = args.index("--hot")
        hot = args[i + 1]
        del args[i:i + 2]
    if "--top" in args:
        i = args.index("--top")
        top = set(open(args[i + 1]).read().splitlines())
        del args[i:i + 2]
    res = {}
    for spec in args:
        name, binary = spec.split("=", 1)
        syms = nm(binary)
        for k, (addr, fn) in enumerate(syms):
            if (hot and re.search(hot, fn)) or fn in top:
                end = syms[k + 1][0] if k + 1 < len(syms) else addr + 64
                res.setdefault(fn, {})[name] = [addr, end - addr, signature(binary, addr, end)]
    json.dump(res, open(out, "w"), indent=0)
    print(f"{len(res)} functions, {len(args)} binaries")


if __name__ == "__main__":
    main()
