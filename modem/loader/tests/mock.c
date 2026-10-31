// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Mock of the modem_v1 boot device and its environment, virtual clock.
 * Behaviour mirrors LS2 6 and 10.2; the CP side follows SYNTHESIS 2.7.
 *
 * Tripwires (LS2 10.1): the dump/crash/upload ioctls, any std_udl word
 * with a stage >= 4 other than FIN, a CRC frame on a stage other than
 * MAIN, an SPI payload that is not the image's BOOT entry, more than one SPI
 * write per power cycle, a first open of a holder between DL_START and the
 * return of BOOT_OFF, and a power-off inside the eFuse window.
 */
#include <errno.h>
#include <fnmatch.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fixtures.h"
#include "mock.h"
#include "sl_abi.h"
#include "sl_crc32.h"

/* forbidden requests, named here only (tests): never sent by the loader */
#define TRIP_DUMP_START		0x6F32u
#define TRIP_FORCE_CRASH_EXIT	0x6F34u
#define TRIP_CP_UPLOAD		0x6F35u
#define TRIP_DUMP_RESET		0x6F36u

enum cp_st {
	CP_WAIT_BOOT_DONE = 0,
	CP_WAIT_START,
	CP_WAIT_FRAMES,
	CP_WAIT_CRC,
	CP_WAIT_DONE,
	CP_FIN_DONE,
};

void mock_viol(struct mock *m, const char *fmt, ...)
{
	va_list ap;

	if (m->nviol < 16) {
		va_start(ap, fmt);
		vsnprintf(m->viol[m->nviol], sizeof(m->viol[0]), fmt, ap);
		va_end(ap);
	}
	m->nviol++;
}

static struct mock_rec *rec_add(struct mock *m, int kind)
{
	struct mock_rec *r;

	if (m->nrec == m->caprec) {
		size_t cap = m->caprec ? m->caprec * 2 : 4096;
		struct mock_rec *n = realloc(m->rec, cap * sizeof(*n));

		if (!n) {
			fprintf(stderr, "mock: out of memory\n");
			abort();
		}
		m->rec = n;
		m->caprec = cap;
	}
	r = &m->rec[m->nrec++];
	memset(r, 0, sizeof(*r));
	r->kind = (uint8_t)kind;
	r->t_us = m->now_us;
	r->txlink = (uint8_t)m->txlink;
	return r;
}

/* ---------------------------------------------------------------- */
/* events and virtual time                                           */
/* ---------------------------------------------------------------- */

static void ev_add(struct mock *m, uint64_t at, int type, const uint8_t *data,
		   int len, int arg)
{
	struct mock_evrec *e;

	if (m->nev >= (int)(sizeof(m->ev) / sizeof(m->ev[0]))) {
		mock_viol(m, "mock event queue full");
		return;
	}
	e = &m->ev[m->nev++];
	memset(e, 0, sizeof(*e));
	e->at = at;
	e->type = type;
	e->gen = m->gen;
	e->len = len;
	e->arg = arg;
	if (data && len > 0)
		memcpy(e->data, data, (size_t)len);
}

static void rx_push(struct mock *m, const uint8_t *d, int len)
{
	int idx;

	if (m->rxn >= 512) {
		mock_viol(m, "mock rx queue overflow");
		return;
	}
	idx = (m->rxh + m->rxn) % 512;
	memcpy(m->rxq[idx].d, d, (size_t)len);
	m->rxq[idx].len = len;
	m->rxn++;
}

static void schedule_scripts(struct mock *m)
{
	int i;

	for (i = 0; i < m->c.nscript; i++) {
		const struct mock_script *s = &m->c.script[i];

		if (s->on_online == m->online_count)
			ev_add(m, m->now_us + (uint64_t)s->delay_ms * 1000u, s->type,
			       NULL, 0, s->arg);
	}
}

static int ev_apply(struct mock *m, struct mock_evrec *e)
{
	int powered_ev = e->type == MEV_CP_STATUS_HIGH || e->type == MEV_LLI_MOUNT ||
			 e->type == MEV_REPLY;

	if (powered_ev && e->gen != m->gen)
		return 0;	/* belongs to an earlier power cycle */
	switch (e->type) {
	case MEV_CP_STATUS_HIGH:
		m->cp_status = 1;
		m->cp_status_rise_us = m->now_us;
		break;
	case MEV_LLI_MOUNT:
		m->lli = 1;
		break;
	case MEV_REPLY:
		rx_push(m, e->data, e->len);
		break;
	case MEV_SIM_CHANGE:
		m->pending_sim = 1;
		break;
	case MEV_CRASH:
		if (m->kstate == SL_STATE_ONLINE)
			m->kstate = SL_STATE_CRASH_EXIT;
		break;
	case MEV_SIGTERM:
		if (m->stop)
			*m->stop = 1;
		m->sig_fired = 1;
		return 1;
	case MEV_BATTERY:
		m->c.bat_capacity = e->arg;
		break;
	case MEV_DAEMON_OPEN:
		mock_daemon_open(m);
		break;
	}
	return 0;
}

