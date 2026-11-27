#!/usr/bin/env python3
"""Check, on a computer, what the installer of the 64-bit system writes in PARAM.

    python3 -I boot/golden/check-param.py STOCK_PARAM [LOADER_PARAM]
    python3 -I boot/golden/check-param.py --members STOCK_PARAM

STOCK_PARAM is a copy of a tablet's own PARAM partition (8 MiB, `dd if=/dev/mmcblk0p8`): it holds
Samsung's firmware and that tablet's data, so it is never published, and this script writes
nothing. It does what the installer's golden_forge does (boot/initramfs/init): PARAM's first
EXTENT bytes are a tar archive of the pictures S-Boot shows; logo.jpg's data is replaced by this
directory's logo.jpg (the loader), the members after it move, the archive is padded with zeros to
EXTENT. Then it says whether the stock part is one of the stock PARAMs the installer knows, and
whether the result is the loader of the same line: the two checks the installer makes before it
writes anything.

The installer knows one stock PARAM per line of stock.sha256 (the firmware T715XXU2CRH1 leaves
PARAM in two states), and loader.sha256 names the loader forged from it on the same line: the
loader of line N is forged from the stock PARAM of line N, never from another. The stock part is
a stock PARAM of line N when its first EXTENT bytes have that line's sha256, or when the archive
has it once the bytes after its end are taken as zeros: S-Boot reads the archive only, and the
installer accepts the second case too (golden_archive), since a flash of the firmware writes the
archive and may leave older bytes after it. The result must then have the sha256 on line N of
loader.sha256; the loader of another line is refused as any other result is.

--members prints the archive's members, one line each, "SHA256 SIZE NAME": how stock.members was
made, the list the installer compares a PARAM it does not know with, to say on screen what
differs. Samsung's pictures and two default settings, nothing of the tablet's own.

LOADER_PARAM, a PARAM image built by the loader's own tools (elkir0/bnuuyloader,
t715/loader/scripts/build_kboot.py), is compared too: its first EXTENT bytes must be the result.
That is how this directory's files were checked when they were made.
"""
import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def word(name: str) -> str:
    """The first word of a file of one word (extent)."""
    return (HERE / name).read_text().split()[0]


def sums(name: str) -> list[tuple[str, str]]:
    """The lines of stock.sha256 or loader.sha256: (sha256, label) for each, in order.  The
    label is the free text after the sum.  Lines of blanks only are skipped, as the installer
    skips them (its golden_words), so that line N of one file pairs with line N of the other."""
    out = []
    for line in (HERE / name).read_text().splitlines():
        fields = line.split(None, 1)
        if fields:
            out.append((fields[0], fields[1].strip() if len(fields) > 1 else ""))
    return out


def line_of(lines: list[tuple[str, str]], digest: str) -> int:
    """The number (from 1) of the line whose sha256 is DIGEST, 0 when none is: the installer's
    golden_line_of."""
    for n, (sum_, _) in enumerate(lines, start=1):
        if sum_ == digest:
            return n
    return 0


def forge(stock: bytes, logo: bytes, extent: int) -> bytes:
    out = bytearray()
    offset = 0
    replaced = False
    while offset + 512 <= extent and stock[offset] != 0:
        header = bytearray(stock[offset:offset + 512])
        name = bytes(header[:100]).split(b"\0")[0]
        size = int(bytes(header[124:136]).split(b"\0")[0].strip() or b"0", 8)
        blocks = (size + 511) // 512
        if name == b"logo.jpg":
            if replaced:
                raise SystemExit("two logo.jpg members in the archive")
            header[124:136] = b"%011o\0" % len(logo)
            header[148:156] = b"        "
            header[148:156] = b"%06o\0 " % (sum(header) & 0o7777777)
            out += header + logo + bytes(-len(logo) % 512)
            replaced = True
        else:
            out += stock[offset:offset + 512 + blocks * 512]
        offset += 512 + blocks * 512
    if not replaced:
        raise SystemExit("no logo.jpg in the archive: not a PARAM image")
    if len(out) + 1024 > extent:
        raise SystemExit(f"the forged archive ({len(out)} bytes) leaves no room before byte {extent}")
    return bytes(out) + bytes(extent - len(out))


