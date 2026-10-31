// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: preflight, boot attempt (B1-B17), stage engine and
 * supervisor for the Shannon SS333 CP of the SM-T715.
 *
 * Specification: SYNTHESIS.md 2.6-2.9 and D4; loader_spec_v2.md (LS2) 4, 7,
 * 9. Written from those documents only.
 *
 * Safety rules enforced in this file (SYNTHESIS 5):
 *  - ioctls go through sl_ioctl(), which refuses every request that is not
 *    on a short allow-list; the dump, crash and upload requests are not on
 *    it and have no name in this program;
 *  - lli_control and cp_status are only ever read (ops->sysfs_read);
 *  - every std_udl word is checked by udl_word_ok() before it is written:
 *    direction AP->CP, stage 0-3 or FIN, CRC step only for MAIN;
 *  - the BOOT bytes sent over SPI are the RADIO BOOT entry, read once,
 *    CRC-checked against the pinned stock value and re-checked before every
 *    attempt;
 *  - every failed attempt ends with MODEM_OFF; at most 3 attempts per boot
 *    cycle, at most 5 silent resets in 30 minutes, and a second rejection of
 *    MAIN by the CP stops the loader.
 */
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "sl_crc32.h"
#include "sl_loader.h"
#include "sl_log.h"
#include "sl_md5.h"
#include "sl_sha256.h"

#define RD_BUF_SIZE	(64u * 1024u)
#define SL_CONTINUE	(-1)

/* ------------------------------------------------------------------ */
/* ioctl allow-list                                                     */
/* ------------------------------------------------------------------ */

static const struct {
	unsigned long req;
	const char *name;
} ioctl_table[] = {
	{ SL_IOCTL_MODEM_ON, "MODEM_ON" },
	{ SL_IOCTL_MODEM_OFF, "MODEM_OFF" },
	{ SL_IOCTL_MODEM_BOOT_ON, "BOOT_ON" },
	{ SL_IOCTL_MODEM_BOOT_OFF, "BOOT_OFF" },
	{ SL_IOCTL_MODEM_BOOT_DONE, "BOOT_DONE" },
	{ SL_IOCTL_MODEM_STATUS, "STATUS" },
	{ SL_IOCTL_MODEM_DL_START, "DL_START" },
	{ SL_IOCTL_MODEM_FW_UPDATE, "FW_UPDATE" },
	{ SL_IOCTL_MODEM_SET_TX_LINK, "SET_TX_LINK" },
	{ SL_IOCTL_MODEM_GET_CP_BOOTLOG, "GET_CP_BOOTLOG" },
	{ SL_IOCTL_MODEM_CLR_CP_BOOTLOG, "CLR_CP_BOOTLOG" },
};

int sl_ioctl_allowed(unsigned long req)
{
	size_t i;

	for (i = 0; i < sizeof(ioctl_table) / sizeof(ioctl_table[0]); i++) {
		if (ioctl_table[i].req == req)
			return 1;
	}
	return 0;
}

static const char *ioctl_name(unsigned long req)
{
	size_t i;

	for (i = 0; i < sizeof(ioctl_table) / sizeof(ioctl_table[0]); i++) {
		if (ioctl_table[i].req == req)
			return ioctl_table[i].name;
	}
	return "?";
}

int sl_ioctl(struct sl_loader *L, unsigned long req, void *arg)
{
	if (!sl_ioctl_allowed(req)) {
		sl_err("BUG: ioctl 0x%lX is not on the allow-list: refused", req);
		return -EPERM;
	}
	if (L->boot_fd < 0)
		return -EBADF;
	return L->ops->boot_ioctl(L->ops->ctx, L->boot_fd, req, arg);
}

/* ------------------------------------------------------------------ */
/* small helpers                                                        */
/* ------------------------------------------------------------------ */

static const char *const rung_names[] = {
	"none", "preflight", "power", "spi", "lli", "stage0", "toc", "main",
	"nv", "fin", "online",
};

const char *sl_rung_name(enum sl_rung r)
{
	if ((unsigned int)r < sizeof(rung_names) / sizeof(rung_names[0]))
		return rung_names[r];
	return "?";
}

int sl_rung_parse(const char *s, enum sl_rung *out)
{
	unsigned int i;

	for (i = 1; i < sizeof(rung_names) / sizeof(rung_names[0]); i++) {
		if (strcmp(s, rung_names[i]) == 0) {
			*out = (enum sl_rung)i;
			return 0;
		}
	}
	return -1;
}

static const char *state_name(int s)
{
	static const char *const n[] = {
		"OFFLINE", "CRASH_RESET", "CRASH_EXIT", "BOOTING", "ONLINE",
		"NV_REBUILDING", "LOADER_DONE", "SIM_ATTACH", "SIM_DETACH",
	};

	if (s >= 0 && (size_t)s < sizeof(n) / sizeof(n[0]))
		return n[s];
	return "UNKNOWN";
}

static const char *stage_name(unsigned int s)
{
	switch (s) {
	case SL_STAGE_BOOT: return "BOOT";
	case SL_STAGE_TOC: return "TOC";
	case SL_STAGE_MAIN: return "MAIN";
	case SL_STAGE_NV: return "NV";
	case SL_STAGE_FIN: return "FIN";
	default: return "?";
	}
}

static void put_le32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t now_us(struct sl_loader *L)
{
	return L->ops->now_us(L->ops->ctx);
}

static uint64_t now_ms(struct sl_loader *L)
{
	return now_us(L) / 1000u;
}

static int stopping(struct sl_loader *L)
{
	return L->stop && *L->stop;
}

static double secs(uint64_t us)
{
	return (double)us / 1e6;
}

/* sleep in slices so that SIGTERM is honoured quickly */
static int sl_sleep(struct sl_loader *L, unsigned int ms)
{
	while (ms > 0) {
		unsigned int s = ms > 100 ? 100 : ms;

		if (stopping(L))
			return -EINTR;
		L->ops->sleep_ms(L->ops->ctx, s);
		ms -= s;
	}
	return stopping(L) ? -EINTR : 0;
}

static void notify(struct sl_loader *L, const char *msg)
{
	int r = L->ops->notify(L->ops->ctx, msg);

	if (r < 0)
		sl_warn("sd_notify failed: %s", strerror(-r));
}

/* CP state file for the daemons: session=<N> state=<...> */
static void publish(struct sl_loader *L, const char *state)
{
	char buf[64];
	int r;

	L->state = state;
	snprintf(buf, sizeof(buf), "session=%u state=%s\n", L->session, state);
	r = L->ops->state_publish(L->ops->ctx, buf);
	if (r < 0)
		sl_warn("state file not updated (%s): %s", state, strerror(-r));
	else
		sl_dbg("state: session=%u state=%s", L->session, state);
}

static void hexdump(const uint8_t *p, size_t n, char *out, size_t outlen)
{
	size_t i, o = 0;

	out[0] = '\0';
	for (i = 0; i < n && o + 4 < outlen; i++)
		o += (size_t)snprintf(out + o, outlen - o, "%s%02X", i ? " " : "", p[i]);
}

/* ioctl with one log line: step, name, result, duration */
static int do_ioctl(struct sl_loader *L, const char *step, unsigned long req,
		    void *arg, const char *argdesc)
{
	uint64_t t0 = now_us(L);
	int r = sl_ioctl(L, req, arg);
	uint64_t dt = now_us(L) - t0;

	if (r >= 0)
		sl_info("%s %s%s -> %d (%.3f s)", step, ioctl_name(req),
			argdesc ? argdesc : "", r, secs(dt));
	else
		sl_info("%s %s%s -> error %s (%.3f s)", step, ioctl_name(req),
			argdesc ? argdesc : "", strerror(-r), secs(dt));
	return r;
}

static int set_tx_link(struct sl_loader *L, const char *step, int link)
{
	int v = link;

	return do_ioctl(L, step, SL_IOCTL_MODEM_SET_TX_LINK, &v,
			link == SL_LINK_LLI ? "(10=LLI)" : "(3=SPI)");
}

static void trim(char *s);

