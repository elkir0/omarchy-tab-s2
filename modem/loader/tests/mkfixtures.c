// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * mkfixtures: writes the synthetic NV / manifest / image fixtures used by
 * the tests into a scratch directory (outside the repository), then the
 * test runner makes that tree read-only. All contents are PRNG patterns.
 *
 *   mkfixtures DIR               create DIR/real, DIR/small/<case>, DIR/bin
 *   mkfixtures --print-boot-sha256
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "fixtures.h"
#include "sl_md5.h"
#include "sl_sha256.h"

static const char *root;

static void die(const char *what, const char *path)
{
	fprintf(stderr, "mkfixtures: %s %s: %s\n", what, path, strerror(errno));
	exit(1);
}

static void mkdirs(const char *rel)
{
	char p[1024];

	snprintf(p, sizeof(p), "%s/%s", root, rel);
	if (mkdir(p, 0755) != 0 && errno != EEXIST)
		die("mkdir", p);
}

static void put_file(const char *rel, const void *data, size_t len)
{
	char p[1024];
	FILE *f;

	snprintf(p, sizeof(p), "%s/%s", root, rel);
	f = fopen(p, "wb");
	if (!f)
		die("fopen", p);
	if (len && fwrite(data, 1, len, f) != len)
		die("fwrite", p);
	if (fclose(f) != 0)
		die("fclose", p);
}

static void put_text(const char *rel, const char *text)
{
	put_file(rel, text, strlen(text));
}

static void sha_hex(const void *d, size_t n, char out[65])
{
	uint8_t h[32];

	sl_sha256(d, n, h);
	sl_hex(h, 32, out);
}

static void md5_hex(const void *d, size_t n, int salted, char out[33])
{
	static const char salt[] = "Samsung_Android_RIL";
	struct sl_md5 c;
	uint8_t h[16];

	sl_md5_init(&c);
	sl_md5_update(&c, d, n);
	if (salted)
		sl_md5_update(&c, salt, sizeof(salt) - 1);
	sl_md5_final(&c, h);
	sl_hex(h, 16, out);
}

/* one NV case directory */
static void nv_case(const char *dir, const uint8_t *nv, size_t nvlen,
		    const char *md5_text, const char *manifest)
{
	char rel[512];

	mkdirs(dir);
	if (nv) {
		snprintf(rel, sizeof(rel), "%s/nv_data.bin", dir);
		put_file(rel, nv, nvlen);
	}
	if (md5_text) {
		snprintf(rel, sizeof(rel), "%s/nv_data.bin.md5", dir);
		put_text(rel, md5_text);
	}
	if (manifest) {
		snprintf(rel, sizeof(rel), "%s/manifest.sha256", dir);
		put_text(rel, manifest);
	}
}

static void manifest2(char *out, size_t n, const void *nv, size_t nvlen,
		      const char *md5_text)
{
	char a[65], b[65];

	sha_hex(nv, nvlen, a);
	if (md5_text) {
		sha_hex(md5_text, strlen(md5_text), b);
		snprintf(out, n, "%s  nv_data.bin\n%s  nv_data.bin.md5\n", a, b);
	} else {
		snprintf(out, n, "%s  nv_data.bin\n", a);
	}
}

