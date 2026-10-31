#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Samsung Exynos boot.img + DTBH packer/unpacker (SM-T715 / Exynos 5433).

A self-contained, stdlib-only re-implementation of the LineageOS C tools in
``src/hardware_samsung-18.1/dtbhtool/`` for the boot image format used
by the Samsung Galaxy Tab S2 8.0 LTE (SM-T715, ``gts28ltexx``): an Android
boot image header v0 with a separate device-tree section (``dt_size``) whose
content is a Samsung "DTBH" container.

Subcommands
-----------
dtbh-pack     Build a DTBH image from compiled DTBs (cf. mkdtbimg/dtbToolCM).
dtbh-unpack   List the DTBH entries and extract each DTB (cf. unpackdtbhimg).
pack          Build a boot.img (header v0 + optional dt section), cf. mkbootimg.
unpack        Split a boot.img into kernel/ramdisk/dt/signature + bootimg.json,
              such that ``pack --from-json DIR/bootimg.json`` rebuilds a
              byte-identical image.
info          Human-readable header dump; exits non-zero on bad magic.

On-disk layout (all multi-byte fields little-endian unless noted)
-----------------------------------------------------------------

Android boot image header v0 (``bootimg.h:28-50``), 608 bytes::

    offset  size  field
    0x000    8    magic "ANDROID!"                       (bootimg.h:23-24)
    0x008    4    kernel_size
    0x00C    4    kernel_addr   = base + kernel_offset   (mkbootimg.c:194)
    0x010    4    ramdisk_size
    0x014    4    ramdisk_addr  = base + ramdisk_offset  (mkbootimg.c:195)
    0x018    4    second_size
    0x01C    4    second_addr   = base + second_offset   (mkbootimg.c:196)
    0x020    4    tags_addr     = base + tags_offset     (mkbootimg.c:197)
    0x024    4    page_size
    0x028    4    dt_size       (device-tree section size; 0 = absent)
    0x02C    4    unused (zero)
    0x030   16    name (board name, NUL padded; <= 15 chars, mkbootimg.c:219)
    0x040  512    cmdline (NUL padded; <= 511 chars, mkbootimg.c:228-231)
    0x240   32    id[8]: id[0..4] = first 20 bytes of the SHA-1 described
                         below, little-endian words (mkbootimg.c:298-299);
                         id[5..7] stay zero.
    total 608 bytes (mkbootimg.c:307 writes sizeof(struct boot_img_hdr))

The SHA-1 ``id`` (``mkbootimg.c:286-299``) is computed over::

    SHA1( kernel            || le32(kernel_size) ||
          ramdisk           || le32(ramdisk_size) ||
          second            || le32(second_size) ||
          [ dt              || le32(dt_size) ] )

where the dt terms are hashed only when dt data was loaded (``if (dt_data)``,
``mkbootimg.c:293-296``).  Empty sections contribute nothing (a zero-size
``SHA1_Update`` is a no-op).  This tool hashes the dt terms whenever a --dt
file was given, which matches the C tool: ``load_file()`` returns a non-NULL
pointer even for a zero-byte file on glibc (``mkbootimg.c:234,268``).

Image layout (``bootimg.h:52-70``, ``mkbootimg.c:307-328``)::

    +-----------------+
    | boot header     | 1 page (608 bytes of header + zero padding)
    +-----------------+
    | kernel          | n pages
    +-----------------+
    | ramdisk         | m pages
    +-----------------+
    | second stage    | o pages   (optional, second_size != 0)
    +-----------------+
    | device tree     | p pages   (optional, dt_size != 0; the DTBH image)
    +-----------------+
    | signature       | 256 bytes (optional, written raw, NOT padded)
    +-----------------+

Padding after every section (``mkbootimg.c:95-111``): ``pad = page_size -
(item_size & (page_size - 1))`` bytes of zeros, i.e. each section starts on a
page boundary; no padding when the size is already a page multiple (this also
means a zero-size section adds no padding).  *Known C quirk, replicated here
for byte-identity:* the padding written after the second stage uses
``ramdisk_size`` instead of ``second_size`` (``mkbootimg.c:318``).  Allowed
page sizes (``mkbootimg.c:178``): 2048, 4096, 8192, 16384, 32768, 65536,
131072.  Defaults (``mkbootimg.c:131,135-139``): page_size 2048, base
0x10000000, kernel_offset 0x00008000, ramdisk_offset 0x01000000, second_offset
0x00f00000, tags_offset 0x00000100.  For this device BoardConfigCommon.mk:10
sets ``BOARD_KERNEL_PAGESIZE := 2048`` and BoardConfigCommon.mk:12 passes
``--ramdisk_offset 0x01000000 --tags_offset 0x00000100``; the base is the AOSP
default.

Trailer: the "SEANDROIDENFORCE" footer (observed, not from the C sources)
-------------------------------------------------------------------------

Real Samsung boot images for this device end with the 16-byte ASCII footer
``SEANDROIDENFORCE`` appended right after the last page-aligned section.
This is *not* derived from the C reference: it was observed by unpacking a
real device image (an official TWRP recovery for the SM-T715) -- the image is
exactly 16 bytes longer than what the C layout accounts for.  ``bootimg.h:
52-70`` only documents a 256-byte signature slot, and none of the dtbhtool
tools read or write the footer.  The Samsung bootloader looks for it to avoid
a "not SEANDROID enforcing" warning.  Handling in this tool:

- ``unpack`` stores any bytes after the last page-aligned section (and after
  the 256-byte signature, when present) in ``bootimg.json`` as
  ``trailer_hex``, and writes them to ``DIR/trailer.bin`` when non-empty;
- ``pack --seandroid`` appends exactly ``b"SEANDROIDENFORCE"``;
- ``pack --from-json`` re-appends the stored trailer, making the round trip
  byte-identical;
- the ``--max-size`` guard applies to the final size including the trailer,
  and ``info`` prints the trailer when present.

