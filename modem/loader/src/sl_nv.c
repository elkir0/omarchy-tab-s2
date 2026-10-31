// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: NV snapshot policy (LS2 8, SYNTHESIS 2.13 and D4).
 *
 * Hard rules implemented here:
 *  - NV, its .md5 and the manifest are opened through ops->ro_open() only,
 *    i.e. O_RDONLY | O_NOFOLLOW | O_CLOEXEC. Nothing in this program can
 *    produce, shorten, extend, rename or modify an NV or EFS file.
 *  - the NV source is a regular file whose size equals the TOC NV size;
 *    missing, short, long, all-0xFF and all-0x00 files are refused;
 *  - the whole file is read into memory before the CP is powered, hashed,
 *    and stage 3 streams that buffer (what was checked is what is sent);
 *  - Mode A (default): SHA-256 must match the manifest written at
 *    provisioning time (sha256sum format);
 *  - Mode B: the file must live on a filesystem mounted read-only;
 *  - MD5 check of nv_data.bin.md5 is advisory by default: the log says
 *    whether it matches MD5(nv) or MD5(nv || "Samsung_Android_RIL").
 * The log never contains NV bytes, only sizes and hashes.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sl_loader.h"
#include "sl_log.h"
#include "sl_md5.h"
#include "sl_sha256.h"

#define SL_MANIFEST_MAX	(64u * 1024u)
#define SL_MD5_FILE_MAX	256u

static const char RIL_SALT[] = "Samsung_Android_RIL";

static const char *base_name(const char *p)
{
	const char *s = strrchr(p, '/');

	return s ? s + 1 : p;
}

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static int parse_hex(const char *s, size_t nhex, uint8_t *out)
{
	size_t i;

	for (i = 0; i < nhex; i += 2) {
		int hi = hexval((unsigned char)s[i]);
		int lo = hexval((unsigned char)s[i + 1]);

		if (hi < 0 || lo < 0)
			return -1;
		out[i / 2] = (uint8_t)((hi << 4) | lo);
	}
	return 0;
}

