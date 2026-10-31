/* SPDX-License-Identifier: GPL-2.0-or-later */
/* zlib-compatible CRC-32 (reflected polynomial 0xEDB88320). */

#ifndef SL_CRC32_H
#define SL_CRC32_H

#include <stddef.h>
#include <stdint.h>

/*
 * zlib-compatible: sl_crc32_update(0, buf, len) == zlib crc32(0, buf, len),
 * and chaining works like zlib: crc = sl_crc32_update(crc, more, n).
 * buf may be NULL when len == 0; that returns crc unchanged.
 */
uint32_t sl_crc32_update(uint32_t crc, const void *buf, size_t len);

#endif /* SL_CRC32_H */
