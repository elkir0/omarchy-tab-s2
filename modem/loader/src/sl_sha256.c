/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * SHA-256 per FIPS 180-4.  All loads and stores are byte-wise, so no
 * alignment or endianness assumptions are made.
 */

#include <string.h>

#include "sl_sha256.h"

/* First 32 bits of the fractional parts of the square roots of the first
 * 8 primes. */
static const uint32_t sl_sha256_h0[8] = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

/* First 32 bits of the fractional parts of the cube roots of the first
 * 64 primes. */
static const uint32_t sl_sha256_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static uint32_t get_be32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
	       ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void put_be32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

/* Compress the full 64-byte block held in ctx->buf. */
static void sl_sha256_block(struct sl_sha256 *ctx)
{
	uint32_t w[64];
	uint32_t a, b, c, d, e, f, g, h;
	unsigned int i;

	for (i = 0; i < 16; i++)
		w[i] = get_be32(&ctx->buf[i * 4]);
	for (; i < 64; i++) {
		uint32_t s0 = w[i - 15];
		uint32_t s1 = w[i - 2];

		s0 = (s0 >> 7 | s0 << 25) ^ (s0 >> 18 | s0 << 14) ^ (s0 >> 3);
		s1 = (s1 >> 17 | s1 << 15) ^ (s1 >> 19 | s1 << 13) ^ (s1 >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}

	a = ctx->h[0];
	b = ctx->h[1];
	c = ctx->h[2];
	d = ctx->h[3];
	e = ctx->h[4];
	f = ctx->h[5];
	g = ctx->h[6];
	h = ctx->h[7];

	for (i = 0; i < 64; i++) {
		uint32_t s1 = e >> 6 | e << 26;
		uint32_t ch = (e & f) ^ (~e & g);
		uint32_t s0 = a >> 2 | a << 30;
		uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t1, t2;

		s1 ^= e >> 11 | e << 21;
		s1 ^= e >> 25 | e << 7;
		s0 ^= a >> 13 | a << 19;
		s0 ^= a >> 22 | a << 10;
		t1 = h + s1 + ch + sl_sha256_k[i] + w[i];
		t2 = s0 + maj;

		h = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
	}

	ctx->h[0] += a;
	ctx->h[1] += b;
	ctx->h[2] += c;
	ctx->h[3] += d;
	ctx->h[4] += e;
	ctx->h[5] += f;
	ctx->h[6] += g;
	ctx->h[7] += h;
}

void sl_sha256_init(struct sl_sha256 *ctx)
{
	unsigned int i;

	for (i = 0; i < 8; i++)
		ctx->h[i] = sl_sha256_h0[i];
	ctx->total = 0;
	ctx->used = 0;
}

void sl_sha256_update(struct sl_sha256 *ctx, const void *data, size_t len)
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
			sl_sha256_block(ctx);
			ctx->used = 0;
		}
	}
}

void sl_sha256_final(struct sl_sha256 *ctx, uint8_t out[SL_SHA256_LEN])
{
	uint64_t bits = ctx->total << 3;
	uint8_t tail[8];
	unsigned int i;

	/* total < 2^61 for any realistic input, so the shift is safe. */
	tail[0] = 0x80;
	for (i = 1; i < 8; i++)
		tail[i] = 0;
	sl_sha256_update(ctx, tail, 1);
	while (ctx->used != 56)
		sl_sha256_update(ctx, tail + 1, 1);

	for (i = 0; i < 8; i++)
		tail[i] = (uint8_t)(bits >> (56 - 8 * i));
	memcpy(ctx->buf + 56, tail, 8);
	ctx->used = 64;
	sl_sha256_block(ctx);

	for (i = 0; i < 8; i++)
		put_be32(&out[i * 4], ctx->h[i]);
}

void sl_sha256(const void *data, size_t len, uint8_t out[SL_SHA256_LEN])
{
	struct sl_sha256 ctx;

	sl_sha256_init(&ctx);
	sl_sha256_update(&ctx, data, len);
	sl_sha256_final(&ctx, out);
}
