// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader level-1 tests (LS2 10.1-10.5): golden transcript on the
 * stock geometry, synthetic images, --stop-after ladder, fault matrix, NV
 * policy, supervisor, eFuse window, power gate, and the tripwires.
 *
 *   test_loader FIXTURE_DIR [filter]
 * FIXTURE_DIR comes from mkfixtures (read-only tree). The whole binary runs
 * under the nv_guard.so LD_PRELOAD interposer in `make test`.
 * Env: SL_TEST_VERBOSE=1 prints the loader log; SL_REAL_RADIO=<radio.img>
 * adds a run against the real RADIO image (read in place, never copied).
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include "fixtures.h"
#include "mock.h"
#include "sl_crc32.h"
#include "sl_loader.h"
#include "sl_log.h"
#include "sl_md5.h"
#include "sl_sha256.h"

/* forbidden requests: named in the tests only */
#define TRIP_DUMP_START		0x6F32u
#define TRIP_FORCE_CRASH_EXIT	0x6F34u
#define TRIP_CP_UPLOAD		0x6F35u
#define TRIP_DUMP_RESET		0x6F36u

#define P_BOOT	"/dev/umts_boot0"
#define P_IPC	"/dev/umts_ipc0"
#define P_RFS	"/dev/umts_rfs0"
#define P_LLI	"/sys/bus/platform/devices/10f24000.mipi-lli/lli_control"
#define P_CPS	"/sys/bus/platform/drivers/mif_sipc5/mif_pdata/cp_status/value"
#define P_CAP	"/sys/class/power_supply/sm5703-fuelgauge/capacity"
#define P_TEMP	"/sys/class/power_supply/sm5703-fuelgauge/temp"
#define P_CUR	"/sys/class/power_supply/sm5703-fuelgauge/current_now"
#define P_AHW	"/sys/module/sec_modem_v1/parameters/allow_hw"
#define P_IMG	"/virt/RADIO"
#define P_STATE	"/run/shannon/cp-state"

static const char *g_fix;
static const char *g_filter;
static int g_case_fail, g_cases, g_failed_cases, g_verbose;
static char *g_log;
static size_t g_loglen, g_logcap;

#define CHECK(c, ...) do { \
	if (!(c)) { \
		g_case_fail++; \
		fprintf(stderr, "    FAIL %s:%d: ", __FILE__, __LINE__); \
		fprintf(stderr, __VA_ARGS__); \
		fputc('\n', stderr); \
	} \
} while (0)

static void sink(void *ctx, int level, const char *line)
{
	size_t n = strlen(line);

	(void)ctx;
	(void)level;
	if (g_loglen + n + 2 > g_logcap) {
		size_t cap = (g_logcap + n + 2) * 2;
		char *p = realloc(g_log, cap);

		if (!p)
			abort();
		g_log = p;
		g_logcap = cap;
	}
	memcpy(g_log + g_loglen, line, n);
	g_loglen += n;
	g_log[g_loglen++] = '\n';
	g_log[g_loglen] = '\0';
}

static int log_has(const char *s)
{
	return g_log && strstr(g_log, s) != NULL;
}

static int log_count(const char *s)
{
	int n = 0;
	const char *p = g_log;

	while (p && (p = strstr(p, s)) != NULL) {
		n++;
		p += strlen(s);
	}
	return n;
}

/* ------------------------------------------------------------------ */
/* environment                                                          */
/* ------------------------------------------------------------------ */

enum geo { GEO_REAL, GEO_SMALL };

struct env {
	struct img im;
	uint8_t *nv;
	size_t nvlen;
	struct mock_cfg mc;
	struct mock m;
	struct sl_ops ops;
	struct sl_config cfg;
	struct sl_loader L;
	volatile sig_atomic_t stop;
	char nv_path[600], man_path[600];
	int production_pin;
	int rc;
};

static uint8_t *read_file(const char *path, size_t max, size_t *len)
{
	struct stat st;
	uint8_t *buf;
	size_t got = 0, want;
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	*len = 0;
	if (fd < 0)
		return NULL;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		close(fd);
		return NULL;
	}
	want = (size_t)st.st_size < max ? (size_t)st.st_size : max;
	buf = malloc(want ? want : 1);
	while (buf && got < want) {
		ssize_t n = read(fd, buf + got, want - got);

		if (n <= 0)
			break;
		got += (size_t)n;
	}
	close(fd);
	*len = got;
	return buf;
}

static int env_setup(struct env *e, enum geo g, const char *nvdir)
{
	struct img_spec s;

	memset(e, 0, sizeof(*e));
	if (g == GEO_REAL)
		img_spec_real(&s);
	else
		img_spec_small(&s);
	if (img_build(&s, &e->im) != 0)
		return -1;
	snprintf(e->nv_path, sizeof(e->nv_path), "%s/%s/nv_data.bin", g_fix, nvdir);
	snprintf(e->man_path, sizeof(e->man_path), "%s/%s/manifest.sha256", g_fix, nvdir);
	e->nv = read_file(e->nv_path, 64u << 20, &e->nvlen);

	e->mc.image_path = P_IMG;
	e->mc.image = e->im.data;
	e->mc.image_len = e->im.len;
	e->mc.image_size = e->im.size;
	e->mc.nv = e->nv;
	e->mc.nv_len = e->nvlen;
	e->mc.boot_path = P_BOOT;
	e->mc.ipc_path = P_IPC;
	e->mc.rfs_path = P_RFS;
	e->mc.lli_path = P_LLI;
	e->mc.cp_status_path = P_CPS;
	e->mc.cap_path = P_CAP;
	e->mc.temp_path = P_TEMP;
	e->mc.cur_path = P_CUR;
	e->mc.allow_hw_path = P_AHW;
	e->mc.bat_capacity = 80;
	e->mc.bat_temp = 300;
	e->mc.bat_current = -150000;
	e->mc.allow_hw_value = "Y";

	e->cfg.boot_dev = P_BOOT;
	e->cfg.ipc_dev = P_IPC;
	e->cfg.rfs_dev = P_RFS;
	e->cfg.image = P_IMG;
	e->cfg.nv_path = e->nv_path;
	e->cfg.nv_manifest = e->man_path;
	e->cfg.nv_mode = SL_NV_MODE_COPY;
	e->cfg.md5_policy = SL_MD5_WARN;
	e->cfg.max_attempts = 1;
	e->cfg.stop_after = SL_RUNG_NONE;
	e->cfg.bat_capacity = P_CAP;
	e->cfg.bat_temp = P_TEMP;
	e->cfg.bat_current = P_CUR;
	e->cfg.allow_hw = P_AHW;
	e->cfg.state_file = P_STATE;
	e->mc.state_path = P_STATE;
	return 0;
}

static uint64_t mock_clock(void *ctx)
{
	return ((struct mock *)ctx)->now_us;
}

static int env_run(struct env *e)
{
	struct sl_log_cfg lc;

	g_loglen = 0;
	if (g_log)
		g_log[0] = '\0';
	mock_init(&e->m, &e->mc, &e->stop);
	mock_get_ops(&e->m, &e->ops);
	sl_loader_init(&e->L, &e->cfg, &e->ops, &e->stop);
	if (!e->production_pin)
		sl_sha256(e->im.data + e->im.boot_off, e->im.boot_size, e->L.pin_boot_sha256);
	memset(&lc, 0, sizeof(lc));
	lc.clock = mock_clock;
	lc.clock_ctx = &e->m;
	lc.to_stderr = g_verbose;
	lc.kmsg_fd = -1;
	lc.max_level = SL_LOG_DEBUG;
	lc.sink = sink;
	sl_log_setup(&lc);
	e->rc = sl_config_check(&e->cfg);
	if (e->rc == 0)
		e->rc = sl_run(&e->L);
	sl_loader_free(&e->L);
	return e->rc;
}

static void env_free(struct env *e)
{
	mock_free(&e->m);
	img_free(&e->im);
	free(e->nv);
}

static void add_script(struct mock_cfg *c, int on_online, uint32_t delay_ms,
		       int type, int arg)
{
	struct mock_script *s = &c->script[c->nscript++];

	s->on_online = on_online;
	s->delay_ms = delay_ms;
	s->type = type;
	s->arg = arg;
}

static void expect_clean(struct env *e)
{
	int i;

	CHECK(e->m.tripwire == 0, "tripwire fired %d times", e->m.tripwire);
	CHECK(e->m.nviol == 0, "%d mock violations", e->m.nviol);
	for (i = 0; i < e->m.nviol && i < 16; i++)
		fprintf(stderr, "      violation: %s\n", e->m.viol[i]);
	CHECK(e->m.idle_deadlock == 0, "scenario ended idle (no SIGTERM scripted)");
}

static int count_ioctl(const struct mock *m, uint32_t req)
{
	size_t i;
	int n = 0;

	for (i = 0; i < m->nrec; i++)
		if (m->rec[i].kind == R_IOCTL && m->rec[i].req == req)
			n++;
	return n;
}

static const struct mock_rec *last_kind(const struct mock *m, int kind)
{
	size_t i = m->nrec;

	while (i-- > 0)
		if (m->rec[i].kind == kind)
			return &m->rec[i];
	return NULL;
}