/* Advance the clock to `t`, applying due events in order. Returns 1 if a
 * signal event fired (the clock then stops at that event). */
static int advance_to(struct mock *m, uint64_t t, int stop_on_signal)
{
	for (;;) {
		int i, best = -1;
		struct mock_evrec e;

		for (i = 0; i < m->nev; i++) {
			if (m->ev[i].at <= t && (best < 0 || m->ev[i].at < m->ev[best].at))
				best = i;
		}
		if (best < 0)
			break;
		e = m->ev[best];
		m->ev[best] = m->ev[--m->nev];
		if (e.at > m->now_us)
			m->now_us = e.at;
		if (ev_apply(m, &e) && stop_on_signal)
			return 1;
	}
	if (t > m->now_us)
		m->now_us = t;
	return 0;
}

static int next_event(struct mock *m, uint64_t *at)
{
	int i, found = 0;

	for (i = 0; i < m->nev; i++) {
		if (!found || m->ev[i].at < *at) {
			*at = m->ev[i].at;
			found = 1;
		}
	}
	return found;
}

static int take(int *count)
{
	if (*count == 0)
		return 0;
	if (*count > 0)
		(*count)--;
	return 1;
}

/* ---------------------------------------------------------------- */
/* CP side of std_udl                                                */
/* ---------------------------------------------------------------- */

static uint32_t toc_u32(const struct mock *m, unsigned int slot, unsigned int field)
{
	return get_le32(m->c.image + slot * 32 + 12 + field * 4);
}

static uint32_t stage_size(const struct mock *m, unsigned int s)
{
	switch (s) {
	case 1: return toc_u32(m, 0, 2);
	case 2: return toc_u32(m, 2, 2);
	case 3: return toc_u32(m, 3, 2);
	default: return 0;
	}
}

static void cp_reply(struct mock *m, uint32_t w)
{
	uint8_t d[16];
	int len = 4;

	put_le32(d, w);
	if (m->c.f_read8_for && w == m->c.f_read8_for && take(&m->c.f_read8_count)) {
		put_le32(d + 4, 0xDEADBEEFu);
		len = 8;
	}
	if (w == 0xA00Du)
		m->a00d_sent = 1;
	ev_add(m, m->now_us + (uint64_t)m->c.reply_delay_ms * 1000u, MEV_REPLY, d, len, 0);
}

/* answer `req` with `resp`, unless a wrong-answer fault is armed for it */
static void cp_answer(struct mock *m, uint32_t req, uint32_t resp)
{
	if (m->c.f_wrong_for && req == m->c.f_wrong_for && take(&m->c.f_wrong_count)) {
		cp_reply(m, m->c.f_wrong_reply);
		m->cp_dead = 1;
		return;
	}
	cp_reply(m, resp);
}

static int word_allowed(uint32_t w, uint32_t len)
{
	uint32_t stage = (w >> 8) & 0xF, step = w & 0xF;

	if ((w & 0xFFFF0000u) || (w & 0xF000u) != 0x9000u)
		return 0;
	if (stage > 3 && stage != 0xF)
		return 0;		/* never a stage >= 4 other than FIN */
	if (step == 0xC && (stage != 2 || len != 8))
		return 0;		/* never 0x930C, 0x910C, 0x900C */
	return 1;
}

