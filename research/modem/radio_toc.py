#!/usr/bin/env python3
"""Parse the TOC of a Samsung Shannon modem firmware container (radio.img).

Layout (see CBD_RE.md §3, byte-verified against dumps/radio.img):
  * image starts with a 512-byte TOC;
  * bytes 0x00..0x1f: self-record, name "TOC", size = 0x200, index = 1;
  * entries: 32 bytes each, contiguous from image byte 0x20 (15 entries max):

        char name[12];   /* +0x00 NUL-padded                    */
        u32  offset;     /* +0x0c byte offset in image          */
        u32  load_addr;  /* +0x10 CP bus address                */
        u32  size;       /* +0x14                               */
        u32  crc32;      /* +0x18 zlib CRC32 of the payload     */
        u32  index;      /* +0x1c                               */

  * cbd itself only validates the names TOC/BOOT/MAIN/NV inside the first
    0x80 bytes (CBD_RE.md §3).

Usage:
    python3 radio_toc.py IMAGE                 # print the TOC table
    python3 radio_toc.py IMAGE --extract DIR   # also extract named entries

stdlib only.
"""

import argparse
import os
import struct
import sys
import zlib

TOC_SIZE = 0x200
ENTRY_SIZE = 0x20
# 32-byte records fill the whole 512-byte TOC; slot 0 (image byte 0x00) is the
# self-record ("TOC"), the named entries follow contiguously from 0x20.
MAX_ENTRIES = TOC_SIZE // ENTRY_SIZE  # 16

ENTRY_STRUCT = struct.Struct("<12sIIIII")


class TocError(Exception):
    pass


class TocEntry:
    __slots__ = ("name", "offset", "load_addr", "size", "crc32", "index")

    def __init__(self, name, offset, load_addr, size, crc32, index):
        self.name = name
        self.offset = offset
        self.load_addr = load_addr
        self.size = size
        self.crc32 = crc32
        self.index = index

    @property
    def has_data(self):
        return self.offset != 0 and self.size != 0

    def __repr__(self):  # pragma: no cover - debugging aid
        return "TocEntry(name=%r, offset=%#x, load_addr=%#x, size=%#x, crc32=%#x, index=%d)" % (
            self.name, self.offset, self.load_addr, self.size, self.crc32, self.index)


def parse_toc(data):
    """Parse the TOC of a firmware image (bytes-like). Returns list[TocEntry].

    The first entry is the TOC self-record (name "TOC"); it is included in the
    returned list like cbd sees it.
    """
    data = bytes(data)
    if len(data) < TOC_SIZE:
        raise TocError("image too small for TOC: %d < %d bytes" % (len(data), TOC_SIZE))
    magic = data[0:4]
    if magic != b"TOC\x00":
        raise TocError("bad TOC magic %r (expected b'TOC\\x00')" % magic)

    entries = []
    for i in range(MAX_ENTRIES):
        base = i * ENTRY_SIZE
        raw = data[base:base + ENTRY_SIZE]
        if raw == bytes(ENTRY_SIZE):  # unused entries are all-zero
            continue
        name_b, offset, load_addr, size, crc, index = ENTRY_STRUCT.unpack(raw)
        name = name_b.split(b"\x00", 1)[0].decode("ascii", "replace")
        entries.append(TocEntry(name, offset, load_addr, size, crc, index))
    if not entries or entries[0].name != "TOC":
        raise TocError("first TOC entry is not the 'TOC' self-record")
    return entries


def verify_entry(data, entry, total_size=None):
    """Recompute the zlib CRC32 of an entry's payload.

    Returns (computed_crc, match). Entries with no data in the image
    (offset==0/size==0, e.g. NV) yield (0, entry.crc32 == 0).
    """
    if not entry.has_data:
        return 0, entry.crc32 == 0
    end = entry.offset + entry.size
    if total_size is not None and end > total_size:
        raise TocError(
            "entry %s extends past end of image (%#x > %#x)" % (entry.name, end, total_size))
    if len(data) < end:
        raise TocError("image truncated: need %#x bytes, have %#x" % (end, len(data)))
    computed = zlib.crc32(data[entry.offset:end]) & 0xFFFFFFFF
    return computed, computed == entry.crc32


def extract(data, entries, outdir):
    """Extract entries that carry data into outdir; returns list of written paths."""
    os.makedirs(outdir, exist_ok=True)
    written = []
    for e in entries:
        if not e.has_data:
            continue
        end = e.offset + e.size
        if end > len(data):
            raise TocError("cannot extract %s: image truncated" % e.name)
        path = os.path.join(outdir, e.name)
        with open(path, "wb") as f:
            f.write(data[e.offset:end])
        written.append(path)
    return written


def print_table(entries, data, verify=True):
    print("%-8s %-10s %-10s %-10s %-10s %-4s %s" %
          ("name", "offset", "load_addr", "size", "crc32", "idx", "crc-check"))
    for e in entries:
        if verify:
            try:
                computed, ok = verify_entry(data, e, len(data))
                status = "OK" if ok else "FAIL (stored %#010x, computed %#010x)" % (
                    e.crc32, computed)
            except TocError as exc:
                status = "n/a (%s)" % exc
        else:
            status = "-"
        print("%-8s %#010x %#010x %#10x %#10x %#4x %s" %
              (e.name, e.offset, e.load_addr, e.size, e.crc32, e.index, status))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Parse a Shannon modem firmware TOC.")
    ap.add_argument("image", help="path to radio.img (RADIO partition image)")
    ap.add_argument("--extract", metavar="DIR",
                    help="extract entries that carry data into DIR")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip CRC32 recomputation")
    args = ap.parse_args(argv)

    with open(args.image, "rb") as f:
        data = f.read()

    try:
        entries = parse_toc(data)
    except TocError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1

    print_table(entries, data, verify=not args.no_verify)

    if args.extract:
        written = extract(data, entries, args.extract)
        for p in written:
            print("extracted %s" % p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
