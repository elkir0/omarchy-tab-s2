// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * t715-photo: take a photograph with t715-camera.ko.  Finds an exposure, averages a few
 * raw frames, then a half-resolution demosaic, gray-world white balance and gamma, into
 * a PNG.  The sensors give raw Bayer and there is no ISP: all of that happens here.
 *
 *   t715-photo [-d /dev/video0] [-e exposure] [-g gain] [-v vblank] [-n frames]
 *              [-f focus] [-F] OUT.png
 *
 * With -e, the exposure is fixed.  Without it, the program steers exposure, gain and
 * frame length from the frames it reads, for a dark room as for daylight; past a
 * handheld 1/30 s the gain rises before the exposure may grow again.  The rear camera
 * focuses by a contrast search over the lens positions, unless -f pins the lens or -F
 * leaves it alone; the front camera has no focus control and skips all of it.
 *
 * Static, with no library: the PNG holds stored deflate blocks.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * Coarse focus metric: 8x8 pixel cells, each the sum of its Gr samples above the black
 * level, then the gradient energy of the cell grid, over the number of terms and the
 * square of the mean cell.  Zero on a window without contrast.
 */
static float af_coarse(const uint16_t *win, unsigned int ww, unsigned int wh)
{
	unsigned int cw = ww / 8, ch = wh / 8;
	unsigned int *cell = malloc((size_t)cw * ch * sizeof(*cell));
	double e = 0, mean = 0;
	unsigned long terms = 0;

	if (!cell)
		return 0;
	for (unsigned int y = 0; y < ch; y++)
		for (unsigned int x = 0; x < cw; x++) {
			const uint16_t *c = win + y * 8 * ww + x * 8;
			long s = 0;

			for (unsigned int yy = 0; yy < 8; yy += 2)	/* Gr: even row, even column */
				for (unsigned int xx = 0; xx < 8; xx += 2)
					s += c[yy * ww + xx] - 64;
			cell[y * cw + x] = s > 0 ? s : 0;
		}
	for (unsigned int i = 0; i < cw * ch; i++)
		mean += cell[i];
	mean /= cw * ch;
	if (mean <= 0) {
		free(cell);
		return 0;
	}
	for (unsigned int y = 0; y < ch; y++)
		for (unsigned int x = 0; x < cw; x++) {
			double c0 = cell[y * cw + x];

			if (x + 1 < cw) {
				double d = cell[y * cw + x + 1] - c0;

				e += d * d;
				terms++;
			}
			if (y + 1 < ch) {
				double d = cell[(y + 1) * cw + x] - c0;

				e += d * d;
				terms++;
			}
		}
	free(cell);
	return e / (terms * mean * mean);
}

/*
 * Fine focus metric (Tenengrad): the green plane at half resolution, a 3x3 Sobel on its
 * interior cells, over the number of cells and the square of the mean.  Zero on a window
 * without contrast.
 */
static float af_fine(const uint16_t *win, unsigned int ww, unsigned int wh)
{
	unsigned int gw = ww / 2, gh = wh / 2;
	int *g = malloc((size_t)gw * gh * sizeof(*g));
	double e = 0, mean = 0;

	if (!g)
		return 0;
	for (unsigned int y = 0; y < gh; y++)
		for (unsigned int x = 0; x < gw; x++) {
			const uint16_t *c = win + y * 2 * ww + x * 2;
			int v = (c[0] + c[ww + 1]) / 2 - 64;	/* Gr and Gb of the 2x2 cell */

			g[y * gw + x] = v > 0 ? v : 0;
		}
	for (unsigned int i = 0; i < gw * gh; i++)
		mean += g[i];
	mean /= gw * gh;
	if (mean <= 0) {
		free(g);
		return 0;
	}
	for (unsigned int y = 1; y < gh - 1; y++)
		for (unsigned int x = 1; x < gw - 1; x++) {
			const int *r0 = g + (y - 1) * gw + x, *r1 = r0 + gw, *r2 = r1 + gw;
			double gx = -r0[-1] + r0[1] - 2 * r1[-1] + 2 * r1[1] - r2[-1] + r2[1];
			double gy = -r0[-1] - 2 * r0[0] - r0[1] + r2[-1] + 2 * r2[0] + r2[1];

			e += gx * gx + gy * gy;
		}
	free(g);
	return e / ((gw - 2) * (gh - 2) * mean * mean);
}

