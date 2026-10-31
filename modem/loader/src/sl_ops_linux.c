// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: real Linux implementation of struct sl_ops.
 *
 * The only open() calls of the program that can write are boot_open()
 * (the modem boot node) and holder_open() (the two holder nodes), the
 * /dev/kmsg log stream opened in main.c and the /run/ state file written by
 * sl_state.c. Every other file is opened with O_RDONLY | O_CLOEXEC (and
 * O_NOFOLLOW where asked).
 */
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <poll.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "sl_abi.h"
#include "sl_ops.h"

/* The allow-list values must be the kernel's _IO('o', nr) encodings. */
_Static_assert(SL_IOCTL_MODEM_ON == _IO('o', 0x19), "MODEM_ON");
_Static_assert(SL_IOCTL_MODEM_OFF == _IO('o', 0x20), "MODEM_OFF");
_Static_assert(SL_IOCTL_MODEM_BOOT_ON == _IO('o', 0x22), "BOOT_ON");
_Static_assert(SL_IOCTL_MODEM_BOOT_OFF == _IO('o', 0x23), "BOOT_OFF");
_Static_assert(SL_IOCTL_MODEM_BOOT_DONE == _IO('o', 0x24), "BOOT_DONE");
_Static_assert(SL_IOCTL_MODEM_STATUS == _IO('o', 0x27), "STATUS");
_Static_assert(SL_IOCTL_MODEM_DL_START == _IO('o', 0x28), "DL_START");
_Static_assert(SL_IOCTL_MODEM_FW_UPDATE == _IO('o', 0x29), "FW_UPDATE");
_Static_assert(SL_IOCTL_MODEM_SET_TX_LINK == _IO('o', 0x37), "SET_TX_LINK");
_Static_assert(SL_IOCTL_MODEM_GET_CP_BOOTLOG == _IO('o', 0x47), "GET_CP_BOOTLOG");
_Static_assert(SL_IOCTL_MODEM_CLR_CP_BOOTLOG == _IO('o', 0x48), "CLR_CP_BOOTLOG");

static int neg_errno(void)
{
	return errno ? -errno : -EIO;
}

static int lx_boot_open(void *ctx, const char *path)
{
	int fd;

	(void)ctx;
	fd = open(path, O_RDWR | O_CLOEXEC | O_NOCTTY);
	return fd < 0 ? neg_errno() : fd;
}

static int lx_boot_ioctl(void *ctx, int fd, unsigned long req, void *arg)
{
	int r;

	(void)ctx;
	r = ioctl(fd, req, arg);
	return r < 0 ? neg_errno() : r;
}

static long lx_boot_write(void *ctx, int fd, const void *buf, size_t len)
{
	ssize_t n;

	(void)ctx;
	n = write(fd, buf, len);	/* exactly one call, never retried */
	return n < 0 ? neg_errno() : (long)n;
}

static long lx_boot_read(void *ctx, int fd, void *buf, size_t len)
{
	ssize_t n;

	(void)ctx;
	n = read(fd, buf, len);
	return n < 0 ? neg_errno() : (long)n;
}

static int lx_boot_poll(void *ctx, int fd, short events, short *revents,
			int timeout_ms)
{
	struct pollfd p = { .fd = fd, .events = events };
	int r;

	(void)ctx;
	r = poll(&p, 1, timeout_ms);
	if (r < 0)
		return neg_errno();
	*revents = p.revents;
	return r > 0 ? 1 : 0;
}

static int lx_holder_open(void *ctx, const char *path)
{
	int fd;

	(void)ctx;
	fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOCTTY);
	return fd < 0 ? neg_errno() : fd;
}

static int lx_close(void *ctx, int fd)
{
	(void)ctx;
	return close(fd) < 0 ? neg_errno() : 0;
}

static int lx_ro_open(void *ctx, const char *path, int nofollow)
{
	int fd;

	(void)ctx;
	fd = open(path, O_RDONLY | O_CLOEXEC | O_NOCTTY | (nofollow ? O_NOFOLLOW : 0));
	return fd < 0 ? neg_errno() : fd;
}

static long lx_ro_pread(void *ctx, int fd, void *buf, size_t len, uint64_t off)
{
	ssize_t n;

	(void)ctx;
	do {
		n = pread(fd, buf, len, (off_t)off);
	} while (n < 0 && errno == EINTR);
	return n < 0 ? neg_errno() : (long)n;
}

static void fill_stat(const struct stat *s, struct sl_stat *st)
{
	if (S_ISREG(s->st_mode))
		st->type = SL_FT_REG;
	else if (S_ISCHR(s->st_mode))
		st->type = SL_FT_CHR;
	else if (S_ISBLK(s->st_mode))
		st->type = SL_FT_BLK;
	else if (S_ISDIR(s->st_mode))
		st->type = SL_FT_DIR;
	else if (S_ISLNK(s->st_mode))
		st->type = SL_FT_LNK;
	else
		st->type = SL_FT_OTHER;
	st->size = (uint64_t)s->st_size;
	st->mode = (unsigned int)(s->st_mode & 07777);
}

