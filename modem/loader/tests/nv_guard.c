// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * nv_guard.so: LD_PRELOAD tripwire for the shannon-loader tests (LS2 10.1).
 *
 * Any attempt by the process to open for writing, create, truncate, rename,
 * unlink or make a directory/link under a guarded path ends the process
 * with exit code 86 and a line on stderr (and in $NV_GUARD_LOG). The same
 * happens for a write-open of a guarded sysfs attribute (lli_control,
 * cp_status) and for the dump/crash/upload ioctls.
 *
 *   NV_GUARD_PATHS  colon-separated directory prefixes (NV copy, /efs, ...)
 *   NV_GUARD_SYSFS  colon-separated exact paths (lli_control, cp_status)
 *   NV_GUARD_LOG    optional file collecting violation lines
 *
 * Built without _FILE_OFFSET_BITS so that the symbol names are the plain
 * ones; the 64-bit variants are wrapped explicitly.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define GUARD_EXIT 86
#define WRITE_FLAGS (O_WRONLY | O_RDWR | O_CREAT | O_TRUNC | O_APPEND)

static void report(const char *what, const char *path, long flags)
{
	char line[PATH_MAX + 128];
	const char *log = getenv("NV_GUARD_LOG");
	int n = snprintf(line, sizeof(line), "NV-GUARD VIOLATION: %s(%s, 0x%lx)\n",
			 what, path ? path : "-", flags);

	if (n > 0) {
		ssize_t ignored = write(2, line, (size_t)n);

		(void)ignored;
		if (log && *log) {
			/* raw syscall: our own open() wrapper must not recurse */
			long fd = syscall(SYS_openat, AT_FDCWD, log,
					  O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);

			if (fd >= 0) {
				ignored = write((int)fd, line, (size_t)n);
				close((int)fd);
			}
		}
	}
	_exit(GUARD_EXIT);
}

static int under(const char *path, const char *prefix, size_t plen)
{
	return strncmp(path, prefix, plen) == 0 &&
	       (path[plen] == '/' || path[plen] == '\0');
}

static int list_match(const char *path, const char *env, int prefix_mode)
{
	const char *l = getenv(env);

	while (l && *l) {
		const char *c = strchr(l, ':');
		size_t len = c ? (size_t)(c - l) : strlen(l);

		if (len > 0) {
			if (prefix_mode ? under(path, l, len) :
			    (strlen(path) == len && strncmp(path, l, len) == 0))
				return 1;
		}
		if (!c)
			break;
		l = c + 1;
	}
	return 0;
}

/* absolute form of (dirfd, path), plus its parent resolved through links */
static int guarded_at(int dirfd, const char *path)
{
	char abs[PATH_MAX], res[PATH_MAX], parent[PATH_MAX];
	char *slash;

	if (!path)
		return 0;
	if (path[0] == '/') {
		snprintf(abs, sizeof(abs), "%s", path);
	} else {
		char base[PATH_MAX];

		if (dirfd == AT_FDCWD) {
			if (!getcwd(base, sizeof(base)))
				return 1;	/* unknown: be strict */
		} else {
			char link[64];
			ssize_t n;

			snprintf(link, sizeof(link), "/proc/self/fd/%d", dirfd);
			n = readlink(link, base, sizeof(base) - 1);
			if (n < 0)
				return 1;
			base[n] = '\0';
		}
		snprintf(abs, sizeof(abs), "%s/%s", base, path);
	}
	if (list_match(abs, "NV_GUARD_PATHS", 1) || list_match(abs, "NV_GUARD_SYSFS", 0))
		return 1;
	if (realpath(abs, res) &&
	    (list_match(res, "NV_GUARD_PATHS", 1) || list_match(res, "NV_GUARD_SYSFS", 0)))
		return 1;
	snprintf(parent, sizeof(parent), "%s", abs);
	slash = strrchr(parent, '/');
	if (slash && slash != parent) {
		*slash = '\0';
		if (realpath(parent, res) && list_match(res, "NV_GUARD_PATHS", 1))
			return 1;
	}
	return 0;
}

static int guarded(const char *path)
{
	return guarded_at(AT_FDCWD, path);
}

#define REAL(name, type) \
	static type real_##name; \
	if (!real_##name) \
		real_##name = (type)dlsym(RTLD_NEXT, #name)

static int open_mode_needed(int flags)
{
#ifdef O_TMPFILE
	if ((flags & O_TMPFILE) == O_TMPFILE)
		return 1;
#endif
	return (flags & O_CREAT) != 0;
}

#define GET_MODE(flags, mode) do { \
	if (open_mode_needed(flags)) { \
		va_list ap; \
		va_start(ap, flags); \
		mode = (mode_t)va_arg(ap, int); \
		va_end(ap); \
	} \
} while (0)

typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);