static const struct mock_rec *first_ioctl(const struct mock *m)
{
	size_t i;

	for (i = 0; i < m->nrec; i++)
		if (m->rec[i].kind == R_IOCTL)
			return &m->rec[i];
	return NULL;
}

static long find_rec(const struct mock *m, size_t from, int kind, uint32_t req_or_word)
{
	size_t i;

	for (i = from; i < m->nrec; i++) {
		const struct mock_rec *r = &m->rec[i];

		if (r->kind != kind)
			continue;
		if (kind == R_IOCTL && r->req == req_or_word)
			return (long)i;
		if ((kind == R_WRITE || kind == R_READ) && r->len >= 4 &&
		    get_le32(r->head) == req_or_word)
			return (long)i;
		if (kind == R_HOPEN || kind == R_HCLOSE)
			return (long)i;
	}
	return -1;
}

static int notify_count(const struct mock *m, const char *s)
{
	int i, n = 0;

	for (i = 0; i < m->nnotify; i++)
		if (strstr(m->notify[i], s))
			n++;
	return n;
}

static int bytes_eq(const uint8_t *a, const char *hex)
{
	unsigned int v;
	size_t i = 0;

	while (*hex) {
		if (*hex == ' ') {
			hex++;
			continue;
		}
		if (sscanf(hex, "%2x", &v) != 1 || a[i] != v)
			return 0;
		i++;
		hex += 2;
	}
	return 1;
}

/* ------------------------------------------------------------------ */
/* golden transcript                                                    */
/* ------------------------------------------------------------------ */

struct exp {
	uint8_t kind, link;
	uint32_t req;
	int32_t ret;
	uint32_t len;
	uint32_t w[4];
	int nw, narg;
};

static struct exp *g_exp;
static size_t g_nexp, g_capexp;

static struct exp *exp_add(int kind)
{
	if (g_nexp == g_capexp) {
		g_capexp = g_capexp ? g_capexp * 2 : 8192;
		g_exp = realloc(g_exp, g_capexp * sizeof(*g_exp));
		if (!g_exp)
			abort();
	}
	memset(&g_exp[g_nexp], 0, sizeof(*g_exp));
	g_exp[g_nexp].kind = (uint8_t)kind;
	return &g_exp[g_nexp++];
}

static void E_io(uint32_t req, int32_t ret, int narg, uint32_t a0, uint32_t a1, uint32_t a2)
{
	struct exp *x = exp_add(R_IOCTL);

	x->req = req;
	x->ret = ret;
	x->narg = narg;
	x->w[0] = a0;
	x->w[1] = a1;
	x->w[2] = a2;
}

static void E_w(uint32_t len, int link, int nw, uint32_t w0, uint32_t w1,
		uint32_t w2, uint32_t w3)
{
	struct exp *x = exp_add(R_WRITE);

	x->len = len;
	x->link = (uint8_t)link;
	x->nw = nw;
	x->w[0] = w0;
	x->w[1] = w1;
	x->w[2] = w2;
	x->w[3] = w3;
}

static void E_r(uint32_t w)
{
	struct exp *x = exp_add(R_READ);

	x->len = 4;
	x->nw = 1;
	x->w[0] = w;
}

static void E_hopen(int which)
{
	exp_add(R_HOPEN)->req = (uint32_t)which;
}

static void build_boot(uint32_t boot_size, uint32_t main_size, uint32_t main_crc,
		       uint32_t nv_size)
{
	const uint32_t sizes[4] = { 0, 0x200, main_size, nv_size };
	uint32_t s;

	E_io(SL_IOCTL_MODEM_SET_TX_LINK, 0, 1, 10, 0, 0);
	E_io(SL_IOCTL_MODEM_ON, 0, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_BOOT_ON, 0, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_DL_START, 0, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_STATUS, 3, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_SET_TX_LINK, 0, 1, 3, 0, 0);
	E_w(boot_size, SL_LINK_SPI, 0, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_SET_TX_LINK, 0, 1, 10, 0, 0);
	E_w(4, SL_LINK_LLI, 1, 0x900D, 0, 0, 0);
	E_r(0xA00D);
	for (s = 1; s <= 3; s++) {
		uint32_t n = (sizes[s] + 2047) / 2048, i;

		E_w(4, SL_LINK_LLI, 1, 0x9000 | (s << 8), 0, 0, 0);
		E_r(0xA000 | (s << 8));
		E_io(SL_IOCTL_MODEM_FW_UPDATE, 0, 3, sizes[s], 0x810, n);
		for (i = 1; i <= n; i++) {
			uint32_t len = i < n ? 2048 : sizes[s] - (n - 1) * 2048;

			E_w(16 + len, SL_LINK_LLI, 4, 0x9001 | (s << 8), n, i, len);
		}
		E_r(0xA001 | (s << 8));
		if (s == 2) {
			E_w(8, SL_LINK_LLI, 2, 0x920C, main_crc, 0, 0);
			E_r(0xA20C);
		}
		E_w(4, SL_LINK_LLI, 1, 0x900D | (s << 8), 0, 0, 0);
		E_r(0xA00D | (s << 8));
	}
	E_w(4, SL_LINK_LLI, 1, 0x9F00, 0, 0, 0);
	E_r(0xAF00);
	E_io(SL_IOCTL_MODEM_BOOT_OFF, 0, 0, 0, 0, 0);
	E_hopen(0);
	E_hopen(1);
	E_io(SL_IOCTL_MODEM_CLR_CP_BOOTLOG, -EINVAL, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_BOOT_DONE, 0, 0, 0, 0, 0);
	E_io(SL_IOCTL_MODEM_STATUS, 4, 0, 0, 0, 0);
}

/* compare g_exp with the mock record from *pos; advances *pos */
static int compare_transcript(const struct mock *m, size_t *pos)
{
	size_t i = *pos, k;

	for (k = 0; k < g_nexp; k++) {
		const struct exp *x = &g_exp[k];
		const struct mock_rec *r;
		int j, ok = 1;

		while (i < m->nrec && (m->rec[i].kind == R_NOTIFY ||
				       m->rec[i].kind == R_BCLOSE))
			i++;
		if (i >= m->nrec) {
			fprintf(stderr, "    transcript ends at expected item %zu\n", k);
			return -1;
		}
		r = &m->rec[i];
		if (r->kind != x->kind)
			ok = 0;
		else if (x->kind == R_IOCTL) {
			ok = r->req == x->req && r->ret == x->ret;
			for (j = 0; j < x->narg && ok; j++)
				ok = r->arg[j] == x->w[j];
		} else if (x->kind == R_WRITE) {
			ok = r->len == x->len && r->txlink == x->link;
			for (j = 0; j < x->nw && ok; j++)
				ok = get_le32(r->head + 4 * j) == x->w[j];
		} else if (x->kind == R_READ) {
			ok = r->len == 4 && get_le32(r->head) == x->w[0];
		} else if (x->kind == R_HOPEN) {
			ok = r->req == x->req;
		}
		if (!ok) {
			fprintf(stderr, "    transcript mismatch at item %zu (record %zu): "
				"expected kind %d req 0x%X len %u w0 0x%X; got kind %d req 0x%X "
				"ret %d len %u w0 0x%X\n", k, i, x->kind, x->req, x->len, x->w[0],
				r->kind, r->req, r->ret, r->len,
				r->len >= 4 ? get_le32(r->head) : 0);
			return -1;
		}
		i++;
	}
	*pos = i;
	return 0;
}

/* ------------------------------------------------------------------ */
/* test cases                                                           */
/* ------------------------------------------------------------------ */

