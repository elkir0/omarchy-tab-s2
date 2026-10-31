// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: CP state file for the telephony daemons (SYNTHESIS v2 D4,
 * D5 "Restart contract").
 *
 * Format, one line, replaced atomically (temporary file in the same
 * directory, then rename):
 *     session=<N> state=<booting|online|crashed|offline>\n
 * N increases by one at every CP power-on (MODEM_ON) of this process.
 *
 * This is the only file the program ever writes. The path must live under
 * /run/ (tmpfs, no persistent state) and may not contain "..": it can
 * never name an NV, EFS or sysfs file. The check is done at configuration
 * time and again here, right before each write.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "sl_ops.h"

#define STATE_PREFIX "/run/"

int sl_state_path_ok(const char *path)
{
	size_t n;

	if (!path || strncmp(path, STATE_PREFIX, strlen(STATE_PREFIX)) != 0)
		return 0;
	n = strlen(path);
	if (n >= 200 || path[n - 1] == '/' || strstr(path, "/..") || strstr(path, "//"))
		return 0;
	return 1;
}

int sl_state_write(const char *path, const char *text)
{
	char tmp[220], dir[220];
	char *slash;
	size_t len = strlen(text), off = 0;
	int fd;

	if (!sl_state_path_ok(path))
		return -EPERM;
	snprintf(dir, sizeof(dir), "%s", path);
	slash = strrchr(dir, '/');
	if (!slash || slash == dir)
		return -EINVAL;
	*slash = '\0';
	/* one level below /run/ may be made (e.g. /run/shannon when the
	 * service manager did not provide RuntimeDirectory=) */
	if (mkdir(dir, 0755) != 0 && errno != EEXIST)
		return -errno;
	snprintf(tmp, sizeof(tmp), "%s.tmp", path);
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
	if (fd < 0)
		return -errno;
	while (off < len) {
		ssize_t n = write(fd, text + off, len - off);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			int e = n < 0 ? -errno : -EIO;

			close(fd);
			unlink(tmp);
			return e;
		}
		off += (size_t)n;
	}
	if (close(fd) != 0 || rename(tmp, path) != 0) {
		int e = -errno;

		unlink(tmp);
		return e;
	}
	return 0;
}
