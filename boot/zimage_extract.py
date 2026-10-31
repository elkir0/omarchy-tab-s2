#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Decompress an ARM zImage and recover the embedded kernel configuration.

zImage layout (Linux 3.1x, arch/arm/boot/compressed/vmlinux.lds.in):

    .text        head.S startup + PIC decompressor (misc.c, decompress.c,
                 string.c, lib1funcs, ...), position-independent
    .rodata      decompressor strings and constants.  Beware: compiler
                 material lives here too, including a literal copy of the
                 lzop magic and the decompressor's own error strings — a
                 magic hit inside the decompressor region is a decoy.
    .piggydata   the compressed kernel image (piggy.lzo/gz/xzkern/lzma)
    .pad         padding to 8 bytes
    _edata       end of the on-disk zImage (stored as a word at 0x2c)

Pipeline:
  1. parse the header words at 0x24: magic 0x016f2818, start, end (_edata)
  2. locate the payload: scan for known magics and validate each hit by
     trial decompression; on total failure, trial-decompress at every
     4-byte-aligned offset bounded by _edata
  3. decompress: gzip / xz / lzma-alone / lz4 (frame or legacy, via the lz4
     CLI when installed) and LZO in the kernel framing (lzop file header +
     256 KiB blocks of [dst_len][src_len][cksum][data]) through a pure-Python
     port of lib/lzo/lzo1x_decompress_safe.c
  4. IKCONFIG: search the uncompressed Image for IKCFG_ST ... IKCFG_ED (a
     gzip stream) and inflate it into the .config
  5. print a report: compressor, offsets, sizes, IKCONFIG status