Samsung DTBH container (``dtbimg.c``, ``samsung_dtbh.h``, ``dtbtool.txt``)::

    offset  size  field
    0x000    4    magic "DTBH" (raw 4 bytes, no NUL;  dtbimg.c:287)
    0x004    4    version = 2 (LE;  dtbimg.c:126,288; DTBH_VERSION)
    0x008    4    entry_count (LE;  dtbimg.c:289)
    0x00C  32*n   entries, each eight LE u32 (dtbimg.c:44-55;
                  DT_ENTRY_PHYS_SIZE = 8 * sizeof(uint32_t)):
        chip        BE u32 from DTB property "model_info-chip"
                    (fdt_getprop + ntohl, dtbimg.c:238)
        platform    DTBH_PLATFORM_CODE = 0x3138   (device samsung_dtbh.h)
        subtype     DTBH_SUBTYPE_CODE = 0x36480ee3 (device samsung_dtbh.h)
        hw_rev      BE u32 from DTB property "model_info-hw_rev"
                    (dtbimg.c:241)
        hw_rev_end  BE u32 from DTB property "model_info-hw_rev_end"
                    (dtbimg.c:242)
        offset      byte offset of the blob from the start of the DTBH image
        size        blob size including page padding (dtbimg.c:275)
        space       0x20 "space delimiter" (dtbimg.c:243)
    after entries:  a 4-byte "eot marker" is *counted* in the header size
                  (dtbimg.c:258) but never written; the whole header page is
                  zero-filled by calloc (dtbimg.c:281).
    blobs, each starting on a page boundary, each padded to a page multiple.

The header region size is ``align_up(12 + 32*n + 4, page_size)``
(DT_HEADER_PHYS_SIZE = 12, ``samsung_dtbh.h``; dtbimg.c:125,248,258-259), and
the total image size is header + sum of padded blob sizes (dtbimg.c:308).
Entries are sorted by (chip, hw_rev) (``dtbimg.c:60-68,261``) but the blobs
are laid out in *directory read order*, not in the sorted order
(``dtbimg.c:149-249,265-268``) -- so with more than one DTB the C tool's
output depends on readdir() order.  This tool lays blobs out in command-line
order instead, which is deterministic; the golden tests account for this by
feeding the tool the DTBs in the order the C tool used.  The C sort uses
qsort() and is therefore not stable for equal (chip, hw_rev); the sort here is
stable (input order preserved for ties).

DTB requirements (``dtbimg.c:149-249``): the C tool scans a directory for
``*.dtb`` files, validates each FDT header (``fdt_check_header``), and skips
any blob whose root properties do not satisfy: ``model_info-chip`` of a
multiple of 4 bytes, ``model_info-platform`` == DTBH_PLATFORM ("gts28"),
``model_info-subtype`` == DTBH_SUBTYPE ("gts28_eur_open"), ``model_info-hw_rev``
and ``model_info-hw_rev_end`` each a multiple of 4 bytes.  The optional
``DTBH_MODEL`` model-name filter (``dtbimg.c:129,168-176``) is compiled out
for this device (no define in ``src/device_gts28ltexx/include/``) and
is not implemented here.  Where the C tool silently *skips* a bad file, this
tool *errors out* (the CLI names blobs explicitly, so skipping would be
surprising); this is a documented behavioural difference with no effect on
valid inputs.

Chip / hw_rev / hw_rev_end values always come from the DTB properties, exactly
as in the C tool.  The ``HWREV[:HWREV_END]`` prefix on ``--dtb`` is a
convenience and a cross-check: when given, it must match the values found in
the blob, otherwise the tool refuses to pack.  ``--platform-code`` /
``--subtype-code`` override the compiled-in constants the C tool uses.

Known C reference divergences (all documented, none affect byte-identity for
valid inputs): bad DTBs abort instead of being skipped; pagesize parse errors
exit 1 (the C mkbootimg returns -1 from main, i.e. status 255); blobs are laid
out in CLI order instead of readdir order; the sort is stable.