static void t_units(void)
{
	static const char crcin[] = "123456789";
	uint8_t buf[200], sha[32], d[16];
	char hex[65];
	struct sl_loader L;
	struct sl_config cfg;
	struct sl_ops ops;
	struct sl_toc t;
	struct img_spec s;
	struct img im;
	char why[160];
	unsigned int i;
	enum sl_rung r;
	static const unsigned long forbidden[] = {
		TRIP_CP_UPLOAD, TRIP_FORCE_CRASH_EXIT, TRIP_DUMP_START, TRIP_DUMP_RESET,
		0x6F21 /* RESET */, 0x6F40 /* XMIT_BOOT */, 0x6F33, 0x6F25, 0x6F51,
	};
	static const unsigned long allowed[] = {
		0x6F19, 0x6F20, 0x6F22, 0x6F23, 0x6F24, 0x6F27, 0x6F28, 0x6F29, 0x6F37,
		0x6F47, 0x6F48,
	};

	{
		struct sl_log_cfg lc;

		memset(&lc, 0, sizeof(lc));
		lc.to_stderr = g_verbose;
		lc.kmsg_fd = -1;
		lc.max_level = SL_LOG_DEBUG;
		lc.sink = sink;
		sl_log_setup(&lc);
	}
	/* production pins */
	memset(&cfg, 0, sizeof(cfg));
	memset(&ops, 0, sizeof(ops));
	sl_loader_init(&L, &cfg, &ops, NULL);
	sl_hex(L.pin_boot_sha256, 32, hex);
	CHECK(strcmp(hex, "dd39fae36c2ccfbc28c3562c405962c827b2cf5d66f9e63d3fb90223dd0f94f4") == 0,
	      "default BOOT SHA-256 pin is %s", hex);
	CHECK(SL_BOOT_CRC_PINNED == 0x5DB1F04Cu, "CRC pin");

	/* CRC32 and forging */
	CHECK(sl_crc32_update(0, crcin, 9) == 0xCBF43926u, "crc32 check value");
	prng_fill(buf, sizeof(buf), 5);
	crc_forge_tail(buf, sizeof(buf), 0x5DB1F04Cu);
	CHECK(sl_crc32_update(0, buf, sizeof(buf)) == 0x5DB1F04Cu, "forged CRC");
	crc_forge_tail(buf, sizeof(buf), 0x1E71169Cu);
	CHECK(sl_crc32_update(0, buf, sizeof(buf)) == 0x1E71169Cu, "forged CRC 2");

	/* manifest parser (sha256sum format) */
	{
		static const char h[] =
			"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
		char txt[600];

		snprintf(txt, sizeof(txt), "%s  nv_data.bin\n", h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "/x/nv_data.bin", sha) == 1 &&
		      sha[0] == 0xe3 && sha[31] == 0x55, "manifest basic");
		CHECK(sl_manifest_lookup(txt, strlen(txt), "/x/other", sha) == 0,
		      "manifest absent name");
		snprintf(txt, sizeof(txt), "# c\n\n%s *nv_data.bin\r\n", h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "nv_data.bin", sha) == 1,
		      "manifest binary mode + CRLF + comment");
		snprintf(txt, sizeof(txt), "%s  nv_data.bin\n%s  nv_data.bin\n", h, h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "nv_data.bin", sha) == -1,
		      "manifest duplicate");
		snprintf(txt, sizeof(txt), "%s nv_data.bin\n", h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "nv_data.bin", sha) == -1,
		      "manifest one space");
		snprintf(txt, sizeof(txt), "%.63sx  nv_data.bin\n", h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "nv_data.bin", sha) == -1,
		      "manifest bad hex");
		snprintf(txt, sizeof(txt), "%s  \\nv_data.bin\n", h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "nv_data.bin", sha) == -1,
		      "manifest escaped name");
		CHECK(sl_manifest_lookup("", 0, "nv_data.bin", sha) == 0, "empty manifest");
		snprintf(txt, sizeof(txt), "%s  /var/lib/shannon/nv/nv_data.bin", h);
		CHECK(sl_manifest_lookup(txt, strlen(txt), "/a/nv_data.bin", sha) == 1,
		      "manifest path name, no final newline");
	}
	/* .md5 text */
	CHECK(sl_nv_parse_md5_text("d41d8cd98f00b204e9800998ecf8427e", 32, d) == 0 && d[0] == 0xd4,
	      "md5 text");
	CHECK(sl_nv_parse_md5_text("D41D8CD98F00B204E9800998ECF8427E\n", 33, d) == 0, "md5 upper+nl");
	CHECK(sl_nv_parse_md5_text("d41d8cd98f00b204e9800998ecf8427e  nv_data.bin\n", 46, d) == 0,
	      "md5sum line");
	CHECK(sl_nv_parse_md5_text("d41d8cd98f00b204e9800998ecf8427", 31, d) == -1, "md5 short");
	CHECK(sl_nv_parse_md5_text("d41d8cd98f00b204e9800998ecf8427eX", 33, d) == -1, "md5 junk");
	CHECK(sl_nv_parse_md5_text("z41d8cd98f00b204e9800998ecf8427e", 32, d) == -1, "md5 nonhex");

	/* TOC validation */
	img_spec_small(&s);
	CHECK(img_build(&s, &im) == 0, "img_build");
	sl_toc_parse(im.data, &t);
	CHECK(sl_toc_validate(&t, im.size, why, sizeof(why)) == 0, "valid toc: %s", why);
	{
		struct sl_toc b;

		b = t; strcpy(b.e[2].name, "MAIM");
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "slot name");
		b = t; memcpy(b.e[1].name, "BOOTBOOTBOOT", 12); b.e[1].name[12] = '\0';
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "unterminated name");
		b = t; b.e[0].offset = 4;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "TOC offset");
		b = t; b.e[0].size = 0x7F;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "TOC size small");
		b = t; b.e[0].size = 0x201;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "TOC size big");
		b = t; b.e[1].size = 0;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "BOOT size 0");
		b = t; b.e[1].size = 0xFFFC;
		CHECK(sl_toc_validate(&b, 1u << 20, why, sizeof(why)) != 0, "BOOT size 0xFFFC");
		b = t; b.e[1].size = 0xFFFB;
		CHECK(sl_toc_validate(&b, 1u << 20, why, sizeof(why)) == 0, "BOOT size 0xFFFB ok: %s", why);
		b = t; b.e[1].crc ^= 1;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "BOOT crc pin");
		b = t; b.e[2].size = 0;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "MAIN size 0");
		b = t; b.e[3].size = 0;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "NV size 0");
		b = t; b.e[3].size = (16u << 20) + 1;
		CHECK(sl_toc_validate(&b, 64u << 20, why, sizeof(why)) != 0, "NV size > 16 MiB");
		b = t; b.e[2].size = (uint32_t)im.size;
		CHECK(sl_toc_validate(&b, im.size, why, sizeof(why)) != 0, "MAIN beyond image");
	}
	img_free(&im);

	/* ioctl allow-list */
	for (i = 0; i < sizeof(allowed) / sizeof(allowed[0]); i++)
		CHECK(sl_ioctl_allowed(allowed[i]), "0x%lX should be allowed", allowed[i]);
	for (i = 0; i < sizeof(forbidden) / sizeof(forbidden[0]); i++)
		CHECK(!sl_ioctl_allowed(forbidden[i]), "0x%lX must be refused", forbidden[i]);

	/* sl_ioctl never reaches the device with a forbidden request */
	{
		struct env e;

		env_setup(&e, GEO_SMALL, "small/ok");
		mock_init(&e.m, &e.mc, &e.stop);
		mock_get_ops(&e.m, &e.ops);
		sl_loader_init(&e.L, &e.cfg, &e.ops, &e.stop);
		e.L.boot_fd = MOCK_BOOT_FD;
		for (i = 0; i < sizeof(forbidden) / sizeof(forbidden[0]); i++)
			CHECK(sl_ioctl(&e.L, forbidden[i], NULL) == -EPERM, "refused");
		CHECK(e.m.n_ioctls == 0 && e.m.tripwire == 0,
		      "forbidden ioctl reached the device (%u)", e.m.n_ioctls);
		e.L.boot_fd = -1;
		sl_loader_free(&e.L);
		env_free(&e);
	}

	for (r = SL_RUNG_PREFLIGHT; r <= SL_RUNG_ONLINE; r++) {
		enum sl_rung back;

		CHECK(sl_rung_parse(sl_rung_name(r), &back) == 0 && back == r, "rung %d", r);
	}
	CHECK(sl_rung_parse("bogus", &r) != 0, "bogus rung");
}

/* The mock's own detectors must fire when provoked (positive controls). */
static void t_mock_selftest(void)
{
	struct env e;
	uint8_t w[4];
	int v, v0;

	env_setup(&e, GEO_SMALL, "small/ok");
	mock_init(&e.m, &e.mc, &e.stop);
	mock_get_ops(&e.m, &e.ops);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, TRIP_CP_UPLOAD, NULL);
	CHECK(e.m.tripwire == 1, "CP_UPLOAD tripwire did not fire");
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, TRIP_DUMP_RESET, NULL);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, TRIP_DUMP_START, NULL);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, TRIP_FORCE_CRASH_EXIT, NULL);
	CHECK(e.m.tripwire == 4, "dump/crash tripwires (%d)", e.m.tripwire);
	v0 = e.m.nviol;

	/* wrong SPI payload, eFuse power-off, stage 4 word, 0x930C */
	v = SL_LINK_LLI;
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_SET_TX_LINK, &v);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_ON, NULL);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_BOOT_ON, NULL);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_DL_START, NULL);
	mock_daemon_open(&e.m);
	CHECK(e.m.nviol == v0 + 2, "daemon open inside the download window not flagged");
	mock_daemon_close(&e.m);
	v = SL_LINK_SPI;
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_SET_TX_LINK, &v);
	e.ops.boot_write(&e.m, MOCK_BOOT_FD, e.im.data, e.im.boot_size);
	CHECK(e.m.tripwire == 5, "wrong SPI payload not flagged");
	e.ops.sleep_ms(&e.m, 400);	/* cp_status rises */
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_OFF, NULL);
	CHECK(e.m.nviol == v0 + 4 && strstr(e.m.viol[v0 + 3], "eFuse"),
	      "eFuse power-off not flagged (%d)", e.m.nviol);
	/* ring words: back to LLI, armed again */
	v = SL_LINK_LLI;
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_SET_TX_LINK, &v);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_ON, NULL);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_BOOT_ON, NULL);
	e.ops.boot_ioctl(&e.m, MOCK_BOOT_FD, SL_IOCTL_MODEM_DL_START, NULL);
	e.m.lli = 1;
	put_le32(w, 0x9400);
	e.ops.boot_write(&e.m, MOCK_BOOT_FD, w, 4);
	CHECK(e.m.tripwire == 6, "stage 4 word not flagged");
	put_le32(w, 0x930C);
	e.ops.boot_write(&e.m, MOCK_BOOT_FD, w, 4);
	CHECK(e.m.tripwire == 7, "0x930C not flagged");
	env_free(&e);
}