static void cp_process(struct mock *m, const uint8_t *buf, uint32_t len)
{
	uint32_t w = len >= 4 ? get_le32(buf) : 0;

	if (len < 4 || !word_allowed(w, len)) {
		m->tripwire++;
		mock_viol(m, "TRIPWIRE: forbidden std_udl write 0x%08X (len %u)", w, len);
		m->cp_dead = 1;
		return;
	}
	if (m->cp_dead || m->silent_now)
		return;		/* BOOT spins silently */

	switch (m->cp_state) {
	case CP_WAIT_BOOT_DONE:
		if (len == 4 && w == 0x900Du) {
			cp_answer(m, w, 0xA00Du);
			m->cp_state = CP_WAIT_START;
			m->next_stage = 1;
			return;
		}
		break;
	case CP_WAIT_START: {
		unsigned int s = m->next_stage;
		uint32_t want = s <= 3 ? 0x9000u | (s << 8) : 0x9F00u;

		if (len == 4 && w == want) {
			if (s > 3) {
				cp_answer(m, w, 0xAF00u);
				m->fin_acked = 1;
				m->cp_state = CP_FIN_DONE;
				return;
			}
			if (m->c.f_daemon_open_at_stage == (int)s)
				mock_daemon_open(m);
			cp_answer(m, w, 0xA000u | (s << 8));
			m->cp_stage = s;
			m->cp_size = stage_size(m, s);
			m->cp_nframes = (m->cp_size + 2047u) / 2048u;
			m->cp_next_frame = 1;
			m->cp_got = 0;
			m->cp_crc = 0;
			m->cp_fw_seen = 0;
			m->cp_state = CP_WAIT_FRAMES;
			return;
		}
		break;
	}
	case CP_WAIT_FRAMES: {
		uint32_t s = m->cp_stage;
		uint32_t n, i, plen, want_len;
		const uint8_t *src;

		if (len < 16)
			break;
		n = get_le32(buf + 4);
		i = get_le32(buf + 8);
		plen = get_le32(buf + 12);
		want_len = m->cp_size - m->cp_got > 2048u ? 2048u : m->cp_size - m->cp_got;
		if (w != (0x9001u | (s << 8)) || n != m->cp_nframes ||
		    i != m->cp_next_frame || plen != want_len || len != 16u + plen) {
			mock_viol(m, "stage %u frame %u: bad header {0x%X,%u,%u,%u} len %u",
				  s, m->cp_next_frame, w, n, i, plen, len);
			m->cp_dead = 1;
			return;
		}
		if (!m->cp_fw_seen)
			mock_viol(m, "stage %u: frame before FW_UPDATE", s);
		if (s == 1)
			src = m->c.image + m->cp_got;
		else if (s == 2)
			src = m->c.image + toc_u32(m, 2, 0) + m->cp_got;
		else
			src = m->c.nv ? m->c.nv + m->cp_got : NULL;
		if (!src || memcmp(src, buf + 16, plen) != 0) {
			mock_viol(m, "stage %u frame %u: payload differs from the source", s, i);
			m->cp_dead = 1;
			return;
		}
		if (s == 2)
			m->cp_crc = sl_crc32_update(m->cp_crc, buf + 16, plen);
		m->cp_got += plen;
		m->cp_next_frame++;
		if (s == 2 && m->c.f_crash_main_frame == i && take(&m->c.f_crash_count)) {
			m->kstate = SL_STATE_CRASH_EXIT;
			m->cp_dead = 1;
			return;
		}
		if (i == m->cp_nframes) {
			cp_answer(m, 0x9001u | (s << 8), 0xA001u | (s << 8));
			m->cp_state = s == 2 ? CP_WAIT_CRC : CP_WAIT_DONE;
		}
		return;
	}
	case CP_WAIT_CRC:
		if (len == 8 && w == 0x920Cu) {
			uint32_t crc = get_le32(buf + 4);

			m->n_crc_frames++;
			if (crc != toc_u32(m, 2, 3) || crc != m->cp_crc ||
			    take(&m->c.f_reject_crc)) {
				cp_answer(m, w, 0xA20Fu);
				m->cp_dead = 1;
				return;
			}
			cp_answer(m, w, 0xA20Cu);
			m->cp_state = CP_WAIT_DONE;
			return;
		}
		mock_viol(m, "MAIN: expected the CRC frame, got 0x%08X len %u", w, len);
		m->cp_dead = 1;
		return;
	case CP_WAIT_DONE: {
		uint32_t want = 0x900Du | (m->cp_stage << 8);

		if (len == 4 && w == want) {
			cp_answer(m, w, 0xA00Du | (m->cp_stage << 8));
			m->next_stage = m->cp_stage + 1;
			m->cp_state = CP_WAIT_START;
			return;
		}
		break;
	}
	case CP_FIN_DONE:
		break;
	}
	mock_viol(m, "CP: unexpected write 0x%08X len %u in state %d", w, len, m->cp_state);
	m->cp_dead = 1;
}

/* ---------------------------------------------------------------- */
/* boot device ops                                                   */
/* ---------------------------------------------------------------- */

