/*
 * dmabuf-import-test: does exynos-drm accept a panfrost (shmem, so
 * non-contiguous) buffer?  This is what Hyprland does with every client
 * buffer.  No libc: raw ARM EABI syscalls, so it builds with the kernel
 * cross compiler and runs on any armhf root.
 *
 *   arm-linux-gnueabihf-gcc -O2 -marm -static -nostdlib -ffreestanding \
 *       -fno-stack-protector -o dmabuf-import-test dmabuf-import-test.c
 *
 * Prints one line per step; exit 0 = imported, 1 = import refused,
 * 2 = setup failed.  Without a DECON System MMU the import fails with
 * EINVAL ("buffer chunks must be mapped contiguously" in dmesg).
 */
typedef unsigned int u32;
typedef unsigned long long u64;

#define NR_exit		1
#define NR_write	4
#define NR_open		5
#define NR_ioctl	54

static long sys3(long nr, long a, long b, long c)
{
	register long r7 asm("r7") = nr;
	register long r0 asm("r0") = a;
	register long r1 asm("r1") = b;
	register long r2 asm("r2") = c;

	asm volatile("svc #0" : "+r"(r0) : "r"(r7), "r"(r1), "r"(r2) : "memory");
	return r0;
}

/* _IOWR('d', nr, size) */
#define DRM_IOWR(nr, size)	((3u << 30) | ((size) << 16) | ('d' << 8) | (nr))

struct drm_panfrost_create_bo {	/* include/uapi/drm/panfrost_drm.h */
	u32 size;
	u32 flags;
	u32 handle;
	u32 pad;
	u64 offset;
};

struct drm_prime_handle {		/* include/uapi/drm/drm.h */
	u32 handle;
	u32 flags;
	int fd;
};

#define PANFROST_CREATE_BO	DRM_IOWR(0x40 + 0x02, sizeof(struct drm_panfrost_create_bo))
#define PRIME_HANDLE_TO_FD	DRM_IOWR(0x2d, sizeof(struct drm_prime_handle))
#define PRIME_FD_TO_HANDLE	DRM_IOWR(0x2e, sizeof(struct drm_prime_handle))
#define DRM_CLOEXEC		02000000
#define DRM_RDWR		02

static void puts1(const char *s)
{
	const char *e = s;

	while (*e)
		e++;
	sys3(NR_write, 1, (long)s, e - s);
}

static void putnum(long v)
{
	char b[16];
	int i = 15;

	b[i] = 0;
	if (v < 0) {
		puts1("-");
		v = -v;
	}
	do {
		b[--i] = '0' + v % 10;
		v /= 10;
	} while (v);
	puts1(b + i);
}

static void step(const char *what, long ret)
{
	puts1(what);
	puts1(": ");
	putnum(ret);
	puts1(ret < 0 ? " (-errno)\n" : "\n");
}

static void quit(long code)
{
	sys3(NR_exit, code, 0, 0);
	for (;;)
		;
}

void _start(void)
{
	struct drm_panfrost_create_bo bo = { .size = 1536 * 2048 * 4 };
	struct drm_prime_handle exp = { 0 }, imp = { 0 };
	long gpu, kms, ret;

	gpu = sys3(NR_open, (long)"/tmp/t715-gpu", 2, 0);
	kms = sys3(NR_open, (long)"/tmp/t715-kms", 2, 0);
	step("open panfrost render node", gpu);
	step("open exynos-drm card", kms);
	if (gpu < 0 || kms < 0)
		quit(2);

	ret = sys3(NR_ioctl, gpu, PANFROST_CREATE_BO, (long)&bo);
	step("panfrost CREATE_BO 12 MiB", ret);
	if (ret < 0)
		quit(2);

	exp.handle = bo.handle;
	exp.flags = DRM_CLOEXEC | DRM_RDWR;
	ret = sys3(NR_ioctl, gpu, PRIME_HANDLE_TO_FD, (long)&exp);
	step("panfrost PRIME_HANDLE_TO_FD", ret);
	if (ret < 0)
		quit(2);

	imp.fd = exp.fd;
	ret = sys3(NR_ioctl, kms, PRIME_FD_TO_HANDLE, (long)&imp);
	step("exynos-drm PRIME_FD_TO_HANDLE", ret);
	puts1(ret < 0 ? "RESULT: import refused\n" : "RESULT: imported\n");
	quit(ret < 0 ? 1 : 0);
}
