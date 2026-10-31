#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Byte-faithful SVR4 "newc" cpio archive reader/writer (stdlib only).

Purpose: surgical edits of Android boot-image ramdisks.  ``read_archive`` +
``write_archive`` round-trip an archive **byte-for-byte** -- entry order,
every header field, the name/data padding bytes, the ``TRAILER!!!`` entry and
any bytes after it -- so that replacing one file's data is the *only* change.
(Ownership is preserved because newc stores uid/gid in each header; this is
why the ramdisk must be rebuilt from the archive, never from a non-root
extraction.)

On-disk format (cpio(5) "new portable ASCII format" / GNU cpio copy-out -H
newc)::

    per entry:
      110-byte ASCII header
        0   6   magic "070701" (newc) or "070702" (crc; same layout, the
                 "check" field carries the sum/CRC of the file data)
        6   8   ino      (hex, lower case per GNU cpio)
        14  8   mode
        22  8   uid
        30  8   gid
        38  8   nlink
        46  8   mtime
        54  8   filesize
        62  8   devmajor
        70  8   devminor
        78  8   rdevmajor
        86  8   rdevminor
        94  8   namesize (name including its terminating NUL)
        102 8   check (0 in practice for newc)
      namesize bytes of name, terminated by NUL
      NUL padding so (110 + namesize) is a multiple of 4
      filesize bytes of data
      NUL padding so filesize is a multiple of 4
    last entry: the name "TRAILER!!!" (usually all-zero fields);
    anything after it (often zero padding to a block multiple) is trailing
    bytes and is preserved verbatim.

API
---
read_archive(data)                 -> list[Entry] (trailing bytes dropped)
read_archive_with_trailing(data)   -> (list[Entry], bytes)
write_archive(entries, trailing=b"") -> bytes
replace_file(entries, name, new_data) -> new list[Entry] (only the target
                                     entry's filesize/data -- and its check
                                     field when the magic is 070702 -- are
                                     updated; hard links to the name would be
                                     left alone, duplicate names are refused)
serialize_entry(entry)             -> bytes (one entry, header+name+data+pads)

CLI
---
list ARCHIVE                          mode, uid:gid, size, name per entry
extract-file ARCHIVE NAME             file data on stdout (binary)
replace ARCHIVE NAME NEWFILE -o OUT   new archive with NAME's data replaced
                                      (trailing bytes preserved)

