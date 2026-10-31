/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Synthetic fixtures for the shannon-loader tests: deterministic PRNG,
 * CRC32 forging (so that synthetic BOOT/MAIN carry the stock CRC values),
 * RADIO image builder (TOC layout of research/modem/radio_toc.py) and NV
 * pattern. Nothing here contains real firmware or real NV data.
 */
#ifndef SL_TEST_FIXTURES_H
#define SL_TEST_FIXTURES_H

#include <stddef.h>
#include <stdint.h>

struct img_spec {
	uint32_t boot_size;
	uint32_t main_size;
	uint32_t nv_size;
	int main_forge;			/* force MAIN CRC to main_crc */
	uint32_t main_crc;
	uint64_t image_size;		/* 0: smallest valid */
	int offset_slot;		/* add the stock OFFSET row */
	uint32_t seed;
};

struct img {
	uint8_t *data;			/* allocated bytes (image beyond is zero) */
	size_t len;
	uint64_t size;			/* reported image size */
	uint32_t boot_off, boot_size, boot_crc;
	uint32_t main_off, main_size, main_crc;
	uint32_t nv_size;
};

/* stock geometry: MAIN 0x21271A0 (16 975 frames), NV 0x100000, BOOT 0x29FC */
void img_spec_real(struct img_spec *s);
/* LS2 10.3 (b): BOOT 0x100, MAIN 5001 (3 frames, last 905), NV 0x1800 */
void img_spec_small(struct img_spec *s);
int img_build(const struct img_spec *s, struct img *out);
void img_free(struct img *im);

void put_le32(uint8_t *p, uint32_t v);
uint32_t get_le32(const uint8_t *p);
void prng_fill(uint8_t *buf, size_t n, uint32_t seed);
void crc_forge_tail(uint8_t *buf, size_t len, uint32_t target);
void nv_pattern(uint8_t *buf, size_t n, uint32_t seed);

#endif