static void check_vectors_real(struct env *e)
{
	const struct mock *m = &e->m;
	size_t i;
	int seen_first_main = 0, seen_toc = 0, seen_crc = 0, seen_fin = 0, seen_900d = 0;
	int seen_last_main = 0, seen_nv_last = 0, fw = 0, req_ring = 0, full_ring = 0;
	uint32_t main_frames = 0;

	for (i = 0; i < m->nrec; i++) {
		const struct mock_rec *r = &m->rec[i];

		if (r->kind == R_IOCTL && r->req == SL_IOCTL_MODEM_FW_UPDATE) {
			if (r->arg[0] == 0x200)
				fw += bytes_eq(r->head, "00 02 00 00 10 08 00 00 01 00 00 00");
			if (r->arg[0] == 0x21271A0)
				fw += bytes_eq(r->head, "A0 71 12 02 10 08 00 00 4F 42 00 00");
			if (r->arg[0] == 0x100000)
				fw += bytes_eq(r->head, "00 00 10 00 10 08 00 00 00 02 00 00");
		}
		if (r->kind != R_WRITE)
			continue;
		if (r->txlink == SL_LINK_SPI) {
			CHECK(bytes_eq(r->ring, "F8 D7 00 2A"), "SPI skb header");
			continue;
		}
		if (r->len == 4) {
			req_ring += bytes_eq(r->ring, "FC D7 08 00") && r->ring_pad == 0;
			if (get_le32(r->head) == 0x900D && !seen_900d)
				seen_900d = bytes_eq(r->head, "0D 90 00 00");
			if (get_le32(r->head) == 0x9F00)
				seen_fin = bytes_eq(r->head, "00 9F 00 00");
		}
		if (r->len == 8) {
			seen_crc = bytes_eq(r->head, "0C 92 00 00 9C 16 71 1E") &&
				   bytes_eq(r->ring, "FC D7 0C 00") && r->ring_pad == 0;
		}
		if (r->len == 528)
			seen_toc = bytes_eq(r->head, "01 91 00 00 01 00 00 00 01 00 00 00 00 02 00 00") &&
				   bytes_eq(r->ring, "FC D7 14 02");
		if (r->len == 2064)
			full_ring += bytes_eq(r->ring, "FC D7 14 08") && r->ring_pad == 0;
		if (r->len >= 16 && get_le32(r->head) == 0x9201) {
			main_frames++;
			if (get_le32(r->head + 8) == 1)
				seen_first_main = bytes_eq(r->head,
					"01 92 00 00 4F 42 00 00 01 00 00 00 00 08 00 00");
			if (get_le32(r->head + 8) == 0x424F)
				seen_last_main = r->len == 432 && bytes_eq(r->head,
					"01 92 00 00 4F 42 00 00 4F 42 00 00 A0 01 00 00") &&
					bytes_eq(r->ring, "FC D7 B4 01") && r->ring_pad == 0;
		}
		if (r->len >= 16 && get_le32(r->head) == 0x9301 && get_le32(r->head + 8) == 0x200)
			seen_nv_last = bytes_eq(r->head,
				"01 93 00 00 00 02 00 00 00 02 00 00 00 08 00 00");
	}
	CHECK(seen_900d, "0x900D bytes 0D 90 00 00");
	CHECK(seen_fin, "FIN bytes 00 9F 00 00");
	CHECK(seen_crc, "CRC frame 0C 92 00 00 9C 16 71 1E / ring FC D7 0C 00");
	CHECK(seen_toc, "TOC frame header + ring FC D7 14 02");
	CHECK(seen_first_main, "first MAIN header vector");
	CHECK(seen_last_main, "last MAIN header vector (432 B, ring FC D7 B4 01)");
	CHECK(seen_nv_last, "last NV header vector");
	CHECK(fw == 3, "FW_UPDATE byte vectors (%d of 3)", fw);
	CHECK(main_frames == 16975, "MAIN frames %u", main_frames);
	CHECK(req_ring == 8, "4-byte request ring headers FC D7 08 00 (%d)", req_ring);
	CHECK(full_ring == 16974 + 512, "full frame ring headers FC D7 14 08 (%d)", full_ring);
}

static void t_golden_real(void)
{
	struct env e;
	size_t pos = 0;
	long hc, off;
	const struct mock_rec *last;

	if (env_setup(&e, GEO_REAL, "real") != 0 || !e.nv) {
		CHECK(0, "fixture setup");
		return;
	}
	CHECK(e.im.main_crc == 0x1E71169C && e.im.boot_crc == 0x5DB1F04C,
	      "synthetic image carries the stock CRCs");
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	env_run(&e);
	CHECK(e.rc == 0, "rc %d", e.rc);
	expect_clean(&e);

	g_nexp = 0;
	build_boot(0x29FC, 0x21271A0, 0x1E71169C, 0x100000);
	CHECK(compare_transcript(&e.m, &pos) == 0, "golden transcript");
	CHECK(e.m.n_ring_writes == 17497, "stage-engine writes %u (expected 17 497)",
	      e.m.n_ring_writes);
	CHECK(e.m.n_spi_writes == 1, "SPI writes %u", e.m.n_spi_writes);
	CHECK(e.m.n_reads4 == 12, "response reads %u", e.m.n_reads4);
	CHECK(e.m.n_fw_update == 3, "FW_UPDATE %u", e.m.n_fw_update);
	CHECK(e.m.n_late_init_end == 1 && e.m.n_handler_init_end == 0,
	      "INIT_END via the late path once (late %u handler %u)",
	      e.m.n_late_init_end, e.m.n_handler_init_end);
	CHECK(count_ioctl(&e.m, SL_IOCTL_MODEM_GET_CP_BOOTLOG) == 0, "no GET_CP_BOOTLOG");
	CHECK(e.m.n_modem_on == 1 && e.m.n_modem_off == 1, "one power cycle");
	/* SIGTERM: holders closed, then MODEM_OFF */
	hc = find_rec(&e.m, pos, R_HCLOSE, 0);
	off = find_rec(&e.m, pos, R_IOCTL, SL_IOCTL_MODEM_OFF);
	CHECK(hc >= 0 && off > hc, "holders closed before MODEM_OFF (%ld, %ld)", hc, off);
	last = last_kind(&e.m, R_IOCTL);
	CHECK(last && last->req == SL_IOCTL_MODEM_OFF, "last ioctl is MODEM_OFF");
	CHECK(notify_count(&e.m, "READY=1") == 1, "READY=1 once");
	CHECK(notify_count(&e.m, "STOPPING=1") == 1, "STOPPING=1");
	CHECK(log_has("MAIN 16975 frames, 34763168 bytes"), "MAIN frame counter line");
	CHECK(log_has("eFuse window closed by 0xA00D"), "eFuse window closed");
	CHECK(log_count("-> 0x") == 9 && log_count("<- 0x") == 12,
	      "one log line per protocol word (%d requests, %d responses)",
	      log_count("-> 0x"), log_count("<- 0x"));
	CHECK(!log_has("0x9201 "), "no per-frame log line");
	check_vectors_real(&e);
	env_free(&e);
}

static void t_golden_small(void)
{
	struct env e;
	size_t pos = 0, i;
	const struct mock_rec *r921 = NULL;

	env_setup(&e, GEO_SMALL, "small/ok");
	add_script(&e.mc, 1, 500, MEV_DAEMON_OPEN, 0);
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	env_run(&e);
	CHECK(e.rc == 0, "rc %d", e.rc);
	expect_clean(&e);
	g_nexp = 0;
	build_boot(0x100, 5001, e.im.main_crc, 0x1800);
	CHECK(compare_transcript(&e.m, &pos) == 0, "small transcript");
	CHECK(e.m.n_holder_opens == 2 && e.m.n_late_init_end == 1,
	      "loader holds umts_ipc0/umts_rfs0 after BOOT_OFF (INIT_END via late path)");
	CHECK(e.m.holder_open[0] == 1 && e.m.holder_open[1] == 1,
	      "daemon fds still open, loader fds closed at SIGTERM");
	for (i = 0; i < e.m.nrec; i++)
		if (e.m.rec[i].kind == R_WRITE && e.m.rec[i].len == 921)
			r921 = &e.m.rec[i];
	CHECK(r921 && bytes_eq(r921->ring, "FC D7 9D 03") && r921->ring_pad == 3,
	      "synthetic last frame ring vector FC D7 9D 03 + 3 padding");
	CHECK(e.m.nstates >= 4 && strcmp(e.m.states[0], "session=0 state=offline\n") == 0 &&
	      strcmp(e.m.states[1], "session=1 state=booting\n") == 0 &&
	      strcmp(e.m.states[2], "session=1 state=online\n") == 0 &&
	      strcmp(e.m.states[e.m.nstates - 1], "session=1 state=offline\n") == 0,
	      "cp-state sequence offline, booting, online, offline");
	env_free(&e);
}