static void check_efuse(struct mock *m, const char *what)
{
	if (m->cp_status_rise_us && !m->a00d_sent &&
	    m->now_us < m->cp_status_rise_us + 10000000u) {
		mock_viol(m, "eFuse window: %s %.3f s after cp_status rose, before 0xA00D",
			  what, (double)(m->now_us - m->cp_status_rise_us) / 1e6);
	}
}

static void cp_reset_model(struct mock *m)
{
	m->cp_state = CP_WAIT_BOOT_DONE;
	m->cp_stage = 0;
	m->next_stage = 0;
	m->fin_acked = 0;
	m->cp_dead = 0;
	m->a00d_sent = 0;
	m->cp_status_rise_us = 0;
}

static int m_boot_open(void *ctx, const char *path)
{
	struct mock *m = ctx;

	if (strcmp(path, m->c.boot_path) != 0)
		return -ENOENT;
	m->boot_opens++;
	return MOCK_BOOT_FD;
}

static int m_ioctl(void *ctx, int fd, unsigned long req, void *arg)
{
	struct mock *m = ctx;
	struct mock_rec *r = rec_add(m, R_IOCTL);
	int ret = 0;

	r->req = (uint32_t)req;
	m->n_ioctls++;
	if (fd != MOCK_BOOT_FD) {
		mock_viol(m, "ioctl on fd %d", fd);
		r->ret = -EBADF;
		return -EBADF;
	}
	switch (req) {
	case TRIP_DUMP_START:
	case TRIP_FORCE_CRASH_EXIT:
	case TRIP_CP_UPLOAD:
	case TRIP_DUMP_RESET:
		m->tripwire++;
		mock_viol(m, "TRIPWIRE: forbidden ioctl 0x%lX", req);
		ret = -EPERM;
		break;
	case SL_IOCTL_MODEM_SET_TX_LINK: {
		int v = *(int *)arg;

		r->arg[0] = (uint32_t)v;
		if (v == SL_LINK_SPI || v == SL_LINK_LLI)
			m->txlink = v;
		else
			ret = -ENODEV;
		break;
	}
	case SL_IOCTL_MODEM_ON:
		check_efuse(m, "MODEM_ON");
		m->n_modem_on++;
		m->attempt++;
		m->gen++;
		m->power = 1;
		m->kstate = SL_STATE_OFFLINE;
		m->cp_status = 0;
		m->lli = 0;
		m->armed = 0;
		m->in_dl_window = 0;
		m->spi_this_power = 0;
		cp_reset_model(m);
		m->silent_now = take(&m->c.f_silent);
		advance_to(m, m->now_us + 1000000u, 0);
		break;
	case SL_IOCTL_MODEM_OFF:
		check_efuse(m, "MODEM_OFF");
		m->n_modem_off++;
		m->gen++;
		m->power = 0;
		m->kstate = SL_STATE_OFFLINE;
		m->cp_status = 0;
		m->lli = 0;
		m->armed = 0;
		m->in_dl_window = 0;
		cp_reset_model(m);
		break;
	case SL_IOCTL_MODEM_BOOT_ON:
		m->kstate = SL_STATE_BOOTING;
		m->cp_boot_done = 0;
		while (m->c.f_stale_rx > 0) {
			uint8_t d[4];

			put_le32(d, 0xA0000000u | (uint32_t)m->c.f_stale_rx);
			rx_push(m, d, 4);
			m->c.f_stale_rx--;
		}
		break;
	case SL_IOCTL_MODEM_DL_START:
		if (m->txlink != SL_LINK_LLI)
			ret = -EINVAL;
		else if (take(&m->c.f_dl_start_efault))
			ret = -EFAULT;
		else {
			m->armed = 1;
			m->in_dl_window = 1;
		}
		break;
	case SL_IOCTL_MODEM_FW_UPDATE: {
		const uint32_t *info = arg;

		memcpy(r->arg, info, 12);
		memcpy(r->head, info, 12);
		if (m->txlink != SL_LINK_LLI) {
			ret = -EINVAL;
			break;
		}
		m->n_fw_update++;
		if (m->cp_state != CP_WAIT_FRAMES || m->cp_fw_seen ||
		    info[0] != m->cp_size || info[1] != 0x810u ||
		    info[2] != m->cp_nframes)
			mock_viol(m, "FW_UPDATE {0x%X,0x%X,%u} unexpected (stage %u)",
				  info[0], info[1], info[2], m->cp_stage);
		m->cp_fw_seen = 1;
		if (m->cp_stage == 2 && m->c.f_corrupt_main_after_preflight) {
			m->c.image[toc_u32(m, 2, 0) + 100] ^= 0x5A;
			m->c.f_corrupt_main_after_preflight = 0;
		}
		break;
	}
	case SL_IOCTL_MODEM_STATUS:
		if (m->pending_sim) {
			m->pending_sim = 0;
			ret = SL_STATE_SIM_ATTACH;
		} else {
			ret = m->kstate;
		}
		break;
	case SL_IOCTL_MODEM_BOOT_OFF:
		m->n_boot_off++;
		if (m->fin_acked && !take(&m->c.f_boot_off_eagain)) {
			advance_to(m, m->now_us + (uint64_t)m->c.phone_start_delay_ms * 1000u, 0);
			if (m->holder_open[0] > 0 && m->holder_open[1] > 0) {
				m->n_handler_init_end++;	/* PHONE_START handler sends INIT_END */
				m->cp_boot_done = 1;
			}
			m->kstate = SL_STATE_ONLINE;
			m->in_dl_window = 0;
			m->online_count++;
			schedule_scripts(m);
		} else {
			advance_to(m, m->now_us + 30000000u, 0);
			ret = -EAGAIN;
		}
		break;
	case SL_IOCTL_MODEM_BOOT_DONE:
		break;
	case SL_IOCTL_MODEM_GET_CP_BOOTLOG:
		m->n_get_bootlog++;
		ret = -EINVAL;
		break;
	case SL_IOCTL_MODEM_CLR_CP_BOOTLOG:
		m->n_clr_bootlog++;
		ret = -EINVAL;
		break;
	default:
		mock_viol(m, "unknown ioctl 0x%lX", req);
		ret = -EINVAL;
		break;
	}
	r->ret = ret;
	return ret;
}

