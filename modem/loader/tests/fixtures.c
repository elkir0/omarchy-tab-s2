// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Synthetic fixtures for the shannon-loader tests.
 */
#include <stdlib.h>
#include <string.h>

#include "fixtures.h"
#include "sl_abi.h"
#include "sl_crc32.h"

void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void prng_fill(uint8_t *buf, size_t n, uint32_t seed)
{
	uint32_t x = seed ? seed : 0x12345678u;
	size_t i;

	for (i = 0; i < n; i++) {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		buf[i] = (uint8_t)(x >> 24);
	}
}

void nv_pattern(uint8_t *buf, size_t n, uint32_t seed)
{
	prng_fill(buf, n, seed ^ 0x4E560000u);
}

/*
 * Reflected CRC-32 (zlib): after the prefix the register is S; feeding the
 * last four bytes P (little-endian) gives f^32(S ^ P), f being one shift
 * step. Choose P = f^-32(~target) ^ S so that the final CRC is `target`.
 */
static uint32_t crc_unstep32(uint32_t r)
{
	int i;

	for (i = 0; i < 32; i++) {
		if (r & 0x80000000u)
			r = ((r ^ 0xEDB88320u) << 1) | 1u;
		else
			r <<= 1;
	}
	return r;
}

void crc_forge_tail(uint8_t *buf, size_t len, uint32_t target)
{
	uint32_t s = ~sl_crc32_update(0, buf, len - 4);

	put_le32(buf + len - 4, crc_unstep32(~target) ^ s);
}

void img_spec_real(struct img_spec *s)
{
	memset(s, 0, sizeof(*s));
	s->boot_size = 0x29FC;
	s->main_size = 0x21271A0;
	s->nv_size = 0x100000;
	s->main_forge = 1;
	s->main_crc = 0x1E71169C;
	s->image_size = 92274688u;	/* RADIO partition */
	s->offset_slot = 1;
	s->seed = 0xC0FFEE01u;
}

void img_spec_small(struct img_spec *s)
{
	memset(s, 0, sizeof(*s));
	s->boot_size = 0x100;
	s->main_size = 5001;
	s->nv_size = 0x1800;
	s->seed = 0xC0FFEE02u;
}

static void toc_entry(uint8_t *toc, unsigned int slot, const char *name,
		      uint32_t off, uint32_t load, uint32_t size, uint32_t crc,
		      uint32_t index)
{
	uint8_t *e = toc + slot * SL_TOC_ENTRY;

	memset(e, 0, SL_TOC_ENTRY);
	memcpy(e, name, strlen(name));
	put_le32(e + 12, off);
	put_le32(e + 16, load);
	put_le32(e + 20, size);
	put_le32(e + 24, crc);
	put_le32(e + 28, index);
}

int img_build(const struct img_spec *s, struct img *im)
{
	uint32_t main_off = (SL_TOC_BYTES + s->boot_size + 0x1FFu) & ~0x1FFu;
	size_t len = (size_t)main_off + s->main_size;
	uint64_t size;

	memset(im, 0, sizeof(*im));
	size = s->image_size ? s->image_size : len;
	if (size < s->nv_size)
		size = s->nv_size;
	size = (size + 0x1FFu) & ~(uint64_t)0x1FFu;
	if (size < len)
		return -1;
	im->data = calloc(1, (size_t)size < len + 0x200 ? (size_t)size : len);
	if (!im->data)
		return -1;
	im->len = (size_t)size < len + 0x200 ? (size_t)size : len;
	im->size = size;

	im->boot_off = SL_TOC_BYTES;
	im->boot_size = s->boot_size;
	prng_fill(im->data + im->boot_off, s->boot_size, s->seed);
	crc_forge_tail(im->data + im->boot_off, s->boot_size, SL_BOOT_CRC_PINNED);
	im->boot_crc = sl_crc32_update(0, im->data + im->boot_off, s->boot_size);

	im->main_off = main_off;
	im->main_size = s->main_size;
	prng_fill(im->data + main_off, s->main_size, s->seed * 2654435761u + 7u);
	if (s->main_forge)
		crc_forge_tail(im->data + main_off, s->main_size, s->main_crc);
	im->main_crc = sl_crc32_update(0, im->data + main_off, s->main_size);
	im->nv_size = s->nv_size;

	toc_entry(im->data, 0, "TOC", 0, 0, SL_TOC_BYTES, 0, 1);
	toc_entry(im->data, 1, "BOOT", im->boot_off, 0, s->boot_size, im->boot_crc, 0);
	toc_entry(im->data, 2, "MAIN", main_off, 0x40000000u, s->main_size, im->main_crc, 2);
	toc_entry(im->data, 3, "NV", 0, 0x47EE0000u, s->nv_size, 0, 3);
	if (s->offset_slot)
		toc_entry(im->data, 4, "OFFSET", 0x7AA00, 0, 0x85600, 0, 4);
	return 0;
}

void img_free(struct img *im)
{
	free(im->data);
	memset(im, 0, sizeof(*im));
}
