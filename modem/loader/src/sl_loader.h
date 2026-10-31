/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * shannon-loader: independent loader and supervisor for the Shannon SS333 CP
 * (Galaxy Tab S2 SM-T715), written from research/modem/research/SYNTHESIS.md
 * (D4) and research/modem/research/analysis/loader_spec_v2.md (LS2).
 */
#ifndef SL_LOADER_H
#define SL_LOADER_H

#include <signal.h>
#include <stddef.h>
#include <stdint.h>

#include "sl_abi.h"
#include "sl_ops.h"

#define SL_VERSION "0.1.0"

/* Exit codes, LS2 4.5 */
enum sl_exit {
	SL_EXIT_OK = 0,
	SL_EXIT_INTERNAL = 1,	/* out of memory, internal invariant */
	SL_EXIT_CONFIG = 2,
	SL_EXIT_NV = 3,		/* NV refused */
	SL_EXIT_IMAGE = 4,	/* RADIO image / TOC invalid */
	SL_EXIT_ABI = 5,	/* kernel ABI missing */
	SL_EXIT_BOOT = 6,	/* boot failed after retries, restart budget spent */
	SL_EXIT_REJECTED = 7,	/* image rejected twice by the CP */
	SL_EXIT_POWER = 8,	/* battery/thermal gate: no CP power-on */
};

/* --stop-after ladder, LS2 10.6 */
enum sl_rung {
	SL_RUNG_NONE = 0,	/* full service: boot, online, supervisor */
	SL_RUNG_PREFLIGHT,	/* F1-F7, no ioctl at all (= --dry-run) */
	SL_RUNG_POWER,		/* B1-B3: TX link LLI, MODEM_ON, BOOT_ON */
	SL_RUNG_SPI,		/* B4-B8: DL_START .. BOOT over SPI, cp_status = 1 */
	SL_RUNG_LLI,		/* B9-B10: LLI mounted */
	SL_RUNG_STAGE0,		/* B11 + record 0: 0x900D -> 0xA00D */
	SL_RUNG_TOC,		/* record 1 */
	SL_RUNG_MAIN,		/* record 2 */
	SL_RUNG_NV,		/* record 3 */
	SL_RUNG_FIN,		/* record 4: 0x9F00 -> 0xAF00 */
	SL_RUNG_ONLINE,		/* B13-B17, then hold without silent resets */
};

enum sl_nv_mode {
	SL_NV_MODE_COPY = 0,	/* Mode A: verified copy + SHA-256 manifest */
	SL_NV_MODE_DIRECT,	/* Mode B: read-only EFS (statvfs ST_RDONLY) */
};

enum sl_md5_policy {
	SL_MD5_WARN = 0,
	SL_MD5_REQUIRE,
	SL_MD5_OFF,
};

struct sl_config {
	const char *boot_dev;		/* /dev/umts_boot0 */
	const char *ipc_dev;		/* /dev/umts_ipc0 */
	const char *rfs_dev;		/* /dev/umts_rfs0 */
	const char *image;		/* /dev/disk/by-partlabel/RADIO */
	const char *lli_control;	/* NULL: discover */
	const char *cp_status;		/* NULL: discover */
	const char *nv_path;		/* /var/lib/shannon/nv/nv_data.bin */
	const char *nv_manifest;	/* Mode A: /var/lib/shannon/nv/manifest.sha256 */
	const char *nv_md5;		/* NULL: <nv_path>.md5 */
	enum sl_nv_mode nv_mode;
	enum sl_md5_policy md5_policy;
	int allow_blank_nv;
	int max_attempts;		/* 1..3 per boot cycle (default 1) */
	enum sl_rung stop_after;
	/* power and thermal gate (review rule 22/24) */
	const char *bat_capacity;	/* .../sm5703-fuelgauge/capacity (%) */
	const char *bat_temp;		/* .../sm5703-fuelgauge/temp (0.1 degC) */
	const char *bat_current;	/* .../sm5703-fuelgauge/current_now (uA), log only */
	int bat_max_deci_c;		/* refuse at or above (0.1 degC); 0: SL_BAT_MAX_DECI_C */
	const char *allow_hw;		/* /sys/module/sec_modem_v1/parameters/allow_hw */
	const char *state_file;		/* /run/shannon/cp-state (must be under /run/) */
};

#define SL_BAT_MIN_PERCENT	5	/* before any CP power-on */
#define SL_BAT_MAX_DECI_C	400	/* default: temperature must be < 40.0 degC */
/*
 * Highest --max-temp. The gauge temperature is the SM5703's own sensor (the
 * inside of the tablet, not the battery thermistor); on the desktop root it
 * reads 44-48 degC with a cool case. Stock Android powers the CP on at any
 * temperature; the owner raised the gate to 55.0 on 2026-10-30, a guard
 * against real overheating only.
 */
#define SL_BAT_MAX_DECI_C_CAP	550

