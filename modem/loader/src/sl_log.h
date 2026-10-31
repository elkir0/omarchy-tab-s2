/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * shannon-loader: logging.
 *
 * Every line carries a CLOCK_MONOTONIC timestamp so that it can be lined up
 * with dmesg. Lines go to stderr (journal) and, with --kmsg, to /dev/kmsg
 * with the prefix "shannon-loader:". NV bytes are never logged: callers log
 * sizes and hashes only.
 */
#ifndef SL_LOG_H
#define SL_LOG_H

#include <stdint.h>

enum sl_log_level {
	SL_LOG_ERR = 3,
	SL_LOG_WARN = 4,
	SL_LOG_NOTICE = 5,
	SL_LOG_INFO = 6,
	SL_LOG_DEBUG = 7,
};

typedef uint64_t (*sl_clock_fn)(void *ctx);
typedef void (*sl_log_sink_fn)(void *ctx, int level, const char *line);

struct sl_log_cfg {
	sl_clock_fn clock;		/* monotonic microseconds */
	void *clock_ctx;
	int to_stderr;			/* 1: write to stderr */
	int stderr_prio_prefix;		/* 1: "<N>" prefix for journald */
	int kmsg_fd;			/* -1: disabled */
	int max_level;			/* lines above this level are dropped */
	sl_log_sink_fn sink;		/* optional extra sink (tests) */
	void *sink_ctx;
};

void sl_log_setup(const struct sl_log_cfg *cfg);
void sl_log(int level, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));

#define sl_err(...)	sl_log(SL_LOG_ERR, __VA_ARGS__)
#define sl_warn(...)	sl_log(SL_LOG_WARN, __VA_ARGS__)
#define sl_notice(...)	sl_log(SL_LOG_NOTICE, __VA_ARGS__)
#define sl_info(...)	sl_log(SL_LOG_INFO, __VA_ARGS__)
#define sl_dbg(...)	sl_log(SL_LOG_DEBUG, __VA_ARGS__)

#endif /* SL_LOG_H */
