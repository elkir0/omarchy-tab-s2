/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Self-test for the sl_ hash primitives: known-answer vectors, split
 * updates at every byte boundary class, padding edges, and an optional
 * file mode whose output can be compared with shasum/md5/crc32.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sl_crc32.h"
#include "sl_md5.h"
#include "sl_sha256.h"

static int n_pass, n_fail;

static void check(const char *what, int ok)
{
	printf("%s %s\n", ok ? "PASS" : "FAIL", what);
	if (ok)
		n_pass++;
	else
		n_fail++;
}

static void check_hex(const char *what, const char *got, const char *want)
{
	char line[256];

	snprintf(line, sizeof(line), "%s = %s", what, got);
	check(line, strcmp(got, want) == 0);
}

/* Fixed xorshift32, seed chosen so the sequence is deterministic. */
static uint32_t xs(uint32_t *st)
{
	uint32_t x = *st;

	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	*st = x;
	return x;
}

#define NBUF 1000

static void fill_buf(uint8_t *b, size_t n)
{
	uint32_t st = 0x12345678;
	size_t i;

	for (i = 0; i < n; i++)
		b[i] = (uint8_t)(xs(&st) >> 24);
}

static void sha_hex(const void *d, size_t n, char *out)
{
	uint8_t raw[SL_SHA256_LEN];

	sl_sha256(d, n, raw);
	sl_hex(raw, SL_SHA256_LEN, out);
}

static void md5_hex(const void *d, size_t n, char *out)
{
	uint8_t raw[SL_MD5_LEN];

	sl_md5(d, n, raw);
	sl_hex(raw, SL_MD5_LEN, out);
}

static void test_crc32(void)
{
	static const uint8_t nine[] = "123456789";
	static uint8_t big[1000000];
	uint32_t c1, c2, oneshot;
	size_t i;

	memset(big, 'a', sizeof(big));

	check("crc32(\"\") == 0", sl_crc32_update(0, NULL, 0) == 0);
	check("crc32(\"123456789\") == 0xCBF43926",
	      sl_crc32_update(0, nine, sizeof(nine) - 1) == 0xCBF43926u);

	oneshot = sl_crc32_update(0, big, sizeof(big));
	c1 = 0;
	for (i = 0; i < sizeof(big); i++)
		c1 = sl_crc32_update(c1, &big[i], 1);
	/* Brief said 0xDC25BFBD, but zlib itself (and the polynomial) give
	 * 0xDC25BFBC; zlib compatibility is the binding requirement. */
	check("crc32(1000000 x 'a') == 0xDC25BFBC (one shot)",
	      oneshot == 0xDC25BFBCu);
	check("crc32(1000000 x 'a') byte at a time", c1 == oneshot);

	/* two halves chained == one shot */
	c1 = sl_crc32_update(0, big, sizeof(big) / 2);
	c1 = sl_crc32_update(c1, big + sizeof(big) / 2,
			     sizeof(big) - sizeof(big) / 2);
	c2 = sl_crc32_update(0, big, sizeof(big));
	check("crc32 chained halves", c1 == c2 && c2 == oneshot);
}