/* Fixed protocol timing (stock or LS2 [D] values); not configurable. */
#define SL_T_GPIO_DEADLINE_MS	5000u	/* B8 cp_status, B10 lli_control */
#define SL_T_GPIO_PERIOD_MS	100u
#define SL_T_RESPONSE_MS	30000u	/* per expected std_udl word */
#define SL_T_RETRY_PAUSE_MS	2000u	/* between attempts */
#define SL_T_RESET_GRACE_MS	3000u	/* supervisor, before MODEM_OFF */
#define SL_T_SPURIOUS_MS	100u
#define SL_RESET_WINDOW_MS	(30u * 60u * 1000u)
#define SL_RESET_MAX		5	/* silent resets per window */
#define SL_ATTEMPTS_MAX		3
#define SL_REJECTIONS_MAX	2
#define SL_DRAIN_MAX		256
/* eFuse window (review D4-a): no CP power-off or reset between cp_status = 1
 * and the first of 0xA00D received or this delay. */
#define SL_T_EFUSE_MS		10000u	/* SYNTHESIS v2 rule 1 (review proposed 3 s) */

/* TOC as parsed (toc.c) */
struct sl_toc_entry {
	char name[SL_TOC_NAME_LEN + 1];
	uint32_t offset;
	uint32_t load_addr;
	uint32_t size;
	uint32_t crc;
	uint32_t index;
};

struct sl_toc {
	struct sl_toc_entry e[SL_TOC_SLOTS];
};

enum { SL_SLOT_TOC = 0, SL_SLOT_BOOT = 1, SL_SLOT_MAIN = 2, SL_SLOT_NV = 3 };

struct sl_loader {
	const struct sl_config *cfg;
	const struct sl_ops *ops;
	volatile sig_atomic_t *stop;	/* set by SIGTERM/SIGINT */

	/* resolved paths */
	char lli_path[256];
	char cp_status_path[256];

	/* RADIO image */
	int img_fd;
	uint64_t img_size;
	uint8_t toc_raw[SL_TOC_BYTES];
	struct sl_toc toc;
	uint8_t *boot_buf;		/* BOOT bytes, CRC + SHA-256 verified, sealed */
	size_t boot_alloc;
	uint8_t pin_boot_sha256[32];	/* production value set by sl_loader_init */
	uint8_t *rd_buf;		/* MAIN read-ahead */

	/* NV snapshot (whole file, read before the first power-on) */
	uint8_t *nv_buf;		/* sealed read-only once loaded */
	size_t nv_size;
	size_t nv_alloc;
	uint8_t nv_sha256[32];

	/* device descriptors */
	int boot_fd;
	int ipc_fd;
	int rfs_fd;

	/* bookkeeping */
	int rejections;			/* CP_STAGE_FAIL on MAIN, per process */
	uint64_t reset_ms[SL_RESET_MAX + 1];
	int nreset;
	int boots_ok;
	int ready_sent;
	int last_crashed;		/* last failed attempt saw CRASH_EXIT */

	/* CP session published in the state file */
	unsigned int session;
	const char *state;

	/* eFuse window bookkeeping */
	int efuse_open;			/* BOOT may be provisioning eFuses */
	int efuse_seen_cp_status;	/* cp_status = 1 observed */
	uint64_t efuse_start_us;
};

/* toc.c */
void sl_toc_parse(const uint8_t raw[SL_TOC_BYTES], struct sl_toc *t);
int sl_toc_validate(const struct sl_toc *t, uint64_t image_size,
		    char *why, size_t whylen);

/* nv.c: returns 0 or an sl_exit code */
int sl_nv_load(struct sl_loader *L);
int sl_nv_parse_md5_text(const char *buf, size_t len, uint8_t out[16]);
int sl_manifest_lookup(const char *text, size_t len, const char *name,
		       uint8_t out[32]);

/* loader.c: page-aligned buffers that can be sealed read-only + locked */
uint8_t *sl_buf_alloc(size_t len, size_t *alloc_len);
void sl_buf_seal(uint8_t *buf, size_t alloc_len);
void sl_buf_free(uint8_t *buf, size_t alloc_len);

/* loader.c */
void sl_loader_init(struct sl_loader *L, const struct sl_config *cfg,
		    const struct sl_ops *ops, volatile sig_atomic_t *stop);
void sl_loader_free(struct sl_loader *L);
int sl_config_check(const struct sl_config *cfg);
int sl_preflight(struct sl_loader *L);
int sl_run(struct sl_loader *L);
/* exposed for the tests */
int sl_ioctl_allowed(unsigned long req);
int sl_ioctl(struct sl_loader *L, unsigned long req, void *arg);
const char *sl_rung_name(enum sl_rung r);
int sl_rung_parse(const char *s, enum sl_rung *out);
int sl_parse_sha256_hex(const char *hex, uint8_t out[32]);

#endif /* SL_LOADER_H */
