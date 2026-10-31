/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * shannon-loader: injectable I/O layer.
 *
 * Every side effect of the loader goes through this table, so that the same
 * code runs against the real kernel (ops_linux.c) and against the C mock of
 * umts_boot0 used by the tests (tests/mock.c).
 *
 * Structural safety: files (RADIO image, NV copy, manifest, .md5, sysfs
 * attributes) can only be opened read-only; the only writable descriptors
 * are the boot device and the two holder nodes. The single file the program
 * writes is the CP state file, through state_publish(), restricted to /run/
 * (sl_state.c). The kmsg log stream and the sd_notify socket are owned by
 * sl_log.c/sl_main.c and sl_ops_linux.c respectively.
 *
 * Conventions: functions return >= 0 on success and -errno on failure.
 */
#ifndef SL_OPS_H
#define SL_OPS_H

#include <stddef.h>
#include <stdint.h>

enum sl_ftype {
	SL_FT_OTHER = 0,
	SL_FT_REG,
	SL_FT_CHR,
	SL_FT_BLK,
	SL_FT_DIR,
	SL_FT_LNK,
};

struct sl_stat {
	enum sl_ftype type;
	uint64_t size;		/* bytes; block devices report their size */
	unsigned int mode;	/* permission bits */
};

struct sl_ops {
	void *ctx;

	/* /dev/umts_boot0: opened O_RDWR | O_CLOEXEC, blocking. */
	int (*boot_open)(void *ctx, const char *path);
	/* returns the ioctl return value (>= 0) or -errno */
	int (*boot_ioctl)(void *ctx, int fd, unsigned long req, void *arg);
	/* one write() call, never retried by the implementation */
	long (*boot_write)(void *ctx, int fd, const void *buf, size_t len);
	long (*boot_read)(void *ctx, int fd, void *buf, size_t len);
	/* 0 = timeout, 1 = *revents valid, -errno (-EINTR on a signal) */
	int (*boot_poll)(void *ctx, int fd, short events, short *revents,
			 int timeout_ms);

	/* /dev/umts_ipc0, /dev/umts_rfs0: O_RDWR | O_NONBLOCK | O_CLOEXEC.
	 * They are held, never read or written. */
	int (*holder_open)(void *ctx, const char *path);

	/* closes any descriptor returned by this table */
	int (*close_fd)(void *ctx, int fd);

	/* Read-only files: O_RDONLY | O_CLOEXEC, plus O_NOFOLLOW if asked.
	 * There is no way to pass other flags. */
	int (*ro_open)(void *ctx, const char *path, int nofollow);
	long (*ro_pread)(void *ctx, int fd, void *buf, size_t len, uint64_t off);
	int (*ro_fstat)(void *ctx, int fd, struct sl_stat *st);
	/* 1 if the filesystem holding fd is mounted read-only, 0 if not */
	int (*ro_fs_readonly)(void *ctx, int fd);

	/* stat() following symlinks */
	int (*path_stat)(void *ctx, const char *path, struct sl_stat *st);
	/* first match of a glob pattern (sorted), 0 or -ENOENT */
	int (*path_glob)(void *ctx, const char *pattern, char *out, size_t outsz);
	/* read a small sysfs attribute (read-only open, read, close);
	 * returns the byte count; the buffer is NUL-terminated */
	long (*sysfs_read)(void *ctx, const char *path, char *buf, size_t len);

	/* CLOCK_MONOTONIC in microseconds */
	uint64_t (*now_us)(void *ctx);
	/* 0, or -EINTR when a signal arrived */
	int (*sleep_ms)(void *ctx, unsigned int ms);

	/* sd_notify(3)-style state message; 0 when no service manager */
	int (*notify)(void *ctx, const char *msg);

	/* replace the CP state file (/run/shannon/cp-state) atomically;
	 * the only file this program ever writes, and only under /run/ */
	int (*state_publish)(void *ctx, const char *text);
};

/* ops_linux.c */
struct sl_linux_ctx {
	char notify_socket[108];	/* copy of $NOTIFY_SOCKET, "" if none */
	const char *state_file;		/* NULL: do not publish */
};

/* sl_state.c */
int sl_state_path_ok(const char *path);
int sl_state_write(const char *path, const char *text);
void sl_ops_linux_init(struct sl_ops *ops, struct sl_linux_ctx *lctx);

#endif /* SL_OPS_H */