Exit codes: 0 success, 1 usage or format error (including bad magic, cmdline
too long, DTB validation failure), 2 output would exceed the boot partition
size guard (``--max-size``, default 0x00e00000 = 14 MiB, the SM-T715 BOOT
partition).
"""

import argparse
import hashlib
import json
import os
import struct
import sys

# ---------------------------------------------------------------------------
# Constants derived from the C reference (see module docstring for citations).
# ---------------------------------------------------------------------------

BOOT_MAGIC = b"ANDROID!"          # bootimg.h:23
BOOT_MAGIC_SIZE = 8               # bootimg.h:24
BOOT_NAME_SIZE = 16               # bootimg.h:25
BOOT_ARGS_SIZE = 512              # bootimg.h:26
BOOT_IMG_HDR_SIZE = 608           # sizeof(struct boot_img_hdr), bootimg.h:28-50

DTBH_MAGIC = b"DTBH"              # samsung_dtbh.h / dtbimg.c:287
DTBH_VERSION = 2                  # device samsung_dtbh.h: DTBH_VERSION
DT_HEADER_PHYS_SIZE = 12          # samsung_dtbh.h: DTBH_MAGIC+VERSION+count
DT_ENTRY_PHYS_SIZE = 32           # samsung_dtbh.h: 8 * sizeof(uint32_t)
DT_ENTRY_SPACE = 0x20             # dtbimg.c:243 "space delimiter"

DTBH_PLATFORM = "gts28"           # device samsung_dtbh.h: DTBH_PLATFORM
DTBH_SUBTYPE = "gts28_eur_open"   # device samsung_dtbh.h: DTBH_SUBTYPE
DTBH_PLATFORM_CODE = 0x3138       # device samsung_dtbh.h: DTBH_PLATFORM_CODE
DTBH_SUBTYPE_CODE = 0x36480ee3    # device samsung_dtbh.h: DTBH_SUBTYPE_CODE

FDT_MAGIC = 0xD00DFEED            # big-endian on disk; dtbimg.c:160 fdt_check_header

DEFAULT_PAGESIZE = 2048           # mkbootimg.c:131 / BoardConfigCommon.mk:10
ALLOWED_PAGESIZES = (2048, 4096, 8192, 16384, 32768, 65536, 131072)  # mkbootimg.c:178
DEFAULT_BASE = 0x10000000         # mkbootimg.c:135 (AOSP default)
DEFAULT_KERNEL_OFFSET = 0x00008000   # mkbootimg.c:136
DEFAULT_RAMDISK_OFFSET = 0x01000000  # mkbootimg.c:137 / BoardConfigCommon.mk:12
DEFAULT_SECOND_OFFSET = 0x00F00000   # mkbootimg.c:138
DEFAULT_TAGS_OFFSET = 0x00000100     # mkbootimg.c:139 / BoardConfigCommon.mk:12

DEFAULT_MAX_SIZE = 0x00E00000     # BOOT partition size, 14 MiB
SIGNATURE_SIZE = 256              # mkbootimg.c:326-328

# Observed on real SM-T715 images (official TWRP recovery): 16-byte ASCII
# footer appended right after the last section.  Never written by the C
# reference tools -- see the module docstring.
SEANDROIDENFORCE_MAGIC = b"SEANDROIDENFORCE"

BOOT_HDR_STRUCT = "<8s10I16s512s32s"   # magic, 10 u32, name, cmdline, id[8]
assert struct.calcsize(BOOT_HDR_STRUCT) == BOOT_IMG_HDR_SIZE

JSON_FORMAT = "samsung-bootimg-v0-json/1"


class ToolError(Exception):
    """Usage or format error -> exit status 1."""


class SizeLimitError(Exception):
    """Output would exceed --max-size -> exit status 2."""


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def pad_len(itemsize, pagesize):
    """Bytes of zero padding after *itemsize*, per write_padding()
    (mkbootimg.c:95-111): 0 when already page aligned (including size 0)."""
    pagemask = pagesize - 1
    if (itemsize & pagemask) == 0:
        return 0
    return pagesize - (itemsize & pagemask)


def parse_int(text, what, base=16):
    """strtoul()-alike.  The C tools parse addresses with strtoul(val, 0, 16)
    (mkbootimg.c:165-173) so both "0x..." and bare hex are accepted; page size
    uses base 10 (mkbootimg.c:177)."""
    try:
        return int(text, base)
    except ValueError:
        raise ToolError("error: invalid %s '%s'" % (what, text))


def read_file(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError as exc:
        raise ToolError("error: could not load '%s': %s" % (path, exc))


# ---------------------------------------------------------------------------
# Minimal FDT (device tree blob) reader -- only what dtbimg.c needs from
# libfdt: fdt_check_header() and the properties of the root node.
# ---------------------------------------------------------------------------

FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9

FDT_HDR_STRUCT = ">10I"           # magic, totalsize, off_struct, off_strings,
#                                  off_mem_rsv, version, last_comp, boot_cpuid,
#                                  size_strings, size_struct


def _be32(data, off):
    return struct.unpack_from(">I", data, off)[0]


def fdt_check_header(data):
    """Subset of libfdt fdt_check_header() used by dtbimg.c:160: magic,
    version >= 2, and the structure/strings blocks within the blob."""
    if len(data) < 40:
        return "too small for an FDT header"
    (magic, totalsize, off_struct, off_strings, off_mem_rsv, version,
     _last_comp, _boot_cpuid, size_strings, size_struct) = struct.unpack_from(
         FDT_HDR_STRUCT, data, 0)
    if magic != FDT_MAGIC:
        return "bad magic (expected 0xd00dfeed)"
    if version < 2:
        return "unsupported FDT version %d" % version
    if totalsize > len(data):
        return "totalsize %d exceeds blob size %d" % (totalsize, len(data))
    if off_struct + size_struct > totalsize:
        return "structure block outside blob"
    if off_strings + size_strings > totalsize:
        return "strings block outside blob"
    if off_mem_rsv >= totalsize:
        return "memrsv block outside blob"
    return None


def fdt_root_properties(data):
    """Return {name: bytes} of the root node's properties, walking the
    structure block (tokens FDT_BEGIN_NODE/END_NODE/PROP/NOP/END)."""
    err = fdt_check_header(data)
    if err:
        raise ToolError("error: not a valid dtb: %s" % err)
    _magic, _total, off_struct, off_strings, _rsv, _ver, _lc, _cpu, \
        size_strings, size_struct = struct.unpack_from(FDT_HDR_STRUCT, data, 0)

    def get_string(nameoff):
        if nameoff >= size_strings:
            raise ToolError("error: dtb property name offset out of range")
        end = data.index(b"\x00", off_strings + nameoff)
        return data[off_strings + nameoff:end].decode("latin-1")

    props = {}
    off = off_struct
    struct_end = off_struct + size_struct
    depth = 0
    in_root = False
    while off + 4 <= struct_end:
        token = _be32(data, off)
        off += 4
        if token == FDT_BEGIN_NODE:
            depth += 1
            end = data.index(b"\x00", off)
            off = (end - off_struct) + 1          # skip name + NUL
            off = ((off + 3) & ~3) + off_struct   # align to 4 bytes
            in_root = (depth == 1)
        elif token == FDT_END_NODE:
            if depth == 1:
                in_root = False
            depth -= 1
            if depth <= 0:
                break
        elif token == FDT_PROP:
            length = _be32(data, off)
            nameoff = _be32(data, off + 4)
            off += 8
            if in_root:
                props[get_string(nameoff)] = data[off:off + length]
            off = ((length + 3) & ~3) + off        # value padded to 4 bytes
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            raise ToolError("error: unknown FDT token 0x%x at 0x%x" % (token, off - 4))
    return props


def prop_as_u32(props, name):
    """ntohl(prop[0]) of a property, per dtbimg.c:179-182,201-206,238-242:
    the property must be present and its length a multiple of 4; the first
    big-endian u32 is used.  Returns None when the property is absent (the C
    tool skips such files; callers here report an error instead)."""
    value = props.get(name)
    if value is None:
        return None
    if len(value) == 0 or len(value) % 4 != 0:
        return None
    return struct.unpack(">I", value[:4])[0]


def prop_as_string(props, name):
    """C-string view of a property (dtbimg.c:186,193 compare with strcmp)."""
    value = props.get(name)
    if value is None:
        return None
    return value.split(b"\x00", 1)[0].decode("latin-1")


# ---------------------------------------------------------------------------
# DTBH container (dtbimg.c / mkdtbimg.c / unpackdtbhimg.c)
# ---------------------------------------------------------------------------

class DtbInput(object):
    """One --dtb argument, validated against the blob's own properties."""

    def __init__(self, path, hw_rev=None, hw_rev_end=None):
        self.path = path
        self.hw_rev_arg = hw_rev
        self.hw_rev_end_arg = hw_rev_end
        self.chip = None
        self.hw_rev = None
        self.hw_rev_end = None
        self.platform = None
        self.subtype = None

    def load(self, want_platform, want_subtype):
        data = read_file(self.path)
        err = fdt_check_header(data)
        if err:
            raise ToolError("error: '%s' is not a valid dtb (%s)" % (self.path, err))
        props = fdt_root_properties(data)

        self.chip = prop_as_u32(props, "model_info-chip")
        if self.chip is None:
            raise ToolError("error: model_info-chip of %s is missing or of "
                            "invalid size" % self.path)
        self.hw_rev = prop_as_u32(props, "model_info-hw_rev")
        if self.hw_rev is None:
            raise ToolError("error: model_info-hw_rev of %s is missing or of "
                            "invalid size" % self.path)
        self.hw_rev_end = prop_as_u32(props, "model_info-hw_rev_end")
        if self.hw_rev_end is None:
            raise ToolError("error: model_info-hw_rev_end of %s is missing or "
                            "of invalid size" % self.path)

        # dtbimg.c:185-199 compares the strings with the compiled-in defines;
        # here the expected strings come from --platform/--subtype.
        self.platform = prop_as_string(props, "model_info-platform")
        if self.platform != want_platform:
            raise ToolError("error: model_info-platform of %s is invalid "
                            "(expected %s but got %s)"
                            % (self.path, want_platform, self.platform))
        self.subtype = prop_as_string(props, "model_info-subtype")
        if self.subtype != want_subtype:
            raise ToolError("error: model_info-subtype of %s is invalid "
                            "(expected %s but got %s)"
                            % (self.path, want_subtype, self.subtype))

        # The C tool takes hw_rev/hw_rev_end from the DTB only; the CLI values
        # are a cross-check (see module docstring).
        if self.hw_rev_arg is not None and self.hw_rev_arg != self.hw_rev:
            raise ToolError("error: hw_rev %d given for %s but the DTB says %d"
                            % (self.hw_rev_arg, self.path, self.hw_rev))
        if self.hw_rev_end_arg is not None and \
                self.hw_rev_end_arg != self.hw_rev_end:
            raise ToolError("error: hw_rev_end %d given for %s but the DTB "
                            "says %d" % (self.hw_rev_end_arg, self.path,
                                         self.hw_rev_end))
        return data