/*
 * eFuse window (review D4-a, rule 1): once BOOT runs (cp_status = 1) it may
 * compare and program CP eFuse slots. No power-off or reset of the CP until
 * 0xA00D has been received or SL_T_EFUSE_MS have elapsed since cp_status
 * was seen at 1. This wait ignores SIGTERM on purpose.
 */
static void efuse_hold(struct sl_loader *L)
{
	uint64_t end, now;

	if (!L->efuse_open)
		return;
	if (!L->efuse_seen_cp_status && L->cp_status_path[0]) {
		char buf[32];

		/* cp_status may have risen after the B8 deadline */
		if (L->ops->sysfs_read(L->ops->ctx, L->cp_status_path, buf,
				       sizeof(buf)) >= 0) {
			trim(buf);
			if (strcmp(buf, "1") == 0) {
				L->efuse_seen_cp_status = 1;
				L->efuse_start_us = now_us(L);
				sl_warn("cp_status reads 1 after the B8 deadline");
			}
		}
	}
	if (L->efuse_seen_cp_status) {
		end = L->efuse_start_us + (uint64_t)SL_T_EFUSE_MS * 1000u;
		now = now_us(L);
		if (now < end) {
			sl_notice("eFuse window: no 0xA00D yet, holding MODEM_OFF for %llu ms",
				  (unsigned long long)((end - now + 999u) / 1000u));
			while ((now = now_us(L)) < end) {
				uint64_t left_ms = (end - now + 999u) / 1000u;

				L->ops->sleep_ms(L->ops->ctx,
						 left_ms > 100 ? 100u : (unsigned int)left_ms);
			}
		}
	}
	L->efuse_open = 0;
	L->efuse_seen_cp_status = 0;
}

static void modem_off(struct sl_loader *L)
{
	efuse_hold(L);
	do_ioctl(L, "--", SL_IOCTL_MODEM_OFF, NULL, NULL);
	publish(L, "offline");
}

static int read_long(struct sl_loader *L, const char *path, long *v)
{
	char buf[64], *end;
	long n;

	if (!path)
		return -ENOENT;
	n = L->ops->sysfs_read(L->ops->ctx, path, buf, sizeof(buf));
	if (n < 0)
		return (int)n;
	trim(buf);
	errno = 0;
	*v = strtol(buf, &end, 10);
	if (errno || end == buf || *end != '\0')
		return -EINVAL;
	return 0;
}

/*
 * Battery and thermal gate (review rule 1 and 22): capacity >= 5 % (50 % until
 * the owner lowered it on 2026-10-31) and temperature below the limit (40.0
 * degC, or --max-temp up to 55.0) before any CP power-on. Logged at the start
 * and at the end of every attempt (rung).
 */
static int power_gate(struct sl_loader *L, const char *when, int enforce)
{
	const struct sl_config *c = L->cfg;
	long cap = 0, temp = 0, cur = 0;
	long max = c->bat_max_deci_c ? c->bat_max_deci_c : SL_BAT_MAX_DECI_C;
	int rc_c = read_long(L, c->bat_capacity, &cap);
	int rc_t = read_long(L, c->bat_temp, &temp);
	int rc_i = read_long(L, c->bat_current, &cur);
	char sc[24] = "?", st[24] = "?", si[24] = "?";

	if (rc_c == 0)
		snprintf(sc, sizeof(sc), "%ld", cap);
	if (rc_t == 0)
		snprintf(st, sizeof(st), "%ld.%ld", temp / 10, (temp < 0 ? -temp : temp) % 10);
	if (rc_i == 0)
		snprintf(si, sizeof(si), "%ld", cur);
	sl_info("%s battery: capacity %s %%, temp %s degC, current_now %s uA",
		when, sc, st, si);
	if (!enforce)
		return 0;
	if (rc_c < 0 || rc_t < 0) {
		sl_err("%s power gate: battery capacity/temperature unreadable: "
		       "refusing CP power-on", when);
		return SL_EXIT_POWER;
	}
	if (cap < SL_BAT_MIN_PERCENT) {
		sl_err("%s power gate: battery %ld %% < %d %%: refusing CP power-on",
		       when, cap, SL_BAT_MIN_PERCENT);
		return SL_EXIT_POWER;
	}
	if (temp >= max) {
		sl_err("%s power gate: battery temperature %s degC >= %ld.%ld: refusing CP power-on",
		       when, st, max / 10, max % 10);
		return SL_EXIT_POWER;
	}
	return 0;
}

static int modem_status(struct sl_loader *L, const char *step)
{
	int s = do_ioctl(L, step, SL_IOCTL_MODEM_STATUS, NULL, NULL);

	if (s >= 0)
		sl_info("%s modem state %d (%s)", step, s, state_name(s));
	return s;
}

/* ------------------------------------------------------------------ */
/* configuration                                                        */
/* ------------------------------------------------------------------ */

static int abs_path_ok(const char *what, const char *p, int optional)
{
	if (!p)
		return optional ? 0 : -1;
	if (p[0] != '/' || strlen(p) >= 240) {
		sl_err("config: %s must be an absolute path shorter than 240 bytes: \"%s\"",
		       what, p);
		return -1;
	}
	return 0;
}

int sl_config_check(const struct sl_config *c)
{
	if (abs_path_ok("boot device", c->boot_dev, 0) ||
	    abs_path_ok("ipc device", c->ipc_dev, 0) ||
	    abs_path_ok("rfs device", c->rfs_dev, 0) ||
	    abs_path_ok("image", c->image, 0) ||
	    abs_path_ok("lli_control", c->lli_control, 1) ||
	    abs_path_ok("cp_status", c->cp_status, 1) ||
	    abs_path_ok("NV file", c->nv_path, 0) ||
	    abs_path_ok("NV manifest", c->nv_manifest, 1) ||
	    abs_path_ok("NV md5 file", c->nv_md5, 1))
		return SL_EXIT_CONFIG;
	if (c->nv_mode == SL_NV_MODE_COPY && !c->nv_manifest) {
		sl_err("config: NV mode copy needs a manifest");
		return SL_EXIT_CONFIG;
	}
	if (abs_path_ok("battery capacity", c->bat_capacity, 0) ||
	    abs_path_ok("battery temp", c->bat_temp, 0) ||
	    abs_path_ok("battery current", c->bat_current, 1) ||
	    abs_path_ok("allow_hw parameter", c->allow_hw, 0))
		return SL_EXIT_CONFIG;
	if (c->state_file && !sl_state_path_ok(c->state_file)) {
		sl_err("config: the state file must be under /run/ without \"..\": \"%s\"",
		       c->state_file);
		return SL_EXIT_CONFIG;
	}
	if (c->max_attempts < 1 || c->max_attempts > SL_ATTEMPTS_MAX) {
		sl_err("config: attempts must be 1..%d", SL_ATTEMPTS_MAX);
		return SL_EXIT_CONFIG;
	}
	return 0;
}

