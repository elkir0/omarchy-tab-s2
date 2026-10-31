/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * shannon-loader: the subset of the modem_v1 userspace ABI the loader uses.
 *
 * Values follow research/modem/modem_v1_uapi.h and LS2 section 2. Only the
 * requests the loader is allowed to issue are defined here, on purpose: the
 * dump, crash and upload requests have no name in this program, and
 * sl_ioctl_allowed() (loader.c) refuses anything that is not in this list.
 */
#ifndef SL_ABI_H
#define SL_ABI_H

#include <stdint.h>

/* _IO('o', nr) == 0x6F00 | nr on Linux (no direction, no size). */
#define SL_IOCTL_MODEM_ON		0x6F19u
#define SL_IOCTL_MODEM_OFF		0x6F20u
#define SL_IOCTL_MODEM_BOOT_ON		0x6F22u
#define SL_IOCTL_MODEM_BOOT_OFF		0x6F23u
#define SL_IOCTL_MODEM_BOOT_DONE	0x6F24u
#define SL_IOCTL_MODEM_STATUS		0x6F27u
#define SL_IOCTL_MODEM_DL_START		0x6F28u
#define SL_IOCTL_MODEM_FW_UPDATE	0x6F29u
#define SL_IOCTL_MODEM_SET_TX_LINK	0x6F37u
#define SL_IOCTL_MODEM_GET_CP_BOOTLOG	0x6F47u
#define SL_IOCTL_MODEM_CLR_CP_BOOTLOG	0x6F48u

/* SET_TX_LINK argument (int *) */
#define SL_LINK_SPI	3
#define SL_LINK_LLI	10

/* enum modem_state, returned by IOCTL_MODEM_STATUS */
enum sl_modem_state {
	SL_STATE_OFFLINE = 0,
	SL_STATE_CRASH_RESET = 1,
	SL_STATE_CRASH_EXIT = 2,
	SL_STATE_BOOTING = 3,
	SL_STATE_ONLINE = 4,
	SL_STATE_NV_REBUILDING = 5,
	SL_STATE_LOADER_DONE = 6,
	SL_STATE_SIM_ATTACH = 7,
	SL_STATE_SIM_DETACH = 8,
};

/* std_udl words: 0xD S 0 T (LS2 2.2) */
#define SL_UDL_AP2CP		0x9000u
#define SL_UDL_CP2AP		0xA000u
#define SL_UDL_DIR_MASK		0xF000u
#define SL_UDL_STAGE_SHIFT	8
#define SL_UDL_STAGE_MASK	0x0F00u
#define SL_UDL_STEP_MASK	0x000Fu

#define SL_STAGE_BOOT		0x0u
#define SL_STAGE_TOC		0x1u
#define SL_STAGE_MAIN		0x2u
#define SL_STAGE_NV		0x3u
#define SL_STAGE_FIN		0xFu

#define SL_STEP_START		0x0u
#define SL_STEP_SEND		0x1u
#define SL_STEP_CRC		0xCu
#define SL_STEP_DONE		0xDu
#define SL_STEP_FAIL		0xFu

#define SL_UDL_WORD(dir, stage, step) \
	((uint32_t)(dir) | ((uint32_t)(stage) << SL_UDL_STAGE_SHIFT) | (uint32_t)(step))

/* Payload framing (LS2 2.2) */
#define SL_FRAME_HDR		16u	/* {cmd, num_frames, curr_frame, len} */
#define SL_FRAME_MSS		2048u	/* payload bytes per frame */
#define SL_FRAME_MTU		0x810u	/* informational, FW_UPDATE.mtu */
#define SL_CRC_FRAME_LEN	8u	/* {cmd, crc} */

/* RADIO image TOC (LS2 2.3) */
#define SL_TOC_BYTES		0x200u
#define SL_TOC_ENTRY		0x20u
#define SL_TOC_SLOTS		(SL_TOC_BYTES / SL_TOC_ENTRY)
#define SL_TOC_NAME_LEN		12u

/* BOOT is sent over SPI in one write; the 3.10 SPI link strips a fixed
 * 4-byte header, so BOOT + 4 must stay <= 0xFFFF (LS2 4.1 F3). */
#define SL_BOOT_MAX_SIZE	0xFFFBu

/* Safety rule 1 (SYNTHESIS 5, review 3.2): the only BOOT ever sent is the
 * stock one, image[0x200..0x2BFC) of RADIO p13: CRC32 and SHA-256 pinned. */
#define SL_BOOT_CRC_PINNED	0x5DB1F04Cu
#define SL_BOOT_SHA256_PINNED_HEX \
	"dd39fae36c2ccfbc28c3562c405962c827b2cf5d66f9e63d3fb90223dd0f94f4"

#define SL_NV_MAX_SIZE		(16u * 1024u * 1024u)

#endif /* SL_ABI_H */