/*
 * The contrast search over the lens positions: a coarse sweep over the working range, a
 * fine one around its best, then a parabola through the fine best.  A scene without
 * contrast falls back to the driver's default position.  The measure callback moves the
 * lens, waits and scores; the self-test drives the same search with a simulated lens.
 */
typedef float (*af_measure_t)(void *ctx, int pos, int fine);

struct af_result {
	int coarse_best, fine_best, final;
	int flat;
};

static int af_search(af_measure_t measure, void *ctx, int def_pos, struct af_result *r)
{
	float v[16];
	int pos[16], n = 0, best = 0;

	r->flat = 0;
	r->fine_best = 0;
	for (int p = 400; p <= 700; p += 25) {	/* the coarse sweep: 13 positions */
		pos[n] = p;
		v[n] = measure(ctx, p, 0);
		if (v[n] > v[best])
			best = n;
		n++;
	}
	r->coarse_best = pos[best];
	{
		float vmin = v[0], vmax = v[0];

		for (int i = 1; i < n; i++) {
			if (v[i] < vmin)
				vmin = v[i];
			if (v[i] > vmax)
				vmax = v[i];
		}
		if (vmax <= 0 || (vmin > 0 && vmax / vmin < 1.2f)) {
			r->flat = 1;
			r->final = def_pos;
			return def_pos;
		}
	}
	n = 0;
	best = 0;
	for (int p = r->coarse_best - 24; p <= r->coarse_best + 24; p += 8) {
		if (p < 0 || p > 1023)	/* the range of the control */
			continue;
		pos[n] = p;
		v[n] = measure(ctx, p, 1);
		if (v[n] > v[best])
			best = n;
		n++;
	}
	r->fine_best = pos[best];
	r->final = pos[best];
	if (best > 0 && best < n - 1) {	/* a parabola through the three around the best */
		double m0 = v[best], mm = v[best - 1], mp = v[best + 1];
		double d = mm - 2 * m0 + mp;

		if (d < 0) {
			double off = 0.5 * (mm - mp) / d * 8;

			if (off > 8)
				off = 8;
			if (off < -8)
				off = -8;
			r->final = pos[best] + (int)lround(off);
		}
	}
	if (r->final < 0)
		r->final = 0;
	if (r->final > 1023)
		r->final = 1023;
	return r->final;
}

/*
 * The handheld cap: the lines in 1/30 s, about the longest exposure a hand holds still,
 * from the frame interval and the frame length in lines.
 */
static int ae_handheld_cap(double interval_us, unsigned int h, int vblank)
{
	double line_time = interval_us / ((double)h + vblank);

	return (int)(1000000.0 / 30.0 / line_time + 0.5);
}

#ifndef T715_PHOTO_SELFTEST
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
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
 * One step of auto exposure, on a frame of the given mean; true when it is good.  The
 * lines climb to the handheld cap first and the gain follows, to 0x100; only then may
 * the lines grow on to AE_MAX_LINES, and last the gain again, to 0x200.
 */
#define AE_TARGET 110.f
#define AE_MAX_LINES 0x7ff0
#define AE_GAIN_MID 0x100
#define AE_GAIN_MAX 0x200
static int ae_step(int fd, float mean, int cap, unsigned int h, int *lines, int *gain, int *vblank)
{
	float want, total;
	int l, g;

	if (mean > AE_TARGET * 0.7f && mean < AE_TARGET * 1.4f)
		return 1;
	want = *lines * (AE_TARGET / (mean < 1 ? 1 : mean));
	if (want < 8)
		want = 8;
	total = want * *gain / 0x20;	/* the wanted exposure, in lines at unit gain */
	if (total <= cap) {
		l = total + 0.5f;
		g = 0x20;
	} else if (total <= (float)cap * AE_GAIN_MID / 0x20) {
		l = cap;
		g = total / cap * 0x20 + 0.5f;
	} else if (total <= (float)AE_MAX_LINES * AE_GAIN_MID / 0x20) {
		l = total * 0x20 / AE_GAIN_MID + 0.5f;
		g = AE_GAIN_MID;
	} else {
		l = AE_MAX_LINES;
		g = total / AE_MAX_LINES * 0x20 + 0.5f;
		if (g > AE_GAIN_MAX)
			g = AE_GAIN_MAX;
	}
	if (l >= AE_MAX_LINES && g >= AE_GAIN_MAX && *lines >= AE_MAX_LINES && *gain >= AE_GAIN_MAX)
		return 1;
	*lines = l;
	*gain = g;
	if (*lines + 16 > (int)h + *vblank) {
		*vblank = *lines + 16 - h;
		set_ctrl(fd, V4L2_CID_VBLANK, *vblank);
	}
	set_ctrl(fd, V4L2_CID_EXPOSURE, *lines);
	set_ctrl(fd, V4L2_CID_ANALOGUE_GAIN, *gain);
	return 0;
}