static void small_cases(uint32_t nvsize)
{
	uint8_t *nv = malloc(nvsize + 1), *alt = malloc(nvsize + 1);
	char md5p[40], md5s[40], man[1024], hex[65], hex2[65], rel[512];

	if (!nv || !alt)
		exit(1);
	nv_pattern(nv, nvsize + 1, 1);
	md5_hex(nv, nvsize, 0, md5p);
	strcat(md5p, "\n");
	md5_hex(nv, nvsize, 1, md5s);
	strcat(md5s, "\n");
	mkdirs("small");

	manifest2(man, sizeof(man), nv, nvsize, md5p);
	nv_case("small/ok", nv, nvsize, md5p, man);

	manifest2(man, sizeof(man), nv, nvsize, md5s);
	nv_case("small/salted", nv, nvsize, md5s, man);

	manifest2(man, sizeof(man), nv, nvsize, "00112233445566778899aabbccddeeff\n");
	nv_case("small/md5_none", nv, nvsize, "00112233445566778899aabbccddeeff\n", man);

	manifest2(man, sizeof(man), nv, nvsize, NULL);
	nv_case("small/md5_absent", nv, nvsize, NULL, man);

	manifest2(man, sizeof(man), nv, nvsize, "not-a-md5-digest\n");
	nv_case("small/md5_malformed", nv, nvsize, "not-a-md5-digest\n", man);

	/* manifest says the .md5 has other content than it has */
	manifest2(man, sizeof(man), nv, nvsize, md5s);
	nv_case("small/md5_tampered", nv, nvsize, md5p, man);

	manifest2(man, sizeof(man), nv, nvsize, md5p);
	nv_case("small/missing", NULL, 0, md5p, man);

	manifest2(man, sizeof(man), nv, nvsize - 1, NULL);
	nv_case("small/short", nv, nvsize - 1, NULL, man);

	manifest2(man, sizeof(man), nv, nvsize + 1, NULL);
	nv_case("small/long", nv, nvsize + 1, NULL, man);

	memset(alt, 0xFF, nvsize);
	manifest2(man, sizeof(man), alt, nvsize, NULL);
	nv_case("small/ff", alt, nvsize, NULL, man);

	memset(alt, 0x00, nvsize);
	manifest2(man, sizeof(man), alt, nvsize, NULL);
	nv_case("small/zero", alt, nvsize, NULL, man);

	nv_pattern(alt, nvsize, 99);
	manifest2(man, sizeof(man), alt, nvsize, NULL);
	nv_case("small/shabad", nv, nvsize, NULL, man);

	nv_case("small/nomanifest", nv, nvsize, md5p, NULL);

	sha_hex(nv, nvsize, hex);
	snprintf(man, sizeof(man), "%s  other.bin\n", hex);
	nv_case("small/noentry", nv, nvsize, NULL, man);

	snprintf(man, sizeof(man), "%s  nv_data.bin\n%s  nv_data.bin\n", hex, hex);
	nv_case("small/dup", nv, nvsize, NULL, man);

	/* sha256sum -b style, comments, CRLF, upper-case hex */
	{
		size_t i;

		snprintf(hex2, sizeof(hex2), "%s", hex);
		for (i = 0; i < 64; i++)
			if (hex2[i] >= 'a' && hex2[i] <= 'f')
				hex2[i] = (char)(hex2[i] - 'a' + 'A');
		snprintf(man, sizeof(man), "# provisioned offline\r\n\r\n%s *nv_data.bin\r\n", hex2);
		nv_case("small/star", nv, nvsize, md5p, man);
	}

	snprintf(man, sizeof(man), "%s  /var/lib/shannon/nv/nv_data.bin\n", hex);
	nv_case("small/abspath", nv, nvsize, NULL, man);

	snprintf(man, sizeof(man), "%s nv_data.bin\n", hex);	/* one space only */
	nv_case("small/malformed", nv, nvsize, NULL, man);

	manifest2(man, sizeof(man), nv, nvsize, NULL);
	nv_case("small/symlink", NULL, 0, NULL, man);
	snprintf(rel, sizeof(rel), "%s/small/symlink/nv_data.bin", root);
	if (symlink("../ok/nv_data.bin", rel) != 0 && errno != EEXIST)
		die("symlink", rel);

	nv_case("small/dir", NULL, 0, NULL, man);
	mkdirs("small/dir/nv_data.bin");

	free(nv);
	free(alt);
}

static void real_case(void)
{
	const size_t n = 0x100000;
	uint8_t *nv = malloc(n);
	char md5s[40], man[1024];

	if (!nv)
		exit(1);
	nv_pattern(nv, n, 7);
	md5_hex(nv, n, 1, md5s);
	strcat(md5s, "\n");
	manifest2(man, sizeof(man), nv, n, md5s);
	nv_case("real", nv, n, md5s, man);
	free(nv);
}

static void bin_case(void)
{
	struct img_spec s;
	struct img im;

	mkdirs("bin");
	img_spec_small(&s);
	if (img_build(&s, &im) != 0)
		exit(1);
	put_file("bin/radio.img", im.data, im.len);
	im.data[im.boot_off + 5] ^= 0x01;	/* BOOT no longer matches its CRC */
	put_file("bin/radio_badboot.img", im.data, im.len);
	img_free(&im);
	put_text("bin/lli_control", "MIPI-LLI 0\n");
	put_text("bin/cp_status", "0\n");
	put_text("bin/capacity", "80\n");
	put_text("bin/capacity_low", "4\n");
	put_text("bin/temp", "301\n");
	put_text("bin/current_now", "-120000\n");
	put_text("bin/allow_hw", "Y\n");
}

int main(int argc, char **argv)
{
	if (argc == 2 && strcmp(argv[1], "--print-boot-sha256") == 0) {
		struct img_spec s;
		struct img im;
		char hex[65];

		img_spec_small(&s);
		if (img_build(&s, &im) != 0)
			return 1;
		sha_hex(im.data + im.boot_off, im.boot_size, hex);
		printf("%s\n", hex);
		img_free(&im);
		return 0;
	}
	if (argc != 2) {
		fprintf(stderr, "usage: mkfixtures DIR | --print-boot-sha256\n");
		return 2;
	}
	root = argv[1];
	if (mkdir(root, 0755) != 0 && errno != EEXIST)
		die("mkdir", root);
	real_case();
	small_cases(0x1800);
	bin_case();
	return 0;
}