static void t_rungs(void)
{
	enum sl_rung r;

	for (r = SL_RUNG_PREFLIGHT; r <= SL_RUNG_FIN; r++) {
		struct env e;
		const struct mock_rec *last;
		const struct mock_rec *lw;
		int case_fail0 = g_case_fail;

		env_setup(&e, GEO_SMALL, "small/ok");
		e.cfg.stop_after = r;
		env_run(&e);
		CHECK(e.rc == 0, "rung %s rc %d", sl_rung_name(r), e.rc);
		expect_clean(&e);
		last = last_kind(&e.m, R_IOCTL);
		lw = last_kind(&e.m, R_WRITE);
		if (r == SL_RUNG_PREFLIGHT) {
			CHECK(e.m.n_ioctls == 0 && e.m.nrec <= 1, "dry run issued %u ioctls",
			      e.m.n_ioctls);
			CHECK(log_has("dry run"), "dry-run log");
		} else {
			CHECK(last && last->req == SL_IOCTL_MODEM_OFF,
			      "rung %s does not end with MODEM_OFF", sl_rung_name(r));
			CHECK(e.m.n_modem_off == 1 && e.m.n_modem_on == 1,
			      "rung %s: one power cycle", sl_rung_name(r));
		}
		switch (r) {
		case SL_RUNG_POWER:
			CHECK(count_ioctl(&e.m, SL_IOCTL_MODEM_DL_START) == 0 &&
			      count_ioctl(&e.m, SL_IOCTL_MODEM_BOOT_ON) == 1, "power rung = B1-B3");
			break;
		case SL_RUNG_SPI: {
			long w = find_rec(&e.m, 0, R_WRITE, get_le32(e.im.data + e.im.boot_off));

			CHECK(e.m.n_spi_writes == 1 && e.m.n_ring_writes == 0, "spi rung");
			CHECK(w >= 0 && last && last->t_us >= e.m.rec[w].t_us + 300000u + 10000000u,
			      "spi rung: MODEM_OFF inside the 10 s eFuse window");
			CHECK(log_has("eFuse window: no 0xA00D yet"), "eFuse hold logged");
			break;
		}
		case SL_RUNG_LLI:
			CHECK(e.m.n_ring_writes == 0, "lli rung wrote to the ring");
			break;
		case SL_RUNG_STAGE0:
			CHECK(e.m.n_ring_writes == 1 && e.m.n_reads4 == 1, "stage0 rung");
			break;
		case SL_RUNG_TOC:
			CHECK(lw && get_le32(lw->head) == 0x910D, "toc rung last write");
			break;
		case SL_RUNG_MAIN:
			CHECK(lw && get_le32(lw->head) == 0x920D && e.m.n_crc_frames == 1,
			      "main rung last write");
			break;
		case SL_RUNG_NV:
			CHECK(lw && get_le32(lw->head) == 0x930D, "nv rung last write");
			break;
		case SL_RUNG_FIN:
			CHECK(lw && get_le32(lw->head) == 0x9F00 && e.m.n_boot_off == 0,
			      "fin rung");
			break;
		default:
			break;
		}
		if (g_case_fail != case_fail0)
			fprintf(stderr, "    (rung %s)\n", sl_rung_name(r));
		env_free(&e);
	}

	/* online rung: hold, no silent reset on a crash */
	{
		struct env e;

		env_setup(&e, GEO_SMALL, "small/ok");
		e.cfg.stop_after = SL_RUNG_ONLINE;
			add_script(&e.mc, 1, 2000, MEV_CRASH, 0);
		env_run(&e);
		CHECK(e.rc == SL_EXIT_BOOT, "online rung crash rc %d", e.rc);
		CHECK(e.m.n_modem_on == 1, "online rung must not reboot the CP");
		CHECK(last_kind(&e.m, R_IOCTL)->req == SL_IOCTL_MODEM_OFF, "MODEM_OFF");
		expect_clean(&e);
		env_free(&e);

		env_setup(&e, GEO_SMALL, "small/ok");
		e.cfg.stop_after = SL_RUNG_ONLINE;
		add_script(&e.mc, 1, 60000, MEV_SIGTERM, 0);
		env_run(&e);
		CHECK(e.rc == 0 && notify_count(&e.m, "READY=1") == 1, "online rung sigterm");
		expect_clean(&e);
		env_free(&e);
	}
}

/* one fault-matrix scenario on the small geometry */
static void run_small(struct env *e, int attempts)
{
	e->cfg.max_attempts = attempts;
	env_run(e);
}

static void t_matrix_image(void)
{
	struct env e;

	/* TOC slot name wrong */
	env_setup(&e, GEO_SMALL, "small/ok");
	memcpy(e.im.data + 2 * 32, "MAIM", 4);
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_IMAGE && e.m.n_ioctls == 0 && e.m.boot_opens == 0,
	      "TOC name: rc %d ioctls %u", e.rc, e.m.n_ioctls);
	env_free(&e);

	/* truncated image / truncated TOC read */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.image_size = 0x1FF;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_IMAGE && e.m.n_ioctls == 0, "truncated: rc %d", e.rc);
	env_free(&e);

	/* BOOT.size = 0xFFFC */
	env_setup(&e, GEO_SMALL, "small/ok");
	put_le32(e.im.data + 32 + 20, 0xFFFC);
	e.mc.image_size = 1u << 20;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_IMAGE && e.m.n_ioctls == 0, "BOOT.size 0xFFFC: rc %d", e.rc);
	CHECK(log_has("SPI header limit"), "reason logged");
	env_free(&e);

	/* BOOT CRC != TOC */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.im.data[e.im.boot_off + 3] ^= 0x10;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_IMAGE && e.m.n_ioctls == 0, "BOOT CRC: rc %d", e.rc);
	env_free(&e);

	/* MAIN CRC != TOC, found in preflight */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.im.data[e.im.main_off + 4000] ^= 0x10;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_IMAGE && e.m.n_ioctls == 0, "MAIN CRC preflight: rc %d", e.rc);
	env_free(&e);

	/* MAIN changes after preflight: abort before the CRC frame */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_corrupt_main_after_preflight = 1;
	run_small(&e, 3);
	CHECK(e.rc == SL_EXIT_IMAGE, "MAIN changed: rc %d", e.rc);
	CHECK(e.m.n_crc_frames == 0 && find_rec(&e.m, 0, R_WRITE, 0x920C) < 0,
	      "CRC frame sent for a changed MAIN");
	CHECK(e.m.n_modem_on == 1, "no retry after an image change");
	CHECK(last_kind(&e.m, R_IOCTL)->req == SL_IOCTL_MODEM_OFF, "MODEM_OFF");
	CHECK(log_has("aborting before the CRC frame"), "log");
	expect_clean(&e);
	env_free(&e);

	/* production BOOT pin rejects a synthetic BOOT even with the right CRC */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.production_pin = 1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_IMAGE && e.m.n_ioctls == 0, "production pin: rc %d", e.rc);
	CHECK(log_has("is not the pinned stock BOOT"), "SHA pin log");
	env_free(&e);
}

