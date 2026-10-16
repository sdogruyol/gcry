"""Function offsets and code-layout signatures of a COFF object (llvm-objdump).

`functions(obj)` maps each function's demangled name to (offset in `.text`,
size, signature). The signature hashes the function's instruction stream as
(mnemonic, encoded length, branch target inside the function) per
instruction: two builds whose function has the same signature lay it out
byte for byte the same way, so where it lands is the only thing that can
differ. Immediates, displacements and calls to other functions are left
out: a type id that differs by one or a callee that moved leaves the layout
alone.

MSVC-target objects write Crystal's names with `.XX.` hex escapes (`.2A.` is
`*`); `demangle` decodes them.
"""
import hashlib, re, subprocess

HEAD = re.compile(r"^([0-9a-f]{16}) <(.*)>:$")
INSN = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s*(\S+)?(.*)$")


def demangle(s):
    return re.sub(r"\.([0-9A-F]{2})\.", lambda m: chr(int(m.group(1), 16)), s)


def functions(obj):
    dis = subprocess.run(["llvm-objdump", "-d", "--section=.text", obj], capture_output=True, text=True).stdout
    out, name, start, sig, last = {}, None, 0, [], 0

    def close():
        if name is not None:
            h = hashlib.sha1("\n".join(sig).encode()).hexdigest()[:10]
            out.setdefault(demangle(name), (start, last - start, h))

    for line in dis.splitlines():
        m = HEAD.match(line)
        if m:
            close()
            name, start, sig, last = m.group(2), int(m.group(1), 16), [], int(m.group(1), 16)
            continue
        m = INSN.match(line)
        if m and name is not None:
            addr, nbytes = int(m.group(1), 16), len(m.group(2).split())
            last = max(last, addr + nbytes)
            if m.group(3) is None:  # a continuation line of a long encoding
                sig.append(f"+{nbytes}")
                continue
            target = re.search(r"<[^>+]*\+0x([0-9a-f]+)>", m.group(4))
            own = target and m.group(4).find("<" + name + "+") >= 0
            sig.append(f"{m.group(3)} {nbytes}" + (f" ->{target.group(1)}" if own else ""))
    close()
    return out
