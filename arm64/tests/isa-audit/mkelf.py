#!/usr/bin/env python3
"""Hand-written ELF fixtures for tests/run.sh (no toolchain needed).

    python3 tests/mkelf.py OUTDIR

Writes:
  helper-symtab.o      ET_REL: LDADDAL + RET inside a symbol named
                       __aarch64_ldadd4_acq_rel (.symtab)        -> OK, outline
  helper-plus-inline.o the same helper, then an LSE op in foo()  -> RISK, 1 inline
  helper-stripped.o    ET_REL without symbols: a libgcc-style outline helper
                       (ADRP/LDRB/CBZ x16 test, LSE, RET, LL/SC loop)
                                                                 -> OK, heuristic
  static-lse           ET_EXEC, no section headers, one PT_LOAD R+X:
                       SWPALB on the stack, then exit(0)         -> RISK (segments);
                       SIGILL on an ARMv8.0 CPU with --run
  x86-64.o             ET_REL for EM_X86_64                       -> skipped
  truncated.o          first 100 bytes of helper-symtab.o         -> ERROR
  truncated-header.o   first 40 bytes of helper-symtab.o          -> ERROR
"""

import os
import struct
import sys

EM_AARCH64, EM_X86_64 = 183, 62

# A64 words (checked against llvm-objdump)
RET = 0xD65F03C0
LDADDAL_W0_W0_X1 = 0xB8E00020      # ldaddal w0, w0, [x1]
ADRP_X16 = 0x90000010              # adrp x16, .
LDRB_W16_X16 = 0x39400210          # ldrb w16, [x16]
CBZ_W16_P12 = 0x34000070           # cbz w16, .+12
MOV_W16_W0 = 0x2A0003F0            # mov w16, w0
LDAXR_W0_X1 = 0x885FFC20           # ldaxr w0, [x1]
ADD_W17_W0_W16 = 0x0B100011        # add w17, w0, w16
STLXR_W15_W17_X1 = 0x880FFC31      # stlxr w15, w17, [x1]
CBNZ_W15_M12 = 0x35FFFFAF          # cbnz w15, .-12
SWPALB_W8_W9_SP = 0x38E883E9       # swpalb w8, w9, [sp]
MOV_X0_0 = 0xD2800000              # mov x0, #0
MOV_X8_93 = 0xD2800BA8             # mov x8, #93 (exit)
SVC_0 = 0xD4000001                 # svc #0


def code(*words):
    return struct.pack("<%dI" % len(words), *words)


def ehdr(e_type, machine, entry, phoff, phnum, shoff, shnum, shstrndx):
    ident = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8)
    return ident + struct.pack("<HHIQQQIHHHHHH", e_type, machine, 1, entry, phoff, shoff, 0,
                               64, 56 if phnum else 0, phnum, 64 if shnum else 0, shnum, shstrndx)


def shdr(name, sh_type, flags, addr, off, size, link, info, align, entsize):
    return struct.pack("<IIQQQQIIQQ", name, sh_type, flags, addr, off, size, link, info, align, entsize)


def pad(buf, align):
    return buf + bytes(-len(buf) % align)


def rel_object(text, symbols=(), machine=EM_AARCH64):
    """ET_REL with .text (+ .symtab/.strtab when symbols are given) and
    .shstrtab. symbols: [(name, value, size)] global FUNC symbols in .text."""
    names = [".text", ".shstrtab"] + ([".symtab", ".strtab"] if symbols else [])
    shstrtab, name_off = b"\0", {}
    for n in names:
        name_off[n] = len(shstrtab)
        shstrtab += n.encode() + b"\0"
    strtab = b"\0"
    syms = [bytes(24)]
    for name, value, size in symbols:
        syms.append(struct.pack("<IBBHQQ", len(strtab), (1 << 4) | 2, 0, 1, value, size))
        strtab += name.encode() + b"\0"
    symtab = b"".join(syms)

    body = bytes(64)
    text_off = len(body)
    body = pad(body + text, 8)
    shstr_off = len(body)
    body = pad(body + shstrtab, 8)
    sym_off = len(body)
    body = pad(body + symtab, 8) if symbols else body
    str_off = len(body)
    body = pad(body + strtab, 8) if symbols else body
    shoff = len(body)
    sh = [bytes(64),
          shdr(name_off[".text"], 1, 0x6, 0, text_off, len(text), 0, 0, 4, 0),
          shdr(name_off[".shstrtab"], 3, 0, 0, shstr_off, len(shstrtab), 0, 0, 1, 0)]
    if symbols:
        sh.append(shdr(name_off[".symtab"], 2, 0, 0, sym_off, len(symtab), 4, 1, 8, 24))
        sh.append(shdr(name_off[".strtab"], 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0))
    head = ehdr(1, machine, 0, 0, 0, shoff, len(sh), 2)
    return head + body[64:] + b"".join(sh)


def static_exec(text):
    """ET_EXEC, no section headers, one PT_LOAD (R+X) holding only the code."""
    off = 64 + 56
    vaddr = 0x400000 + off
    head = ehdr(2, EM_AARCH64, vaddr, 64, 1, 0, 0, 0)
    ph = struct.pack("<IIQQQQQQ", 1, 0x5, off, vaddr, vaddr, len(text), len(text), 0x1000)
    return head + ph + text


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: mkelf.py OUTDIR")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    helper = code(LDADDAL_W0_W0_X1, RET)
    libgcc_helper = code(RET,                       # end of the previous function
                         ADRP_X16, LDRB_W16_X16, CBZ_W16_P12,
                         LDADDAL_W0_W0_X1, RET,
                         MOV_W16_W0, LDAXR_W0_X1, ADD_W17_W0_W16, STLXR_W15_W17_X1,
                         CBNZ_W15_M12, RET)
    files = {
        "helper-symtab.o": rel_object(helper, [("__aarch64_ldadd4_acq_rel", 0, 8)]),
        "helper-plus-inline.o": rel_object(helper + helper, [("__aarch64_ldadd4_acq_rel", 0, 8),
                                                             ("foo", 8, 8)]),
        "helper-stripped.o": rel_object(libgcc_helper),
        "static-lse": static_exec(code(SWPALB_W8_W9_SP, MOV_X0_0, MOV_X8_93, SVC_0)),
        "x86-64.o": rel_object(b"\x31\xc0\xc3\x90", [("f", 0, 3)], machine=EM_X86_64),
    }
    files["truncated.o"] = files["helper-symtab.o"][:100]
    files["truncated-header.o"] = files["helper-symtab.o"][:40]
    for name, data in files.items():
        path = os.path.join(out, name)
        with open(path, "wb") as f:
            f.write(data)
        if name == "static-lse":
            os.chmod(path, 0o755)


if __name__ == "__main__":
    main()