static void t_matrix_boot(void)
{
	struct env e;
	long w, off;

	/* DL_START -EFAULT: retries then exit 6 */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_dl_start_efault = -1;
	run_small(&e, 3);
	CHECK(e.rc == SL_EXIT_BOOT, "DL_START: rc %d", e.rc);
	CHECK(count_ioctl(&e.m, SL_IOCTL_MODEM_DL_START) == 3 && e.m.n_modem_off == 3,
	      "3 attempts, 3 MODEM_OFF");
	expect_clean(&e);
	env_free(&e);

	/* default --attempts=1: a single attempt */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_dl_start_efault = -1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && e.m.n_modem_on == 1, "attempts=1");
	env_free(&e);

	/* SPI write -1/EINTR: attempt failure, never retried inside the attempt */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_spi_eintr = -1;
	run_small(&e, 3);
	CHECK(e.rc == SL_EXIT_BOOT && e.m.n_spi_writes == 3 && e.m.n_modem_on == 3,
	      "SPI EINTR: rc %d spi %u", e.rc, e.m.n_spi_writes);
	expect_clean(&e);
	env_free(&e);

	/* cp_status never 1: failure after 5 s */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_cp_status_never = -1;
	run_small(&e, 1);
	w = find_rec(&e.m, 0, R_WRITE, get_le32(e.im.data + e.im.boot_off));
	off = find_rec(&e.m, 0, R_IOCTL, SL_IOCTL_MODEM_OFF);
	CHECK(e.rc == SL_EXIT_BOOT && w >= 0 && off > w, "cp_status: rc %d", e.rc);
	if (w >= 0 && off > w)
		CHECK(e.m.rec[off].t_us - e.m.rec[w].t_us >= 5000000u &&
		      e.m.rec[off].t_us - e.m.rec[w].t_us < 5500000u,
		      "cp_status deadline %.3f s",
		      (double)(e.m.rec[off].t_us - e.m.rec[w].t_us) / 1e6);
	CHECK(count_ioctl(&e.m, SL_IOCTL_MODEM_SET_TX_LINK) == 2, "no switch back to LLI");
	expect_clean(&e);
	env_free(&e);

	/* LLI never mounted: failure after 5 s, no std_udl word written */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_lli_never = -1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && e.m.n_ring_writes == 0, "LLI: rc %d ring %u",
	      e.rc, e.m.n_ring_writes);
	CHECK(log_has("B10") && log_has("still \"MIPI-LLI 0\""), "LLI log");
	CHECK(log_has("eFuse window: no 0xA00D yet"), "LLI failure holds MODEM_OFF for the window");
	expect_clean(&e);
	env_free(&e);

	/* no answer to any word: 30 s timeout */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_silent = -1;
	run_small(&e, 1);
	w = find_rec(&e.m, 0, R_WRITE, 0x900D);
	off = find_rec(&e.m, 0, R_IOCTL, SL_IOCTL_MODEM_OFF);
	CHECK(e.rc == SL_EXIT_BOOT && w >= 0 && off > w, "silent: rc %d", e.rc);
	if (w >= 0 && off > w)
		CHECK(e.m.rec[off].t_us - e.m.rec[w].t_us >= 30000000u &&
		      e.m.rec[off].t_us - e.m.rec[w].t_us < 31500000u, "30 s timeout");
	CHECK(log_has("TIMEOUT"), "timeout log");
	CHECK(e.m.n_ring_writes == 1, "nothing written after the unanswered word");
	expect_clean(&e);
	env_free(&e);

	/* wrong answer */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_wrong_for = 0x9200;
	e.mc.f_wrong_reply = 0xA100;
	e.mc.f_wrong_count = 1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && log_has("PROTOCOL_MISMATCH"), "wrong answer: rc %d", e.rc);
	expect_clean(&e);
	env_free(&e);

	/* 0xA20F once: retry and succeed */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_reject_crc = 1;
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	run_small(&e, 3);
	CHECK(e.rc == 0 && e.m.n_modem_on == 2, "reject once: rc %d on %u", e.rc, e.m.n_modem_on);
	CHECK(log_has("MAIN image rejected"), "rejection logged");
	expect_clean(&e);
	env_free(&e);

	/* 0xA20F twice: exit 7 */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_reject_crc = 2;
	run_small(&e, 3);
	CHECK(e.rc == SL_EXIT_REJECTED && e.m.n_modem_on == 2, "reject twice: rc %d on %u",
	      e.rc, e.m.n_modem_on);
	CHECK(last_kind(&e.m, R_IOCTL)->req == SL_IOCTL_MODEM_OFF, "MODEM_OFF");
	expect_clean(&e);
	env_free(&e);

	/* read returns 8 bytes */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_read8_for = 0xA100;
	e.mc.f_read8_count = 1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && log_has("read returned 8 bytes"), "read 8: rc %d", e.rc);
	expect_clean(&e);
	env_free(&e);

	/* POLLHUP mid-MAIN with STATUS 2 */
	env_setup(&e, GEO_REAL, "real");
	e.mc.f_crash_main_frame = 100;
	e.mc.f_crash_count = 1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && log_has("crash during boot"), "POLLHUP: rc %d", e.rc);
	CHECK(log_has("modem state 2 (CRASH_EXIT)"), "STATUS 2 read");
	CHECK(e.m.n_writes_after_crash <= 64, "%u frames streamed into a crashed CP",
	      e.m.n_writes_after_crash);
	expect_clean(&e);
	env_free(&e);

	/* write -ENOSPC */
	env_setup(&e, GEO_REAL, "real");
	e.mc.f_enospc_stage = 2;
	e.mc.f_enospc_frame = 50;
	e.mc.f_enospc_count = 1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && log_has("ring full"), "ENOSPC: rc %d", e.rc);
	expect_clean(&e);
	env_free(&e);

	/* BOOT_OFF -EAGAIN: GET_CP_BOOTLOG then failure */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_boot_off_eagain = 1;
	run_small(&e, 1);
	CHECK(e.rc == SL_EXIT_BOOT && e.m.n_get_bootlog == 1, "BOOT_OFF: rc %d get %u",
	      e.rc, e.m.n_get_bootlog);
	expect_clean(&e);
	env_free(&e);

	/* a third party opening the holders during the download is flagged */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_daemon_open_at_stage = 2;
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	run_small(&e, 1);
	CHECK(e.m.nviol == 2 && strstr(e.m.viol[0], "daemon") && strstr(e.m.viol[1], "daemon"),
	      "daemon violation flagged (%d)", e.m.nviol);
	CHECK(e.m.n_holder_opens == 2, "loader holder opens after BOOT_OFF");
	env_free(&e);

	/* stale RX words from an earlier attempt are drained (B11) */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_stale_rx = 3;
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	run_small(&e, 1);
	CHECK(e.rc == 0 && log_count("stale RX frame dropped") == 3, "stale RX: rc %d", e.rc);
	expect_clean(&e);
	env_free(&e);
}

static void t_supervisor(void)
{
	struct env e;
	long crash_off;

	/* STATUS 7 (SIM event) ignored, then 2: silent reset */
	env_setup(&e, GEO_SMALL, "small/ok");
	add_script(&e.mc, 1, 5000, MEV_SIM_CHANGE, 0);
	add_script(&e.mc, 1, 10000, MEV_CRASH, 0);
	add_script(&e.mc, 2, 5000, MEV_SIGTERM, 0);
	env_run(&e);
	CHECK(e.rc == 0, "rc %d", e.rc);
	expect_clean(&e);
	CHECK(log_has("SIM state change event consumed"), "SIM event ignored");
	CHECK(e.m.n_modem_on == 2 && e.m.n_modem_off == 2, "reset = OFF + boot (on %u off %u)",
	      e.m.n_modem_on, e.m.n_modem_off);
	CHECK(e.m.n_holder_opens == 2, "holders kept open across the reset");
	CHECK(e.m.n_handler_init_end == 1, "INIT_END from the PHONE_START handler after reset");
	CHECK(notify_count(&e.m, "STATUS=CP crashed, restarting") == 1, "notify crash");
	CHECK(notify_count(&e.m, "READY=1") == 1, "READY once");
	{
		static const char *const want[] = {
			"session=0 state=offline\n", "session=1 state=booting\n",
			"session=1 state=online\n", "session=1 state=crashed\n",
			"session=1 state=offline\n", "session=2 state=booting\n",
			"session=2 state=online\n", "session=2 state=offline\n",
		};
		int k, okseq = e.m.nstates == 8;

		for (k = 0; okseq && k < 8; k++)
			okseq = strcmp(e.m.states[k], want[k]) == 0;
		CHECK(okseq, "cp-state sequence across a silent reset (%d lines)", e.m.nstates);
	}
	crash_off = find_rec(&e.m, 0, R_IOCTL, SL_IOCTL_MODEM_OFF);
	{
		long st = -1;
		size_t i;

		for (i = 0; i < e.m.nrec; i++)
			if (e.m.rec[i].kind == R_IOCTL && e.m.rec[i].req == SL_IOCTL_MODEM_STATUS &&
			    e.m.rec[i].ret == SL_STATE_CRASH_EXIT)
				st = (long)i;
		CHECK(st >= 0 && crash_off > st &&
		      e.m.rec[crash_off].t_us - e.m.rec[st].t_us >= 3000000u,
		      "3 s grace before MODEM_OFF");
	}
	env_free(&e);

	/* 6 crashes in 30 min: MODEM_OFF, exit 6 after 5 resets */
	env_setup(&e, GEO_SMALL, "small/ok");
	{
		int k;

		for (k = 1; k <= 7; k++)
			add_script(&e.mc, k, 60000, MEV_CRASH, 0);
	}
	env_run(&e);
	CHECK(e.rc == SL_EXIT_BOOT, "crash loop rc %d", e.rc);
	CHECK(e.m.n_modem_on == 6, "6 boots (1 + 5 resets), got %u", e.m.n_modem_on);
	CHECK(last_kind(&e.m, R_IOCTL)->req == SL_IOCTL_MODEM_OFF, "MODEM_OFF last");
	CHECK(log_has("giving up"), "giving up logged");
	expect_clean(&e);
	env_free(&e);

	/* 6 crashes spread over 42 min: never more than 4 in a window */
	env_setup(&e, GEO_SMALL, "small/ok");
	{
		int k;

		for (k = 1; k <= 6; k++)
			add_script(&e.mc, k, 7 * 60000, MEV_CRASH, 0);
		add_script(&e.mc, 7, 1000, MEV_SIGTERM, 0);
	}
	env_run(&e);
	CHECK(e.rc == 0 && e.m.n_modem_on == 7, "spread crashes: rc %d on %u", e.rc,
	      e.m.n_modem_on);
	expect_clean(&e);
	env_free(&e);

	/* battery drops below 5 % before a reset: no power-on, exit 8 */
	env_setup(&e, GEO_SMALL, "small/ok");
	add_script(&e.mc, 1, 10000, MEV_BATTERY, 4);
	add_script(&e.mc, 1, 20000, MEV_CRASH, 0);
	env_run(&e);
	CHECK(e.rc == SL_EXIT_POWER && e.m.n_modem_on == 1, "battery gate at reset: rc %d", e.rc);
	CHECK(last_kind(&e.m, R_IOCTL)->req == SL_IOCTL_MODEM_OFF, "MODEM_OFF last");
	expect_clean(&e);
	env_free(&e);
}

