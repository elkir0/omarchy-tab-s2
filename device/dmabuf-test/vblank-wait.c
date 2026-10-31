/*
 * vblank-wait: wait for 600 vblanks on /tmp/t715-kms (DRM_IOCTL_WAIT_VBLANK,
 * relative 1), which keeps the CRTC's vblank interrupt enabled so the
 * DECON frame rate can be counted in /proc/interrupts.  Needs no DRM
 * master.  No libc (raw ARM EABI syscalls), like dmabuf-import-test.
 */
typedef unsigned int u32;

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

/* union drm_wait_vblank (include/uapi/drm/drm.h): 16 bytes on arm32 */
struct wait_vblank {
	u32 type;
	u32 sequence;
	long a;
	long b;
};

#define DRM_IOWR(nr, size)	((3u << 30) | ((size) << 16) | ('d' << 8) | (nr))
#define WAIT_VBLANK		DRM_IOWR(0x3a, sizeof(struct wait_vblank))
#define VBLANK_RELATIVE		0x1

void _start(void)
{
	long fd = sys3(NR_open, (long)"/tmp/t715-kms", 2, 0);
	long bad = 0;
	int i;

	if (fd < 0) {
		sys3(NR_write, 1, (long)"vblank-wait: open failed\n", 25);
		sys3(NR_exit, 2, 0, 0);
	}
	for (i = 0; i < 600; i++) {
		struct wait_vblank v = { VBLANK_RELATIVE, 1, 0, 0 };

		if (sys3(NR_ioctl, fd, WAIT_VBLANK, (long)&v) < 0)
			bad++;
	}
	sys3(NR_write, 1, bad ? (long)"vblank-wait: errors\n" : (long)"vblank-wait: 600 ok\n", 20);
	sys3(NR_exit, bad ? 1 : 0, 0, 0);
	for (;;)
		;
}