def dtbh_build(blobs, pagesize, platform_code, subtype_code):
    """Assemble the DTBH image.  *blobs* is a list of (DtbInput, data) in the
    desired blob layout order (CLI order here; readdir order in the C tool).
    Entry order is sorted by (chip, hw_rev) as dtbimg.c:261 does."""
    pagemask = pagesize - 1

    def align_up(n):
        return (n + pagemask) & ~pagemask

    # Blob list, in layout order (dtbimg.c:215-229 builds it in readdir order).
    ordered = list(blobs)

    # Entries start unsorted (dtbimg.c:230-248) and are then sorted
    # (dtbimg.c:261); the sort must be stable so ties keep input order.
    indexed = sorted(range(len(ordered)),
                     key=lambda i: (ordered[i][0].chip, ordered[i][0].hw_rev))

    # Header size: 12 + 32*n + 4 (eot marker counted, not written),
    # rounded up to a page (dtbimg.c:125,248,258-259).
    hdr_sz = align_up(DT_HEADER_PHYS_SIZE + len(ordered) * DT_ENTRY_PHYS_SIZE
                      + 4)

    # Blob offsets are assigned in layout order (dtbimg.c:263-268) and each
    # entry records its blob's offset and padded size (dtbimg.c:271-276).
    offset = hdr_sz
    offsets = []
    sizes = []
    for _entry, data in ordered:
        offsets.append(offset)
        sizes.append(align_up(len(data)))
        offset += align_up(len(data))
    blob_sz = offset - hdr_sz

    image = bytearray(hdr_sz + blob_sz)      # calloc'd, dtbimg.c:281
    image[0:4] = DTBH_MAGIC                  # dtbimg.c:287
    struct.pack_into("<I", image, 4, DTBH_VERSION)    # dtbimg.c:288
    struct.pack_into("<I", image, 8, len(ordered))    # dtbimg.c:289

    entry_off = DT_HEADER_PHYS_SIZE
    for i in indexed:
        entry, _data = ordered[i]
        struct.pack_into("<8I", image, entry_off,
                         entry.chip,
                         platform_code,
                         subtype_code,
                         entry.hw_rev,
                         entry.hw_rev_end,
                         offsets[i],
                         sizes[i],
                         DT_ENTRY_SPACE)
        entry_off += DT_ENTRY_PHYS_SIZE

    for i, (_entry, data) in enumerate(ordered):
        image[offsets[i]:offsets[i] + len(data)] = data   # dtbimg.c:303-306

    return bytes(image)


def dtbh_parse(image):
    """Inverse of dtbh_build: returns (version, [entry dicts], [blob bytes]).
    Blobs are returned in file order (increasing offset), i.e. the C tool's
    readdir order."""
    if len(image) < DT_HEADER_PHYS_SIZE:
        raise ToolError("error: DTBH image too small")
    magic = image[0:4]
    if magic != DTBH_MAGIC:
        raise ToolError("error: bad DTBH magic %r (expected b'DTBH')"
                        % magic.decode("latin-1"))
    version, count = struct.unpack_from("<II", image, 4)
    if len(image) < DT_HEADER_PHYS_SIZE + count * DT_ENTRY_PHYS_SIZE:
        raise ToolError("error: DTBH image truncated")
    entries = []
    for i in range(count):
        chip, platform, subtype, hw_rev, hw_rev_end, off, size, space = \
            struct.unpack_from("<8I", image,
                               DT_HEADER_PHYS_SIZE + i * DT_ENTRY_PHYS_SIZE)
        if off + size > len(image):
            raise ToolError("error: DTBH entry %d points outside the image" % i)
        entries.append(dict(chip=chip, platform=platform, subtype=subtype,
                            hw_rev=hw_rev, hw_rev_end=hw_rev_end,
                            offset=off, size=size, space=space))
    # Blobs in file order (increasing offset): the C tool's readdir order.
    blobs = [(ent, image[ent["offset"]:ent["offset"] + ent["size"]])
             for ent in sorted(entries, key=lambda e: e["offset"])]
    return version, entries, blobs


def parse_dtb_spec(spec):
    """Parse HWREV[:HWREV_END]=path into (path, hw_rev, hw_rev_end)."""
    if "=" not in spec:
        raise ToolError("error: --dtb expects HWREV[:HWREV_END]=path, got '%s'"
                        % spec)
    revs, path = spec.split("=", 1)
    if not revs:
        raise ToolError("error: --dtb is missing the HWREV[:HWREV_END] "
                        "prefix: '%s'" % spec)
    parts = revs.split(":", 1)
    try:
        hw_rev = int(parts[0], 0)
    except ValueError:
        raise ToolError("error: invalid hw_rev '%s'" % parts[0])
    hw_rev_end = None
    if len(parts) == 2:
        try:
            hw_rev_end = int(parts[1], 0)
        except ValueError:
            raise ToolError("error: invalid hw_rev_end '%s'" % parts[1])
    return path, hw_rev, hw_rev_end