static void t_efuse_and_gates(void)
{
	struct env e;
	const struct mock_rec *first;

	/* SIGTERM right after cp_status rises: MODEM_OFF waits for the window */
	env_setup(&e, GEO_SMALL, "small/ok");
	add_script(&e.mc, 0, 1350, MEV_SIGTERM, 0);	/* 30 ms after cp_status = 1 */
	env_run(&e);
	CHECK(e.rc == 0, "sigterm in window: rc %d", e.rc);
	expect_clean(&e);	/* the mock checks MODEM_OFF >= rise + 3 s */
	CHECK(log_has("eFuse window: no 0xA00D yet"), "hold logged");
	CHECK(e.m.n_ring_writes == 0, "no std_udl word after SIGTERM");
	env_free(&e);

	/* CP alive from an earlier session: powered off first, outside its window */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.f_cp_alive_at_start = 1;
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	env_run(&e);
	first = first_ioctl(&e.m);
	CHECK(e.rc == 0 && first && first->req == SL_IOCTL_MODEM_OFF, "alive CP: rc %d", e.rc);
	CHECK(first && first->t_us >= 11000000u, "MODEM_OFF of the alive CP at %.3f s",
	      first ? (double)first->t_us / 1e6 : 0.0);
	CHECK(log_has("CP alive from an earlier session"), "alive CP logged");
	expect_clean(&e);
	env_free(&e);

	/* power gate */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.bat_capacity = 4;
	env_run(&e);
	CHECK(e.rc == SL_EXIT_POWER && e.m.n_ioctls == 0, "battery 4 %%: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.bat_temp = 400;
	env_run(&e);
	CHECK(e.rc == SL_EXIT_POWER && e.m.n_ioctls == 0, "40.0 degC: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.bat_missing = 1;
	env_run(&e);
	CHECK(e.rc == SL_EXIT_POWER && e.m.n_ioctls == 0, "no fuel gauge: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.bat_capacity = 5;
	e.mc.bat_temp = 399;
	e.cfg.stop_after = SL_RUNG_POWER;
	env_run(&e);
	CHECK(e.rc == 0, "5 %% / 39.9 degC accepted: rc %d", e.rc);
	CHECK(log_count("battery: capacity 5 %, temp 39.9 degC") >= 3,
	      "battery logged at preflight, start and end of the rung");
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.cfg.bat_max_deci_c = 450;
	e.mc.bat_temp = 449;
	e.cfg.stop_after = SL_RUNG_POWER;
	env_run(&e);
	CHECK(e.rc == 0, "--max-temp=45.0, 44.9 degC accepted: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.cfg.bat_max_deci_c = 450;
	e.mc.bat_temp = 450;
	env_run(&e);
	CHECK(e.rc == SL_EXIT_POWER && e.m.n_ioctls == 0, "--max-temp=45.0, 45.0 degC: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.cfg.bat_max_deci_c = 550;
	e.mc.bat_temp = 550;
	env_run(&e);
	CHECK(e.rc == SL_EXIT_POWER && e.m.n_ioctls == 0, "--max-temp=55.0, 55.0 degC: rc %d", e.rc);
	env_free(&e);

	/* allow_hw = N */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.allow_hw_value = "N";
	env_run(&e);
	CHECK(e.rc == SL_EXIT_ABI && e.m.n_ioctls == 0, "allow_hw N: rc %d", e.rc);
	env_free(&e);

	/* session numbering continues from an earlier loader process */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.state_initial = "session=41 state=online\n";
	e.cfg.stop_after = SL_RUNG_POWER;
	env_run(&e);
	CHECK(e.rc == 0 && e.m.nstates >= 3 &&
	      strcmp(e.m.states[0], "session=41 state=offline\n") == 0 &&
	      strcmp(e.m.states[1], "session=42 state=booting\n") == 0 &&
	      strcmp(e.m.states[e.m.nstates - 1], "session=42 state=offline\n") == 0,
	      "session resumes at 42");
	env_free(&e);
	/* dry run does not touch the state file */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.cfg.stop_after = SL_RUNG_PREFLIGHT;
	env_run(&e);
	CHECK(e.rc == 0 && e.m.nstates == 0, "dry run published a state");
	env_free(&e);
	/* the state file must stay under /run/ */
	{
		static const char *const bad[] = {
			"/var/lib/shannon/nv/cp-state", "/run/../var/lib/shannon/nv/x",
			"/efs/cp-state", "/run/shannon/", "/sys/bus/platform/x", "run/x",
		};
		size_t k;

		for (k = 0; k < sizeof(bad) / sizeof(bad[0]); k++) {
			env_setup(&e, GEO_SMALL, "small/ok");
			e.cfg.state_file = bad[k];
			env_run(&e);
			CHECK(e.rc == SL_EXIT_CONFIG && e.m.n_ioctls == 0 && e.m.nstates == 0,
			      "state file %s accepted (rc %d)", bad[k], e.rc);
			env_free(&e);
		}
	}

	/* configuration and discovery */
	env_setup(&e, GEO_SMALL, "small/ok");
	e.cfg.nv_path = "relative/nv_data.bin";
	env_run(&e);
	CHECK(e.rc == SL_EXIT_CONFIG && e.m.n_ioctls == 0, "relative path: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.lli_path = "/dev/mipi-lli/lli_control";
	e.mc.cp_status_path = "/sys/bus/platform/devices/mif_pdata/cp_status/value";
	e.cfg.stop_after = SL_RUNG_PREFLIGHT;
	env_run(&e);
	CHECK(e.rc == 0 && log_has("F1 lli_control: /dev/mipi-lli/lli_control") &&
	      log_has("devices/mif_pdata/cp_status/value"), "discovery fallbacks");
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.lli_path = "/nowhere/lli_control";
	env_run(&e);
	CHECK(e.rc == SL_EXIT_ABI && e.m.n_ioctls == 0, "lli missing: rc %d", e.rc);
	env_free(&e);
	env_setup(&e, GEO_SMALL, "small/ok");
	e.mc.boot_path = "/dev/other";
	env_run(&e);
	CHECK(e.rc == SL_EXIT_ABI && e.m.n_ioctls == 0, "boot dev missing: rc %d", e.rc);
	env_free(&e);
}

struct nvcase {
	const char *dir;
	enum sl_md5_policy pol;
	int blank;
	int rc;
	const char *log;
};

static void t_nv_policy(void)
{
	static const struct nvcase cases[] = {
		{ "small/ok", SL_MD5_WARN, 0, 0, "matches MD5(nv) (unsalted)" },
		{ "small/ok", SL_MD5_REQUIRE, 0, 0, "unsalted" },
		{ "small/salted", SL_MD5_WARN, 0, 0, "RIL salt" },
		{ "small/salted", SL_MD5_REQUIRE, 0, 0, "RIL salt" },
		{ "small/md5_none", SL_MD5_WARN, 0, 0, "matches neither" },
		{ "small/md5_none", SL_MD5_REQUIRE, 0, SL_EXIT_NV, "matches neither" },
		{ "small/md5_none", SL_MD5_OFF, 0, 0, "MD5 check disabled" },
		{ "small/md5_absent", SL_MD5_WARN, 0, 0, "absent" },
		{ "small/md5_absent", SL_MD5_REQUIRE, 0, SL_EXIT_NV, "unreadable" },
		{ "small/md5_malformed", SL_MD5_WARN, 0, 0, "not 32 hex digits" },
		{ "small/md5_malformed", SL_MD5_REQUIRE, 0, SL_EXIT_NV, "not 32 hex digits" },
		{ "small/md5_tampered", SL_MD5_WARN, 0, 0, "does not match its manifest entry" },
		{ "small/md5_tampered", SL_MD5_REQUIRE, 0, SL_EXIT_NV, "does not match" },
		{ "small/missing", SL_MD5_WARN, 0, SL_EXIT_NV, "is missing" },
		{ "small/short", SL_MD5_WARN, 0, SL_EXIT_NV, "no padding" },
		{ "small/long", SL_MD5_WARN, 0, SL_EXIT_NV, "no padding" },
		{ "small/ff", SL_MD5_WARN, 0, SL_EXIT_NV, "every byte is 0xFF" },
		{ "small/ff", SL_MD5_WARN, 1, 0, "WARNING: every byte is 0xFF" },
		{ "small/zero", SL_MD5_WARN, 0, SL_EXIT_NV, "every byte is 0x00" },
		{ "small/shabad", SL_MD5_WARN, 0, SL_EXIT_NV, "SHA-256 mismatch" },
		{ "small/nomanifest", SL_MD5_WARN, 0, SL_EXIT_NV, "manifest" },
		{ "small/noentry", SL_MD5_WARN, 0, SL_EXIT_NV, "no entry" },
		{ "small/dup", SL_MD5_WARN, 0, SL_EXIT_NV, "malformed or ambiguous" },
		{ "small/malformed", SL_MD5_WARN, 0, SL_EXIT_NV, "malformed or ambiguous" },
		{ "small/star", SL_MD5_WARN, 0, 0, "SHA-256 matches manifest" },
		{ "small/abspath", SL_MD5_WARN, 0, 0, "SHA-256 matches manifest" },
		{ "small/symlink", SL_MD5_WARN, 0, SL_EXIT_NV, "symbolic link" },
		{ "small/dir", SL_MD5_WARN, 0, SL_EXIT_NV, "not a regular file" },
	};
	size_t i;

	for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
		const struct nvcase *c = &cases[i];
		struct env e;
		struct stat st;
		int before = 0, after = 0;
		char dir[600];
		DIR *d;
		struct dirent *de;

		snprintf(dir, sizeof(dir), "%s/%s", g_fix, c->dir);
		d = opendir(dir);
		while (d && (de = readdir(d)) != NULL)
			before++;
		if (d)
			closedir(d);

		env_setup(&e, GEO_SMALL, c->dir);
		e.cfg.md5_policy = c->pol;
		e.cfg.allow_blank_nv = c->blank;
		e.cfg.stop_after = SL_RUNG_PREFLIGHT;
		env_run(&e);
		CHECK(e.rc == c->rc, "%s pol %d: rc %d (expected %d)", c->dir, c->pol, e.rc, c->rc);
		CHECK(log_has(c->log), "%s: log lacks \"%s\"", c->dir, c->log);
		CHECK(e.m.n_ioctls == 0, "%s: ioctl issued", c->dir);
		if (c->rc)
			CHECK(e.m.boot_opens == 0, "%s: boot device opened after a refusal", c->dir);
		d = opendir(dir);
		while (d && (de = readdir(d)) != NULL)
			after++;
		if (d)
			closedir(d);
		CHECK(before == after, "%s: directory changed (%d -> %d entries)", c->dir,
		      before, after);
		if (strcmp(c->dir, "small/missing") == 0)
			CHECK(stat(e.nv_path, &st) != 0 && errno == ENOENT,
			      "missing NV was created");
		env_free(&e);
	}

	/* Mode B: read-only filesystem required */
	{
		struct env e;

		env_setup(&e, GEO_SMALL, "small/ok");
		e.cfg.nv_mode = SL_NV_MODE_DIRECT;
		e.cfg.nv_manifest = NULL;
		e.cfg.stop_after = SL_RUNG_PREFLIGHT;
		env_run(&e);
		CHECK(e.rc == SL_EXIT_NV && log_has("mounted read-write"),
		      "mode B on a rw fs: rc %d", e.rc);
		CHECK(e.m.n_ioctls == 0, "mode B: ioctl issued");
		env_free(&e);

		env_setup(&e, GEO_SMALL, "small/ok");
		e.cfg.nv_mode = SL_NV_MODE_DIRECT;
		e.cfg.nv_manifest = NULL;
		e.cfg.stop_after = SL_RUNG_PREFLIGHT;
		e.mc.fake_ro_fs = 1;
		env_run(&e);
		CHECK(e.rc == 0 && log_has("read-only filesystem"), "mode B on a ro fs: rc %d", e.rc);
		env_free(&e);
	}

	/* stage 3 streams exactly the verified snapshot (checked by the mock) */
	{
		struct env e;
		uint8_t sha[32];

		env_setup(&e, GEO_SMALL, "small/salted");
		add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
		env_run(&e);
		CHECK(e.rc == 0, "salted boot rc %d", e.rc);
		expect_clean(&e);
		sl_sha256(e.nv, e.nvlen, sha);
		CHECK(e.m.n_ring_writes == 1 + 3 + (1 + 3 + 1 + 1) + (1 + 3 + 1) + 1,
		      "small writes %u", e.m.n_ring_writes);
		env_free(&e);
	}
}

/* optional: the real RADIO image, read in place (SL_REAL_RADIO) */
static void t_real_radio(void)
{
	const char *path = getenv("SL_REAL_RADIO");
	struct env e;
	struct sl_toc t;
	size_t pos = 0, len = 0;
	uint8_t *data;

	if (!path || !*path) {
		printf("    (skipped: SL_REAL_RADIO not set)\n");
		return;
	}
	env_setup(&e, GEO_SMALL, "real");
	img_free(&e.im);
	data = read_file(path, 0x2C00 + 0x21271A0, &len);
	if (!data || len < SL_TOC_BYTES) {
		CHECK(0, "cannot read %s", path);
		free(data);
		env_free(&e);
		return;
	}
	sl_toc_parse(data, &t);
	e.im.data = data;
	e.im.len = len;
	e.im.size = 92274688u;
	e.im.boot_off = t.e[1].offset;
	e.im.boot_size = t.e[1].size;
	e.im.main_off = t.e[2].offset;
	e.im.main_size = t.e[2].size;
	e.im.main_crc = t.e[2].crc;
	e.mc.image = data;
	e.mc.image_len = len;
	e.mc.image_size = e.im.size;
	e.production_pin = 1;		/* the shipped trust anchor */
	add_script(&e.mc, 1, 1000, MEV_SIGTERM, 0);
	env_run(&e);
	CHECK(e.rc == 0, "real RADIO with production pins: rc %d", e.rc);
	expect_clean(&e);
	g_nexp = 0;
	build_boot(0x29FC, 0x21271A0, 0x1E71169C, 0x100000);
	CHECK(compare_transcript(&e.m, &pos) == 0, "real RADIO transcript");
	CHECK(log_has("SHA-256 dd39fae36c2ccfbc28c3562c405962c827b2cf5d66f9e63d3fb90223dd0f94f4"),
	      "real BOOT matches the pinned SHA-256");
	env_free(&e);
}

/* the hand-written sd_notify client against a real datagram socket */
static void t_sd_notify(void)
{
	static const char *const names[2] = { "path", "abstract" };
	int k;

	for (k = 0; k < 2; k++) {
		struct sl_linux_ctx lctx;
		struct sl_ops ops;
		struct sockaddr_un sa;
		socklen_t len;
		char buf[128];
		ssize_t n;
		int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);

		CHECK(fd >= 0, "socket");
		if (fd < 0)
			return;
		memset(&sa, 0, sizeof(sa));
		sa.sun_family = AF_UNIX;
		if (k == 0) {
			snprintf(sa.sun_path, sizeof(sa.sun_path), "/tmp/sl-notify-%d", (int)getpid());
			len = (socklen_t)sizeof(sa);
		} else {
			snprintf(sa.sun_path + 1, sizeof(sa.sun_path) - 1, "sl-notify-%d", (int)getpid());
			len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 +
					  strlen(sa.sun_path + 1));
		}
		CHECK(bind(fd, (struct sockaddr *)&sa, len) == 0, "bind %s", names[k]);
		sl_ops_linux_init(&ops, &lctx);
		if (k == 0)
			snprintf(lctx.notify_socket, sizeof(lctx.notify_socket), "%s", sa.sun_path);
		else
			snprintf(lctx.notify_socket, sizeof(lctx.notify_socket), "@%s", sa.sun_path + 1);
		CHECK(ops.notify(ops.ctx, "READY=1\nSTATUS=CP online") == 0, "notify %s", names[k]);
		n = recv(fd, buf, sizeof(buf) - 1, MSG_DONTWAIT);
		CHECK(n == 24 && memcmp(buf, "READY=1\nSTATUS=CP online", 24) == 0,
		      "%s socket received %zd bytes", names[k], n);
		close(fd);
		if (k == 0)
			unlink(sa.sun_path);
		lctx.notify_socket[0] = '\0';
		CHECK(ops.notify(ops.ctx, "READY=1") == 0, "no NOTIFY_SOCKET: no-op");
	}
}

struct tcase {
	const char *name;
	void (*fn)(void);
};

static const struct tcase tests[] = {
	{ "units", t_units },
	{ "mock_selftest", t_mock_selftest },
	{ "golden_real_geometry", t_golden_real },
	{ "golden_small_daemon_after_ready", t_golden_small },
	{ "stop_after_ladder", t_rungs },
	{ "matrix_image", t_matrix_image },
	{ "matrix_boot", t_matrix_boot },
	{ "supervisor", t_supervisor },
	{ "efuse_window_and_gates", t_efuse_and_gates },
	{ "nv_policy", t_nv_policy },
	{ "sd_notify_socket", t_sd_notify },
	{ "real_radio_optional", t_real_radio },
};

int main(int argc, char **argv)
{
	size_t i;

	if (argc < 2) {
		fprintf(stderr, "usage: test_loader FIXTURE_DIR [filter]\n");
		return 2;
	}
	g_fix = argv[1];
	g_filter = argc > 2 ? argv[2] : NULL;
	g_verbose = getenv("SL_TEST_VERBOSE") != NULL;
	g_logcap = 1 << 16;
	g_log = calloc(1, g_logcap);
	if (!g_log)
		return 1;

	for (i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		if (g_filter && !strstr(tests[i].name, g_filter))
			continue;
		g_case_fail = 0;
		g_cases++;
		tests[i].fn();
		if (g_case_fail) {
			g_failed_cases++;
			printf("FAIL %s (%d checks)\n", tests[i].name, g_case_fail);
			if (!g_verbose && g_log)
				fprintf(stderr, "---- last loader log ----\n%s-------------------------\n",
					g_log);
		} else {
			printf("PASS %s\n", tests[i].name);
		}
	}
	printf("%d/%d test groups passed\n", g_cases - g_failed_cases, g_cases);
	free(g_log);
	free(g_exp);
	return g_failed_cases ? 1 : 0;
}