int open(const char *path, int flags, ...)
{
	mode_t mode = 0;

	REAL(open, open_fn);
	GET_MODE(flags, mode);
	if ((flags & WRITE_FLAGS) && guarded(path))
		report("open", path, flags);
	return real_open(path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
	mode_t mode = 0;

	REAL(open64, open_fn);
	GET_MODE(flags, mode);
	if ((flags & WRITE_FLAGS) && guarded(path))
		report("open64", path, flags);
	return real_open64(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;

	REAL(openat, openat_fn);
	GET_MODE(flags, mode);
	if ((flags & WRITE_FLAGS) && guarded_at(dirfd, path))
		report("openat", path, flags);
	return real_openat(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
	mode_t mode = 0;

	REAL(openat64, openat_fn);
	GET_MODE(flags, mode);
	if ((flags & WRITE_FLAGS) && guarded_at(dirfd, path))
		report("openat64", path, flags);
	return real_openat64(dirfd, path, flags, mode);
}

/* _FORTIFY_SOURCE entry points */
int __open_2(const char *path, int flags);
int __open_2(const char *path, int flags)
{
	if ((flags & WRITE_FLAGS) && guarded(path))
		report("__open_2", path, flags);
	return open(path, flags);
}

int __open64_2(const char *path, int flags);
int __open64_2(const char *path, int flags)
{
	if ((flags & WRITE_FLAGS) && guarded(path))
		report("__open64_2", path, flags);
	return open64(path, flags);
}

int __openat_2(int dirfd, const char *path, int flags);
int __openat_2(int dirfd, const char *path, int flags)
{
	if ((flags & WRITE_FLAGS) && guarded_at(dirfd, path))
		report("__openat_2", path, flags);
	return openat(dirfd, path, flags);
}

int creat(const char *path, mode_t mode)
{
	if (guarded(path))
		report("creat", path, 0);
	return open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
}

int creat64(const char *path, mode_t mode)
{
	if (guarded(path))
		report("creat64", path, 0);
	return open64(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
}

static int fmode_writes(const char *mode)
{
	return mode && (strchr(mode, 'w') || strchr(mode, 'a') || strchr(mode, '+'));
}

typedef FILE *(*fopen_fn)(const char *, const char *);
typedef FILE *(*freopen_fn)(const char *, const char *, FILE *);

FILE *fopen(const char *path, const char *mode)
{
	REAL(fopen, fopen_fn);
	if (fmode_writes(mode) && guarded(path))
		report("fopen", path, 0);
	return real_fopen(path, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
	REAL(fopen64, fopen_fn);
	if (fmode_writes(mode) && guarded(path))
		report("fopen64", path, 0);
	return real_fopen64(path, mode);
}

FILE *freopen(const char *path, const char *mode, FILE *f)
{
	REAL(freopen, freopen_fn);
	if (fmode_writes(mode) && guarded(path))
		report("freopen", path, 0);
	return real_freopen(path, mode, f);
}

typedef int (*path1_fn)(const char *);
typedef int (*path2_fn)(const char *, const char *);
typedef int (*trunc_fn)(const char *, off_t);
typedef int (*mkdir_fn)(const char *, mode_t);
typedef int (*unlinkat_fn)(int, const char *, int);
typedef int (*renameat_fn)(int, const char *, int, const char *);
typedef int (*renameat2_fn)(int, const char *, int, const char *, unsigned int);

int truncate(const char *path, off_t len)
{
	REAL(truncate, trunc_fn);
	if (guarded(path))
		report("truncate", path, 0);
	return real_truncate(path, len);
}

int unlink(const char *path)
{
	REAL(unlink, path1_fn);
	if (guarded(path))
		report("unlink", path, 0);
	return real_unlink(path);
}

int unlinkat(int dirfd, const char *path, int flags)
{
	REAL(unlinkat, unlinkat_fn);
	if (guarded_at(dirfd, path))
		report("unlinkat", path, flags);
	return real_unlinkat(dirfd, path, flags);
}

int rmdir(const char *path)
{
	REAL(rmdir, path1_fn);
	if (guarded(path))
		report("rmdir", path, 0);
	return real_rmdir(path);
}

int rename(const char *a, const char *b)
{
	REAL(rename, path2_fn);
	if (guarded(a) || guarded(b))
		report("rename", a, 0);
	return real_rename(a, b);
}

int renameat(int da, const char *a, int db, const char *b)
{
	REAL(renameat, renameat_fn);
	if (guarded_at(da, a) || guarded_at(db, b))
		report("renameat", a, 0);
	return real_renameat(da, a, db, b);
}

int renameat2(int da, const char *a, int db, const char *b, unsigned int fl)
{
	REAL(renameat2, renameat2_fn);
	if (guarded_at(da, a) || guarded_at(db, b))
		report("renameat2", a, fl);
	return real_renameat2(da, a, db, b, fl);
}

int mkdir(const char *path, mode_t mode)
{
	REAL(mkdir, mkdir_fn);
	if (guarded(path))
		report("mkdir", path, 0);
	return real_mkdir(path, mode);
}

int symlink(const char *target, const char *linkpath)
{
	REAL(symlink, path2_fn);
	if (guarded(linkpath))
		report("symlink", linkpath, 0);
	return real_symlink(target, linkpath);
}

int link(const char *a, const char *b)
{
	REAL(link, path2_fn);
	if (guarded(b))
		report("link", b, 0);
	return real_link(a, b);
}

typedef int (*ioctl_fn)(int, unsigned long, ...);

/* dump / crash / upload requests of modem_v1 */
int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;

	REAL(ioctl, ioctl_fn);
	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	if (req == 0x6F32ul || req == 0x6F34ul || req == 0x6F35ul || req == 0x6F36ul)
		report("ioctl", NULL, (long)req);
	return real_ioctl(fd, req, arg);
}
