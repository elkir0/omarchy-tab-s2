/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * C mock of /dev/umts_boot0 (+ holders, sysfs, RADIO image, battery) with a
 * virtual clock: the state machine of LS2 10.2, the CP side of the std_udl
 * protocol (SYNTHESIS 2.7) and the safety tripwires of LS2 10.1.
 */
#ifndef SL_TEST_MOCK_H
#define SL_TEST_MOCK_H

#include <signal.h>
#include <stddef.h>
#include <stdint.h>

#include "sl_ops.h"

enum mock_ev {
	MEV_CP_STATUS_HIGH = 1,
	MEV_LLI_MOUNT,
	MEV_REPLY,
	MEV_SIM_CHANGE,
	MEV_CRASH,
	MEV_SIGTERM,
	MEV_BATTERY,		/* arg: new capacity */
	MEV_DAEMON_OPEN,	/* a third party opens both holders */
};

struct mock_script {
	int on_online;		/* fire after the n-th ONLINE (1-based); 0 = from start */
	uint32_t delay_ms;
	int type;
	int arg;
};

struct mock_cfg {
	/* virtual RADIO image */
	const char *image_path;
	uint8_t *image;
	size_t image_len;
	uint64_t image_size;
	/* expected NV payload of stage 3 */
	const uint8_t *nv;
	size_t nv_len;
	/* paths */
	const char *boot_path, *ipc_path, *rfs_path;
	const char *lli_path, *cp_status_path;
	const char *cap_path, *temp_path, *cur_path, *allow_hw_path;
	const char *state_path;		/* published CP state (virtual) */
	const char *state_initial;	/* content before the run, or NULL */
	/* battery and gate */
	int bat_capacity, bat_temp, bat_current;
	int bat_missing;
	const char *allow_hw_value;
	int fake_ro_fs;
	/* timing (ms) */
	unsigned int cp_status_delay_ms, lli_delay_ms, phone_start_delay_ms;
	unsigned int reply_delay_ms;
	/* faults: counts of occurrences (attempts), -1 = always */
	int f_dl_start_efault;
	int f_spi_eintr;
	int f_cp_status_never;
	int f_lli_never;
	int f_silent;
	uint32_t f_wrong_for, f_wrong_reply;
	int f_wrong_count;
	int f_reject_crc;
	uint32_t f_read8_for;
	int f_read8_count;
	uint32_t f_crash_main_frame;
	int f_crash_count;
	unsigned int f_enospc_stage;
	uint32_t f_enospc_frame;
	int f_enospc_count;
	int f_boot_off_eagain;
	int f_corrupt_main_after_preflight;
	int f_stale_rx;			/* stale words queued at the first BOOT_ON */
	int f_daemon_open_at_stage;	/* 0 = off, else stage number (1..3) */
	int f_cp_alive_at_start;
	struct mock_script script[16];
	int nscript;
};

enum mock_rec_kind {
	R_IOCTL = 1, R_WRITE, R_READ, R_HOPEN, R_HCLOSE, R_NOTIFY, R_BCLOSE,
};

struct mock_rec {
	uint64_t t_us;
	uint8_t kind;
	uint8_t txlink;
	int32_t ret;
	uint32_t req;		/* ioctl request */
	uint32_t len;		/* write length */
	uint8_t head[16];	/* first bytes written / read */
	uint32_t arg[3];	/* ioctl argument snapshot */
	uint8_t ring[4];	/* SIPC5 header the kernel would put in the ring */
	uint8_t ring_pad;
};

struct mock_evrec {
	uint64_t at;
	int type;
	int gen;
	int len;
	int arg;
	uint8_t data[16];
};

struct mock {
	struct mock_cfg c;
	uint64_t now_us;
	volatile sig_atomic_t *stop;
	int sig_fired;

	struct mock_evrec ev[256];
	int nev;
	int gen;

	/* device state (LS2 10.2) */
	int power, kstate, txlink, armed, cp_status, lli;
	int boot_opens, holder_open[2], cp_boot_done, pending_sim;
	int in_dl_window;
	int attempt, online_count, spi_this_power;

	/* CP model */
	int cp_state;
	unsigned int cp_stage, next_stage;
	uint32_t cp_nframes, cp_next_frame, cp_size, cp_got, cp_crc;
	int cp_fw_seen, fin_acked, cp_dead, silent_now;
	uint64_t cp_status_rise_us;
	int a00d_sent;

	/* RX queue of the boot device */
	struct { uint8_t d[16]; int len; } rxq[512];
	int rxh, rxn;

	/* record of every interaction */
	struct mock_rec *rec;
	size_t nrec, caprec;

	/* counters */
	unsigned int n_ring_writes, n_spi_writes, n_reads4, n_fw_update;
	unsigned int n_modem_on, n_modem_off, n_boot_off, n_get_bootlog, n_clr_bootlog;
	unsigned int n_unmounted_writes, n_late_init_end, n_handler_init_end;
	unsigned int n_crc_frames, n_ioctls, n_holder_opens, n_writes_after_crash;

	/* safety */
	int nviol;
	char viol[16][200];
	int tripwire;
	int idle_deadlock;

	/* sd_notify and state-file capture */
	char notify[64][96];
	int nnotify;
	char states[96][48];
	int nstates;

	/* real ops for files that are not virtual (NV fixtures) */
	struct sl_ops real;
	struct sl_linux_ctx real_ctx;
};

void mock_init(struct mock *m, const struct mock_cfg *c,
	       volatile sig_atomic_t *stop);
void mock_get_ops(struct mock *m, struct sl_ops *ops);
void mock_free(struct mock *m);
void mock_daemon_open(struct mock *m);	/* a third party opens both holders */
void mock_daemon_close(struct mock *m);
void mock_viol(struct mock *m, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));

#define MOCK_BOOT_FD	7000
#define MOCK_IPC_FD	7001
#define MOCK_RFS_FD	7002
#define MOCK_IMG_FD	7100
#define MOCK_DAEMON_FD	7200

#endif
