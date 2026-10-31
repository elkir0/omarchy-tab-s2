// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: logging to stderr and /dev/kmsg.
 */
#include "sl_log.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static struct sl_log_cfg g_log = {
	.clock = NULL,
	.to_stderr = 1,
	.kmsg_fd = -1,
	.max_level = SL_LOG_INFO,
};

void sl_log_setup(const struct sl_log_cfg *cfg)
{
	g_log = *cfg;
}

static void write_all(int fd, const char *buf, size_t len)
{
	while (len > 0) {
		ssize_t n = write(fd, buf, len);

		if (n <= 0)
			return;	/* logging must never block the loader */
		buf += n;
		len -= (size_t)n;
	}
}

void sl_log(int level, const char *fmt, ...)
{
	char msg[768];
	char line[900];
	uint64_t us = 0;
	va_list ap;
	int n;

	if (level > g_log.max_level)
		return;
	if (g_log.clock)
		us = g_log.clock(g_log.clock_ctx);

	va_start(ap, fmt);
	vsnprintf(msg, sizeof(msg), fmt, ap);
	va_end(ap);

	n = snprintf(line, sizeof(line), "[%5llu.%06llu] %s",
		     (unsigned long long)(us / 1000000u),
		     (unsigned long long)(us % 1000000u), msg);
	if (n < 0)
		return;
	if ((size_t)n >= sizeof(line))
		n = (int)sizeof(line) - 1;

	if (g_log.sink)
		g_log.sink(g_log.sink_ctx, level, line);

	if (g_log.to_stderr) {
		char out[960];
		int m;

		if (g_log.stderr_prio_prefix)
			m = snprintf(out, sizeof(out), "<%d>%s\n", level, line);
		else
			m = snprintf(out, sizeof(out), "shannon-loader: %s\n", line);
		if (m > 0)
			write_all(STDERR_FILENO, out,
				  (size_t)m < sizeof(out) ? (size_t)m : sizeof(out) - 1);
	}

	if (g_log.kmsg_fd >= 0) {
		char out[960];
		int m = snprintf(out, sizeof(out), "<%d>shannon-loader: %s\n",
				 level, line);

		/* one write() per record: /dev/kmsg takes one record per call */
		if (m > 0) {
			ssize_t ignored = write(g_log.kmsg_fd, out,
				(size_t)m < sizeof(out) ? (size_t)m : sizeof(out) - 1);
			(void)ignored;
		}
	}
}