/* Dequeue one frame; a dead link gives no frame and no error, and the longest takes 2 s. */
static struct v4l2_buffer dq_frame(int fd)
{
	struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .memory = V4L2_MEMORY_MMAP };
	struct pollfd ready = { .fd = fd, .events = POLLIN };

	if (poll(&ready, 1, 15000) <= 0) {
		fprintf(stderr, "t715-photo: no frame in 15 s\n");
		exit(1);
	}
	if (xioctl(fd, VIDIOC_DQBUF, &b) < 0)
		die("VIDIOC_DQBUF");
	return b;
}

static void q_frame(int fd, struct v4l2_buffer *b)
{
	if (xioctl(fd, VIDIOC_QBUF, b) < 0)
		die("VIDIOC_QBUF");
}

static int64_t buf_us(const struct v4l2_buffer *b)
{
	return (int64_t)b->timestamp.tv_sec * 1000000 + b->timestamp.tv_usec;
}

/* The deadline after a lens move: 40 ms for the mechanics and two frames of pipeline. */
static int64_t lens_deadline(double interval_us)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000 + 40000 + (int64_t)(2 * interval_us);
}

/*
 * Dequeue until a frame that ended past the deadline of the last lens move; every frame
 * goes back to the driver.
 */
static struct v4l2_buffer lens_frame(int fd, double interval_us)
{
	int64_t deadline = lens_deadline(interval_us);
	struct v4l2_buffer b;

	for (;;) {
		b = dq_frame(fd);
		if (buf_us(&b) > deadline)
			return b;
		q_frame(fd, &b);
	}
}

static void skip_frames(int fd, int n)
{
	while (n-- > 0) {
		struct v4l2_buffer b = dq_frame(fd);

		q_frame(fd, &b);
	}
}

/*
 * The autofocus window and the measurement at one lens position: move, wait out the
 * move, copy the centre half of the frame (the buffers are uncached) and score it.
 */
struct af_dev {
	int fd;
	void **map;
	unsigned int w, wx, wy, ww, wh;
	double interval_us;
	uint16_t *win;
};