static int lx_ro_fstat(void *ctx, int fd, struct sl_stat *st)
{
	struct stat s;

	(void)ctx;
	if (fstat(fd, &s) < 0)
		return neg_errno();
	fill_stat(&s, st);
	if (st->type == SL_FT_BLK) {
		off_t end = lseek(fd, 0, SEEK_END);

		if (end < 0)
			return neg_errno();
		st->size = (uint64_t)end;
		if (lseek(fd, 0, SEEK_SET) < 0)
			return neg_errno();
	}
	return 0;
}

static int lx_ro_fs_readonly(void *ctx, int fd)
{
	struct statvfs v;

	(void)ctx;
	if (fstatvfs(fd, &v) < 0)
		return neg_errno();
	return (v.f_flag & ST_RDONLY) ? 1 : 0;
}

static int lx_path_stat(void *ctx, const char *path, struct sl_stat *st)
{
	struct stat s;

	(void)ctx;
	if (stat(path, &s) < 0)
		return neg_errno();
	fill_stat(&s, st);
	return 0;
}

static int lx_path_glob(void *ctx, const char *pattern, char *out, size_t outsz)
{
	glob_t g;
	int rc = -ENOENT;

	(void)ctx;
	memset(&g, 0, sizeof(g));
	if (glob(pattern, GLOB_ERR, NULL, &g) == 0 && g.gl_pathc > 0) {
		size_t len = strlen(g.gl_pathv[0]);

		if (len < outsz) {
			memcpy(out, g.gl_pathv[0], len + 1);
			rc = 0;
		} else {
			rc = -ENAMETOOLONG;
		}
	}
	globfree(&g);
	return rc;
}

static long lx_sysfs_read(void *ctx, const char *path, char *buf, size_t len)
{
	ssize_t n;
	int fd;

	(void)ctx;
	if (len == 0)
		return -EINVAL;
	fd = open(path, O_RDONLY | O_CLOEXEC | O_NOCTTY);
	if (fd < 0)
		return neg_errno();
	do {
		n = read(fd, buf, len - 1);
	} while (n < 0 && errno == EINTR);
	if (n < 0) {
		int e = neg_errno();

		close(fd);
		return e;
	}
	buf[n] = '\0';
	close(fd);
	return (long)n;
}

static uint64_t lx_now_us(void *ctx)
{
	struct timespec ts;

	(void)ctx;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static int lx_sleep_ms(void *ctx, unsigned int ms)
{
	struct timespec ts = {
		.tv_sec = ms / 1000u,
		.tv_nsec = (long)(ms % 1000u) * 1000000L,
	};

	(void)ctx;
	return nanosleep(&ts, NULL) < 0 ? neg_errno() : 0;
}

/* sd_notify(3) protocol, written by hand: one datagram to $NOTIFY_SOCKET */
static int lx_notify(void *ctx, const char *msg)
{
	struct sl_linux_ctx *lc = ctx;
	struct sockaddr_un sa;
	size_t plen = strlen(lc->notify_socket);
	socklen_t salen;
	ssize_t n;
	int fd;

	if (plen == 0)
		return 0;
	if (plen >= sizeof(sa.sun_path) ||
	    (lc->notify_socket[0] != '/' && lc->notify_socket[0] != '@'))
		return -EAFNOSUPPORT;
	memset(&sa, 0, sizeof(sa));
	sa.sun_family = AF_UNIX;
	memcpy(sa.sun_path, lc->notify_socket, plen);
	if (sa.sun_path[0] == '@')
		sa.sun_path[0] = '\0';	/* abstract namespace */
	salen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + plen);

	fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return neg_errno();
	n = sendto(fd, msg, strlen(msg), MSG_NOSIGNAL, (struct sockaddr *)&sa, salen);
	if (n < 0) {
		int e = neg_errno();

		close(fd);
		return e;
	}
	close(fd);
	return 0;
}

static int lx_state_publish(void *ctx, const char *text)
{
	struct sl_linux_ctx *lc = ctx;

	return lc->state_file ? sl_state_write(lc->state_file, text) : 0;
}

void sl_ops_linux_init(struct sl_ops *ops, struct sl_linux_ctx *lctx)
{
	const char *ns = getenv("NOTIFY_SOCKET");

	memset(lctx, 0, sizeof(*lctx));
	if (ns && strlen(ns) < sizeof(lctx->notify_socket))
		memcpy(lctx->notify_socket, ns, strlen(ns) + 1);

	memset(ops, 0, sizeof(*ops));
	ops->ctx = lctx;
	ops->boot_open = lx_boot_open;
	ops->boot_ioctl = lx_boot_ioctl;
	ops->boot_write = lx_boot_write;
	ops->boot_read = lx_boot_read;
	ops->boot_poll = lx_boot_poll;
	ops->holder_open = lx_holder_open;
	ops->close_fd = lx_close;
	ops->ro_open = lx_ro_open;
	ops->ro_pread = lx_ro_pread;
	ops->ro_fstat = lx_ro_fstat;
	ops->ro_fs_readonly = lx_ro_fs_readonly;
	ops->path_stat = lx_path_stat;
	ops->path_glob = lx_path_glob;
	ops->sysfs_read = lx_sysfs_read;
	ops->now_us = lx_now_us;
	ops->sleep_ms = lx_sleep_ms;
	ops->notify = lx_notify;
	ops->state_publish = lx_state_publish;
}