The archive given to the CLI is a *raw* cpio file; (de)compression is the
caller's business (Android ramdisks are gzip streams around exactly this
format).
"""

import argparse
import binascii
import sys

MAGIC_NEWC = b"070701"
MAGIC_CRC = b"070702"
MAGICS = (MAGIC_NEWC, MAGIC_CRC)

TRAILER_NAME = "TRAILER!!!"

HEADER_SIZE = 110          # 6-byte magic + 13 * 8-byte hex fields
FIELD_COUNT = 13

# Field order in the header after the magic (names as in the struct above).
FIELD_NAMES = ("ino", "mode", "uid", "gid", "nlink", "mtime", "filesize",
               "devmajor", "devminor", "rdevmajor", "rdevminor",
               "namesize", "check")


class CpioFormatError(Exception):
    """Malformed archive or entry -> exit status 1 from the CLI."""


def pad_to_4(n):
    """NUL padding after *n* bytes so the result is 4-byte aligned."""
    return (4 - (n % 4)) % 4


def name_pad_len(namesize):
    """Padding after the name field: aligns 110 + namesize to 4."""
    return pad_to_4(HEADER_SIZE + namesize)


def data_pad_len(filesize):
    """Padding after the data: aligns filesize to 4."""
    return pad_to_4(filesize)


class Entry(object):
    """One cpio entry: the 13 header fields plus name and data.

    ``name_pad``/``data_pad`` hold the exact padding bytes found in the
    source archive (``None`` means "canonical NUL padding of the computed
    length" when constructing entries by hand).  Keeping the raw bytes --
    instead of regenerating NULs -- is what makes the round trip byte-exact
    even for archives padded with something unusual.
    """

    __slots__ = ("magic", "ino", "mode", "uid", "gid", "nlink", "mtime",
                 "filesize", "devmajor", "devminor", "rdevmajor", "rdevminor",
                 "check", "name", "data", "name_pad", "data_pad")

    def __init__(self, name, data=b"", mode=0o100644, uid=0, gid=0,
                 magic=MAGIC_NEWC, ino=0, nlink=1, mtime=0, devmajor=0,
                 devminor=0, rdevmajor=0, rdevminor=0, check=0,
                 name_pad=None, data_pad=None):
        self.magic = magic
        self.ino = ino
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.nlink = nlink
        self.mtime = mtime
        self.filesize = len(data) if data is not None else 0
        self.devmajor = devmajor
        self.devminor = devminor
        self.rdevmajor = rdevmajor
        self.rdevminor = rdevminor
        self.check = check
        self.name = name
        self.data = bytes(data) if data is not None else b""
        self.name_pad = name_pad
        self.data_pad = data_pad

    @property
    def is_trailer(self):
        return self.name == TRAILER_NAME

    def __repr__(self):
        return "Entry(%r, size=%d, mode=%06o, uid=%d, gid=%d, nlink=%d)" % (
            self.name, self.filesize, self.mode, self.uid, self.gid,
            self.nlink)


def _check_magic(magic, where):
    if magic not in MAGICS:
        raise CpioFormatError(
            "bad cpio magic %r at offset %d (expected '070701' or '070702')"
            % (magic.decode("latin-1"), where))


def _read_with_trailing(data):
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError("archive must be bytes-like, got %s"
                        % type(data).__name__)
    data = bytes(data)
    entries = []
    pos = 0
    while True:
        if len(data) - pos < HEADER_SIZE:
            raise CpioFormatError(
                "truncated cpio header at offset %d (%d bytes left, need %d)"
                % (pos, len(data) - pos, HEADER_SIZE))
        header = data[pos:pos + HEADER_SIZE]
        magic = header[0:6]
        _check_magic(magic, pos)
        try:
            values = [int(header[6 + 8 * i:6 + 8 * i + 8], 16)
                      for i in range(FIELD_COUNT)]
        except ValueError as exc:
            raise CpioFormatError(
                "non-hex header field at offset %d: %s" % (pos, exc))
        (ino, mode, uid, gid, nlink, mtime, filesize, devmajor, devminor,
         rdevmajor, rdevminor, namesize, check) = values

        name_start = pos + HEADER_SIZE
        if namesize == 0:
            raise CpioFormatError("zero namesize at offset %d" % pos)
        if name_start + namesize > len(data):
            raise CpioFormatError(
                "name of %d bytes at offset %d runs past the end of the "
                "archive" % (namesize, name_start))
        raw_name = data[name_start:name_start + namesize]
        if raw_name[-1:] != b"\x00":
            raise CpioFormatError(
                "name at offset %d is not NUL-terminated" % name_start)
        name_bytes = raw_name[:-1]
        if b"\x00" in name_bytes:
            raise CpioFormatError(
                "embedded NUL in name at offset %d" % name_start)

        after_name = name_start + namesize
        npad_len = name_pad_len(namesize)
        if after_name + npad_len > len(data):
            raise CpioFormatError("archive ends inside the name padding "
                                  "at offset %d" % after_name)
        name_pad = data[after_name:after_name + npad_len]

        data_start = after_name + npad_len
        if data_start + filesize > len(data):
            raise CpioFormatError(
                "data of %d bytes at offset %d runs past the end of the "
                "archive" % (filesize, data_start))
        entry_data = data[data_start:data_start + filesize]
        dpad_len = data_pad_len(filesize)
        if data_start + filesize + dpad_len > len(data):
            raise CpioFormatError("archive ends inside the data padding at "
                                  "offset %d" % (data_start + filesize))
        data_pad = data[data_start + filesize:data_start + filesize + dpad_len]

        pos = data_start + filesize + dpad_len
        entry = Entry(name=name_bytes.decode("latin-1"), data=entry_data,
                      mode=mode, uid=uid, gid=gid, magic=magic, ino=ino,
                      nlink=nlink, mtime=mtime, devmajor=devmajor,
                      devminor=devminor, rdevmajor=rdevmajor,
                      rdevminor=rdevminor, check=check, name_pad=name_pad,
                      data_pad=data_pad)
        entries.append(entry)
        if entry.is_trailer:
            return entries, data[pos:]


def read_archive_with_trailing(data):
    """Parse a newc archive; returns (entries, trailing bytes after the
    TRAILER!!! entry)."""
    return _read_with_trailing(data)


def read_archive(data):
    """Parse a newc archive into its entries (trailing bytes discarded; use
    read_archive_with_trailing to keep them)."""
    return _read_with_trailing(data)[0]


def _hex_field(value, what):
    if not 0 <= value <= 0xFFFFFFFF:
        raise CpioFormatError("header field %s = %d does not fit in 8 hex "
                              "digits" % (what, value))
    return b"%08x" % value


def serialize_entry(entry):
    """Serialise one entry (header + name + padding + data + padding)."""
    _check_magic(entry.magic, 0)
    name_bytes = entry.name.encode("latin-1")
    if b"\x00" in name_bytes:
        raise CpioFormatError("embedded NUL in name %r" % entry.name)
    if entry.name == "" and not entry.is_trailer:
        raise CpioFormatError("empty entry name")
    namesize = len(name_bytes) + 1
    values = (entry.ino, entry.mode, entry.uid, entry.gid, entry.nlink,
              entry.mtime, entry.filesize, entry.devmajor, entry.devminor,
              entry.rdevmajor, entry.rdevminor, namesize, entry.check)
    out = bytearray()
    out += entry.magic
    out += b"".join(_hex_field(v, n)
                    for v, n in zip(values, FIELD_NAMES))
    out += name_bytes
    out += b"\x00"

    npad_len = name_pad_len(namesize)
    if entry.name_pad is None:
        out += b"\x00" * npad_len
    else:
        if len(entry.name_pad) != npad_len:
            raise CpioFormatError(
                "entry %r: name padding is %d bytes but the format requires "
                "%d (name length changed?)" % (entry.name,
                                               len(entry.name_pad), npad_len))
        out += entry.name_pad

    out += entry.data
    dpad_len = data_pad_len(entry.filesize)
    if entry.data_pad is None:
        out += b"\x00" * dpad_len
    else:
        if len(entry.data_pad) != dpad_len:
            raise CpioFormatError(
                "entry %r: data padding is %d bytes but filesize %d "
                "requires %d" % (entry.name, len(entry.data_pad),
                                 entry.filesize, dpad_len))
        out += entry.data_pad
    return bytes(out)


def write_archive(entries, trailing=b""):
    """Serialise entries (plus an all-zero TRAILER!!! when the caller did not
    end with one) followed by *trailing* bytes verbatim."""
    out = bytearray()
    for entry in entries:
        out += serialize_entry(entry)
    if not entries or entries[-1].name != TRAILER_NAME:
        last_magic = entries[-1].magic if entries else MAGIC_NEWC
        out += serialize_entry(Entry(name=TRAILER_NAME, magic=last_magic))
    out += trailing
    return bytes(out)


def replace_file(entries, name, new_data):
    """Return a new entry list with the data of the entry called *name*
    replaced.  Only that entry's ``filesize``/``data`` (and its padding, and
    ``check`` for 070702 archives, where check is the CRC of the data) are
    touched; every other entry object is reused unchanged.  Refuses names
    that are missing or duplicated.
    """
    new_data = bytes(new_data)
    hits = [i for i, entry in enumerate(entries) if entry.name == name]
    if not hits:
        raise KeyError("no cpio entry named %r" % name)
    if len(hits) > 1:
        raise CpioFormatError("%d entries named %r; refusing to guess"
                              % (len(hits), name))
    target = entries[hits[0]]
    if target.is_trailer:
        raise CpioFormatError("cannot replace the TRAILER!!! entry")

    replaced = Entry(name=target.name, data=new_data, mode=target.mode,
                     uid=target.uid, gid=target.gid, magic=target.magic,
                     ino=target.ino, nlink=target.nlink, mtime=target.mtime,
                     devmajor=target.devmajor, devminor=target.devminor,
                     rdevmajor=target.rdevmajor, rdevminor=target.rdevminor,
                     check=(binascii.crc32(new_data) & 0xFFFFFFFF
                            if target.magic == MAGIC_CRC else target.check),
                     name_pad=target.name_pad,
                     data_pad=(target.data_pad
                               if target.data_pad is not None and
                               len(target.data_pad) == data_pad_len(
                                   len(new_data))
                               else b"\x00" * data_pad_len(len(new_data))))
    return [replaced if i == hits[0] else entry
            for i, entry in enumerate(entries)]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _read_file(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as exc:
        raise CpioFormatError("error: cannot read '%s': %s" % (path, exc))


def _write_file(path, data):
    try:
        with open(path, "wb") as f:
            f.write(data)
    except OSError as exc:
        raise CpioFormatError("error: cannot write '%s': %s" % (path, exc))


def _load(path):
    return _read_with_trailing(_read_file(path))


def cmd_list(args):
    entries, _trailing = _load(args.archive)
    for entry in entries:
        if entry.is_trailer:
            continue
        print("%06o %d:%d %8d %s" % (entry.mode, entry.uid, entry.gid,
                                     entry.filesize, entry.name))
    return 0


def cmd_extract_file(args):
    entries, _trailing = _load(args.archive)
    hits = [entry for entry in entries if entry.name == args.name]
    if not hits:
        raise CpioFormatError("error: no entry named '%s' in %s"
                              % (args.name, args.archive))
    if len(hits) > 1:
        raise CpioFormatError("error: %d entries named '%s'"
                              % (len(hits), args.name))
    sys.stdout.buffer.write(hits[0].data)
    sys.stdout.buffer.flush()
    return 0


def cmd_replace(args):
    entries, trailing = _load(args.archive)
    new_data = _read_file(args.newfile)
    new_entries = replace_file(entries, args.name, new_data)
    _write_file(args.output, write_archive(new_entries, trailing))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        prog="cpio_newc.py",
        description="Byte-faithful SVR4 'newc' cpio archive editor "
                    "(see the module docstring for the format).")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("list", help="list entries: mode uid:gid size name")
    p.add_argument("archive")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("extract-file",
                       help="write one entry's file data to stdout")
    p.add_argument("archive")
    p.add_argument("name")
    p.set_defaults(func=cmd_extract_file)

    p = sub.add_parser("replace",
                       help="replace one entry's data, keeping everything "
                            "else byte-identical")
    p.add_argument("archive")
    p.add_argument("name")
    p.add_argument("newfile", help="file with the replacement data")
    p.add_argument("-o", "--output", required=True,
                   help="output archive path")
    p.set_defaults(func=cmd_replace)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "func", None) is None:
        parser.print_help()
        return 1
    try:
        return args.func(args)
    except (CpioFormatError, KeyError) as exc:
        sys.stderr.write("%s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