static long m_write(void *ctx, int fd, const void *buf, size_t len)
{
	struct mock *m = ctx;
	struct mock_rec *r = rec_add(m, R_WRITE);
	const uint8_t *b = buf;
	uint32_t n32 = (uint32_t)len;

	r->len = n32;
	memcpy(r->head, b, len < 16 ? len : 16);
	if (fd != MOCK_BOOT_FD) {
		mock_viol(m, "write on fd %d", fd);
		r->ret = -EBADF;
		return -EBADF;
	}
	if (m->txlink == SL_LINK_SPI) {
		uint32_t boff = toc_u32(m, 1, 0), bsz = toc_u32(m, 1, 2);

		/* kernel skb: cfg 0xF8 (SPI link never aligned), ch 0xD7, len16 */
		r->ring[0] = 0xF8;
		r->ring[1] = 0xD7;
		r->ring[2] = (uint8_t)((4 + n32) & 0xFF);
		r->ring[3] = (uint8_t)(((4 + n32) >> 8) & 0xFF);
		m->n_spi_writes++;
		if (++m->spi_this_power > 1)
			mock_viol(m, "more than one SPI write per MODEM_ON");
		if (!m->power || m->kstate != SL_STATE_BOOTING || !m->armed)
			mock_viol(m, "SPI write outside BOOTING/armed");
		if (n32 != bsz || memcmp(b, m->c.image + boff, bsz) != 0) {
			m->tripwire++;
			mock_viol(m, "TRIPWIRE: SPI payload is not the RADIO BOOT entry");
		}
		if (take(&m->c.f_spi_eintr)) {
			r->ret = -EINTR;
			return -EINTR;
		}
		advance_to(m, m->now_us + (uint64_t)n32 * 80u, 0);	/* 100 kHz */
		if (!take(&m->c.f_cp_status_never))
			ev_add(m, m->now_us + (uint64_t)m->c.cp_status_delay_ms * 1000u,
			       MEV_CP_STATUS_HIGH, NULL, 0, 0);
		if (!take(&m->c.f_lli_never))
			ev_add(m, m->now_us + (uint64_t)m->c.lli_delay_ms * 1000u,
			       MEV_LLI_MOUNT, NULL, 0, 0);
		r->ret = (int32_t)n32;
		return (long)len;
	}

	/* LLI ring: cfg 0xFC (start + padding), ch 0xD7, len = 4 + payload */
	r->ring[0] = 0xFC;
	r->ring[1] = 0xD7;
	r->ring[2] = (uint8_t)((4 + n32) & 0xFF);
	r->ring[3] = (uint8_t)(((4 + n32) >> 8) & 0xFF);
	r->ring_pad = (uint8_t)((4 - ((4 + n32) % 4)) % 4);
	if (!m->armed)
		mock_viol(m, "ring write before DL_START");
	if (m->kstate == SL_STATE_CRASH_EXIT)
		m->n_writes_after_crash++;	/* the kernel accepts them */
	else if (m->kstate != SL_STATE_BOOTING)
		mock_viol(m, "ring write while not BOOTING (state %d)", m->kstate);
	m->n_ring_writes++;
	if (m->c.f_enospc_count && len >= 16 &&
	    ((get_le32(b) >> 8) & 0xF) == m->c.f_enospc_stage &&
	    get_le32(b + 8) == m->c.f_enospc_frame && take(&m->c.f_enospc_count)) {
		r->ret = -ENOSPC;
		return -ENOSPC;
	}
	if (!m->lli) {
		m->n_unmounted_writes++;
		r->ret = (int32_t)n32;
		return (long)len;	/* accepted, never answered */
	}
	cp_process(m, b, n32);
	r->ret = (int32_t)n32;
	return (long)len;
}