int sl_parse_sha256_hex(const char *hex, uint8_t out[32])
{
	size_t i;

	if (!hex || strlen(hex) != 64)
		return -1;
	for (i = 0; i < 64; i++) {
		char c = hex[i];
		int v = (c >= '0' && c <= '9') ? c - '0' :
			(c >= 'a' && c <= 'f') ? c - 'a' + 10 :
			(c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;

		if (v < 0)
			return -1;
		if (i % 2 == 0)
			out[i / 2] = (uint8_t)(v << 4);
		else
			out[i / 2] |= (uint8_t)v;
	}
	return 0;
}

void sl_loader_init(struct sl_loader *L, const struct sl_config *cfg,
		    const struct sl_ops *ops, volatile sig_atomic_t *stop)
{
	memset(L, 0, sizeof(*L));
	L->cfg = cfg;
	L->ops = ops;
	L->stop = stop;
	L->img_fd = -1;
	L->boot_fd = -1;
	L->ipc_fd = -1;
	L->rfs_fd = -1;
	/* production trust anchor; only test code replaces it */
	if (sl_parse_sha256_hex(SL_BOOT_SHA256_PINNED_HEX, L->pin_boot_sha256) != 0)
		memset(L->pin_boot_sha256, 0, sizeof(L->pin_boot_sha256));
}

/* Page-aligned buffers: sealed read-only (and locked in RAM when allowed)
 * once verified, so that what was checked is what is sent. */
uint8_t *sl_buf_alloc(size_t len, size_t *alloc_len)
{
	long pg = sysconf(_SC_PAGESIZE);
	size_t page = pg > 0 ? (size_t)pg : 4096u;
	size_t n = (len + page - 1) / page * page;
	void *p = NULL;

	if (n == 0 || posix_memalign(&p, page, n) != 0)
		return NULL;
	memset(p, 0, n);
	*alloc_len = n;
	return p;
}

void sl_buf_seal(uint8_t *buf, size_t alloc_len)
{
	if (!buf)
		return;
	if (mprotect(buf, alloc_len, PROT_READ) != 0)
		sl_warn("cannot seal a buffer read-only: %s", strerror(errno));
	if (mlock(buf, alloc_len) != 0)
		sl_dbg("mlock: %s (buffer not locked in RAM)", strerror(errno));
}

void sl_buf_free(uint8_t *buf, size_t alloc_len)
{
	if (!buf)
		return;
	munlock(buf, alloc_len);
	mprotect(buf, alloc_len, PROT_READ | PROT_WRITE);
	memset(buf, 0, alloc_len);
	free(buf);
}

/* BOOT buffer must match both pins; checked in F4, before every attempt and
 * right before the SPI write. */
static int boot_buf_ok(struct sl_loader *L, uint32_t *crc_out, uint8_t sha[32])
{
	const struct sl_toc_entry *boot = &L->toc.e[SL_SLOT_BOOT];
	uint32_t crc = sl_crc32_update(0, L->boot_buf, boot->size);

	sl_sha256(L->boot_buf, boot->size, sha);
	if (crc_out)
		*crc_out = crc;
	return crc == SL_BOOT_CRC_PINNED && crc == boot->crc &&
	       memcmp(sha, L->pin_boot_sha256, 32) == 0;
}

static void close_holders(struct sl_loader *L)
{
	if (L->ipc_fd >= 0) {
		L->ops->close_fd(L->ops->ctx, L->ipc_fd);
		sl_info("closed %s", L->cfg->ipc_dev);
		L->ipc_fd = -1;
	}
	if (L->rfs_fd >= 0) {
		L->ops->close_fd(L->ops->ctx, L->rfs_fd);
		sl_info("closed %s", L->cfg->rfs_dev);
		L->rfs_fd = -1;
	}
}

void sl_loader_free(struct sl_loader *L)
{
	close_holders(L);
	if (L->boot_fd >= 0)
		L->ops->close_fd(L->ops->ctx, L->boot_fd);
	if (L->img_fd >= 0)
		L->ops->close_fd(L->ops->ctx, L->img_fd);
	L->boot_fd = L->img_fd = -1;
	sl_buf_free(L->boot_buf, L->boot_alloc);
	free(L->rd_buf);
	sl_buf_free(L->nv_buf, L->nv_alloc);
	L->boot_buf = L->rd_buf = L->nv_buf = NULL;
	L->boot_alloc = L->nv_alloc = 0;
}

/* ------------------------------------------------------------------ */
/* preflight F1-F7 (no CP power change, no ioctl)                       */
/* ------------------------------------------------------------------ */

static const char *const lli_candidates[] = {
	"/sys/bus/platform/devices/10f24000.mipi-lli/lli_control",
	"/dev/mipi-lli/lli_control",
	"/sys/devices/10f24000.mipi-lli/lli_control",
	"/sys/devices/platform/10f24000.mipi-lli/lli_control",
};

static const char *const cp_status_globs[] = {
	"/sys/bus/platform/drivers/mif_sipc5/*mif_pdata*/cp_status/value",
	"/sys/bus/platform/drivers/mif_sipc5/*mif_sipc5*/cp_status/value",
	"/sys/bus/platform/devices/mif_pdata*/cp_status/value",
	"/sys/bus/platform/devices/*mif_pdata*/cp_status/value",
};

static void trim(char *s)
{
	size_t n = strlen(s);

	while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == ' ' ||
			 s[n - 1] == '\t' || s[n - 1] == '\r'))
		s[--n] = '\0';
	while (s[0] == ' ' || s[0] == '\t')
		memmove(s, s + 1, strlen(s));
}

static int resolve_paths(struct sl_loader *L)
{
	const struct sl_ops *o = L->ops;
	const struct sl_config *c = L->cfg;
	struct sl_stat st;
	size_t i;

	if (c->lli_control) {
		snprintf(L->lli_path, sizeof(L->lli_path), "%s", c->lli_control);
	} else {
		for (i = 0; i < sizeof(lli_candidates) / sizeof(lli_candidates[0]); i++) {
			if (o->path_stat(o->ctx, lli_candidates[i], &st) == 0) {
				snprintf(L->lli_path, sizeof(L->lli_path), "%s",
					 lli_candidates[i]);
				break;
			}
		}
		if (!L->lli_path[0]) {
			sl_err("F1: no lli_control attribute found (mipi-lli driver missing?)");
			return SL_EXIT_ABI;
		}
	}
	if (c->cp_status) {
		snprintf(L->cp_status_path, sizeof(L->cp_status_path), "%s", c->cp_status);
	} else {
		for (i = 0; i < sizeof(cp_status_globs) / sizeof(cp_status_globs[0]); i++) {
			if (o->path_glob(o->ctx, cp_status_globs[i], L->cp_status_path,
					 sizeof(L->cp_status_path)) == 0)
				break;
			L->cp_status_path[0] = '\0';
		}
		if (!L->cp_status_path[0]) {
			sl_err("F1: no cp_status/value attribute found (modem_v1 driver missing?)");
			return SL_EXIT_ABI;
		}
	}
	sl_info("F1 lli_control: %s", L->lli_path);
	sl_info("F1 cp_status:   %s", L->cp_status_path);
	return 0;
}

static int pread_exact(struct sl_loader *L, int fd, void *buf, size_t len,
		       uint64_t off)
{
	size_t got = 0;

	while (got < len) {
		long n = L->ops->ro_pread(L->ops->ctx, fd, (uint8_t *)buf + got,
					  len - got, off + got);
		if (n < 0)
			return (int)n;
		if (n == 0)
			return -EIO;	/* truncated */
		got += (size_t)n;
	}
	return 0;
}

