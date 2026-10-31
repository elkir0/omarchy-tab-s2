/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * MD5 per RFC 1321.  All loads and stores are byte-wise, so no alignment
 * or endianness assumptions are made.
 */

#include <string.h>

#include "sl_md5.h"

/* abs(sin(i + 1)) * 2^32, i = 0..63. */
static const uint32_t sl_md5_t[64] = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
	0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
	0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
	0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
	0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
	0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
	0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
	0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
	0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};

/* Left-rotation amounts, rounds 1..4. */
static const uint8_t sl_md5_r[64] = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
};

static uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
	       (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

/* Rotate left; n is in [1, 31]. */
static uint32_t rotl(uint32_t v, unsigned int n)
{
	return v << n | v >> (32 - n);
}

/* Process the full 64-byte block held in ctx->buf. */
static void sl_md5_block(struct sl_md5 *ctx)
{
	uint32_t a = ctx->s[0];
	uint32_t b = ctx->s[1];
	uint32_t c = ctx->s[2];
	uint32_t d = ctx->s[3];
	unsigned int i;

	for (i = 0; i < 64; i++) {
		uint32_t f, g, tmp;

		if (i < 16) {
			f = (b & c) | (~b & d);
			g = i;
		} else if (i < 32) {
			f = (d & b) | (~d & c);
			g = (5 * i + 1) % 16;
		} else if (i < 48) {
			f = b ^ c ^ d;
			g = (3 * i + 5) % 16;
		} else {
			f = c ^ (b | ~d);
			g = (7 * i) % 16;
		}

		tmp = d;
		d = c;
		c = b;
		b += rotl(a + f + sl_md5_t[i] + get_le32(&ctx->buf[g * 4]),
			  sl_md5_r[i]);
		a = tmp;
	}

	ctx->s[0] += a;
	ctx->s[1] += b;
	ctx->s[2] += c;
	ctx->s[3] += d;
}

void sl_md5_init(struct sl_md5 *ctx)
{
	ctx->s[0] = 0x67452301;
	ctx->s[1] = 0xefcdab89;
	ctx->s[2] = 0x98badcfe;
	ctx->s[3] = 0x10325476;
	ctx->total = 0;
	ctx->used = 0;
}

void sl_md5_update(struct sl_md5 *ctx, const void *data, size_t len)
{
	const uint8_t *p = data;

	if (!p)
		return;
	ctx->total += len;

	while (len) {
		size_t n = 64 - ctx->used;

		if (n > len)
			n = len;
		memcpy(ctx->buf + ctx->used, p, n);
		ctx->used += n;
		p += n;
		len -= n;
		if (ctx->used == 64) {
			sl_md5_block(ctx);
			ctx->used = 0;
		}
	}
}

void sl_md5_final(struct sl_md5 *ctx, uint8_t out[SL_MD5_LEN])
{
	uint64_t bits = ctx->total << 3;
	uint8_t pad[64];
	unsigned int i;

	/* Padding: 0x80, then zeros up to 56 bytes used (a second block is
	 * appended when there is no room for the 8-byte length). */
	pad[0] = 0x80;
	for (i = 1; i < 64; i++)
		pad[i] = 0;
	if (ctx->used < 56) {
		sl_md5_update(ctx, pad, 56 - ctx->used);
	} else {
		sl_md5_update(ctx, pad, 64 - ctx->used);
		sl_md5_update(ctx, pad, 56);
	}

	/* total is captured before padding, so the shift is safe (inputs
	 * below 2 EiB). */
	for (i = 0; i < 8; i++)
		pad[i] = (uint8_t)(bits >> (8 * i));
	memcpy(ctx->buf + 56, pad, 8);
	sl_md5_block(ctx);
	ctx->used = 0;

	for (i = 0; i < 4; i++)
		put_le32(&out[i * 4], ctx->s[i]);
}

void sl_md5(const void *data, size_t len, uint8_t out[SL_MD5_LEN])
{
	struct sl_md5 ctx;

	sl_md5_init(&ctx);
	sl_md5_update(&ctx, data, len);
	sl_md5_final(&ctx, out);
}

void sl_hex(const uint8_t *in, size_t n, char *out)
{
	static const char digits[] = "0123456789abcdef";
	size_t i;

	for (i = 0; i < n; i++) {
		out[2 * i] = digits[in[i] >> 4];
		out[2 * i + 1] = digits[in[i] & 0x0f];
	}
	out[2 * n] = '\0';
}