def cmd_dtbh_pack(args):
    if not args.dtb:
        raise ToolError("error: no dtb specified (use --dtb "
                        "HWREV[:HWREV_END]=path.dtb)")
    inputs = []
    for spec in args.dtb:
        path, hw_rev, hw_rev_end = parse_dtb_spec(spec)
        inputs.append(DtbInput(path, hw_rev, hw_rev_end))
    loaded = [(inp, inp.load(args.platform, args.subtype)) for inp in inputs]
    image = dtbh_build(loaded, args.pagesize, args.platform_code,
                       args.subtype_code)
    write_output(args.output, image)
    return 0


def cmd_dtbh_unpack(args):
    image = read_file(args.input)
    version, entries, blobs = dtbh_parse(image)
    os.makedirs(args.output, exist_ok=True)

    print("DTBH_MAGIC = 'DTBH'")
    print("DTBH_VERSION = %u" % version)
    print("Number of entries: %u" % len(entries))
    print("%-4s %-10s %-11s %-11s %-7s %-11s %-10s %-7s" %
          ("#", "chip", "platform", "subtype", "hw_rev", "hw_rev_end",
           "offset", "size"))
    for i, ent in enumerate(entries):
        print("%-4u 0x%08x 0x%08x 0x%08x %-7u %-11u %-10u %-7u" %
              (i, ent["chip"], ent["platform"], ent["subtype"],
               ent["hw_rev"], ent["hw_rev_end"], ent["offset"], ent["size"]))
        # Same naming scheme as unpackdtbhimg.c:165.
        name = "chip%u-0x%x-0x%x_rev%u-%u.dtb" % (
            ent["chip"], ent["platform"], ent["subtype"],
            ent["hw_rev"], ent["hw_rev_end"])
        # unpackdtbhimg.c:152-168 dumps entry.size bytes, i.e. the blob
        # including its trailing page padding.
        blob = image[ent["offset"]:ent["offset"] + ent["size"]]
        with open(os.path.join(args.output, name), "wb") as f:
            f.write(blob)
        print("  -> %s (%u bytes)" % (name, len(blob)))
    return 0


# ---------------------------------------------------------------------------
# Boot image (bootimg.h / mkbootimg.c / unpackbootimg.c)
# ---------------------------------------------------------------------------

class BootHeader(object):
    """struct boot_img_hdr, bootimg.h:28-50."""

    def __init__(self):
        self.magic = BOOT_MAGIC
        self.kernel_size = 0
        self.kernel_addr = 0
        self.ramdisk_size = 0
        self.ramdisk_addr = 0
        self.second_size = 0
        self.second_addr = 0
        self.tags_addr = 0
        self.page_size = DEFAULT_PAGESIZE
        self.dt_size = 0
        self.unused = 0
        self.name = b""
        self.cmdline = b""
        self.id = [0] * 8

    def pack(self):
        return struct.pack(BOOT_HDR_STRUCT,
                           self.magic,
                           self.kernel_size, self.kernel_addr,
                           self.ramdisk_size, self.ramdisk_addr,
                           self.second_size, self.second_addr,
                           self.tags_addr, self.page_size,
                           self.dt_size, self.unused,
                           self.name,
                           self.cmdline,
                           struct.pack("<8I", *self.id))

    @classmethod
    def unpack(cls, data):
        if len(data) < BOOT_IMG_HDR_SIZE:
            raise ToolError("error: header truncated (%d bytes, expected %d)"
                            % (len(data), BOOT_IMG_HDR_SIZE))
        hdr = cls()
        (magic, hdr.kernel_size, hdr.kernel_addr, hdr.ramdisk_size,
         hdr.ramdisk_addr, hdr.second_size, hdr.second_addr, hdr.tags_addr,
         hdr.page_size, hdr.dt_size, hdr.unused, name, cmdline,
         id_raw) = struct.unpack_from(BOOT_HDR_STRUCT, data, 0)
        if magic != BOOT_MAGIC:
            raise ToolError("error: bad boot image magic %r"
                            % magic.decode("latin-1"))
        hdr.magic = magic
        hdr.name = name.split(b"\x00", 1)[0]
        hdr.cmdline = cmdline.split(b"\x00", 1)[0]
        hdr.id = list(struct.unpack("<8I", id_raw))
        return hdr


def compute_sha1_id(kernel, ramdisk, second, dt):
    """mkbootimg.c:286-299: SHA-1 over each payload followed by its LE size;
    the dt terms only when dt data was loaded."""
    ctx = hashlib.sha1()
    ctx.update(kernel)
    ctx.update(struct.pack("<I", len(kernel)))
    ctx.update(ramdisk)
    ctx.update(struct.pack("<I", len(ramdisk)))
    ctx.update(second)
    ctx.update(struct.pack("<I", len(second)))
    if dt is not None:
        ctx.update(dt)
        ctx.update(struct.pack("<I", len(dt)))
    return ctx.digest()


def image_length(header, dt_given, signature_given, trailer=b""):
    """Exact on-disk length of the image pack() would write, including any
    trailing bytes (e.g. the SEANDROIDENFORCE footer)."""
    p = header.page_size
    total = p                                   # header page
    total += header.kernel_size + pad_len(header.kernel_size, p)
    total += header.ramdisk_size + pad_len(header.ramdisk_size, p)
    if header.second_size:
        # mkbootimg.c:316-319: second data, padded per ramdisk_size (C quirk).
        total += header.second_size + pad_len(header.ramdisk_size, p)
    if dt_given:
        total += header.dt_size + pad_len(header.dt_size, p)
    if signature_given:
        total += SIGNATURE_SIZE                 # mkbootimg.c:326-328
    total += len(trailer)
    return total


def write_output(path, data):
    try:
        with open(path, "wb") as f:
            f.write(data)
    except OSError as exc:
        raise ToolError("error: failed writing '%s': %s" % (path, exc))


def build_boot_image(hdr, kernel, ramdisk, second, dt, signature,
                     trailer=b""):
    """Serialise the image exactly like mkbootimg.c:301-328, plus the
    observed Samsung footer (module docstring) appended verbatim at the very
    end."""
    p = hdr.page_size
    out = bytearray()
    out += hdr.pack()
    out += b"\x00" * pad_len(BOOT_IMG_HDR_SIZE, p)
    out += kernel
    out += b"\x00" * pad_len(hdr.kernel_size, p)
    out += ramdisk
    out += b"\x00" * pad_len(hdr.ramdisk_size, p)
    if second:
        out += second
        # mkbootimg.c:318 pads the second stage using ramdisk_size.  Replicated
        # verbatim for byte-identity (see module docstring).
        out += b"\x00" * pad_len(hdr.ramdisk_size, p)
    if dt is not None:
        out += dt
        out += b"\x00" * pad_len(hdr.dt_size, p)
    if signature:
        out += signature[:SIGNATURE_SIZE]
    out += trailer
    return bytes(out)