static int image_checks(struct sl_loader *L)
{
	const struct sl_ops *o = L->ops;
	const struct sl_toc_entry *boot, *mainp;
	struct sl_stat st;
	char why[160];
	uint32_t crc;
	uint64_t off;
	unsigned int i;
	int fd, r;

	/* F2 */
	fd = o->ro_open(o->ctx, L->cfg->image, 0);
	if (fd < 0) {
		sl_err("F2: cannot open image %s read-only: %s", L->cfg->image,
		       strerror(-fd));
		return SL_EXIT_IMAGE;
	}
	L->img_fd = fd;
	r = o->ro_fstat(o->ctx, fd, &st);
	if (r < 0 || (st.type != SL_FT_BLK && st.type != SL_FT_REG)) {
		sl_err("F2: image %s is not a block device or regular file", L->cfg->image);
		return SL_EXIT_IMAGE;
	}
	L->img_size = st.size;
	if (L->img_size < SL_TOC_BYTES) {
		sl_err("F2: image is %llu bytes, smaller than a TOC",
		       (unsigned long long)L->img_size);
		return SL_EXIT_IMAGE;
	}
	r = pread_exact(L, fd, L->toc_raw, SL_TOC_BYTES, 0);
	if (r < 0) {
		sl_err("F2: cannot read the TOC: %s", strerror(-r));
		return SL_EXIT_IMAGE;
	}

	/* F3 */
	sl_toc_parse(L->toc_raw, &L->toc);
	for (i = 0; i < SL_TOC_SLOTS; i++) {
		const struct sl_toc_entry *e = &L->toc.e[i];

		if (i >= 4 && e->name[0] == '\0')
			continue;
		sl_info("F3 TOC[%u] %-8.12s offset 0x%08X load 0x%08X size 0x%08X crc 0x%08X",
			i, e->name, e->offset, e->load_addr, e->size, e->crc);
	}
	if (sl_toc_validate(&L->toc, L->img_size, why, sizeof(why)) != 0) {
		sl_err("F3: TOC refused: %s", why);
		return SL_EXIT_IMAGE;
	}

	/* F4: BOOT, kept in memory; this buffer is what goes over SPI */
	boot = &L->toc.e[SL_SLOT_BOOT];
	L->boot_buf = sl_buf_alloc(boot->size, &L->boot_alloc);
	if (!L->boot_buf)
		return SL_EXIT_INTERNAL;
	r = pread_exact(L, fd, L->boot_buf, boot->size, boot->offset);
	if (r < 0) {
		sl_err("F4: cannot read BOOT: %s", strerror(-r));
		return SL_EXIT_IMAGE;
	}
	{
		uint8_t sha[32];
		char hex[65];

		if (!boot_buf_ok(L, &crc, sha)) {
			sl_hex(sha, 32, hex);
			sl_err("F4: BOOT is not the pinned stock BOOT (CRC32 0x%08X, TOC 0x%08X, "
			       "pinned 0x%08X; SHA-256 %s): refused",
			       crc, boot->crc, SL_BOOT_CRC_PINNED, hex);
			return SL_EXIT_IMAGE;
		}
		sl_hex(sha, 32, hex);
		sl_info("F4 BOOT %u bytes, CRC32 0x%08X, SHA-256 %s (pinned stock BOOT)",
			boot->size, crc, hex);
		sl_buf_seal(L->boot_buf, L->boot_alloc);	/* read-only from here on */
	}

	/* MAIN CRC before any power-on (re-checked while streaming) */
	mainp = &L->toc.e[SL_SLOT_MAIN];
	L->rd_buf = malloc(RD_BUF_SIZE);
	if (!L->rd_buf)
		return SL_EXIT_INTERNAL;
	crc = 0;
	for (off = 0; off < mainp->size; ) {
		size_t n = mainp->size - off > RD_BUF_SIZE ? RD_BUF_SIZE :
			   (size_t)(mainp->size - off);

		r = pread_exact(L, fd, L->rd_buf, n, mainp->offset + off);
		if (r < 0) {
			sl_err("F4: cannot read MAIN: %s", strerror(-r));
			return SL_EXIT_IMAGE;
		}
		crc = sl_crc32_update(crc, L->rd_buf, n);
		off += n;
	}
	if (crc != mainp->crc) {
		sl_err("F4: MAIN CRC32 0x%08X != TOC 0x%08X: refused", crc, mainp->crc);
		return SL_EXIT_IMAGE;
	}
	sl_info("F4 MAIN %u bytes, CRC32 0x%08X matches the TOC", mainp->size, crc);
	return 0;
}

static int device_checks(struct sl_loader *L)
{
	const struct sl_ops *o = L->ops;
	const struct sl_config *c = L->cfg;
	struct sl_stat st;
	char buf[64];
	long n;
	int fd;

	/* F6 */
	if (o->path_stat(o->ctx, c->boot_dev, &st) != 0 || st.type != SL_FT_CHR) {
		sl_err("F6: %s is missing or not a character device", c->boot_dev);
		return SL_EXIT_ABI;
	}
	if (o->path_stat(o->ctx, c->ipc_dev, &st) != 0 || st.type != SL_FT_CHR ||
	    o->path_stat(o->ctx, c->rfs_dev, &st) != 0 || st.type != SL_FT_CHR) {
		sl_err("F6: %s and %s must exist as character devices (held after BOOT_OFF)",
		       c->ipc_dev, c->rfs_dev);
		return SL_EXIT_ABI;
	}
	n = o->sysfs_read(o->ctx, L->lli_path, buf, sizeof(buf));
	if (n < 0) {
		sl_err("F6: cannot read %s: %s", L->lli_path, strerror((int)-n));
		return SL_EXIT_ABI;
	}
	trim(buf);
	sl_info("F6 lli_control = \"%s\" (expected \"MIPI-LLI 0\" before power-on)", buf);
	n = o->sysfs_read(o->ctx, L->cp_status_path, buf, sizeof(buf));
	if (n < 0) {
		sl_err("F6: cannot read %s: %s", L->cp_status_path, strerror((int)-n));
		return SL_EXIT_ABI;
	}
	trim(buf);
	sl_info("F6 cp_status = \"%s\" (expected \"0\" before power-on)", buf);
	if (strcmp(buf, "1") == 0)
		sl_warn("F6 cp_status is 1: a CP is alive from an earlier session "
			"(it will be powered off before B1)");
	/* review D4-e: the kernel's hardware gate must be open */
	n = o->sysfs_read(o->ctx, c->allow_hw, buf, sizeof(buf));
	if (n < 0) {
		sl_err("F6: cannot read %s: %s", c->allow_hw, strerror((int)-n));
		return SL_EXIT_ABI;
	}
	trim(buf);
	if (strcmp(buf, "Y") != 0 && strcmp(buf, "1") != 0) {
		sl_err("F6: %s = \"%s\": the modem driver refuses hardware side effects "
		       "(set allow_hw=1 first)", c->allow_hw, buf);
		return SL_EXIT_ABI;
	}
	sl_info("F6 allow_hw = %s", buf);

	/* F7: kept open for the life of the process */
	fd = o->boot_open(o->ctx, c->boot_dev);
	if (fd < 0) {
		sl_err("F7: cannot open %s: %s", c->boot_dev, strerror(-fd));
		return SL_EXIT_ABI;
	}
	L->boot_fd = fd;
	sl_info("F7 %s open", c->boot_dev);
	return 0;
}

int sl_preflight(struct sl_loader *L)
{
	int rc;

	sl_notice("shannon-loader %s: preflight (no hardware side effect)", SL_VERSION);
	rc = resolve_paths(L);
	if (rc)
		return rc;
	rc = image_checks(L);
	if (rc)
		return rc;
	rc = sl_nv_load(L);		/* F5 */
	if (rc)
		return rc;
	rc = device_checks(L);
	if (rc)
		return rc;
	rc = power_gate(L, "F8", 1);
	if (rc)
		return rc;
	sl_notice("preflight OK");
	return 0;
}

/* ------------------------------------------------------------------ */
/* boot attempt                                                         */
/* ------------------------------------------------------------------ */

enum att {
	ATT_OK,
	ATT_POWER,		/* battery/thermal gate refused the power-on */
	ATT_FAIL,
	ATT_REJECTED,		/* CP_STAGE_FAIL on MAIN */
	ATT_RUNG,		/* --stop-after rung reached */
	ATT_STOP,		/* SIGTERM */
	ATT_FATAL_IMAGE,
	ATT_FATAL_NV,
	ATT_INTERNAL,
};

/* Only words the protocol allows: AP->CP, stage 0-3 or FIN, steps
 * START/SEND/CRC/DONE, CRC only on MAIN, FIN only as 0x9F00. */
static int udl_word_ok(uint32_t w)
{
	uint32_t stage = (w & SL_UDL_STAGE_MASK) >> SL_UDL_STAGE_SHIFT;
	uint32_t step = w & SL_UDL_STEP_MASK;

	if ((w & ~0xFFFFu) != 0 || (w & SL_UDL_DIR_MASK) != SL_UDL_AP2CP)
		return 0;
	if ((w & 0x00F0u) != 0)
		return 0;
	if (stage > SL_STAGE_NV && stage != SL_STAGE_FIN)
		return 0;
	if (stage == SL_STAGE_FIN)
		return step == SL_STEP_START;
	if (step == SL_STEP_CRC)
		return stage == SL_STAGE_MAIN;
	return step == SL_STEP_START || step == SL_STEP_SEND || step == SL_STEP_DONE;
}

static long boot_write(struct sl_loader *L, const void *buf, size_t len)
{
	return L->ops->boot_write(L->ops->ctx, L->boot_fd, buf, len);
}