Only the Python stdlib is required.
"""

import argparse
import bz2
import datetime
import gzip
import lzma
import os
import struct
import sys
import zlib

ZIMAGE_MAGIC = 0x016F2818
LZOP_MAGIC = b'\x89LZO\x00\r\n\x1a\n'
GZIP_MAGIC = b'\x1f\x8b\x08'
XZ_MAGIC = b'\xfd7zXZ\x00'
LZ4_FRAME_MAGIC = b'\x04\x22\x4d\x18'
LZ4_LEGACY_MAGIC = b'\x02\x21\x4c\x18'
LZO_BLOCK_SIZE = 256 * 1024

HEADER_HAS_FILTER = 0x00000800
F_ADLER32_D = 0x1
F_ADLER32_C = 0x2
F_CRC32_D = 0x4
F_CRC32_C = 0x8

# lzo1x return codes (include/linux/lzo.h)
(LZO_E_OK, LZO_E_ERROR, LZO_E_INPUT_OVERRUN, LZO_E_OUTPUT_OVERRUN,
 LZO_E_LOOKBEHIND_OVERRUN, LZO_E_EOF_NOT_FOUND, LZO_E_INPUT_NOT_CONSUMED) = (
    0, -1, -4, -5, -6, -7, -8)

M2_MAX_OFFSET = 0x0800


# --------------------------------------------------------------------------
# pure-Python LZO1X decompressor
# --------------------------------------------------------------------------

def _get_le16(buf, pos):
    return buf[pos] | (buf[pos + 1] << 8)


def lzo1x_decompress_safe(in_buf, in_len, out_cap):
    """Port of lib/lzo/lzo1x_decompress_safe.c (Linux 3.10).

    Returns (out bytearray, out_len, code).  The C fast paths that use
    unaligned 4/8-byte copies are byte-for-byte equivalent to the plain
    forward byte loop implemented here.
    """
    out = bytearray(out_cap)
    op = 0
    ip = 0
    ip_end = in_len
    state = 0
    t = 0

    if in_len < 3:
        return out, 0, LZO_E_INPUT_OVERRUN

    def copy_literal_run(count):
        """Copy `count` literal bytes; returns error code or None."""
        nonlocal ip, op
        if in_len - ip < count + 3:
            return LZO_E_INPUT_OVERRUN
        if len(out) - op < count:
            return LZO_E_OUTPUT_OVERRUN
        out[op:op + count] = in_buf[ip:ip + count]
        op += count
        ip += count
        return None

    def copy_match(m_pos, count):
        """Copy `count` bytes from m_pos (overlap-safe, forward byte loop);
        returns error code or None."""
        nonlocal ip, op
        if m_pos < 0:
            return LZO_E_LOOKBEHIND_OVERRUN
        if len(out) - op < count:
            return LZO_E_OUTPUT_OVERRUN
        for _ in range(count):
            out[op] = out[m_pos]
            op += 1
            m_pos += 1
        return None

    def copy_next(next_):
        """The match_next block: copy `next_` literal bytes; returns code."""
        nonlocal ip, op
        if in_len - ip < next_ + 3:
            return LZO_E_INPUT_OVERRUN
        if len(out) - op < next_:
            return LZO_E_OUTPUT_OVERRUN
        out[op:op + next_] = in_buf[ip:ip + next_]
        op += next_
        ip += next_
        return None

    # C: if (*ip > 17) { t = *ip++ - 17; ... }
    if in_buf[ip] > 17:
        t = in_buf[ip] - 17
        ip += 1
        if t < 4:
            # goto match_next
            state = t
            err = copy_next(t)
            if err:
                return out, op, err
        else:
            # goto copy_literal_run
            err = copy_literal_run(t)
            if err:
                return out, op, err
            state = 4

    while True:
        t = in_buf[ip]
        ip += 1
        if t < 16:
            if state == 0:
                if t == 0:
                    ip_last = ip
                    while in_buf[ip] == 0:
                        ip += 1
                        if ip >= in_len:
                            return out, op, LZO_E_INPUT_OVERRUN
                    offset = ip - ip_last
                    offset = (offset << 8) - offset
                    t += offset + 15 + in_buf[ip]
                    ip += 1
                t += 3
                err = copy_literal_run(t)
                if err:
                    return out, op, err
                state = 4
                continue
            elif state != 4:
                nxt = t & 3
                m_pos = op - 1 - (t >> 2) - (in_buf[ip] << 2)
                ip += 1
                err = copy_match(m_pos, 2)
                if err:
                    return out, op, err
                # goto match_next
                state = nxt
                err = copy_next(nxt)
                if err:
                    return out, op, err
                continue
            else:
                nxt = t & 3
                m_pos = op - (1 + M2_MAX_OFFSET) - (t >> 2) - (in_buf[ip] << 2)
                ip += 1
                t = 3
        elif t >= 64:
            nxt = t & 3
            m_pos = op - 1 - ((t >> 2) & 7) - (in_buf[ip] << 3)
            ip += 1
            t = (t >> 5) - 1 + 2
        elif t >= 32:
            t = (t & 31) + 2
            if t == 2:
                ip_last = ip
                while in_buf[ip] == 0:
                    ip += 1
                    if ip >= in_len:
                        return out, op, LZO_E_INPUT_OVERRUN
                offset = ip - ip_last
                offset = (offset << 8) - offset
                t += offset + 31 + in_buf[ip]
                ip += 1
                if in_len - ip < 2:
                    return out, op, LZO_E_INPUT_OVERRUN
            word = _get_le16(in_buf, ip)
            ip += 2
            m_pos = op - 1 - (word >> 2)
            nxt = word & 3
        else:
            # 16 <= t < 32: M4 (big offset) match
            m_pos = op - ((t & 8) << 11)
            t = (t & 7) + 2
            if t == 2:
                ip_last = ip
                while in_buf[ip] == 0:
                    ip += 1
                    if ip >= in_len:
                        return out, op, LZO_E_INPUT_OVERRUN
                offset = ip - ip_last
                offset = (offset << 8) - offset
                t += offset + 7 + in_buf[ip]
                ip += 1
                if in_len - ip < 2:
                    return out, op, LZO_E_INPUT_OVERRUN
            word = _get_le16(in_buf, ip)
            ip += 2
            m_pos -= word >> 2
            nxt = word & 3
            if m_pos == op:
                # eof_found
                if t != 3:
                    return out, op, LZO_E_ERROR
                if ip == ip_end:
                    return out, op, LZO_E_OK
                return out, op, (LZO_E_INPUT_NOT_CONSUMED if ip < ip_end
                                 else LZO_E_INPUT_OVERRUN)
            m_pos -= 0x4000

        # common match copy + match_next (C: TEST_LB / copy / match_next)
        err = copy_match(m_pos, t)
        if err:
            return out, op, err
        state = nxt
        err = copy_next(nxt)
        if err:
            return out, op, err


# --------------------------------------------------------------------------
# zImage header
# --------------------------------------------------------------------------

class ZImageHeader(object):
    """The three words at 0x24 (head.S): magic, start, end (_edata)."""

    def __init__(self, data):
        if len(data) < 0x30:
            raise ValueError('file too small to be an ARM zImage (%d bytes)'
                             % len(data))
        self.magic, self.start, self.end = struct.unpack_from('<III', data,
                                                              0x24)
        self.valid = (self.magic == ZIMAGE_MAGIC)
        self.file_size = len(data)
        self.trailing = self.file_size - self.end if self.valid else None

    def describe(self):
        lines = ['zImage header @0x24: magic=%#010x start=%#010x '
                 'end(_edata)=%#010x' % (self.magic, self.start, self.end)]
        if self.valid:
            lines.append('  file size %#x (%d bytes)' % (self.file_size,
                                                         self.file_size))
            if self.trailing == 0:
                lines.append('  _edata == file size: nothing after the zImage')
            else:
                lines.append('  %#x bytes appended after _edata'
                             % self.trailing)
        return '\n'.join(lines)


# --------------------------------------------------------------------------
# lzop / kernel-LZO stream
# --------------------------------------------------------------------------

def parse_lzop_header(data, off):
    """Parse an lzop file header at `off`; None if there is none.

    Layout (lzop 1.x, cf. lib/decompress_unlzo.c:parse_header):
      9B magic | u16be version | u16be libversion | u16be needversion |
      u8 method | u8 level | u32be flags | [u32be filter info] |
      u32be mode | u32be mtime_lo | [u32be mtime_hi, lzop >= 0x0940] |
      u32be namelen | name | u32be header checksum (adler32 of the fields
      after the magic, stored big-endian).
    """
    if data[off:off + 9] != LZOP_MAGIC:
        return None
    p = off + 9
    version, lib_ver, need_ver = struct.unpack_from('>HHH', data, p)
    p += 6
    method = data[p]
    level = data[p + 1]
    p += 2
    flags = struct.unpack_from('>I', data, p)[0]
    p += 4
    filter_ = None
    if flags & HEADER_HAS_FILTER:
        filter_ = struct.unpack_from('>I', data, p)[0]
        p += 4
    mode, mtime_lo = struct.unpack_from('>II', data, p)
    p += 8
    if version >= 0x0940:
        mtime_hi = struct.unpack_from('>I', data, p)[0]
        p += 4
    else:
        mtime_hi = 0
    namelen = data[p]
    p += 1
    name = bytes(data[p:p + namelen])
    p += namelen
    hdr_fields_end = p
    hdr_cksum_be = struct.unpack_from('>I', data, p)[0]
    p += 4
    calc = zlib.adler32(data[off + 9:hdr_fields_end]) & 0xffffffff
    return {
        'off': off,
        'version': version,
        'lib_version': lib_ver,
        'need_version': need_ver,
        'method': method,
        'level': level,
        'flags': flags,
        'filter': filter_,
        'mode': mode,
        'mtime': (mtime_hi << 32) | mtime_lo,
        'name': name,
        'hdr_cksum': hdr_cksum_be,
        'hdr_cksum_ok': (hdr_cksum_be == calc),
        'blocks_off': p,
    }


def decompress_lzo_stream(data, off, max_out=256 * 1024 * 1024):
    """Decompress an lzop stream as lib/decompress_unlzo.c consumes it:
    after the file header, blocks of [u32be dst_len][u32be src_len]
    [u32be cksum][data]; dst_len == 0 terminates.  The kernel never verifies
    the block checksums; we verify the structural invariants instead.

    Returns (out bytes, end offset, info dict); raises ValueError.
    """
    h = parse_lzop_header(data, off)
    if h is None:
        raise ValueError('not an lzop stream at %#x' % off)
    info = dict(h)
    pos = h['blocks_off']
    out = bytearray()
    nblocks = 0
    while True:
        if pos + 4 > len(data):
            raise ValueError('truncated stream: block header at %#x' % pos)
        dst_len = struct.unpack_from('>I', data, pos)[0]
        if dst_len == 0:
            pos += 4
            break
        if dst_len > LZO_BLOCK_SIZE:
            raise ValueError('dst_len %d > LZO_BLOCK_SIZE at %#x'
                             % (dst_len, pos))
        if pos + 12 > len(data):
            raise ValueError('truncated block header at %#x' % pos)
        src_len = struct.unpack_from('>I', data, pos + 4)[0]
        if src_len == 0 or src_len > dst_len:
            raise ValueError('bad src_len %d (dst %d) at %#x'
                             % (src_len, dst_len, pos))
        blk = data[pos + 12:pos + 12 + src_len]
        if len(blk) < src_len:
            raise ValueError('truncated block at %#x' % pos)
        if dst_len == src_len:
            out += blk
        else:
            res, produced, code = lzo1x_decompress_safe(blk, src_len, dst_len)
            if code != LZO_E_OK:
                raise ValueError('lzo error %d in block %d at %#x'
                                 % (code, nblocks + 1, pos))
            if produced != dst_len:
                raise ValueError('block %d: produced %d, header said %d'
                                 % (nblocks + 1, produced, dst_len))
            out += res
        if len(out) > max_out:
            raise ValueError('output exceeds %d bytes' % max_out)
        pos += 12 + src_len
        nblocks += 1
    info['nblocks'] = nblocks
    info['stream_end'] = pos
    return bytes(out), pos, info


# --------------------------------------------------------------------------
# other compressors
# --------------------------------------------------------------------------

def _trim_gz(gz_bytes):
    """Inflate a gzip member, tolerating trailing data."""
    d = zlib.decompressobj(zlib.MAX_WBITS | 16)
    return d.decompress(gz_bytes)


def try_gzip(data, off):
    return _trim_gz(data[off:]), None


def try_xz(data, off):
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    return dec.decompress(data[off:]), None


def try_lzma_alone(data, off):
    # magicless format: the probe would "succeed" on arbitrary bytes whenever
    # the header's declared size happens to be small, so require a complete,
    # fully-consumed stream (EOS seen, no trailing unused input)
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_ALONE)
    out = dec.decompress(data[off:])
    if not dec.eof or dec.unused_data:
        raise ValueError('lzma-alone: incomplete stream')
    return out, None


def try_bz2(data, off):
    return bz2.decompress(data[off:]), None


def _external(cmd_args, tag):
    import shutil
    import subprocess
    exe = shutil.which(cmd_args[0])
    if not exe:
        raise ValueError('%s CLI not available' % tag)
    proc = subprocess.run(cmd_args, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise ValueError('%s -d failed: %s' % (tag, proc.stderr[:200]))
    return proc.stdout


def try_lz4_frame(data, off):
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, 'in.lz4')
        with open(src, 'wb') as f:
            f.write(data[off:])
        out = _external(['lz4', '-d', '-c', src], 'lz4')
    return out, None


def try_lz4_legacy(data, off):
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, 'in.lz4')
        with open(src, 'wb') as f:
            f.write(data[off:])
        out = _external(['lz4', '-d', '-c', '-l', src], 'lz4-legacy')
    return out, None


def try_lzo_kernel(data, off):
    out, end, info = decompress_lzo_stream(data, off)
    return out, {'end': end, 'info': info}


# probe order: most common/likely first; lzma-alone has no magic and is only
# tried during the aligned brute-force pass
def _probe_at(data, off):
    """Try every format at `off`; returns (name, out, meta) or None."""
    for name, fn in (('lzo-kernel', try_lzo_kernel),
                     ('gzip', try_gzip),
                     ('xz', try_xz),
                     ('lz4-frame', try_lz4_frame),
                     ('lz4-legacy', try_lz4_legacy),
                     ('bzip2', try_bz2),
                     ('lzma-alone', try_lzma_alone)):
        try:
            out, meta = fn(data, off)
        except Exception:
            continue
        if out:
            return name, out, meta
    return None


def find_payload(data, edata):
    """Locate the compressed payload.

    Pass 1: magic hits (each validated by trial decompression — the
    decompressor's .rodata contains decoy copies of the magics).
    Pass 2 (fallback): trial decompression at every 4-byte-aligned offset
    bounded by _edata (piggydata is word-aligned per the linker script).
    """
    limit = min(len(data), edata) if edata else len(data)
    magics = (('lzo-kernel', LZOP_MAGIC),
              ('gzip', GZIP_MAGIC),
              ('xz', XZ_MAGIC),
              ('lz4-frame', LZ4_FRAME_MAGIC),
              ('lz4-legacy', LZ4_LEGACY_MAGIC))
    for name, magic in magics:
        pos = 0
        while True:
            hit = data.find(magic, pos, limit)
            if hit < 0:
                break
            pos = hit + 1
            if hit % 4 != 0:
                continue  # piggydata is word aligned; skip obvious decoys
            r = _probe_at(data, hit)
            if r:
                fmt, out, meta = r
                return hit, fmt, out, meta
    for off in range(0, limit, 4):
        r = _probe_at(data, off)
        if r:
            fmt, out, meta = r
            return off, fmt, out, meta
    return None


# --------------------------------------------------------------------------
# IKCONFIG
# --------------------------------------------------------------------------

def extract_ikconfig(image):
    """IKCFG_ST ... IKCFG_ED frames a gzip'ed .config
    (scripts/extract-ikconfig).  Returns the .config bytes or None."""
    start = image.find(b'IKCFG_ST')
    if start < 0:
        return None
    start += 8
    end = image.find(b'IKCFG_ED', start)
    if end < 0:
        raise ValueError('IKCFG_ST without IKCFG_ED')
    blob = image[start:end]
    if blob[:2] != b'\x1f\x8b':
        raise ValueError('IKCONFIG blob is not gzip')
    return gzip.decompress(blob)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def _human(n):
    return '%#x (%d)' % (n, n)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description='Decompress an ARM zImage; recover the kernel Image and '
                    'the embedded (IKCONFIG) .config when present.')
    ap.add_argument('kernel',
                    help='zImage file (boot image kernel section)')
    ap.add_argument('-o', '--outdir', default='.',
                    help='output directory for the Image and .config')
    ap.add_argument('--image-name', default='Image.stock')
    ap.add_argument('--config-name', default='running_kernel.config')
    ap.add_argument('--no-write', action='store_true',
                    help='analyse only; write nothing')
    args = ap.parse_args(argv)

    with open(args.kernel, 'rb') as f:
        data = f.read()
    print('input: %s, %s bytes' % (args.kernel, _human(len(data))))

    hdr = ZImageHeader(data)
    print(hdr.describe())
    if not hdr.valid:
        print('warning: no zImage magic at 0x24; trying anyway',
              file=sys.stderr)

    hit = find_payload(data, hdr.end if hdr.valid else len(data))
    if hit is None:
        print('ERROR: no payload found (magic scan + 4-aligned brute force '
              'up to _edata)')
        return 1
    off, fmt, image, meta = hit
    print('payload: compressor=%s offset=%s' % (fmt, _human(off)))
    if fmt == 'lzo-kernel':
        info = meta['info']
        mtime = datetime.datetime.fromtimestamp(
            info['mtime'], datetime.timezone.utc)
        print('  lzop header: version=%#06x lib=%#06x need=%#06x method=%d '
              'level=%d flags=%#010x' % (info['version'], info['lib_version'],
                                         info['need_version'], info['method'],
                                         info['level'], info['flags']))
        print('  mtime=%s name=%r header adler32(be) ok: %s'
              % (mtime.isoformat(), info['name'], info['hdr_cksum_ok']))
        print('  blocks: %d, stream end %s, gap to _edata: %d bytes'
              % (info['nblocks'], _human(info['stream_end']),
                 hdr.end - info['stream_end']))
    print('decompressed Image: %s bytes' % _human(len(image)))

    if not args.no_write:
        os.makedirs(args.outdir, exist_ok=True)
        img_path = os.path.join(args.outdir, args.image_name)
        with open(img_path, 'wb') as f:
            f.write(image)
        print('written: %s' % img_path)

    try:
        cfg = extract_ikconfig(image)
    except ValueError as e:
        print('IKCONFIG: %s' % e)
        cfg = None
    if cfg is not None:
        if not args.no_write:
            cfg_path = os.path.join(args.outdir, args.config_name)
            with open(cfg_path, 'wb') as f:
                f.write(cfg)
            print('written: %s (%d CONFIG_ lines)' %
                  (cfg_path, cfg.count(b'\nCONFIG_')))
    else:
        print('IKCONFIG: not embedded (no IKCFG_ST in the decompressed '
              'Image)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
