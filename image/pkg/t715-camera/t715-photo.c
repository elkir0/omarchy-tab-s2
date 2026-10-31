// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * t715-photo: take a photograph with t715-camera.ko.  Finds an exposure, averages a few
 * raw frames, then a half-resolution demosaic, gray-world white balance and gamma, into
 * a PNG.  The sensors give raw Bayer and there is no ISP: all of that happens here.
 *
 *   t715-photo [-d /dev/video0] [-e exposure] [-g gain] [-v vblank] [-n frames] OUT.png
 *
 * With -e, the exposure is fixed.  Without it, the program steers exposure, gain and
 * frame length from the frames it reads, for a dark room as for daylight.
 *
 * Static, with no library: the PNG holds stored deflate blocks.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <math.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define NBUF 3

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

static void die(const char *what)
{
	perror(what);
	exit(1);
}

static void set_ctrl(int fd, unsigned int id, int value)
{
	struct v4l2_control c = { .id = id, .value = value };

	if (value >= 0 && xioctl(fd, VIDIOC_S_CTRL, &c) < 0)
		die("VIDIOC_S_CTRL");
}

/* Mean of the green cells above the black level, on a coarse grid. */
static float frame_mean(const uint16_t *p, unsigned int w, unsigned int h)
{
	unsigned long long sum = 0;
	unsigned int n = 0;

	for (unsigned int y = 0; y < h; y += 16)
		for (unsigned int x = 0; x < w; x += 16, n++)
			sum += p[(size_t)y * w + x];
	return (float)sum / n - 64;
}

/*
 * One step of auto exposure, on a frame of the given mean; true when it is good.  Lines
 * first, then the frame gets longer, then analogue gain.
 */
#define AE_TARGET 110.f
#define AE_MAX_LINES 0x7ff0
static int ae_step(int fd, float mean, unsigned int h, int *lines, int *gain, int *vblank)
{
	float want;

	if (mean > AE_TARGET * 0.7f && mean < AE_TARGET * 1.4f)
		return 1;
	want = *lines * (AE_TARGET / (mean < 1 ? 1 : mean));
	if (want > AE_MAX_LINES) {
		if (*lines >= AE_MAX_LINES && *gain >= 0x100)
			return 1;
		*gain = want / AE_MAX_LINES * *gain;
		*gain = *gain > 0x100 ? 0x100 : *gain;
		want = AE_MAX_LINES;
	} else if (want < 8) {
		want = 8;
	}
	*lines = want;
	if (*lines + 16 > (int)h + *vblank) {
		*vblank = *lines + 16 - h;
		set_ctrl(fd, V4L2_CID_VBLANK, *vblank);
	}
	set_ctrl(fd, V4L2_CID_EXPOSURE, *lines);
	set_ctrl(fd, V4L2_CID_ANALOGUE_GAIN, *gain);
	return 0;
}

static uint32_t crc_table[256];

static uint32_t crc(uint32_t c, const uint8_t *p, size_t n)
{
	while (n--)
		c = crc_table[(c ^ *p++) & 0xff] ^ (c >> 8);
	return c;
}

static void be32(uint8_t *p, uint32_t v)
{
	p[0] = v >> 24;
	p[1] = v >> 16;
	p[2] = v >> 8;
	p[3] = v;
}

static void chunk(FILE *f, const char *type, const uint8_t *data, size_t n)
{
	uint8_t b[4];
	uint32_t c;

	be32(b, n);
	fwrite(b, 1, 4, f);
	fwrite(type, 1, 4, f);
	fwrite(data, 1, n, f);
	c = crc(0xffffffff, (const uint8_t *)type, 4);
	c = crc(c, data, n) ^ 0xffffffff;
	be32(b, c);
	fwrite(b, 1, 4, f);
}

