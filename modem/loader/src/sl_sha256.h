/* SPDX-License-Identifier: GPL-2.0-or-later */
/* SHA-256 (FIPS 180-4), incremental API. */

#ifndef SL_SHA256_H
#define SL_SHA256_H

#include <stddef.h>
#include <stdint.h>

#define SL_SHA256_LEN 32

struct sl_sha256 {
	uint32_t h[8];
	uint64_t total;		/* message length in bytes */
	uint8_t buf[64];	/* partial block */
	size_t used;		/* bytes occupied in buf */
};

void sl_sha256_init(struct sl_sha256 *c);
void sl_sha256_update(struct sl_sha256 *c, const void *data, size_t len);
void sl_sha256_final(struct sl_sha256 *c, uint8_t out[SL_SHA256_LEN]);
void sl_sha256(const void *data, size_t len, uint8_t out[SL_SHA256_LEN]);

#endif /* SL_SHA256_H */