static long m_read(void *ctx, int fd, void *buf, size_t len)
{
	struct mock *m = ctx;
	struct mock_rec *r;
	int n;

	if (fd != MOCK_BOOT_FD)
		return -EBADF;
	advance_to(m, m->now_us, 0);
	if (m->rxn == 0) {
		if (advance_to(m, m->now_us + 100000u, 1))
			return -EINTR;
		if (m->rxn == 0)
			return 0;
	}
	n = m->rxq[m->rxh].len;
	if ((size_t)n > len) {
		/* partial read: the kernel pushes the remainder back */
		memcpy(buf, m->rxq[m->rxh].d, len);
		memmove(m->rxq[m->rxh].d, m->rxq[m->rxh].d + len, (size_t)n - len);
		m->rxq[m->rxh].len = n - (int)len;
		n = (int)len;
	} else {
		memcpy(buf, m->rxq[m->rxh].d, (size_t)n);
		m->rxh = (m->rxh + 1) % 512;
		m->rxn--;
	}
	r = rec_add(m, R_READ);
	r->ret = n;
	r->len = (uint32_t)n;
	memcpy(r->head, buf, (size_t)n < 16 ? (size_t)n : 16);
	if (n == 4)
		m->n_reads4++;
	return n;
}

static short poll_mask(struct mock *m, short events)
{
	short rev = 0;

	if (m->pending_sim || m->kstate == SL_STATE_CRASH_EXIT ||
	    m->kstate == SL_STATE_CRASH_RESET || m->kstate == SL_STATE_NV_REBUILDING)
		rev |= POLLHUP;
	if ((events & POLLIN) && m->rxn > 0 &&
	    (m->kstate == SL_STATE_BOOTING || m->kstate == SL_STATE_ONLINE))
		rev |= POLLIN;
	return rev;
}

static int m_poll(void *ctx, int fd, short events, short *revents, int timeout_ms)
{
	struct mock *m = ctx;
	uint64_t deadline = timeout_ms < 0 ? UINT64_MAX :
			    m->now_us + (uint64_t)timeout_ms * 1000u;

	if (fd != MOCK_BOOT_FD)
		return -EBADF;
	for (;;) {
		uint64_t nxt;
		short rev;

		if (advance_to(m, m->now_us, 1) || (m->stop && *m->stop))
			return -EINTR;
		rev = poll_mask(m, events);
		if (rev) {
			*revents = rev;
			return 1;
		}
		if (m->now_us >= deadline)
			return 0;
		if (!next_event(m, &nxt)) {
			if (deadline == UINT64_MAX) {
				/* nothing will ever happen: end the scenario */
				m->idle_deadlock++;
				if (m->stop)
					*m->stop = 1;
				return -EINTR;
			}
			nxt = deadline;
		}
		if (advance_to(m, nxt < deadline ? nxt : deadline, 1))
			return -EINTR;
	}
}

/* ---------------------------------------------------------------- */
/* holders                                                           */
/* ---------------------------------------------------------------- */

static void holder_opened(struct mock *m, int which, const char *who)
{
	if (m->holder_open[which] == 0 && m->in_dl_window)
		mock_viol(m, "%s: first open of %s between DL_START and BOOT_OFF",
			  who, which ? "umts_rfs0" : "umts_ipc0");
	m->holder_open[which]++;
	if (m->holder_open[0] > 0 && m->holder_open[1] > 0 &&
	    m->kstate == SL_STATE_ONLINE && !m->cp_boot_done) {
		m->n_late_init_end++;	/* late path sends INIT_END */
		m->cp_boot_done = 1;
	}
}