static void write_png(const char *path, const uint8_t *rgb, unsigned int w, unsigned int h)
{
	size_t raw = (size_t)(w * 3 + 1) * h, blocks = raw / 65535 + 1, n = 2 + raw + blocks * 5 + 4;
	uint8_t *z = malloc(n), *out = z;
	uint8_t *row = malloc(raw);
	uint32_t a = 1, b = 0;
	size_t i, left, off = 0;
	uint8_t ihdr[13] = { 0 };
	FILE *f = fopen(path, "wb");

	if (!f || !z || !row)
		die(path);
	for (i = 0; i < 256; i++) {
		uint32_t c = i;

		for (int k = 0; k < 8; k++)
			c = c & 1 ? 0xedb88320 ^ (c >> 1) : c >> 1;
		crc_table[i] = c;
	}
	for (unsigned int y = 0; y < h; y++) {
		row[y * (size_t)(w * 3 + 1)] = 0;
		memcpy(row + y * (size_t)(w * 3 + 1) + 1, rgb + y * (size_t)w * 3, w * 3);
	}
	for (i = 0; i < raw; i++) {
		a = (a + row[i]) % 65521;
		b = (b + a) % 65521;
	}
	*out++ = 0x78;
	*out++ = 0x01;
	for (left = raw; left || off == 0; ) {
		size_t len = left > 65535 ? 65535 : left;

		*out++ = len == left;
		*out++ = len;
		*out++ = len >> 8;
		*out++ = ~len;
		*out++ = (~len) >> 8;
		memcpy(out, row + off, len);
		out += len;
		off += len;
		left -= len;
		if (!left)
			break;
	}
	be32(out, b << 16 | a);
	out += 4;
	fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
	be32(ihdr, w);
	be32(ihdr + 4, h);
	ihdr[8] = 8;
	ihdr[9] = 2;
	chunk(f, "IHDR", ihdr, 13);
	chunk(f, "IDAT", z, out - z);
	chunk(f, "IEND", NULL, 0);
	fclose(f);
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/video0", *out;
	int exposure = -1, gain = -1, vblank = -1, frames = 4, opt, fd, auto_exposure;
	int ae_tries = 10, ae_done, lines, ae_gain, ae_vblank;
	struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_requestbuffers req = { .count = NBUF, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
					   .memory = V4L2_MEMORY_MMAP };
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	void *map[NBUF];
	uint32_t *sum;
	uint8_t *rgb;
	float *plane[3], mean[3] = { 0 }, top = 0, lut_scale;
	unsigned int w, h, w2, h2, got = 0, skip = 2;
	size_t i;

	while ((opt = getopt(argc, argv, "d:e:g:v:n:")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 'e': exposure = strtol(optarg, NULL, 0); break;
		case 'g': gain = strtol(optarg, NULL, 0); break;
		case 'v': vblank = strtol(optarg, NULL, 0); break;
		case 'n': frames = atoi(optarg); break;
		default: return 2;
		}
	}
	if (optind >= argc)
		return 2;
	out = argv[optind];

	fd = open(dev, O_RDWR);
	if (fd < 0)
		die(dev);
	if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0)
		die("VIDIOC_G_FMT");
	w = fmt.fmt.pix.width;
	h = fmt.fmt.pix.height;
	auto_exposure = exposure < 0;
	if (auto_exposure) {
		exposure = h / 2;
		gain = gain < 0 ? 0x40 : gain;
		vblank = vblank < 0 ? 200 : vblank;
	}
	lines = exposure;
	ae_gain = gain;
	ae_vblank = vblank;
	ae_done = !auto_exposure;
	set_ctrl(fd, V4L2_CID_VBLANK, vblank);
	set_ctrl(fd, V4L2_CID_EXPOSURE, exposure);
	set_ctrl(fd, V4L2_CID_ANALOGUE_GAIN, gain);
	if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2)
		die("VIDIOC_REQBUFS");
	for (i = 0; i < req.count; i++) {
		struct v4l2_buffer b = { .index = i, .type = type, .memory = V4L2_MEMORY_MMAP };

		if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0)
			die("VIDIOC_QUERYBUF");
		map[i] = mmap(NULL, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
		if (map[i] == MAP_FAILED)
			die("mmap");
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0)
			die("VIDIOC_QBUF");
	}
	if (xioctl(fd, VIDIOC_STREAMON, &type) < 0)
		die("VIDIOC_STREAMON");

	sum = calloc((size_t)w * h, sizeof(*sum));
	if (!sum)
		die("calloc");
	while (got < (unsigned int)frames) {
		struct v4l2_buffer b = { .type = type, .memory = V4L2_MEMORY_MMAP };
		struct pollfd ready = { .fd = fd, .events = POLLIN };

		/* A dead link gives no frame and no error; the longest frame takes 2 s. */
		if (poll(&ready, 1, 15000) <= 0) {
			fprintf(stderr, "t715-photo: no frame in 15 s\n");
			exit(1);
		}
		if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)
			die("VIDIOC_DQBUF");
		if (skip) {
			skip--;
		} else if (!ae_done) {
			ae_done = ae_step(fd, frame_mean(map[b.index], w, h), h, &lines, &ae_gain,
					  &ae_vblank) || !--ae_tries;
			skip = ae_done ? 1 : 2;	/* the sensor takes two frames to follow */
		} else {
			const uint16_t *p = map[b.index];

			for (i = 0; i < (size_t)w * h; i++)
				sum[i] += p[i];
			got++;
		}
		if (xioctl(fd, VIDIOC_QBUF, &b) < 0)
			die("VIDIOC_QBUF");
	}
	xioctl(fd, VIDIOC_STREAMOFF, &type);
	close(fd);

	/* GRBG; half resolution, each output pixel one 2x2 cell. */
	w2 = w / 2;
	h2 = h / 2;
	for (i = 0; i < 3; i++)
		plane[i] = malloc((size_t)w2 * h2 * sizeof(float));
	rgb = malloc((size_t)w2 * h2 * 3);
	for (unsigned int y = 0; y < h2; y++) {
		const uint32_t *r0 = sum + (size_t)y * 2 * w, *r1 = r0 + w;

		for (unsigned int x = 0; x < w2; x++) {
			float gr = r0[x * 2], r = r0[x * 2 + 1], b = r1[x * 2], gb = r1[x * 2 + 1];
			size_t o = (size_t)y * w2 + x;

			plane[0][o] = r / frames - 64;
			plane[1][o] = (gr + gb) / 2 / frames - 64;
			plane[2][o] = b / frames - 64;
		}
	}
	for (int c = 0; c < 3; c++) {
		for (i = 0; i < (size_t)w2 * h2; i++)
			mean[c] += plane[c][i];
		mean[c] /= (float)w2 * h2;
		if (mean[c] < 1)
			mean[c] = 1;
	}
	/* The top of the picture is the 99.5th percentile: hot pixels do not count. */
	{
		static unsigned int hist[1024];
		size_t n = 0, seen = 0;

		for (i = 0; i < (size_t)w2 * h2; i += 7, n++) {
			int v = plane[1][i];

			hist[v < 0 ? 0 : v > 1023 ? 1023 : v]++;
		}
		for (int v = 1023; v >= 0 && !top; v--) {
			seen += hist[v];
			if (seen > n / 200)
				top = v;
		}
	}
	lut_scale = top > 1 ? 1 / top : 1;
	for (i = 0; i < (size_t)w2 * h2; i++) {
		for (int c = 0; c < 3; c++) {
			float v = plane[c][i] * mean[1] / mean[c] * lut_scale;

			v = v < 0 ? 0 : v > 1 ? 1 : v;
			rgb[i * 3 + c] = (uint8_t)(255 * powf(v, 1 / 2.2f));
		}
	}
	write_png(out, rgb, w2, h2);
	printf("%s: %ux%u, %d frames, exposure %d, gain %d, means %.1f %.1f %.1f, top %.1f\n", out,
	       w2, h2, frames, lines, ae_gain, mean[0], mean[1], mean[2], top);
	return 0;
}