/*
 * Request/response primitive (LS2 4.3). `req` == 0 means response only.
 */
static enum att udl_xchg(struct sl_loader *L, uint32_t req, uint32_t expect,
			 unsigned int stage, int *hup)
{
	const struct sl_ops *o = L->ops;
	const char *sn = stage_name(stage);
	uint8_t b[16];
	uint64_t t0, deadline;
	char hex[64];

	if (req) {
		long n;

		if (!udl_word_ok(req)) {
			sl_err("BUG: refusing to send std_udl word 0x%04X", req);
			return ATT_INTERNAL;
		}
		put_le32(b, req);
		n = boot_write(L, b, 4);
		if (n != 4) {
			sl_err("%-4s -> 0x%04X: write returned %ld (%s)", sn, req, n,
			       n < 0 ? strerror((int)-n) : "short");
			return ATT_FAIL;
		}
		sl_info("%-4s -> 0x%04X", sn, req);
	}

	t0 = now_ms(L);
	deadline = t0 + SL_T_RESPONSE_MS;
	for (;;) {
		uint64_t now = now_ms(L);
		short rev = 0;
		int r;

		if (stopping(L))
			return ATT_STOP;
		if (now >= deadline) {
			sl_err("%-4s TIMEOUT: no answer within %u s (expected 0x%04X, step 0x%X)",
			       sn, SL_T_RESPONSE_MS / 1000u, expect, expect & 0xFu);
			return ATT_FAIL;
		}
		r = o->boot_poll(o->ctx, L->boot_fd, POLLIN, &rev,
				 (int)(deadline - now > 1000 ? 1000 : deadline - now));
		if (r == -EINTR || r == 0)
			continue;
		if (r < 0) {
			sl_err("%-4s poll: %s", sn, strerror(-r));
			return ATT_FAIL;
		}
		if (rev & POLLIN) {
			long n = o->boot_read(o->ctx, L->boot_fd, b, sizeof(b));
			uint32_t w;

			if (n == 0 || n == -EINTR || n == -EAGAIN)
				continue;
			if (n < 0) {
				sl_err("%-4s read: %s", sn, strerror((int)-n));
				return ATT_FAIL;
			}
			if (n != 4) {
				hexdump(b, (size_t)n, hex, sizeof(hex));
				sl_err("%-4s protocol error: read returned %ld bytes [%s] (expected 4)",
				       sn, n, hex);
				return ATT_FAIL;
			}
			w = get_le32(b);
			if (w == expect) {
				sl_info("%-4s <- 0x%04X (%.3f s)", sn, w,
					(double)(now_ms(L) - t0) / 1000.0);
				if (w == SL_UDL_WORD(SL_UDL_CP2AP, SL_STAGE_BOOT, SL_STEP_DONE) &&
				    L->efuse_open) {
					L->efuse_open = 0;
					L->efuse_seen_cp_status = 0;
					sl_info("eFuse window closed by 0x%04X", w);
				}
				return ATT_OK;
			}
			if ((w & 0xFFFFFFF0u) == SL_UDL_WORD(SL_UDL_CP2AP, stage, 0) &&
			    (w & 0xFu) == SL_STEP_FAIL) {
				sl_err("%-4s <- 0x%04X: CP rejected stage %s (expected 0x%04X)%s",
				       sn, w, sn, expect,
				       stage == SL_STAGE_MAIN ? ": MAIN image rejected" : "");
				return stage == SL_STAGE_MAIN ? ATT_REJECTED : ATT_FAIL;
			}
			sl_err("%-4s PROTOCOL_MISMATCH: expected 0x%04X, received 0x%08X",
			       sn, expect, w);
			return ATT_FAIL;
		}
		if (rev & (POLLHUP | POLLERR | POLLNVAL)) {
			sl_err("%-4s POLLHUP on the boot device while waiting for 0x%04X",
			       sn, expect);
			*hup = 1;
			return ATT_FAIL;
		}
	}
}

/* Non-blocking look at the boot device while a payload streams. */
static enum att stream_check(struct sl_loader *L, unsigned int stage, uint32_t i,
			     uint32_t n)
{
	const struct sl_ops *o = L->ops;
	const char *sn = stage_name(stage);
	short rev = 0;
	uint8_t b[16];
	char hex[64];
	long got;
	int r = o->boot_poll(o->ctx, L->boot_fd, POLLIN, &rev, 0);

	if (r <= 0)
		return ATT_OK;	/* nothing, or EINTR (stop is checked by the caller) */
	if (rev & POLLIN) {
		got = o->boot_read(o->ctx, L->boot_fd, b, sizeof(b));
		if (got <= 0)
			return ATT_OK;
		hexdump(b, (size_t)got, hex, sizeof(hex));
		if (got == 4 && (get_le32(b) & 0xFFFFFFF0u) ==
		    SL_UDL_WORD(SL_UDL_CP2AP, stage, 0) && (b[0] & 0xFu) == SL_STEP_FAIL) {
			sl_err("%-4s <- 0x%04X before frame %u/%u: CP rejected stage %s",
			       sn, get_le32(b), i, n, sn);
			return stage == SL_STAGE_MAIN ? ATT_REJECTED : ATT_FAIL;
		}
		sl_err("%-4s unexpected %ld bytes [%s] from the CP before frame %u/%u",
		       sn, got, hex, i, n);
		return ATT_FAIL;
	}
	if (rev & (POLLHUP | POLLERR | POLLNVAL)) {
		sl_err("%-4s POLLHUP on the boot device before frame %u/%u", sn, i, n);
		return ATT_FAIL;
	}
	return ATT_OK;
}

enum src { SRC_NONE, SRC_TOC, SRC_MAIN, SRC_NV };

struct stage_rec {
	unsigned int stage;
	int start, download, validate, finish;
	enum src src;
	enum sl_rung rung;
};

/* LS2 4.3: processed in this order, none skipped */
static const struct stage_rec stage_recs[5] = {
	{ SL_STAGE_BOOT, 0, 0, 1, 1, SRC_NONE, SL_RUNG_STAGE0 },
	{ SL_STAGE_TOC,  1, 1, 0, 1, SRC_TOC,  SL_RUNG_TOC },
	{ SL_STAGE_MAIN, 1, 1, 1, 1, SRC_MAIN, SL_RUNG_MAIN },
	{ SL_STAGE_NV,   1, 1, 0, 1, SRC_NV,   SL_RUNG_NV },
	{ SL_STAGE_FIN,  1, 0, 0, 0, SRC_NONE, SL_RUNG_FIN },
};