def members(stock: bytes, extent: int) -> tuple[list[tuple[str, int, str]], int]:
    """The archive's members ((name, size, sha256 of the data)) and where it ends: the first
    header block whose first byte is zero, as golden_forge and the installer's golden_members
    read it."""
    out = []
    offset = 0
    while offset + 512 <= extent and stock[offset] != 0:
        header = stock[offset:offset + 512]
        name = bytes(header[:100]).split(b"\0")[0].decode("ascii", "replace")
        size = int(bytes(header[124:136]).split(b"\0")[0].strip() or b"0", 8)
        blocks = (size + 511) // 512
        if offset + 512 + blocks * 512 > extent:
            raise SystemExit(f"the member {name!r} runs past byte {extent}: not a PARAM image")
        data = stock[offset + 512:offset + 512 + size]
        out.append((name, size, hashlib.sha256(data).hexdigest()))
        offset += 512 + blocks * 512
    return out, offset


def archive_sum(stock: bytes, extent: int) -> tuple[str, int, int]:
    """The sha256 of the first EXTENT bytes with those after the archive's end taken as zeros,
    the archive's end, and how many bytes after it are not zero."""
    _, end = members(stock, extent)
    tail = stock[end:extent]
    nonzero = len(tail) - tail.count(0)
    return hashlib.sha256(stock[:end] + bytes(extent - end)).hexdigest(), end, nonzero


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--members":
        extent = int(word("extent"))
        for name, size, digest in members(Path(sys.argv[2]).read_bytes()[:extent], extent)[0]:
            print(f"{digest} {size} {name}")
        return 0
    if len(sys.argv) not in (2, 3) or sys.argv[1].startswith("-"):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    extent = int(word("extent"))
    stock_sums, loader_sums = sums("stock.sha256"), sums("loader.sha256")
    if len(stock_sums) != len(loader_sums) or not stock_sums:
        raise SystemExit("stock.sha256 and loader.sha256 do not name stock PARAMs and loaders in pairs")
    stock = Path(sys.argv[1]).read_bytes()
    if len(stock) < extent:
        raise SystemExit(f"{sys.argv[1]} is shorter than {extent} bytes")
    logo = (HERE / "logo.jpg").read_bytes()

    def known(n: int) -> str:
        """How the installer's log names a line: its number and its label."""
        label = stock_sums[n - 1][1]
        return f"stock line {n}" + (f" ({label})" if label else "")

    stock_sum = hashlib.sha256(stock[:extent]).hexdigest()
    line = line_of(stock_sums, stock_sum)
    stock_ok = line != 0
    verdict = lambda ok: "one this installer knows" if ok else "NOT one this installer knows"
    print(f"stock part: {stock_sum[:16]}...: {verdict(stock_ok)}" + (f", {known(line)}" if stock_ok else ""))
    if not stock_ok:
        arch_sum, end, nonzero = archive_sum(stock, extent)
        line = line_of(stock_sums, arch_sum)
        stock_ok = line != 0
        print(f"its archive: {arch_sum[:16]}... (ends at byte {end}, {nonzero} bytes after it not zero): "
              f"{verdict(stock_ok)}" + (f", {known(line)}" if stock_ok else ""))
    result = forge(stock, logo, extent)
    result_sum = hashlib.sha256(result).hexdigest()
    # the loader of the same line only: another line's is refused like any other result
    want = loader_sums[line - 1][0] if stock_ok else None
    result_ok = stock_ok and result_sum == want
    if result_ok:
        print(f"forged:     {result_sum[:16]}...: the loader of {known(line)}")
    elif stock_ok and line_of(loader_sums, result_sum):
        other = line_of(loader_sums, result_sum)
        print(f"forged:     {result_sum[:16]}...: NOT the loader of {known(line)}, "
              f"but the loader of stock line {other}: cross-paired, the installer writes nothing")
    else:
        print(f"forged:     {result_sum[:16]}...: NOT the loader this installer was built for")
    ok = stock_ok and result_ok
    if len(sys.argv) == 3:
        built = Path(sys.argv[2]).read_bytes()[:extent]
        same = built == result
        print(f"the loader's own image: {'the same bytes' if same else 'DIFFERENT bytes'}")
        ok = ok and same
    print("the installer would write the loader" if ok else "the installer would write nothing")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