static int m_holder_open(void *ctx, const char *path)
{
	struct mock *m = ctx;
	struct mock_rec *r;
	int which;

	if (strcmp(path, m->c.ipc_path) == 0)
		which = 0;
	else if (strcmp(path, m->c.rfs_path) == 0)
		which = 1;
	else
		return -ENOENT;
	r = rec_add(m, R_HOPEN);
	r->req = (uint32_t)which;
	m->n_holder_opens++;
	holder_opened(m, which, "loader");
	return which ? MOCK_RFS_FD : MOCK_IPC_FD;
}

void mock_daemon_open(struct mock *m)
{
	holder_opened(m, 0, "daemon");
	holder_opened(m, 1, "daemon");
}

void mock_daemon_close(struct mock *m)
{
	m->holder_open[0]--;
	m->holder_open[1]--;
}

static int m_close(void *ctx, int fd)
{
	struct mock *m = ctx;
	struct mock_rec *r;

	switch (fd) {
	case MOCK_BOOT_FD:
		rec_add(m, R_BCLOSE);
		if (--m->boot_opens == 0)
			m->cp_boot_done = 0;
		return 0;
	case MOCK_IPC_FD:
	case MOCK_RFS_FD:
		r = rec_add(m, R_HCLOSE);
		r->req = (uint32_t)(fd - MOCK_IPC_FD);
		m->holder_open[fd - MOCK_IPC_FD]--;
		return 0;
	case MOCK_IMG_FD:
		return 0;
	default:
		return m->real.close_fd(m->real.ctx, fd);
	}
}

/* ---------------------------------------------------------------- */
/* files, sysfs, time                                                */
/* ---------------------------------------------------------------- */

static int m_ro_open(void *ctx, const char *path, int nofollow)
{
	struct mock *m = ctx;

	if (m->c.image_path && strcmp(path, m->c.image_path) == 0)
		return MOCK_IMG_FD;
	return m->real.ro_open(m->real.ctx, path, nofollow);
}

static long m_ro_pread(void *ctx, int fd, void *buf, size_t len, uint64_t off)
{
	struct mock *m = ctx;
	size_t n;

	if (fd != MOCK_IMG_FD)
		return m->real.ro_pread(m->real.ctx, fd, buf, len, off);
	if (off >= m->c.image_size)
		return 0;
	n = len;
	if (off + n > m->c.image_size)
		n = (size_t)(m->c.image_size - off);
	memset(buf, 0, n);
	if (off < m->c.image_len) {
		size_t c = n;

		if (off + c > m->c.image_len)
			c = m->c.image_len - (size_t)off;
		memcpy(buf, m->c.image + off, c);
	}
	return (long)n;
}

static int m_ro_fstat(void *ctx, int fd, struct sl_stat *st)
{
	struct mock *m = ctx;

	if (fd != MOCK_IMG_FD)
		return m->real.ro_fstat(m->real.ctx, fd, st);
	st->type = SL_FT_BLK;
	st->size = m->c.image_size;
	st->mode = 0440;
	return 0;
}

static int m_ro_fs_readonly(void *ctx, int fd)
{
	struct mock *m = ctx;

	if (m->c.fake_ro_fs)
		return 1;
	return m->real.ro_fs_readonly(m->real.ctx, fd);
}

static int is_path(const char *a, const char *b)
{
	return a && b && strcmp(a, b) == 0;
}

static int m_path_stat(void *ctx, const char *path, struct sl_stat *st)
{
	struct mock *m = ctx;

	memset(st, 0, sizeof(*st));
	if (is_path(path, m->c.boot_path) || is_path(path, m->c.ipc_path) ||
	    is_path(path, m->c.rfs_path)) {
		st->type = SL_FT_CHR;
		return 0;
	}
	if (is_path(path, m->c.lli_path) || is_path(path, m->c.cp_status_path)) {
		st->type = SL_FT_REG;
		return 0;
	}
	if (is_path(path, m->c.image_path)) {
		st->type = SL_FT_BLK;
		st->size = m->c.image_size;
		return 0;
	}
	return m->real.path_stat(m->real.ctx, path, st);
}

static int m_path_glob(void *ctx, const char *pattern, char *out, size_t outsz)
{
	struct mock *m = ctx;

	if (m->c.cp_status_path &&
	    fnmatch(pattern, m->c.cp_status_path, FNM_PATHNAME) == 0 &&
	    strlen(m->c.cp_status_path) < outsz) {
		strcpy(out, m->c.cp_status_path);
		return 0;
	}
	return -ENOENT;
}