static enum att send_payload(struct sl_loader *L, const struct stage_rec *r,
			     uint32_t *crc_out)
{
	const char *sn = stage_name(r->stage);
	uint8_t frame[SL_FRAME_HDR + SL_FRAME_MSS];
	uint32_t size, nframes, i, crc = 0;
	uint32_t info[3];
	uint64_t t0 = now_us(L), rd_base = 0;
	size_t rd_len = 0;
	char desc[64];
	int rc;
	const uint32_t cmd = SL_UDL_WORD(SL_UDL_AP2CP, r->stage, SL_STEP_SEND);

	switch (r->src) {
	case SRC_TOC:
		size = L->toc.e[SL_SLOT_TOC].size;
		break;
	case SRC_MAIN:
		size = L->toc.e[SL_SLOT_MAIN].size;
		break;
	case SRC_NV:
		size = (uint32_t)L->nv_size;
		break;
	default:
		return ATT_INTERNAL;
	}
	if (!udl_word_ok(cmd) || size == 0)
		return ATT_INTERNAL;
	nframes = (size + SL_FRAME_MSS - 1) / SL_FRAME_MSS;

	/* struct std_dload_info {u32 size, mtu, num_frames}, host order (LE) */
	info[0] = size;
	info[1] = SL_FRAME_MTU;
	info[2] = nframes;
	snprintf(desc, sizeof(desc), "{size 0x%X, mtu 0x%X, frames %u}",
		 size, SL_FRAME_MTU, nframes);
	rc = do_ioctl(L, sn, SL_IOCTL_MODEM_FW_UPDATE, info, desc);
	if (rc < 0)
		return ATT_FAIL;

	for (i = 1; i <= nframes; i++) {
		uint64_t off = (uint64_t)(i - 1) * SL_FRAME_MSS;
		uint32_t len = size - (uint32_t)off > SL_FRAME_MSS ?
			       SL_FRAME_MSS : size - (uint32_t)off;
		uint8_t *payload = frame + SL_FRAME_HDR;
		long n;

		if (stopping(L))
			return ATT_STOP;
		/* the CP says nothing while frames flow: look for a crash or an
		 * early fail word every 64 frames instead of streaming blind */
		if ((i - 1) % 64 == 0) {
			enum att a = stream_check(L, r->stage, i, nframes);

			if (a != ATT_OK)
				return a;
		}
		put_le32(frame + 0, cmd);
		put_le32(frame + 4, nframes);
		put_le32(frame + 8, i);
		put_le32(frame + 12, len);

		switch (r->src) {
		case SRC_TOC:
			memcpy(payload, L->toc_raw + off, len);
			break;
		case SRC_NV:
			memcpy(payload, L->nv_buf + off, len);
			break;
		case SRC_MAIN:
			if (off < rd_base || off + len > rd_base + rd_len) {
				uint32_t msize = L->toc.e[SL_SLOT_MAIN].size;
				size_t want = msize - off > RD_BUF_SIZE ?
					      RD_BUF_SIZE : (size_t)(msize - off);

				rc = pread_exact(L, L->img_fd, L->rd_buf, want,
						 L->toc.e[SL_SLOT_MAIN].offset + off);
				if (rc < 0) {
					sl_err("MAIN: image read failed at +0x%llX: %s",
					       (unsigned long long)off, strerror(-rc));
					return ATT_FATAL_IMAGE;
				}
				rd_base = off;
				rd_len = want;
			}
			memcpy(payload, L->rd_buf + (off - rd_base), len);
			crc = sl_crc32_update(crc, payload, len);
			break;
		default:
			return ATT_INTERNAL;
		}

		n = boot_write(L, frame, SL_FRAME_HDR + len);
		if (n != (long)(SL_FRAME_HDR + len)) {
			if (n == -ENOSPC)
				sl_err("%-4s frame %u/%u: ring full (CP stopped draining for >= 1 s)",
				       sn, i, nframes);
			else
				sl_err("%-4s frame %u/%u: write returned %ld (%s)", sn, i,
				       nframes, n, n < 0 ? strerror((int)-n) : "short");
			return ATT_FAIL;
		}
	}
	sl_info("%-4s %u frames, %u bytes in %.3f s", sn, nframes, size,
		secs(now_us(L) - t0));
	*crc_out = crc;
	return ATT_OK;
}

static enum att stage_engine(struct sl_loader *L, int *hup)
{
	size_t k;

	for (k = 0; k < sizeof(stage_recs) / sizeof(stage_recs[0]); k++) {
		const struct stage_rec *r = &stage_recs[k];
		const unsigned int s = r->stage;
		uint64_t t0 = now_us(L);
		uint32_t crc = 0;
		enum att a;

		if (r->start) {
			a = udl_xchg(L, SL_UDL_WORD(SL_UDL_AP2CP, s, SL_STEP_START),
				     SL_UDL_WORD(SL_UDL_CP2AP, s, SL_STEP_START), s, hup);
			if (a != ATT_OK)
				return a;
		}
		if (r->download) {
			a = send_payload(L, r, &crc);
			if (a != ATT_OK)
				return a;
			/* response only: no write before this wait */
			a = udl_xchg(L, 0, SL_UDL_WORD(SL_UDL_CP2AP, s, SL_STEP_SEND), s, hup);
			if (a != ATT_OK)
				return a;
		}
		if (r->download && r->validate) {
			uint32_t want = L->toc.e[SL_SLOT_MAIN].crc;
			uint8_t f[SL_CRC_FRAME_LEN];
			uint32_t cmd = SL_UDL_WORD(SL_UDL_AP2CP, s, SL_STEP_CRC);
			long n;

			if (r->src != SRC_MAIN || !udl_word_ok(cmd))
				return ATT_INTERNAL;
			if (crc != want) {
				sl_err("MAIN: streamed CRC32 0x%08X != TOC 0x%08X: image changed, "
				       "aborting before the CRC frame", crc, want);
				return ATT_FATAL_IMAGE;
			}
			put_le32(f, cmd);
			put_le32(f + 4, want);	/* the TOC value, as stock */
			n = boot_write(L, f, sizeof(f));
			if (n != (long)sizeof(f)) {
				sl_err("MAIN -> CRC frame: write returned %ld", n);
				return ATT_FAIL;
			}
			sl_info("%-4s -> 0x%04X crc 0x%08X", stage_name(s), cmd, want);
			a = udl_xchg(L, 0, SL_UDL_WORD(SL_UDL_CP2AP, s, SL_STEP_CRC), s, hup);
			if (a != ATT_OK)
				return a;
		}
		if (r->finish) {
			a = udl_xchg(L, SL_UDL_WORD(SL_UDL_AP2CP, s, SL_STEP_DONE),
				     SL_UDL_WORD(SL_UDL_CP2AP, s, SL_STEP_DONE), s, hup);
			if (a != ATT_OK)
				return a;
		}
		sl_info("stage %s done in %.3f s", stage_name(s), secs(now_us(L) - t0));
		if (L->cfg->stop_after == r->rung)
			return ATT_RUNG;
	}
	return ATT_OK;
}

enum sysfs_kind { WAIT_CP_STATUS, WAIT_LLI };

static int wait_sysfs(struct sl_loader *L, const char *step, const char *path,
		      enum sysfs_kind kind)
{
	const struct sl_ops *o = L->ops;
	uint64_t t0 = now_ms(L);
	char buf[64] = "";
	int reads = 0;

	for (;;) {
		long n = o->sysfs_read(o->ctx, path, buf, sizeof(buf));
		int ok = 0;

		reads++;
		if (n >= 0) {
			if (kind == WAIT_LLI) {
				ok = strncmp(buf, "MIPI-LLI 1", 10) == 0;
				trim(buf);
			} else {
				trim(buf);
				ok = strcmp(buf, "1") == 0;
			}
		} else {
			snprintf(buf, sizeof(buf), "<%s>", strerror((int)-n));
		}
		if (ok) {
			sl_info("%s %s = \"%s\" after %.3f s (%d reads)", step, path, buf,
				(double)(now_ms(L) - t0) / 1000.0, reads);
			return 0;
		}
		if (now_ms(L) - t0 >= SL_T_GPIO_DEADLINE_MS) {
			sl_err("%s %s still \"%s\" after %u s (%d reads)", step, path, buf,
			       SL_T_GPIO_DEADLINE_MS / 1000u, reads);
			return -ETIMEDOUT;
		}
		if (sl_sleep(L, SL_T_GPIO_PERIOD_MS) < 0)
			return -EINTR;
	}
}

static enum att drain_rx(struct sl_loader *L, int *hup)
{
	const struct sl_ops *o = L->ops;
	uint8_t buf[SL_FRAME_HDR + SL_FRAME_MSS];
	char hex[64];
	int i, stale = 0;

	for (i = 0; i < SL_DRAIN_MAX; i++) {
		short rev = 0;
		int r = o->boot_poll(o->ctx, L->boot_fd, POLLIN, &rev, 0);
		long n;

		if (stopping(L))
			return ATT_STOP;
		if (r == -EINTR)
			continue;
		if (r <= 0)
			break;
		if (!(rev & POLLIN)) {
			if (rev & (POLLHUP | POLLERR | POLLNVAL)) {
				sl_err("B11 POLLHUP on the boot device before the stage engine");
				*hup = 1;
				return ATT_FAIL;
			}
			break;
		}
		n = o->boot_read(o->ctx, L->boot_fd, buf, sizeof(buf));
		if (n <= 0)
			break;
		hexdump(buf, (size_t)n < 8 ? (size_t)n : 8, hex, sizeof(hex));
		sl_warn("B11 stale RX frame dropped: %ld bytes [%s]", n, hex);
		stale++;
	}
	if (i == SL_DRAIN_MAX) {
		sl_err("B11 RX queue not quiescent after %d frames", SL_DRAIN_MAX);
		return ATT_FAIL;
	}
	sl_info("B11 RX drained (%d stale frames)", stale);
	return ATT_OK;
}

