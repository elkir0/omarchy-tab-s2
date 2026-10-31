// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Positive control for nv_guard.so: each mode performs one forbidden (or
 * allowed) operation. Under the guard, forbidden modes must end with exit
 * code 86 before the operation returns.
 *
 *   guard_selftest ro|rw|creat|fopen|trunc|rename|unlink|mkdir|ioctl PATH [PATH2]
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	const char *m, *p;
	int fd;

	if (argc < 3)
		return 2;
	m = argv[1];
	p = argv[2];
	if (strcmp(m, "ro") == 0) {
		fd = open(p, O_RDONLY | O_NOFOLLOW);
		return fd >= 0 ? 0 : 3;
	}
	if (strcmp(m, "rw") == 0)
		fd = open(p, O_RDWR);
	else if (strcmp(m, "wronly") == 0)
		fd = open(p, O_WRONLY);
	else if (strcmp(m, "creat") == 0)
		fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	else if (strcmp(m, "openat") == 0)
		fd = openat(AT_FDCWD, p, O_RDWR | O_CREAT, 0600);
	else if (strcmp(m, "fopen") == 0)
		fd = fopen(p, "a") ? 0 : -1;
	else if (strcmp(m, "trunc") == 0)
		fd = truncate(p, 0);
	else if (strcmp(m, "rename") == 0)
		fd = rename(p, argc > 3 ? argv[3] : "/tmp/x");
	else if (strcmp(m, "unlink") == 0)
		fd = unlink(p);
	else if (strcmp(m, "mkdir") == 0)
		fd = mkdir(p, 0700);
	else if (strcmp(m, "ioctl") == 0) {
		fd = open("/dev/null", O_RDONLY);
		/* 0x6F35: the forbidden upload request */
		fd = ioctl(fd, 0x6F35ul, NULL);
	} else
		return 2;
	(void)fd;
	return 1;	/* the guard did not stop us */
}