def check_pagesize(pagesize):
    """The same set mkbootimg.c:178 accepts."""
    if pagesize not in ALLOWED_PAGESIZES:
        raise ToolError("error: unsupported page size %d" % pagesize)
    return pagesize


def check_cmdline(cmdline_bytes):
    """mkbootimg.c:228-231: BOOT_ARGS_SIZE - 1 chars max (no extra-cmdline
    support in this header version)."""
    if len(cmdline_bytes) > BOOT_ARGS_SIZE - 1:
        raise ToolError("error: kernel commandline too large")
    return cmdline_bytes


def find_boot_magic(data):
    """unpackbootimg.c:83-95 scans for the magic within the first 512+1 bytes
    (stock Samsung images carry a leading signature block)."""
    for i in range(513):
        if data[i:i + BOOT_MAGIC_SIZE] == BOOT_MAGIC:
            return i
    raise ToolError("error: Android boot magic not found")


def cmd_pack(args):
    if getattr(args, "from_json", None):
        return cmd_pack_from_json(args)
    pagesize = check_pagesize(args.pagesize)
    base = parse_int(str(args.base), "base")
    kernel_offset = parse_int(str(args.kernel_offset), "kernel_offset")
    ramdisk_offset = parse_int(str(args.ramdisk_offset), "ramdisk_offset")
    second_offset = parse_int(str(args.second_offset), "second_offset")
    tags_offset = parse_int(str(args.tags_offset), "tags_offset")
    max_size = parse_int(str(args.max_size), "max_size")

    board = args.board.encode("latin-1")
    if len(board) >= BOOT_NAME_SIZE:                      # mkbootimg.c:219-222
        raise ToolError("error: board name too large")
    cmdline = check_cmdline(args.cmdline.encode("latin-1"))

    if args.kernel is None:
        raise ToolError("error: no kernel image specified")
    kernel = read_file(args.kernel)

    # mkbootimg requires --ramdisk but accepts the literal "NONE"; here an
    # omitted --ramdisk means the same thing (mkbootimg.c:240-249).
    ramdisk = b""
    if args.ramdisk is not None and args.ramdisk != "NONE":
        ramdisk = read_file(args.ramdisk)

    second = None
    if args.second is not None:
        second = read_file(args.second)

    dt = None
    if args.dt is not None:
        dt = read_file(args.dt)

    signature = None
    if args.signature is not None:
        signature = read_file(args.signature)

    trailer = b""
    if args.seandroid:
        trailer = SEANDROIDENFORCE_MAGIC

    hdr = BootHeader()
    hdr.page_size = pagesize
    hdr.kernel_addr = (base + kernel_offset) & 0xFFFFFFFF   # mkbootimg.c:194-197
    hdr.ramdisk_addr = (base + ramdisk_offset) & 0xFFFFFFFF
    hdr.second_addr = (base + second_offset) & 0xFFFFFFFF
    hdr.tags_addr = (base + tags_offset) & 0xFFFFFFFF
    hdr.name = board
    hdr.cmdline = cmdline
    hdr.kernel_size = len(kernel)
    hdr.ramdisk_size = len(ramdisk)
    hdr.second_size = len(second) if second is not None else 0
    hdr.dt_size = len(dt) if dt is not None else 0

    total = image_length(hdr, dt is not None, signature is not None,
                         trailer)
    if total > max_size:
        raise SizeLimitError(
            "error: boot image would be %d bytes (0x%x), exceeding the "
            "--max-size limit of %d bytes (0x%x)" % (total, total, max_size,
                                                     max_size))

    id_digest = compute_sha1_id(kernel, ramdisk,
                                second if second is not None else b"",
                                dt)
    hdr.id = list(struct.unpack("<5I", id_digest)) + [0, 0, 0]

    write_output(args.output, build_boot_image(
        hdr, kernel, ramdisk, second if second is not None else b"", dt,
        signature, trailer))
    return 0


def split_boot_image(data):
    """Inverse of build_boot_image(), following unpackbootimg.c's layout walk
    (read_padding() at unpackbootimg.c:14-30 and the section reads at
    unpackbootimg.c:151-216)."""
    base_off = find_boot_magic(data)
    hdr = BootHeader.unpack(data[base_off:base_off + BOOT_IMG_HDR_SIZE])
    p = hdr.page_size
    pos = base_off + BOOT_IMG_HDR_SIZE
    pos += pad_len(BOOT_IMG_HDR_SIZE, p)

    def take(size):
        nonlocal pos
        chunk = data[pos:pos + size]
        if len(chunk) != size:
            raise ToolError("error: boot image truncated")
        pos += size
        return chunk

    kernel = take(hdr.kernel_size)
    pos += pad_len(hdr.kernel_size, p)
    ramdisk = take(hdr.ramdisk_size)
    pos += pad_len(hdr.ramdisk_size, p)
    second = take(hdr.second_size) if hdr.second_size else b""
    if hdr.second_size:
        # The packer pads the second stage using ramdisk_size (mkbootimg.c:318),
        # so that is where the next section actually starts.  (unpackbootimg.c:
        # 194 skips second_size padding instead, which misparses any image
        # whose ramdisk_size and second_size disagree modulo page_size; see
        # the module docstring.)
        pos += pad_len(hdr.ramdisk_size, p)
    dt = take(hdr.dt_size) if hdr.dt_size else None
    if dt is not None:
        pos += pad_len(hdr.dt_size, p)
    signature = None
    if len(data) - pos >= SIGNATURE_SIZE:
        signature = take(SIGNATURE_SIZE)
    # Anything left is trailing bytes the header does not account for: the
    # observed Samsung "SEANDROIDENFORCE" footer on real device images (see
    # the module docstring).
    trailer = data[pos:]
    return hdr, dict(kernel=kernel, ramdisk=ramdisk,
                     second=second if hdr.second_size else None,
                     dt=dt, signature=signature, trailer=trailer)