static enum att open_holders(struct sl_loader *L)
{
	const struct sl_ops *o = L->ops;
	int fd;

	if (L->ipc_fd < 0) {
		fd = o->holder_open(o->ctx, L->cfg->ipc_dev);
		if (fd < 0) {
			sl_err("B14 cannot open %s: %s", L->cfg->ipc_dev, strerror(-fd));
			return ATT_FAIL;
		}
		L->ipc_fd = fd;
		sl_info("B14 holding %s", L->cfg->ipc_dev);
	}
	if (L->rfs_fd < 0) {
		fd = o->holder_open(o->ctx, L->cfg->rfs_dev);
		if (fd < 0) {
			sl_err("B14 cannot open %s: %s", L->cfg->rfs_dev, strerror(-fd));
			close_holders(L);
			return ATT_FAIL;
		}
		L->rfs_fd = fd;
		sl_info("B14 holding %s (second open sends INIT_END when cp_boot_done is 0)",
			L->cfg->rfs_dev);
	}
	return ATT_OK;
}

/* Inputs read before power-on must still be what preflight checked. */
static enum att reverify(struct sl_loader *L)
{
	uint8_t toc[SL_TOC_BYTES];
	uint8_t sha[32];

	if (pread_exact(L, L->img_fd, toc, sizeof(toc), 0) != 0 ||
	    memcmp(toc, L->toc_raw, sizeof(toc)) != 0) {
		sl_err("image TOC changed since preflight: refusing to boot");
		return ATT_FATAL_IMAGE;
	}
	if (!boot_buf_ok(L, NULL, sha)) {
		sl_err("BOOT buffer no longer matches the pins: refusing to boot");
		return ATT_FATAL_IMAGE;
	}
	sl_sha256(L->nv_buf, L->nv_size, sha);
	if (memcmp(sha, L->nv_sha256, sizeof(sha)) != 0) {
		sl_err("NV snapshot changed in memory: refusing to boot");
		return ATT_FATAL_NV;
	}
	return ATT_OK;
}

#define CHECK_STOP(L) do { if (stopping(L)) return ATT_STOP; } while (0)

static enum att attempt(struct sl_loader *L, int n, int *hup)
{
	const struct sl_config *c = L->cfg;
	const struct sl_toc_entry *boot = &L->toc.e[SL_SLOT_BOOT];
	uint64_t t0 = now_us(L);
	enum att a;
	long w;
	int r;

	sl_notice("boot attempt %d/%d", n, c->max_attempts);
	if (power_gate(L, "B0", 1) != 0)
		return ATT_POWER;
	a = reverify(L);
	if (a != ATT_OK)
		return a;

	/* review D4-e: a CP left powered by an earlier session is powered off
	 * first, outside any eFuse window it might still be in */
	{
		char buf[32];

		if (L->ops->sysfs_read(L->ops->ctx, L->cp_status_path, buf, sizeof(buf)) >= 0) {
			trim(buf);
			if (strcmp(buf, "1") == 0) {
				sl_warn("B0 cp_status is 1 before power-on: CP alive from an "
					"earlier session, powering it off first");
				L->efuse_open = 1;
				L->efuse_seen_cp_status = 1;
				L->efuse_start_us = now_us(L);
				modem_off(L);
				CHECK_STOP(L);
			}
		}
	}

	L->session++;
	publish(L, "booting");
	if (set_tx_link(L, "B1", SL_LINK_LLI) != 0)
		return ATT_FAIL;
	CHECK_STOP(L);
	if (do_ioctl(L, "B2", SL_IOCTL_MODEM_ON, NULL, NULL) != 0)
		return ATT_FAIL;
	CHECK_STOP(L);
	if (do_ioctl(L, "B3", SL_IOCTL_MODEM_BOOT_ON, NULL, NULL) != 0)
		return ATT_FAIL;
	if (c->stop_after == SL_RUNG_POWER)
		return ATT_RUNG;
	CHECK_STOP(L);
	if (do_ioctl(L, "B4", SL_IOCTL_MODEM_DL_START, NULL, NULL) != 0)
		return ATT_FAIL;
	modem_status(L, "B5");
	if (set_tx_link(L, "B6", SL_LINK_SPI) != 0)
		return ATT_FAIL;
	CHECK_STOP(L);

	{
		uint64_t ts = now_us(L);
		uint8_t sha[32];

		/* the buffer written here is the one that matches both pins */
		if (!boot_buf_ok(L, NULL, sha)) {
			sl_err("B7 BOOT buffer does not match the pins: not sent");
			return ATT_FATAL_IMAGE;
		}
		/* from here on BOOT may run: eFuse window bookkeeping */
		L->efuse_open = 1;
		L->efuse_seen_cp_status = 0;
		L->efuse_start_us = now_us(L);
		w = boot_write(L, L->boot_buf, boot->size);
		if (w != (long)boot->size) {
			sl_err("B7 SPI write of BOOT (%u bytes) returned %ld (%s)", boot->size,
			       w, w < 0 ? strerror((int)-w) : "short");
			return ATT_FAIL;
		}
		sl_info("B7 BOOT %u bytes written over SPI in %.3f s", boot->size,
			secs(now_us(L) - ts));
	}
	r = wait_sysfs(L, "B8", L->cp_status_path, WAIT_CP_STATUS);
	if (r == 0) {
		L->efuse_seen_cp_status = 1;
		L->efuse_start_us = now_us(L);
	}
	if (r == -EINTR)
		return ATT_STOP;
	if (r < 0)
		return ATT_FAIL;
	if (c->stop_after == SL_RUNG_SPI)
		return ATT_RUNG;

	if (set_tx_link(L, "B9", SL_LINK_LLI) != 0)
		return ATT_FAIL;
	r = wait_sysfs(L, "B10", L->lli_path, WAIT_LLI);
	if (r == -EINTR)
		return ATT_STOP;
	if (r < 0)
		return ATT_FAIL;
	if (c->stop_after == SL_RUNG_LLI)
		return ATT_RUNG;

	a = drain_rx(L, hup);
	if (a != ATT_OK)
		return a;
	a = stage_engine(L, hup);
	if (a != ATT_OK)
		return a;

	if (do_ioctl(L, "B13", SL_IOCTL_MODEM_BOOT_OFF, NULL, NULL) != 0) {
		do_ioctl(L, "B13", SL_IOCTL_MODEM_GET_CP_BOOTLOG, NULL, " (result ignored)");
		sl_err("B13 BOOT_OFF failed: no PHONE_START from the CP");
		return ATT_FAIL;
	}
	/* B14: held for the life of the CP, across silent resets, never read
	 * (SYNTHESIS v2 D5 restart contract); already open after a reset */
	a = open_holders(L);
	if (a != ATT_OK)
		return a;
	do_ioctl(L, "B15", SL_IOCTL_MODEM_CLR_CP_BOOTLOG, NULL,
		 " (EINVAL expected, ignored)");
	if (do_ioctl(L, "B16", SL_IOCTL_MODEM_BOOT_DONE, NULL, NULL) != 0)
		sl_warn("B16 BOOT_DONE did not return 0");
	r = modem_status(L, "B17");
	if (r != SL_STATE_ONLINE)
		sl_warn("B17 state is not ONLINE");
	sl_notice("CP online after %.3f s", secs(now_us(L) - t0));
	return ATT_OK;
}

