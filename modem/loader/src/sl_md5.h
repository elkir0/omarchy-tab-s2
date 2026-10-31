/* SPDX-License-Identifier: GPL-2.0-or-later */
/* MD5 (RFC 1321), incremental API, plus a shared hex helper. */

#ifndef SL_MD5_H
#define SL_MD5_H

#include <stddef.h>
#include <stdint.h>

#define SL_MD5_LEN 16

struct sl_md5 {
	uint32_t s[4];
	uint64_t total;		/* message length in bytes */
	uint8_t buf[64];	/* partial block */
	size_t used;		/* bytes occupied in buf */
};

void sl_md5_init(struct sl_md5 *c);
void sl_md5_update(struct sl_md5 *c, const void *data, size_t len);
void sl_md5_final(struct sl_md5 *c, uint8_t out[SL_MD5_LEN]);
void sl_md5(const void *data, size_t len, uint8_t out[SL_MD5_LEN]);

/* writes 2*n lowercase hex chars plus a NUL into out (size >= 2*n+1) */
void sl_hex(const uint8_t *in, size_t n, char *out);

#endif /* SL_MD5_H */