def cmd_unpack(args):
    data = read_file(args.input)
    hdr, parts = split_boot_image(data)
    os.makedirs(args.output, exist_ok=True)

    with open(os.path.join(args.output, "kernel"), "wb") as f:
        f.write(parts["kernel"])
    with open(os.path.join(args.output, "ramdisk"), "wb") as f:
        f.write(parts["ramdisk"])
    if parts["second"] is not None:
        with open(os.path.join(args.output, "second"), "wb") as f:
            f.write(parts["second"])
    if parts["dt"] is not None:
        with open(os.path.join(args.output, "dt.img"), "wb") as f:
            f.write(parts["dt"])
    if parts["signature"] is not None:
        with open(os.path.join(args.output, "signature"), "wb") as f:
            f.write(parts["signature"])
    if parts["trailer"]:
        with open(os.path.join(args.output, "trailer.bin"), "wb") as f:
            f.write(parts["trailer"])

    manifest = {
        "format": JSON_FORMAT,
        "input": os.path.basename(args.input),
        "magic": hdr.magic.decode("latin-1"),
        # Payload files, relative to this json file (None = section absent).
        "kernel": "kernel",
        "ramdisk": "ramdisk",
        "second": "second" if parts["second"] is not None else None,
        "dt": "dt.img" if parts["dt"] is not None else None,
        "signature": "signature" if parts["signature"] is not None else None,
        # Trailing bytes after the last section (e.g. the observed Samsung
        # "SEANDROIDENFORCE" footer); hex-encoded so json stays text.
        "trailer_hex": parts["trailer"].hex(),
        # Raw header fields; pack --from-json reproduces the image from these
        # verbatim (the id is reused rather than recomputed, so images whose
        # id was not produced by this SHA-1 scheme round-trip too).
        "header": {
            "kernel_size": hdr.kernel_size,
            "kernel_addr": hdr.kernel_addr,
            "ramdisk_size": hdr.ramdisk_size,
            "ramdisk_addr": hdr.ramdisk_addr,
            "second_size": hdr.second_size,
            "second_addr": hdr.second_addr,
            "tags_addr": hdr.tags_addr,
            "page_size": hdr.page_size,
            "dt_size": hdr.dt_size,
            "unused": hdr.unused,
            # latin-1 gives a byte-exact bijection for these NUL-padded
            # ASCII fields.
            "name": hdr.name.decode("latin-1"),
            "cmdline": hdr.cmdline.decode("latin-1"),
            "id": hdr.id,
        },
        # Convenience breakdown (unpackbootimg.c:99-102 conventions); not used
        # by --from-json, which trusts the raw addrs above.
        "derived": {
            "base": hdr.kernel_addr - DEFAULT_KERNEL_OFFSET,
            "kernel_offset": DEFAULT_KERNEL_OFFSET,
            "ramdisk_offset": hdr.ramdisk_addr - hdr.kernel_addr + DEFAULT_KERNEL_OFFSET,
            "second_offset": hdr.second_addr - hdr.kernel_addr + DEFAULT_KERNEL_OFFSET,
            "tags_offset": hdr.tags_addr - hdr.kernel_addr + DEFAULT_KERNEL_OFFSET,
        },
    }
    with open(os.path.join(args.output, "bootimg.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print("unpacked %s into %s" % (args.input, args.output))
    return 0


def cmd_pack_from_json(args):
    with open(args.from_json, "r") as f:
        manifest = json.load(f)
    if manifest.get("format") != JSON_FORMAT:
        raise ToolError("error: %s is not a %s manifest"
                        % (args.from_json, JSON_FORMAT))
    base_dir = os.path.dirname(os.path.abspath(args.from_json))
    hdr = BootHeader()
    for field in ("kernel_size", "kernel_addr", "ramdisk_size", "ramdisk_addr",
                  "second_size", "second_addr", "tags_addr", "page_size",
                  "dt_size", "unused"):
        setattr(hdr, field, int(manifest["header"][field]))
    hdr.name = manifest["header"]["name"].encode("latin-1")
    hdr.cmdline = check_cmdline(
        manifest["header"]["cmdline"].encode("latin-1"))
    hdr.id = [int(v) & 0xFFFFFFFF for v in manifest["header"]["id"]]
    check_pagesize(hdr.page_size)

    def payload(key, expected_size):
        rel = manifest.get(key)
        if rel is None:
            return None
        data = read_file(os.path.join(base_dir, rel))
        if expected_size and len(data) != expected_size:
            raise ToolError("error: %s is %d bytes but the header says %d"
                            % (rel, len(data), expected_size))
        return data

    kernel = payload("kernel", hdr.kernel_size)
    if kernel is None:
        raise ToolError("error: manifest has no kernel payload")
    ramdisk = payload("ramdisk", hdr.ramdisk_size)
    if ramdisk is None:
        ramdisk = b""
    second = payload("second", hdr.second_size)
    dt = payload("dt", hdr.dt_size)
    signature = payload("signature", None)

    trailer = bytes.fromhex(manifest.get("trailer_hex", ""))

    max_size = parse_int(str(args.max_size), "max_size")
    total = image_length(hdr, dt is not None, signature is not None,
                         trailer)
    if total > max_size:
        raise SizeLimitError(
            "error: boot image would be %d bytes (0x%x), exceeding the "
            "--max-size limit of %d bytes (0x%x)" % (total, total, max_size,
                                                     max_size))

    write_output(args.output, build_boot_image(hdr, kernel, ramdisk,
                                               second if second is not None else b"",
                                               dt,
                                               signature, trailer))
    return 0


def cmd_info(args):
    data = read_file(args.input)
    hdr, parts = split_boot_image(data)
    digest = bytes(b for word in hdr.id[:5] for b in struct.pack("<I", word))
    total = image_length(hdr, parts["dt"] is not None,
                         parts["signature"] is not None, parts["trailer"])
    print("boot_img_hdr v0 (%s)" % args.input)
    print("  magic          = %s" % hdr.magic.decode("latin-1"))
    print("  kernel_size    = %u (0x%x)" % (hdr.kernel_size, hdr.kernel_size))
    print("  kernel_addr    = 0x%08x" % hdr.kernel_addr)
    print("  ramdisk_size   = %u (0x%x)" % (hdr.ramdisk_size, hdr.ramdisk_size))
    print("  ramdisk_addr   = 0x%08x" % hdr.ramdisk_addr)
    print("  second_size    = %u (0x%x)" % (hdr.second_size, hdr.second_size))
    print("  second_addr    = 0x%08x" % hdr.second_addr)
    print("  tags_addr      = 0x%08x" % hdr.tags_addr)
    print("  page_size      = %u" % hdr.page_size)
    print("  dt_size        = %u (0x%x)" % (hdr.dt_size, hdr.dt_size))
    print("  unused         = %u" % hdr.unused)
    print("  name           = %s" % hdr.name.decode("latin-1"))
    print("  cmdline        = %s" % hdr.cmdline.decode("latin-1"))
    print("  id             = %s" % " ".join("%08x" % w for w in hdr.id))
    print("  id (sha1)      = %s" % digest.hex())
    print("  base           = 0x%08x (kernel_addr - 0x%08x)"
          % (hdr.kernel_addr - DEFAULT_KERNEL_OFFSET, DEFAULT_KERNEL_OFFSET))
    print("  ramdisk_offset = 0x%08x" % (hdr.ramdisk_addr - hdr.kernel_addr
                                         + DEFAULT_KERNEL_OFFSET))
    print("  tags_offset    = 0x%08x" % (hdr.tags_addr - hdr.kernel_addr
                                         + DEFAULT_KERNEL_OFFSET))
    print("  image size     = %u (0x%x) bytes; BOOT partition limit is %u "
          "(0x%x)" % (total, total, DEFAULT_MAX_SIZE, DEFAULT_MAX_SIZE))
    if total > DEFAULT_MAX_SIZE:
        print("  WARNING: image exceeds the BOOT partition size")
    trailer = parts["trailer"]
    if trailer:
        printable = "".join(chr(b) if 0x20 <= b < 0x7F else "."
                            for b in trailer)
        print("  trailer        = %u bytes: %s%s" %
              (len(trailer), printable,
               " (SEANDROIDENFORCE footer)"
               if trailer == SEANDROIDENFORCE_MAGIC else ""))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def add_pagesize_option(parser, default=DEFAULT_PAGESIZE):
    parser.add_argument("--pagesize", type=lambda v: parse_int(v, "pagesize",
                                                               base=10),
                        default=default,
                        help="flash page size (default %d)" % default)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="samsung_bootimg.py",
        description="Samsung Exynos (SM-T715) boot.img + DTBH packer/unpacker,"
                    " byte-compatible with the LineageOS dtbhtool C reference"
                    " (see --help on each subcommand and the module docstring).")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("dtbh-pack", help="build a DTBH image from DTBs")
    p.add_argument("-o", "--output", required=True, help="output dt.img path")
    p.add_argument("--platform", default=DTBH_PLATFORM,
                   help="expected model_info-platform string "
                        "(default %s)" % DTBH_PLATFORM)
    p.add_argument("--subtype", default=DTBH_SUBTYPE,
                   help="expected model_info-subtype string "
                        "(default %s)" % DTBH_SUBTYPE)
    p.add_argument("--platform-code", type=lambda v: parse_int(v, "platform-code"),
                   default=DTBH_PLATFORM_CODE,
                   help="DTBH platform code written to every entry "
                        "(default 0x%x)" % DTBH_PLATFORM_CODE)
    p.add_argument("--subtype-code", type=lambda v: parse_int(v, "subtype-code"),
                   default=DTBH_SUBTYPE_CODE,
                   help="DTBH subtype code written to every entry "
                        "(default 0x%x)" % DTBH_SUBTYPE_CODE)
    add_pagesize_option(p)
    p.add_argument("--dtb", action="append", metavar="HWREV[:HWREV_END]=path",
                   help="DTB to include; may be repeated.  chip/hw_rev/"
                        "hw_rev_end always come from the DTB's model_info-* "
                        "properties (as the C tool does); the prefix is "
                        "cross-checked against them.")
    p.set_defaults(func=cmd_dtbh_pack)

    p = sub.add_parser("dtbh-unpack", help="list DTBH entries and extract DTBs")
    p.add_argument("input", help="DTBH image (dt.img)")
    p.add_argument("-o", "--output", required=True, help="output directory")
    add_pagesize_option(p)
    p.set_defaults(func=cmd_dtbh_unpack)

    p = sub.add_parser("pack", help="build a boot.img (header v0 + dt)")
    p.add_argument("--kernel", help="kernel image (zImage); not required with"
                                    " --from-json")
    p.add_argument("--ramdisk", help="ramdisk image; omitted or 'NONE' means "
                                     "an empty ramdisk")
    p.add_argument("--dt", help="device tree image (DTBH dt.img)")
    p.add_argument("--second", help="optional second-stage image")
    p.add_argument("--signature", help="optional trailing 256-byte signature")
    p.add_argument("--seandroid", action="store_true",
                   help="append the Samsung 'SEANDROIDENFORCE' footer "
                        "(16 bytes, observed on real device images; not "
                        "written by the C reference tools)")
    p.add_argument("--cmdline", default="", help="kernel commandline "
                                                 "(<= 511 chars)")
    p.add_argument("--board", default="", help="board name (<= 15 chars)")
    p.add_argument("--base", default="0x%08x" % DEFAULT_BASE)
    p.add_argument("--kernel-offset", default="0x%08x" % DEFAULT_KERNEL_OFFSET)
    p.add_argument("--ramdisk-offset", dest="ramdisk_offset",
                   default="0x%08x" % DEFAULT_RAMDISK_OFFSET)
    p.add_argument("--second-offset", dest="second_offset",
                   default="0x%08x" % DEFAULT_SECOND_OFFSET)
    p.add_argument("--tags-offset", dest="tags_offset",
                   default="0x%08x" % DEFAULT_TAGS_OFFSET)
    add_pagesize_option(p)
    p.add_argument("--max-size", default="0x%08x" % DEFAULT_MAX_SIZE,
                   help="refuse to write an image larger than this "
                        "(default 0x%x = 14 MiB BOOT partition)"
                        % DEFAULT_MAX_SIZE)
    p.add_argument("--from-json", dest="from_json", metavar="DIR/bootimg.json",
                   help="rebuild from an 'unpack' manifest instead of "
                        "individual input files")
    p.add_argument("-o", "--output", required=True, help="output boot.img path")
    p.set_defaults(func=cmd_pack)

    p = sub.add_parser("unpack", help="split a boot.img into parts + json")
    p.add_argument("input", help="boot image")
    p.add_argument("-o", "--output", required=True, help="output directory")
    p.set_defaults(func=cmd_unpack)

    p = sub.add_parser("info", help="dump the boot image header")
    p.add_argument("input", help="boot image")
    p.set_defaults(func=cmd_info)

    # Rebuild a boot.img from an unpack'd bootimg.json.
    p = sub.add_parser("pack-from-json",
                       help="rebuild a boot.img from an unpack'd bootimg.json")
    p.add_argument("from_json", metavar="bootimg.json",
                   help="manifest produced by 'unpack'")
    p.add_argument("--max-size", default="0x%08x" % DEFAULT_MAX_SIZE)
    p.add_argument("-o", "--output", required=True, help="output boot.img path")
    p.set_defaults(func=cmd_pack_from_json)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "func", None) is None:
        parser.print_help()
        return 1
    try:
        return args.func(args)
    except ToolError as exc:
        sys.stderr.write("%s\n" % exc)
        return 1
    except SizeLimitError as exc:
        sys.stderr.write("%s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main())