static long m_sysfs_read(void *ctx, const char *path, char *buf, size_t len)
{
	struct mock *m = ctx;
	int n;

	advance_to(m, m->now_us, 0);
	if (is_path(path, m->c.lli_path))
		n = snprintf(buf, len, "MIPI-LLI %d\n", m->lli);
	else if (is_path(path, m->c.cp_status_path))
		n = snprintf(buf, len, "%d\n", m->cp_status);
	else if (is_path(path, m->c.allow_hw_path))
		n = snprintf(buf, len, "%s\n", m->c.allow_hw_value ? m->c.allow_hw_value : "Y");
	else if (!m->c.bat_missing && is_path(path, m->c.cap_path))
		n = snprintf(buf, len, "%d\n", m->c.bat_capacity);
	else if (!m->c.bat_missing && is_path(path, m->c.temp_path))
		n = snprintf(buf, len, "%d\n", m->c.bat_temp);
	else if (!m->c.bat_missing && is_path(path, m->c.cur_path))
		n = snprintf(buf, len, "%d\n", m->c.bat_current);
	else if (is_path(path, m->c.state_path) && m->nstates > 0)
		n = snprintf(buf, len, "%s", m->states[m->nstates - 1]);
	else if (is_path(path, m->c.state_path) && m->c.state_initial)
		n = snprintf(buf, len, "%s", m->c.state_initial);
	else
		return -ENOENT;
	return n;
}

static uint64_t m_now_us(void *ctx)
{
	return ((struct mock *)ctx)->now_us;
}

static int m_sleep_ms(void *ctx, unsigned int ms)
{
	struct mock *m = ctx;

	if (advance_to(m, m->now_us + (uint64_t)ms * 1000u, 1))
		return -EINTR;
	return 0;
}

static int m_notify(void *ctx, const char *msg)
{
	struct mock *m = ctx;
	struct mock_rec *r = rec_add(m, R_NOTIFY);

	(void)r;
	if (m->nnotify < 64)
		snprintf(m->notify[m->nnotify++], sizeof(m->notify[0]), "%s", msg);
	return 0;
}

static int m_state_publish(void *ctx, const char *text)
{
	struct mock *m = ctx;

	if (m->nstates < 96) {
		size_t n;

		snprintf(m->states[m->nstates], sizeof(m->states[0]), "%s", text);
		n = strlen(m->states[m->nstates]);
		if (n && m->states[m->nstates][n - 1] != '\n')
			mock_viol(m, "state line without newline");
		m->nstates++;
	}
	return 0;
}

void mock_init(struct mock *m, const struct mock_cfg *c,
	       volatile sig_atomic_t *stop)
{
	memset(m, 0, sizeof(*m));
	m->c = *c;
	m->stop = stop;
	m->txlink = SL_LINK_LLI;
	m->kstate = SL_STATE_OFFLINE;
	if (!m->c.cp_status_delay_ms)
		m->c.cp_status_delay_ms = 300;
	if (!m->c.lli_delay_ms)
		m->c.lli_delay_ms = 800;
	if (!m->c.phone_start_delay_ms)
		m->c.phone_start_delay_ms = 200;
	if (m->c.f_cp_alive_at_start) {
		m->power = 1;
		m->cp_status = 1;
		m->cp_status_rise_us = 1;	/* at t = 0 */
	}
	m->now_us = 1000000u;	/* start the clock at 1 s */
	schedule_scripts(m);	/* on_online == 0: relative to the start */
	sl_ops_linux_init(&m->real, &m->real_ctx);
	m->real_ctx.notify_socket[0] = '\0';
}

void mock_get_ops(struct mock *m, struct sl_ops *o)
{
	memset(o, 0, sizeof(*o));
	o->ctx = m;
	o->boot_open = m_boot_open;
	o->boot_ioctl = m_ioctl;
	o->boot_write = m_write;
	o->boot_read = m_read;
	o->boot_poll = m_poll;
	o->holder_open = m_holder_open;
	o->close_fd = m_close;
	o->ro_open = m_ro_open;
	o->ro_pread = m_ro_pread;
	o->ro_fstat = m_ro_fstat;
	o->ro_fs_readonly = m_ro_fs_readonly;
	o->path_stat = m_path_stat;
	o->path_glob = m_path_glob;
	o->sysfs_read = m_sysfs_read;
	o->now_us = m_now_us;
	o->sleep_ms = m_sleep_ms;
	o->notify = m_notify;
	o->state_publish = m_state_publish;
}

void mock_free(struct mock *m)
{
	free(m->rec);
	m->rec = NULL;
	m->nrec = m->caprec = 0;
}
