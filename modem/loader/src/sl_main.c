// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: command line, signals, logging set-up.
 */
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "sl_loader.h"
#include "sl_log.h"

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static void usage(FILE *f)
{
	fprintf(f,
"usage: shannon-loader [options]\n"
"Boots the Shannon SS333 CP over SPI + MIPI-LLI and supervises it.\n"
"\n"
"  --dry-run                 preflight only, no ioctl (= --stop-after=preflight)\n"
"  --stop-after=RUNG         preflight|power|spi|lli|stage0|toc|main|nv|fin|online\n"
"                            every rung but online ends with MODEM_OFF\n"
"  --attempts=N              boot attempts per boot cycle, 1..3 (default 1)\n"
"  --state-file=PATH         CP state for the daemons, under /run/ only\n"
"                            (default /run/shannon/cp-state)\n"
"  --kmsg                    also log to /dev/kmsg\n"
"  --verbose                 debug log level\n"
"  --boot-dev=PATH           default /dev/umts_boot0\n"
"  --ipc-dev=PATH            default /dev/umts_ipc0\n"
"  --rfs-dev=PATH            default /dev/umts_rfs0\n"
"  --image=PATH              default /dev/disk/by-partlabel/RADIO\n"
"  --lli-control=PATH        default: discovered under /sys/bus/platform\n"
"  --cp-status=PATH          default: discovered under /sys/bus/platform\n"
"  --allow-hw-param=PATH     default /sys/module/sec_modem_v1/parameters/allow_hw\n"
"  --nv-mode=copy|direct     copy (A, default) or direct read-only EFS (B)\n"
"  --nv=PATH                 default /var/lib/shannon/nv/nv_data.bin (direct: /efs/nv_data.bin)\n"
"  --nv-manifest=PATH        default /var/lib/shannon/nv/manifest.sha256 (copy mode)\n"
"  --nv-md5-file=PATH        default <nv>.md5\n"
"  --nv-md5=warn|require|off MD5 check policy (default warn: log only)\n"
"  --allow-blank-nv          accept an all-0xFF/all-0x00 NV (loud warning)\n"
"  --battery-capacity=PATH   default /sys/class/power_supply/sm5703-fuelgauge/capacity\n"
"  --battery-temp=PATH       default /sys/class/power_supply/sm5703-fuelgauge/temp\n"
"  --battery-current=PATH    default /sys/class/power_supply/sm5703-fuelgauge/current_now\n"
"  --max-temp=DEG            refuse a CP power-on at DEG or above, 30.0..55.0\n"
"                            (default 40.0; gauge sensor, not the battery thermistor)\n"
"  --version, --help\n"
"\n"
"umts_ipc0/umts_rfs0 are opened after BOOT_OFF and held (never read) for the\n"
"life of the CP, across silent resets.\n"
"\n"
"exit: 0 ok, 2 config, 3 NV refused, 4 image/TOC, 5 kernel ABI, 6 boot failed,\n"
"      7 image rejected by the CP, 8 battery/thermal gate\n");
}

enum {
	OPT_DRY = 256, OPT_STOP, OPT_ATT, OPT_STATE, OPT_KMSG, OPT_VERB, OPT_BOOT,
	OPT_IPC, OPT_RFS, OPT_IMG, OPT_LLI, OPT_CPS, OPT_AHW, OPT_NVMODE, OPT_NV,
	OPT_MAN, OPT_MD5F, OPT_MD5P, OPT_BLANK, OPT_BCAP, OPT_BTEMP, OPT_BCUR, OPT_TMAX,
	OPT_VER, OPT_HELP,
};

static const struct option long_opts[] = {
	{ "dry-run", no_argument, NULL, OPT_DRY },
	{ "stop-after", required_argument, NULL, OPT_STOP },
	{ "attempts", required_argument, NULL, OPT_ATT },
	{ "state-file", required_argument, NULL, OPT_STATE },
	{ "kmsg", no_argument, NULL, OPT_KMSG },
	{ "verbose", no_argument, NULL, OPT_VERB },
	{ "boot-dev", required_argument, NULL, OPT_BOOT },
	{ "ipc-dev", required_argument, NULL, OPT_IPC },
	{ "rfs-dev", required_argument, NULL, OPT_RFS },
	{ "image", required_argument, NULL, OPT_IMG },
	{ "lli-control", required_argument, NULL, OPT_LLI },
	{ "cp-status", required_argument, NULL, OPT_CPS },
	{ "allow-hw-param", required_argument, NULL, OPT_AHW },
	{ "nv-mode", required_argument, NULL, OPT_NVMODE },
	{ "nv", required_argument, NULL, OPT_NV },
	{ "nv-manifest", required_argument, NULL, OPT_MAN },
	{ "nv-md5-file", required_argument, NULL, OPT_MD5F },
	{ "nv-md5", required_argument, NULL, OPT_MD5P },
	{ "allow-blank-nv", no_argument, NULL, OPT_BLANK },
	{ "battery-capacity", required_argument, NULL, OPT_BCAP },
	{ "battery-temp", required_argument, NULL, OPT_BTEMP },
	{ "battery-current", required_argument, NULL, OPT_BCUR },
	{ "max-temp", required_argument, NULL, OPT_TMAX },
	{ "version", no_argument, NULL, OPT_VER },
	{ "help", no_argument, NULL, OPT_HELP },
	{ NULL, 0, NULL, 0 },
};