/* Returns an exit code; *online = 1 when the CP reached ONLINE. */
static int boot_cycle(struct sl_loader *L, int *online)
{
	const int max = L->cfg->max_attempts;
	int n;

	*online = 0;
	for (n = 1; n <= max; n++) {
		int hup = 0;
		enum att a = attempt(L, n, &hup);
		int st;

		switch (a) {
		case ATT_OK:
			L->boots_ok++;
			*online = 1;
			publish(L, "online");
			power_gate(L, "B17", 0);
			return SL_EXIT_OK;
		case ATT_RUNG:
			sl_notice("--stop-after=%s reached: powering the CP off",
				  sl_rung_name(L->cfg->stop_after));
			modem_off(L);
			power_gate(L, "end", 0);
			return SL_EXIT_OK;
		case ATT_STOP:
			sl_notice("stop requested during the boot attempt");
			modem_off(L);
			power_gate(L, "end", 0);
			return SL_EXIT_OK;
		case ATT_POWER:
			modem_off(L);
			return SL_EXIT_POWER;
		case ATT_FATAL_IMAGE:
			modem_off(L);
			return SL_EXIT_IMAGE;
		case ATT_FATAL_NV:
			modem_off(L);
			return SL_EXIT_NV;
		case ATT_INTERNAL:
			modem_off(L);
			return SL_EXIT_INTERNAL;
		case ATT_FAIL:
		case ATT_REJECTED:
			break;
		}

		st = modem_status(L, "--");
		L->last_crashed = (st == SL_STATE_CRASH_EXIT);
		if (L->last_crashed || hup)
			sl_err("attempt %d: crash during boot (state %s)", n, state_name(st));
		modem_off(L);
		power_gate(L, "end", 0);
		if (a == ATT_REJECTED) {
			L->rejections++;
			if (L->rejections >= SL_REJECTIONS_MAX) {
				sl_err("MAIN image rejected %d times by the CP: stopping "
				       "(no automatic restart)", L->rejections);
				return SL_EXIT_REJECTED;
			}
		}
		if (n < max) {
			sl_notice("attempt %d/%d failed; retrying in %u s", n, max,
				  SL_T_RETRY_PAUSE_MS / 1000u);
			if (sl_sleep(L, SL_T_RETRY_PAUSE_MS) < 0)
				return SL_EXIT_OK;
		}
	}
	sl_err("boot failed after %d attempts", max);
	return SL_EXIT_BOOT;
}

/* ------------------------------------------------------------------ */
/* supervisor (LS2 9.3)                                                 */
/* ------------------------------------------------------------------ */

static int shutdown_clean(struct sl_loader *L)
{
	sl_notice("stop requested: closing holders, MODEM_OFF");
	notify(L, "STOPPING=1");
	close_holders(L);
	modem_off(L);
	power_gate(L, "end", 0);
	return SL_EXIT_OK;
}

static int silent_reset(struct sl_loader *L, int st)
{
	uint64_t now = now_ms(L);
	char msg[96];
	int i, k = 0, online = 0, rc;

	for (i = 0; i < L->nreset; i++) {
		if (now - L->reset_ms[i] < SL_RESET_WINDOW_MS)
			L->reset_ms[k++] = L->reset_ms[i];
	}
	L->nreset = k;
	if (L->nreset >= SL_RESET_MAX) {
		sl_err("CP crashed again (state %s) after %d silent resets in 30 min: giving up",
		       state_name(st), L->nreset);
		notify(L, "STATUS=CP crash loop, giving up");
		modem_off(L);
		return SL_EXIT_BOOT;
	}
	L->reset_ms[L->nreset++] = now;
	sl_warn("CP left ONLINE (state %s): silent reset %d/%d in the last 30 min",
		state_name(st), L->nreset, SL_RESET_MAX);
	notify(L, "STATUS=CP crashed, restarting");
	if (sl_sleep(L, SL_T_RESET_GRACE_MS) < 0)
		return shutdown_clean(L);
	modem_off(L);
	rc = boot_cycle(L, &online);
	if (rc != SL_EXIT_OK)
		return rc;
	if (!online)
		return shutdown_clean(L);
	snprintf(msg, sizeof(msg), "STATUS=CP online (restart %d)", L->boots_ok - 1);
	notify(L, msg);
	return SL_CONTINUE;
}

static int supervise(struct sl_loader *L, int hold_only)
{
	const struct sl_ops *o = L->ops;
	int errs = 0;

	for (;;) {
		short rev = 0;
		int r, st;

		if (stopping(L))
			return shutdown_clean(L);
		r = o->boot_poll(o->ctx, L->boot_fd, POLLIN | POLLHUP, &rev, -1);
		if (r == -EINTR || r == 0)
			continue;
		if (r < 0 || (rev & POLLNVAL)) {
			sl_err("supervisor: poll failed: %s", r < 0 ? strerror(-r) : "POLLNVAL");
			if (++errs > 10) {
				modem_off(L);
				return SL_EXIT_BOOT;
			}
			sl_sleep(L, 1000);
			continue;
		}
		if (rev & (POLLHUP | POLLERR)) {
			st = modem_status(L, "supervisor");
			if (st < 0) {
				if (++errs > 10) {
					modem_off(L);
					return SL_EXIT_BOOT;
				}
				sl_sleep(L, 1000);
				continue;
			}
			errs = 0;
			switch (st) {
			case SL_STATE_SIM_ATTACH:
			case SL_STATE_SIM_DETACH:
				sl_info("supervisor: SIM state change event consumed, ignored");
				break;
			case SL_STATE_NV_REBUILDING:
				sl_info("supervisor: NV_REBUILDING reported, ignored");
				break;
			case SL_STATE_BOOTING:
			case SL_STATE_ONLINE:
				sl_info("supervisor: spurious POLLHUP");
				sl_sleep(L, SL_T_SPURIOUS_MS);
				break;
			case SL_STATE_CRASH_EXIT:
			case SL_STATE_CRASH_RESET:
			case SL_STATE_OFFLINE:
				publish(L, "crashed");
				if (hold_only) {
					sl_err("CP left ONLINE (state %s) with --stop-after=online: "
					       "no silent reset", state_name(st));
					notify(L, "STATUS=CP crashed (hold mode)");
					close_holders(L);
					modem_off(L);
					return SL_EXIT_BOOT;
				}
				r = silent_reset(L, st);
				if (r != SL_CONTINUE)
					return r;
				break;
			default:
				sl_warn("supervisor: unexpected state %d", st);
				sl_sleep(L, SL_T_SPURIOUS_MS);
				break;
			}
			continue;
		}
		if (rev & POLLIN) {
			uint8_t buf[64];
			long n = o->boot_read(o->ctx, L->boot_fd, buf, sizeof(buf));

			sl_warn("supervisor: %ld unexpected bytes on the boot device", n);
			if (n <= 0)
				sl_sleep(L, SL_T_SPURIOUS_MS);
		}
	}
}

/* continue the session numbering of an earlier loader process (same AP
 * boot: /run is a tmpfs), so that a daemon never sees a number twice */
static void resume_session(struct sl_loader *L)
{
	char buf[96];
	unsigned int n;

	if (L->cfg->state_file &&
	    L->ops->sysfs_read(L->ops->ctx, L->cfg->state_file, buf, sizeof(buf)) > 0 &&
	    sscanf(buf, "session=%u", &n) == 1 && n < 1000000u)
		L->session = n;
}

int sl_run(struct sl_loader *L)
{
	int online = 0, rc;

	if (L->cfg->stop_after != SL_RUNG_PREFLIGHT) {
		resume_session(L);
		publish(L, "offline");
	}
	rc = sl_preflight(L);
	if (rc)
		return rc;
	if (L->cfg->stop_after == SL_RUNG_PREFLIGHT) {
		sl_notice("dry run: preflight passed, no ioctl issued, CP untouched");
		return SL_EXIT_OK;
	}
	rc = boot_cycle(L, &online);
	if (rc != SL_EXIT_OK || !online) {
		close_holders(L);
		return rc;
	}
	if (L->cfg->stop_after == SL_RUNG_ONLINE)
		sl_notice("--stop-after=online: CP online, holding until SIGTERM (no silent reset)");
	notify(L, "READY=1\nSTATUS=CP online");
	L->ready_sent = 1;
	rc = supervise(L, L->cfg->stop_after == SL_RUNG_ONLINE);
	close_holders(L);
	return rc;
}