static void test_sha256(void)
{
	static const char abc[] = "abc";
	static const char nopq[] =
		"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
	static uint8_t big[1000000];
	char hex[2 * SL_SHA256_LEN + 1];

	memset(big, 'a', sizeof(big));

	sha_hex("", 0, hex);
	check_hex("sha256(\"\")", hex,
		  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
	sha_hex(abc, 3, hex);
	check_hex("sha256(\"abc\")", hex,
		  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
	sha_hex(nopq, sizeof(nopq) - 1, hex);
	check_hex("sha256(nopq)", hex,
		  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
	sha_hex(big, sizeof(big), hex);
	check_hex("sha256(1000000 x 'a')", hex,
		  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

static void test_md5(void)
{
	static const char abc[] = "abc";
	static const char dig[] = "message digest";
	static const char eights[] = "1234567890123456789012345678901234567890"
		"12345678901234567890123456789012345678901234567890";
	char hex[2 * SL_MD5_LEN + 1];

	md5_hex("", 0, hex);
	check_hex("md5(\"\")", hex, "d41d8cd98f00b204e9800998ecf8427e");
	md5_hex(abc, 3, hex);
	check_hex("md5(\"abc\")", hex, "900150983cd24fb0d6963f7d28e17f72");
	md5_hex(dig, sizeof(dig) - 1, hex);
	check_hex("md5(\"message digest\")", hex,
		  "f96b697d7cb7938d525a2f31aaf161d0");
	md5_hex(eights, 80, hex);
	check_hex("md5(80 digits)", hex, "57edf4a22be3c955ac49da2e2107b67a");
}

static void test_split(void)
{
	static const size_t chunks[] = { 1, 3, 63, 64, 65, 127 };
	static uint8_t buf[NBUF];
	uint8_t sha_ref[SL_SHA256_LEN], md5_ref[SL_MD5_LEN];
	char hex[2 * SL_SHA256_LEN + 1];
	char hex2[2 * SL_MD5_LEN + 1];
	uint32_t crc_oneshot;
	size_t ci, off;

	fill_buf(buf, sizeof(buf));

	sha_hex(buf, sizeof(buf), hex);
	sl_sha256(buf, sizeof(buf), sha_ref);
	md5_hex(buf, sizeof(buf), hex2);
	sl_md5(buf, sizeof(buf), md5_ref);
	crc_oneshot = sl_crc32_update(0, buf, sizeof(buf));

	for (ci = 0; ci < sizeof(chunks) / sizeof(chunks[0]); ci++) {
		size_t step = chunks[ci];
		struct sl_sha256 sc;
		struct sl_md5 mc;
		uint32_t crc = 0;
		uint8_t raw[SL_SHA256_LEN];
		uint8_t raw2[SL_MD5_LEN];
		char what[64];

		off = 0;
		sl_sha256_init(&sc);
		sl_md5_init(&mc);
		while (off < sizeof(buf)) {
			size_t n = sizeof(buf) - off;

			if (n > step)
				n = step;
			sl_sha256_update(&sc, buf + off, n);
			sl_md5_update(&mc, buf + off, n);
			crc = sl_crc32_update(crc, buf + off, n);
			off += n;
		}
		sl_sha256_final(&sc, raw);
		sl_md5_final(&mc, raw2);
		sl_hex(raw, SL_SHA256_LEN, hex);
		sl_hex(raw2, SL_MD5_LEN, hex2);

		snprintf(what, sizeof(what), "split step %zu: sha256", step);
		check(what, memcmp(raw, sha_ref, SL_SHA256_LEN) == 0);
		snprintf(what, sizeof(what), "split step %zu: md5", step);
		check(what, memcmp(raw2, md5_ref, SL_MD5_LEN) == 0);
		snprintf(what, sizeof(what), "split step %zu: crc32", step);
		check(what, crc == crc_oneshot);
	}
}

static void test_pad_edges(void)
{
	static const size_t lens[] = { 55, 56, 63, 64, 65, 119, 120 };
	static uint8_t buf[NBUF];
	unsigned int i;

	fill_buf(buf, sizeof(buf));

	for (i = 0; i < sizeof(lens) / sizeof(lens[0]); i++) {
		size_t n = lens[i];
		uint8_t r1[SL_SHA256_LEN], r2[SL_SHA256_LEN];
		uint8_t m1[SL_MD5_LEN], m2[SL_MD5_LEN];
		struct sl_sha256 sc;
		struct sl_md5 mc;
		char what[64];

		sl_sha256(buf, n, r1);
		sl_sha256_init(&sc);
		{
			size_t k;

			for (k = 0; k < n; k++)
				sl_sha256_update(&sc, buf + k, 1);
		}
		sl_sha256_final(&sc, r2);

		sl_md5(buf, n, m1);
		sl_md5_init(&mc);
		{
			size_t k;

			for (k = 0; k < n; k++)
				sl_md5_update(&mc, buf + k, 1);
		}
		sl_md5_final(&mc, m2);

		snprintf(what, sizeof(what), "pad edge len %zu", n);
		check(what, memcmp(r1, r2, SL_SHA256_LEN) == 0 &&
			    memcmp(m1, m2, SL_MD5_LEN) == 0);
	}
}

static int hash_file(const char *path)
{
	FILE *f = fopen(path, "rb");
	struct sl_sha256 sc;
	struct sl_md5 mc;
	uint32_t crc = 0;
	uint8_t buf[8192];
	uint8_t rs[SL_SHA256_LEN], rm[SL_MD5_LEN];
	char hs[2 * SL_SHA256_LEN + 1], hm[2 * SL_MD5_LEN + 1];
	size_t n;

	if (!f) {
		fprintf(stderr, "test_hashes: %s: cannot open\n", path);
		return 1;
	}

	sl_sha256_init(&sc);
	sl_md5_init(&mc);
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
		sl_sha256_update(&sc, buf, n);
		sl_md5_update(&mc, buf, n);
		crc = sl_crc32_update(crc, buf, n);
	}
	fclose(f);

	sl_sha256_final(&sc, rs);
	sl_md5_final(&mc, rm);
	sl_hex(rs, SL_SHA256_LEN, hs);
	sl_hex(rm, SL_MD5_LEN, hm);
	printf("%s  %s  %08x  %s\n", hs, hm, crc, path);
	return 0;
}

int main(int argc, char **argv)
{
	int i;

	if (argc > 1) {
		int rc = 0;

		for (i = 1; i < argc; i++)
			if (hash_file(argv[i]))
				rc = 1;
		return rc;
	}

	test_crc32();
	test_sha256();
	test_md5();
	test_split();
	test_pad_edges();

	printf("%d passed, %d failed\n", n_pass, n_fail);
	return n_fail ? 1 : 0;
}