static float af_measure_dev(void *ctx, int pos, int fine)
{
	struct af_dev *a = ctx;
	struct v4l2_buffer b;
	float m;

	set_ctrl(a->fd, V4L2_CID_FOCUS_ABSOLUTE, pos);
	b = lens_frame(a->fd, a->interval_us);
	for (unsigned int y = 0; y < a->wh; y++)
		memcpy(a->win + (size_t)y * a->ww,
		       (const uint16_t *)a->map[b.index] + (size_t)(a->wy + y) * a->w + a->wx,
		       a->ww * sizeof(*a->win));
	m = fine ? af_fine(a->win, a->ww, a->wh) : af_coarse(a->win, a->ww, a->wh);
	q_frame(a->fd, &b);
	return m;
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
	int ae_tries = 10, ae_done, lines, ae_gain, ae_vblank, cap, skip = 0;
	int focus_fixed = -1, focus_free = 0, focus_final = -1, has_focus;
	double interval_us;
	struct v4l2_queryctrl qfocus = { .id = V4L2_CID_FOCUS_ABSOLUTE };
	struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_requestbuffers req = { .count = NBUF, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
					   .memory = V4L2_MEMORY_MMAP };
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	void *map[NBUF];
	uint32_t *sum;
	uint8_t *rgb;
	float *plane[3], mean[3] = { 0 }, top = 0, lut_scale;
	unsigned int w, h, w2, h2, got = 0;
	size_t i;

	while ((opt = getopt(argc, argv, "d:e:f:g:v:n:F")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 'e': exposure = strtol(optarg, NULL, 0); break;
		case 'g': gain = strtol(optarg, NULL, 0); break;
		case 'v': vblank = strtol(optarg, NULL, 0); break;
		case 'n': frames = atoi(optarg); break;
		case 'f': focus_fixed = strtol(optarg, NULL, 0); break;
		case 'F': focus_free = 1; break;
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
	has_focus = xioctl(fd, VIDIOC_QUERYCTRL, &qfocus) >= 0 &&
		!(qfocus.flags & V4L2_CTRL_FLAG_DISABLED);
	if (focus_fixed >= 0 && !has_focus) {
		fprintf(stderr, "t715-photo: no focus control on %s\n", dev);
		return 1;
	}
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

	/* Frame interval: the median gap between the timestamps of the first six frames. */
	{
		int64_t t[6], gap[5], tmp;

		for (unsigned int k = 0; k < 6; k++) {
			struct v4l2_buffer b = dq_frame(fd);

			t[k] = buf_us(&b);
			q_frame(fd, &b);
		}
		for (unsigned int k = 0; k < 5; k++)
			gap[k] = t[k + 1] - t[k];
		for (unsigned int k = 1; k < 5; k++)	/* an insertion sort: five gaps */
			for (unsigned int j = k; j > 0 && gap[j - 1] > gap[j]; j--) {
				tmp = gap[j];
				gap[j] = gap[j - 1];
				gap[j - 1] = tmp;
			}
		interval_us = gap[2];
	}
	/* A VBLANK never set rests at the driver's own; only the auto exposure uses the cap. */
	cap = ae_handheld_cap(interval_us, h, ae_vblank > 0 ? ae_vblank : 36);
	if (cap < 8)
		cap = 8;

	while (!ae_done) {
		struct v4l2_buffer b = dq_frame(fd);

		if (skip) {
			skip--;
		} else {
			ae_done = ae_step(fd, frame_mean(map[b.index], w, h), cap, h, &lines,
					  &ae_gain, &ae_vblank) || !--ae_tries;
			skip = 2;	/* the sensor takes two frames to follow */
		}
		q_frame(fd, &b);
	}

	/* Focus: the contrast search, the pinned -f position, or nothing at all. */
	if (has_focus && !focus_free) {
		struct af_dev a = { .fd = fd, .map = map, .w = w, .interval_us = interval_us };
		struct v4l2_buffer b;

		a.wx = (w / 4 + 1) & ~1u;	/* the centre half of the frame, even-aligned */
		a.ww = (w * 3 / 4 & ~1u) - a.wx;
		a.wy = (h / 4 + 1) & ~1u;
		a.wh = (h * 3 / 4 & ~1u) - a.wy;
		a.win = malloc((size_t)a.ww * a.wh * sizeof(*a.win));
		if (!a.win)
			die("malloc");
		if (focus_fixed >= 0) {
			focus_final = focus_fixed;
			fprintf(stderr, "af: fixed %d\n", focus_final);
		} else {
			struct af_result r;

			focus_final = af_search(af_measure_dev, &a, qfocus.default_value, &r);
			if (r.flat)
				fprintf(stderr, "af: flat, default %d\n", focus_final);
			else
				fprintf(stderr, "af: coarse best %d, fine best %d, final %d\n",
					r.coarse_best, r.fine_best, focus_final);
		}
		set_ctrl(fd, V4L2_CID_FOCUS_ABSOLUTE, focus_final);
		b = lens_frame(fd, interval_us);
		q_frame(fd, &b);
	} else if (auto_exposure) {
		skip_frames(fd, 1);	/* one frame between the last write and the shot */
	}

	sum = calloc((size_t)w * h, sizeof(*sum));
	if (!sum)
		die("calloc");
	while (got < (unsigned int)frames) {
		struct v4l2_buffer b = dq_frame(fd);
		const uint16_t *p = map[b.index];

		for (i = 0; i < (size_t)w * h; i++)
			sum[i] += p[i];
		got++;
		q_frame(fd, &b);
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
	if (focus_final >= 0)
		printf("%s: %ux%u, %d frames, exposure %d, gain %d, means %.1f %.1f %.1f, top %.1f, focus %d\n",
		       out, w2, h2, frames, lines, ae_gain, mean[0], mean[1], mean[2], top, focus_final);
	else
		printf("%s: %ux%u, %d frames, exposure %d, gain %d, means %.1f %.1f %.1f, top %.1f, focus -\n",
		       out, w2, h2, frames, lines, ae_gain, mean[0], mean[1], mean[2], top);
	return 0;
}
#else
/* Host self-test: cc -DT715_PHOTO_SELFTEST t715-photo.c -lm */

struct af_sim {
	int peak;
	int flat;
};

/* A lens whose metric is a Gaussian of the position, with deterministic +-3 % noise. */
static float af_measure_sim(void *ctx, int pos, int fine)
{
	struct af_sim *s = ctx;
	double d = pos - s->peak;

	(void)fine;
	if (s->flat)
		return 0.5f;
	return (float)(exp(-d * d / (2.0 * 40 * 40)) * (1.0 + 0.03 * sin(pos * 0.117)));
}

/*
 * A raw window: flat, or a vertical edge at the middle, or that edge box-blurred over
 * nine pixels.
 */
static uint16_t *test_window(unsigned int w, unsigned int h, int edge, int blur)
{
	uint16_t *p = malloc((size_t)w * h * sizeof(*p));

	if (!p)
		return NULL;
	for (unsigned int y = 0; y < h; y++)
		for (unsigned int x = 0; x < w; x++) {
			int v;

			if (!edge) {
				v = 300;
			} else if (!blur) {
				v = x < w / 2 ? 200 : 900;
			} else {
				v = 0;
				for (int k = -4; k <= 4; k++) {
					int xx = (int)x + k;

					xx = xx < 0 ? 0 : xx >= (int)w ? (int)w - 1 : xx;
					v += xx < (int)(w / 2) ? 200 : 900;
				}
				v /= 9;
			}
			p[(size_t)y * w + x] = v;
		}
	return p;
}

int main(void)
{
	struct {
		const char *name;
		int pass;
	} c[6];
	uint16_t *flat, *sharp, *blur;
	struct af_result r;
	struct af_sim sim;
	int n = 0, fail = 0;

	flat = test_window(256, 256, 0, 0);
	sharp = test_window(256, 256, 1, 0);
	blur = test_window(256, 256, 1, 1);
	if (!flat || !sharp || !blur)
		return 1;

	c[n].name = "a flat frame scores 0 on both metrics";
	c[n].pass = af_coarse(flat, 256, 256) == 0 && af_fine(flat, 256, 256) == 0;
	n++;
	c[n].name = "the sharp edge beats the box-blurred one on both metrics";
	c[n].pass = af_coarse(sharp, 256, 256) > af_coarse(blur, 256, 256) &&
		af_fine(sharp, 256, 256) > af_fine(blur, 256, 256);
	n++;
	sim.peak = 544;
	sim.flat = 0;
	af_search(af_measure_sim, &sim, 500, &r);
	c[n].name = "a simulated lens peaked at 544 focuses within 8";
	c[n].pass = !r.flat && r.final >= 544 - 8 && r.final <= 544 + 8;
	n++;
	sim.peak = 488;
	af_search(af_measure_sim, &sim, 500, &r);
	c[n].name = "a simulated lens peaked at 488 focuses within 8";
	c[n].pass = !r.flat && r.final >= 488 - 8 && r.final <= 488 + 8;
	n++;
	sim.flat = 1;
	af_search(af_measure_sim, &sim, 500, &r);
	c[n].name = "a flat scene falls back to the driver default, 500";
	c[n].pass = r.flat && r.final == 500;
	n++;
	{
		int cap = ae_handheld_cap(35000.0, 2458, 36);

		c[n].name = "the handheld cap is 2375 for a 35 ms frame";
		c[n].pass = cap >= 2375 - 5 && cap <= 2375 + 5;
		n++;
	}

	for (int i = 0; i < n; i++)
		if (!c[i].pass) {
			printf("selftest: failed: %s\n", c[i].name);
			fail++;
		}
	if (!fail)
		printf("selftest: all %d checks passed\n", n);
	return fail ? 1 : 0;
}
#endif
