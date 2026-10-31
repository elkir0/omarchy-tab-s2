// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * shannon-loader: RADIO TOC decoding and preflight checks (LS2 2.3, 4.1 F3).
 *
 * The TOC is 512 bytes of 32-byte records:
 *   char name[12]; u32 offset; u32 load_addr; u32 size; u32 crc; u32 index;
 * all little-endian. Slots 0-3 must be TOC, BOOT, MAIN, NV.
 */
#include <stdio.h>
#include <string.h>

#include "sl_loader.h"

static uint32_t le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

void sl_toc_parse(const uint8_t raw[SL_TOC_BYTES], struct sl_toc *t)
{
	unsigned int i;

	memset(t, 0, sizeof(*t));
	for (i = 0; i < SL_TOC_SLOTS; i++) {
		const uint8_t *r = raw + i * SL_TOC_ENTRY;
		struct sl_toc_entry *e = &t->e[i];

		memcpy(e->name, r, SL_TOC_NAME_LEN);
		e->name[SL_TOC_NAME_LEN] = '\0';
		e->offset = le32(r + 12);
		e->load_addr = le32(r + 16);
		e->size = le32(r + 20);
		e->crc = le32(r + 24);
		e->index = le32(r + 28);
	}
}

/* name must be NUL-terminated inside its 12 bytes and equal `want` */
static int name_is(const struct sl_toc_entry *e, const char *want)
{
	if (memchr(e->name, '\0', SL_TOC_NAME_LEN) == NULL)
		return 0;
	return strcmp(e->name, want) == 0;
}

int sl_toc_validate(const struct sl_toc *t, uint64_t image_size,
		    char *why, size_t whylen)
{
	static const char *const names[4] = { "TOC", "BOOT", "MAIN", "NV" };
	const struct sl_toc_entry *toc = &t->e[SL_SLOT_TOC];
	const struct sl_toc_entry *boot = &t->e[SL_SLOT_BOOT];
	const struct sl_toc_entry *main_ = &t->e[SL_SLOT_MAIN];
	const struct sl_toc_entry *nv = &t->e[SL_SLOT_NV];
	unsigned int i;

	for (i = 0; i < 4; i++) {
		if (!name_is(&t->e[i], names[i])) {
			snprintf(why, whylen, "slot %u name is not \"%s\"",
				 i, names[i]);
			return -1;
		}
	}
	if (toc->offset != 0) {
		snprintf(why, whylen, "TOC.offset 0x%X != 0", toc->offset);
		return -1;
	}
	if (toc->size < 0x80 || toc->size > SL_TOC_BYTES) {
		snprintf(why, whylen, "TOC.size 0x%X outside [0x80, 0x200]",
			 toc->size);
		return -1;
	}
	for (i = 0; i < 4; i++) {
		const struct sl_toc_entry *e = &t->e[i];

		if ((uint64_t)e->offset + (uint64_t)e->size > image_size) {
			snprintf(why, whylen,
				 "%s: offset 0x%X + size 0x%X beyond image size 0x%llX",
				 names[i], e->offset, e->size,
				 (unsigned long long)image_size);
			return -1;
		}
	}
	if (boot->size == 0 || boot->size > SL_BOOT_MAX_SIZE) {
		snprintf(why, whylen,
			 "BOOT.size 0x%X outside [1, 0x%X] (SPI header limit)",
			 boot->size, SL_BOOT_MAX_SIZE);
		return -1;
	}
	if (boot->crc != SL_BOOT_CRC_PINNED) {
		snprintf(why, whylen,
			 "TOC BOOT.crc 0x%08X is not the pinned stock BOOT 0x%08X",
			 boot->crc, SL_BOOT_CRC_PINNED);
		return -1;
	}
	if (main_->size == 0) {
		snprintf(why, whylen, "MAIN.size is 0");
		return -1;
	}
	if (nv->size == 0 || nv->size > SL_NV_MAX_SIZE) {
		snprintf(why, whylen, "NV.size 0x%X outside [1, 16 MiB]", nv->size);
		return -1;
	}
	return 0;
}