static uint64_t log_clock(void *ctx)
{
	const struct sl_ops *ops = ctx;

	return ops->now_us(ops->ctx);
}

int main(int argc, char **argv)
{
	struct sl_config cfg = {
		.boot_dev = "/dev/umts_boot0",
		.ipc_dev = "/dev/umts_ipc0",
		.rfs_dev = "/dev/umts_rfs0",
		.image = "/dev/disk/by-partlabel/RADIO",
		.nv_mode = SL_NV_MODE_COPY,
		.md5_policy = SL_MD5_WARN,
		.max_attempts = 1,
		.stop_after = SL_RUNG_NONE,
		.bat_capacity = "/sys/class/power_supply/sm5703-fuelgauge/capacity",
		.bat_temp = "/sys/class/power_supply/sm5703-fuelgauge/temp",
		.bat_current = "/sys/class/power_supply/sm5703-fuelgauge/current_now",
		.allow_hw = "/sys/module/sec_modem_v1/parameters/allow_hw",
		.state_file = "/run/shannon/cp-state",
	};
	const char *nv_path = NULL, *manifest = NULL;
	struct sl_linux_ctx lctx;
	struct sl_log_cfg lc;
	struct sl_ops ops;
	struct sl_loader L;
	struct sigaction sa;
	int use_kmsg = 0, verbose = 0, show_version = 0;
	int kmsg_fd = -1, rc, opt;
	char *end;
	long v;

	while ((opt = getopt_long(argc, argv, "", long_opts, NULL)) != -1) {
		switch (opt) {
		case OPT_DRY:
			cfg.stop_after = SL_RUNG_PREFLIGHT;
			break;
		case OPT_STOP:
			if (sl_rung_parse(optarg, &cfg.stop_after) != 0) {
				fprintf(stderr, "shannon-loader: unknown rung \"%s\"\n", optarg);
				return SL_EXIT_CONFIG;
			}
			break;
		case OPT_ATT:
			errno = 0;
			v = strtol(optarg, &end, 10);
			if (errno || *end || v < 1 || v > SL_ATTEMPTS_MAX) {
				fprintf(stderr, "shannon-loader: --attempts must be 1..%d\n",
					SL_ATTEMPTS_MAX);
				return SL_EXIT_CONFIG;
			}
			cfg.max_attempts = (int)v;
			break;
		case OPT_STATE: cfg.state_file = optarg; break;
		case OPT_KMSG: use_kmsg = 1; break;
		case OPT_VERB: verbose = 1; break;
		case OPT_BOOT: cfg.boot_dev = optarg; break;
		case OPT_IPC: cfg.ipc_dev = optarg; break;
		case OPT_RFS: cfg.rfs_dev = optarg; break;
		case OPT_IMG: cfg.image = optarg; break;
		case OPT_LLI: cfg.lli_control = optarg; break;
		case OPT_CPS: cfg.cp_status = optarg; break;
		case OPT_AHW: cfg.allow_hw = optarg; break;
		case OPT_NVMODE:
			if (strcmp(optarg, "copy") == 0) {
				cfg.nv_mode = SL_NV_MODE_COPY;
			} else if (strcmp(optarg, "direct") == 0) {
				cfg.nv_mode = SL_NV_MODE_DIRECT;
			} else {
				fprintf(stderr, "shannon-loader: --nv-mode is copy or direct\n");
				return SL_EXIT_CONFIG;
			}
			break;
		case OPT_NV: nv_path = optarg; break;
		case OPT_MAN: manifest = optarg; break;
		case OPT_MD5F: cfg.nv_md5 = optarg; break;
		case OPT_MD5P:
			if (strcmp(optarg, "warn") == 0) {
				cfg.md5_policy = SL_MD5_WARN;
			} else if (strcmp(optarg, "require") == 0) {
				cfg.md5_policy = SL_MD5_REQUIRE;
			} else if (strcmp(optarg, "off") == 0) {
				cfg.md5_policy = SL_MD5_OFF;
			} else {
				fprintf(stderr, "shannon-loader: --nv-md5 is warn, require or off\n");
				return SL_EXIT_CONFIG;
			}
			break;
		case OPT_BLANK: cfg.allow_blank_nv = 1; break;
		case OPT_BCAP: cfg.bat_capacity = optarg; break;
		case OPT_BTEMP: cfg.bat_temp = optarg; break;
		case OPT_BCUR: cfg.bat_current = optarg; break;
		case OPT_TMAX:
			/* DEG or DEG.D, in 0.1 degC */
			errno = 0;
			v = strtol(optarg, &end, 10) * 10;
			if (!errno && *end == '.' && end[1] >= '0' && end[1] <= '9' && !end[2]) {
				v += end[1] - '0';
				end += 2;
			}
			if (errno || end == optarg || *end || v < 300 || v > SL_BAT_MAX_DECI_C_CAP) {
				fprintf(stderr, "shannon-loader: --max-temp must be 30.0..%d.%d\n",
					SL_BAT_MAX_DECI_C_CAP / 10, SL_BAT_MAX_DECI_C_CAP % 10);
				return SL_EXIT_CONFIG;
			}
			cfg.bat_max_deci_c = (int)v;
			break;
		case OPT_VER: show_version = 1; break;
		case OPT_HELP:
			usage(stdout);
			return SL_EXIT_OK;
		default:
			usage(stderr);
			return SL_EXIT_CONFIG;
		}
	}
	if (optind != argc) {
		usage(stderr);
		return SL_EXIT_CONFIG;
	}

	if (cfg.nv_mode == SL_NV_MODE_COPY) {
		cfg.nv_path = nv_path ? nv_path : "/var/lib/shannon/nv/nv_data.bin";
		cfg.nv_manifest = manifest ? manifest : "/var/lib/shannon/nv/manifest.sha256";
	} else {
		cfg.nv_path = nv_path ? nv_path : "/efs/nv_data.bin";
		cfg.nv_manifest = manifest;	/* optional in direct mode */
	}

	sl_ops_linux_init(&ops, &lctx);
	lctx.state_file = cfg.state_file;
	sl_loader_init(&L, &cfg, &ops, &g_stop);
#ifdef SL_TEST_BOOT_SHA256_HEX
	/* test build only: lets synthetic images pass the BOOT pin */
	if (sl_parse_sha256_hex(SL_TEST_BOOT_SHA256_HEX, L.pin_boot_sha256) != 0)
		return SL_EXIT_INTERNAL;
#endif

	if (show_version) {
		printf("shannon-loader %s\nBOOT pin: CRC32 0x%08X, SHA-256 %s%s\n",
		       SL_VERSION, SL_BOOT_CRC_PINNED,
#ifdef SL_TEST_BOOT_SHA256_HEX
		       SL_TEST_BOOT_SHA256_HEX, " (TEST BUILD)"
#else
		       SL_BOOT_SHA256_PINNED_HEX, ""
#endif
		       );
		return SL_EXIT_OK;
	}

	if (use_kmsg) {
		kmsg_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC | O_NOCTTY);
		if (kmsg_fd < 0)
			fprintf(stderr, "shannon-loader: /dev/kmsg: %s (continuing)\n",
				strerror(errno));
	}
	memset(&lc, 0, sizeof(lc));
	lc.clock = log_clock;
	lc.clock_ctx = &ops;
	lc.to_stderr = 1;
	lc.stderr_prio_prefix = getenv("JOURNAL_STREAM") != NULL;
	lc.kmsg_fd = kmsg_fd;
	lc.max_level = verbose ? SL_LOG_DEBUG : SL_LOG_INFO;
	sl_log_setup(&lc);

#ifdef SL_TEST_BOOT_SHA256_HEX
	sl_warn("TEST BUILD: BOOT SHA-256 pin replaced by %s", SL_TEST_BOOT_SHA256_HEX);
#endif

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;	/* no SA_RESTART: poll/sleep return EINTR */
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	rc = sl_config_check(&cfg);
	if (rc == 0)
		rc = sl_run(&L);
	sl_loader_free(&L);
	sl_info("exit %d", rc);
	if (kmsg_fd >= 0)
		close(kmsg_fd);
	return rc;
}