static int is_space(char c)
{
	return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

/*
 * .md5 file: exactly 32 hex digits, optionally followed by whitespace and,
 * md5sum-style, a file name. Returns 0 or -1 (malformed).
 */
int sl_nv_parse_md5_text(const char *buf, size_t len, uint8_t out[16])
{
	size_t i;

	if (len < 32)
		return -1;
	if (parse_hex(buf, 32, out) != 0)
		return -1;
	if (len == 32)
		return 0;
	if (!is_space(buf[32]))
		return -1;
	for (i = 33; i < len; i++) {
		if (buf[i] == '\0')
			return -1;
	}
	return 0;
}

/*
 * Manifest in sha256sum(1) format: "<64 hex><space><space|*><name>\n".
 * Blank lines and lines starting with '#' are ignored; any other line must
 * be well formed. Names are compared by basename. Returns 1 and the digest
 * when `name` is listed exactly once, 0 when it is absent, -1 when the
 * manifest is malformed or lists the name twice.
 */
int sl_manifest_lookup(const char *text, size_t len, const char *name,
		       uint8_t out[32])
{
	const char *want = base_name(name);
	size_t pos = 0;
	int found = 0;

	while (pos < len) {
		const char *line = text + pos;
		const char *nl = memchr(line, '\n', len - pos);
		size_t ll = nl ? (size_t)(nl - line) : len - pos;
		uint8_t digest[32];
		char fname[256];
		size_t fl;

		pos += ll + (nl ? 1 : 0);
		if (ll > 0 && line[ll - 1] == '\r')
			ll--;
		if (ll == 0 || line[0] == '#')
			continue;
		if (memchr(line, '\0', ll))
			return -1;
		if (ll < 64 + 2 + 1 || line[64] != ' ' ||
		    (line[65] != ' ' && line[65] != '*'))
			return -1;
		if (parse_hex(line, 64, digest) != 0)
			return -1;
		fl = ll - 66;
		if (fl >= sizeof(fname) || line[66] == '\\')
			return -1;
		memcpy(fname, line + 66, fl);
		fname[fl] = '\0';
		if (strcmp(base_name(fname), want) != 0)
			continue;
		if (found)
			return -1;	/* ambiguous */
		memcpy(out, digest, 32);
		found = 1;
	}
	return found;
}

/* Read a small regular file entirely (read-only, no symlink). */
static int read_small(struct sl_loader *L, const char *path, char *buf,
		      size_t max, size_t *outlen)
{
	const struct sl_ops *o = L->ops;
	struct sl_stat st;
	size_t got = 0;
	int fd, rc;

	fd = o->ro_open(o->ctx, path, 1);
	if (fd < 0)
		return fd;
	rc = o->ro_fstat(o->ctx, fd, &st);
	if (rc < 0)
		goto out;
	if (st.type != SL_FT_REG) {
		rc = -EINVAL;
		goto out;
	}
	if (st.size > max) {
		rc = -EFBIG;
		goto out;
	}
	while (got < st.size) {
		long n = o->ro_pread(o->ctx, fd, buf + got, (size_t)st.size - got, got);

		if (n < 0) {
			rc = (int)n;
			goto out;
		}
		if (n == 0)
			break;
		got += (size_t)n;
	}
	*outlen = got;
	rc = 0;
out:
	o->close_fd(o->ctx, fd);
	return rc;
}

static int all_bytes(const uint8_t *p, size_t n, uint8_t v)
{
	size_t i;

	for (i = 0; i < n; i++) {
		if (p[i] != v)
			return 0;
	}
	return 1;
}

static int load_nv_file(struct sl_loader *L, const char *path, size_t want)
{
	const struct sl_ops *o = L->ops;
	struct sl_stat st;
	uint8_t extra;
	size_t got = 0;
	long n;
	int fd, rc;

	fd = o->ro_open(o->ctx, path, 1);
	if (fd == -ENOENT) {
		sl_err("NV: %s is missing: refusing to boot (the loader never makes an NV file)",
		       path);
		return SL_EXIT_NV;
	}
	if (fd == -ELOOP) {
		sl_err("NV: %s is a symbolic link: refused", path);
		return SL_EXIT_NV;
	}
	if (fd < 0) {
		sl_err("NV: cannot open %s read-only: %s", path, strerror(-fd));
		return SL_EXIT_NV;
	}
	rc = o->ro_fstat(o->ctx, fd, &st);
	if (rc < 0) {
		sl_err("NV: fstat %s: %s", path, strerror(-rc));
		rc = SL_EXIT_NV;
		goto out;
	}
	if (st.type != SL_FT_REG) {
		sl_err("NV: %s is not a regular file: refused", path);
		rc = SL_EXIT_NV;
		goto out;
	}
	if (st.size != want) {
		sl_err("NV: %s is %llu bytes, TOC NV size is %zu: refused (no padding, no truncation)",
		       path, (unsigned long long)st.size, want);
		rc = SL_EXIT_NV;
		goto out;
	}

	L->nv_buf = sl_buf_alloc(want, &L->nv_alloc);
	if (!L->nv_buf) {
		rc = SL_EXIT_INTERNAL;
		goto out;
	}
	while (got < want) {
		n = o->ro_pread(o->ctx, fd, L->nv_buf + got, want - got, got);
		if (n < 0) {
			sl_err("NV: read %s: %s", path, strerror((int)-n));
			rc = SL_EXIT_NV;
			goto out;
		}
		if (n == 0)
			break;
		got += (size_t)n;
	}
	if (got != want) {
		sl_err("NV: short read on %s (%zu of %zu bytes): refused", path, got, want);
		rc = SL_EXIT_NV;
		goto out;
	}
	n = o->ro_pread(o->ctx, fd, &extra, 1, want);
	if (n != 0) {
		sl_err("NV: %s changed size while being read: refused", path);
		rc = SL_EXIT_NV;
		goto out;
	}
	L->nv_size = want;

	if (L->cfg->nv_mode == SL_NV_MODE_DIRECT) {
		int ro = o->ro_fs_readonly(o->ctx, fd);

		if (ro != 1) {
			sl_err("NV mode direct: the filesystem holding %s is %s: refused",
			       path, ro == 0 ? "mounted read-write" : "of unknown mount state");
			rc = SL_EXIT_NV;
			goto out;
		}
		sl_info("NV mode direct: %s is on a read-only filesystem", path);
	}
	rc = 0;
out:
	o->close_fd(o->ctx, fd);
	return rc;
}

static int check_manifest(struct sl_loader *L, const char *manifest,
			  const char *nv_path, const char *md5_path,
			  int *md5_listed, uint8_t md5_file_sha[32])
{
	char *text;
	size_t len = 0;
	uint8_t want[32];
	char hex[65];
	int rc;

	text = malloc(SL_MANIFEST_MAX);
	if (!text)
		return SL_EXIT_INTERNAL;
	rc = read_small(L, manifest, text, SL_MANIFEST_MAX, &len);
	if (rc == -ENOENT) {
		sl_err("NV: manifest %s is missing: refused (provision the copy first)", manifest);
		rc = SL_EXIT_NV;
		goto out;
	}
	if (rc < 0) {
		sl_err("NV: cannot read manifest %s: %s", manifest, strerror(-rc));
		rc = SL_EXIT_NV;
		goto out;
	}
	rc = sl_manifest_lookup(text, len, nv_path, want);
	if (rc < 0) {
		sl_err("NV: manifest %s is malformed or ambiguous: refused", manifest);
		rc = SL_EXIT_NV;
		goto out;
	}
	if (rc == 0) {
		sl_err("NV: manifest %s has no entry for %s: refused", manifest,
		       base_name(nv_path));
		rc = SL_EXIT_NV;
		goto out;
	}
	if (memcmp(want, L->nv_sha256, 32) != 0) {
		sl_hex(want, 32, hex);
		sl_err("NV: SHA-256 mismatch with manifest (manifest %s): refused", hex);
		rc = SL_EXIT_NV;
		goto out;
	}
	sl_info("NV: SHA-256 matches manifest %s", manifest);

	*md5_listed = 0;
	if (md5_path) {
		rc = sl_manifest_lookup(text, len, md5_path, md5_file_sha);
		if (rc < 0) {
			sl_err("NV: manifest lists %s twice: refused", base_name(md5_path));
			rc = SL_EXIT_NV;
			goto out;
		}
		*md5_listed = rc;
	}
	rc = 0;
out:
	free(text);
	return rc;
}

static int check_md5(struct sl_loader *L, const char *md5_path, int listed,
		     const uint8_t listed_sha[32])
{
	enum sl_md5_policy pol = L->cfg->md5_policy;
	char buf[SL_MD5_FILE_MAX];
	uint8_t stored[16], plain[16], salted[16], sha[32];
	struct sl_md5 m;
	size_t len = 0;
	int rc;

	if (pol == SL_MD5_OFF) {
		sl_info("NV: MD5 check disabled (--nv-md5=off)");
		return 0;
	}
	rc = read_small(L, md5_path, buf, sizeof(buf), &len);
	if (rc < 0) {
		if (pol == SL_MD5_REQUIRE) {
			sl_err("NV: %s unreadable (%s) and --nv-md5=require: refused",
			       md5_path, strerror(-rc));
			return SL_EXIT_NV;
		}
		sl_info("NV: md5 file %s: %s (advisory check skipped)", md5_path,
			rc == -ENOENT ? "absent" : strerror(-rc));
		return 0;
	}
	if (listed) {
		sl_sha256(buf, len, sha);
		if (memcmp(sha, listed_sha, 32) != 0) {
			if (pol == SL_MD5_REQUIRE) {
				sl_err("NV: %s does not match its manifest entry: refused", md5_path);
				return SL_EXIT_NV;
			}
			sl_warn("NV: %s does not match its manifest entry: ignored", md5_path);
			return 0;
		}
	}
	if (sl_nv_parse_md5_text(buf, len, stored) != 0) {
		if (pol == SL_MD5_REQUIRE) {
			sl_err("NV: %s is not 32 hex digits: refused", md5_path);
			return SL_EXIT_NV;
		}
		sl_warn("NV: %s is not 32 hex digits: ignored", md5_path);
		return 0;
	}

	sl_md5(L->nv_buf, L->nv_size, plain);
	sl_md5_init(&m);
	sl_md5_update(&m, L->nv_buf, L->nv_size);
	sl_md5_update(&m, RIL_SALT, sizeof(RIL_SALT) - 1);
	sl_md5_final(&m, salted);

	if (memcmp(stored, plain, 16) == 0) {
		sl_info("NV: md5 file matches MD5(nv) (unsalted)");
		return 0;
	}
	if (memcmp(stored, salted, 16) == 0) {
		sl_info("NV: md5 file matches MD5(nv || \"%s\") (RIL salt)", RIL_SALT);
		return 0;
	}
	if (pol == SL_MD5_REQUIRE) {
		sl_err("NV: md5 file matches neither MD5(nv) nor the salted form: refused");
		return SL_EXIT_NV;
	}
	sl_warn("NV: md5 file matches neither MD5(nv) nor the salted form (advisory only)");
	return 0;
}

int sl_nv_load(struct sl_loader *L)
{
	const struct sl_config *c = L->cfg;
	size_t want = L->toc.e[SL_SLOT_NV].size;
	char md5_default[300];
	const char *md5_path = c->nv_md5;
	uint8_t md5_sha[32];
	int md5_listed = 0;
	char hex[65];
	int rc;

	if (!md5_path) {
		if ((size_t)snprintf(md5_default, sizeof(md5_default), "%s.md5",
				     c->nv_path) >= sizeof(md5_default))
			return SL_EXIT_CONFIG;
		md5_path = md5_default;
	}

	sl_info("NV: mode %s, source %s, expected size %zu bytes",
		c->nv_mode == SL_NV_MODE_COPY ? "copy (A)" : "direct (B)",
		c->nv_path, want);

	rc = load_nv_file(L, c->nv_path, want);
	if (rc)
		return rc;

	if (all_bytes(L->nv_buf, L->nv_size, 0xFF) ||
	    all_bytes(L->nv_buf, L->nv_size, 0x00)) {
		const char *what = L->nv_buf[0] == 0xFF ? "0xFF" : "0x00";

		if (!c->allow_blank_nv) {
			sl_err("NV: every byte is %s (blank NV): refused (use --allow-blank-nv only on purpose)",
			       what);
			return SL_EXIT_NV;
		}
		sl_warn("NV: WARNING: every byte is %s (blank NV) and --allow-blank-nv was given: "
			"the CP will boot with a blank NV", what);
	}

	sl_sha256(L->nv_buf, L->nv_size, L->nv_sha256);
	sl_hex(L->nv_sha256, 32, hex);
	sl_info("NV: snapshot %zu bytes in memory, SHA-256 %s", L->nv_size, hex);

	if (c->nv_manifest) {
		rc = check_manifest(L, c->nv_manifest, c->nv_path, md5_path,
				    &md5_listed, md5_sha);
		if (rc)
			return rc;
	} else if (c->nv_mode == SL_NV_MODE_COPY) {
		sl_err("NV mode copy requires a manifest");
		return SL_EXIT_CONFIG;
	}

	rc = check_md5(L, md5_path, md5_listed, md5_sha);
	if (rc == 0)
		sl_buf_seal(L->nv_buf, L->nv_alloc);	/* read-only from here on */
	return rc;
}
