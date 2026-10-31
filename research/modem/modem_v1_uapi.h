/*
 * modem_v1_uapi.h — Userspace ABI of the Samsung modem_v1 driver
 *                   (drivers/misc/modem_v1, SM-T715 / Exynos 5433 / SS333)
 *
 * Standalone header: no kernel includes required. Values are transcribed
 * verbatim from:
 *   - drivers/misc/modem_v1/modem_prj.h   (ioctls, constants, structs)
 *   - include/linux/platform_data/modem_v1.h (enums, channel IDs, attrs)
 *   - drivers/misc/modem_v1/include/sipc5.h  (SIPC5 framing, std_dload_info)
 *   - drivers/misc/modem_v1/link_device_memory.h (masks, commands, magics,
 *     4 MiB shared-memory map)
 *
 * Corrected and extended 2026-10-30 (research/SYNTHESIS.md §9.4): ARM32-only
 * note, GET/CLR_CP_BOOTLOG, SET_TX_LINK values, warnings on CP_UPLOAD,
 * XMIT_BOOT and MIF_LOG_DUMP, padding rule, STD_UDL boot protocol, RFS
 * header, doorbell values and shared-memory offsets. Every pre-existing
 * identifier keeps its name and value.
 *
 * SPDX-License-Identifier: GPL-2.0
 * Copyright (C) 2012 Samsung Electronics.
 */

#ifndef _MODEM_V1_UAPI_H
#define _MODEM_V1_UAPI_H

/*
 * Fixed-width types without <linux/types.h>. This ABI is used only with an
 * ARM32 kernel and ARM32 userspace on the SM-T715 (corrected 2026-10-30: the
 * earlier comment also named arm64 userspace, but struct modem_firmware holds
 * a char * and IOCTL_MIF_LOG_DUMP copies an unsigned long, both 4 bytes only
 * on ARM32). unsigned short is 16 bits and unsigned int is 32 bits.
 */
typedef unsigned char  mv1_u8;
typedef unsigned short mv1_u16;
typedef unsigned int   mv1_u32;

#ifndef _IO
/* asm-generic _IO(): no direction, no size -> (_IOC_NONE, type, nr, 0) */
#define _IO(type, nr)	(((type) << 8) | (nr))
#endif

/* ------------------------------------------------------------------ */
/* IOCTL commands — modem_prj.h:54-94                                  */
/* All commands use magic 'o' (0x6F); e.g. IOCTL_MODEM_ON == 0x6F19.   */
/* ------------------------------------------------------------------ */

#define IOCTL_MODEM_ON			_IO('o', 0x19)	/* modem_prj.h:54 */
#define IOCTL_MODEM_OFF			_IO('o', 0x20)	/* modem_prj.h:55 */
#define IOCTL_MODEM_RESET		_IO('o', 0x21)	/* modem_prj.h:56 */
#define IOCTL_MODEM_BOOT_ON		_IO('o', 0x22)	/* modem_prj.h:57 */
#define IOCTL_MODEM_BOOT_OFF		_IO('o', 0x23)	/* modem_prj.h:58 */
#define IOCTL_MODEM_BOOT_DONE		_IO('o', 0x24)	/* modem_prj.h:59 */

#define IOCTL_MODEM_PROTOCOL_SUSPEND	_IO('o', 0x25)	/* modem_prj.h:61 */
#define IOCTL_MODEM_PROTOCOL_RESUME	_IO('o', 0x26)	/* modem_prj.h:62 */

#define IOCTL_MODEM_STATUS		_IO('o', 0x27)	/* modem_prj.h:64 */

#define IOCTL_MODEM_DL_START		_IO('o', 0x28)	/* modem_prj.h:66 */
#define IOCTL_MODEM_FW_UPDATE		_IO('o', 0x29)	/* modem_prj.h:67 */

#define IOCTL_MODEM_NET_SUSPEND		_IO('o', 0x30)	/* modem_prj.h:69 */
#define IOCTL_MODEM_NET_RESUME		_IO('o', 0x31)	/* modem_prj.h:70 */

#define IOCTL_MODEM_DUMP_START		_IO('o', 0x32)	/* modem_prj.h:72 */
#define IOCTL_MODEM_DUMP_UPDATE		_IO('o', 0x33)	/* modem_prj.h:73 */
#define IOCTL_MODEM_FORCE_CRASH_EXIT	_IO('o', 0x34)	/* modem_prj.h:74 */
/* WARNING (2026-10-30): the stock kernel copies 512 B of crash text and then
 * calls panic(); with oops=panic the tablet reboots. Never issue it
 * (research/SYNTHESIS.md rule 7); the port returns without panicking. */
#define IOCTL_MODEM_CP_UPLOAD		_IO('o', 0x35)	/* modem_prj.h:75 */
#define IOCTL_MODEM_DUMP_RESET		_IO('o', 0x36)	/* modem_prj.h:76 */

/* NOTE: same numeric value as IOCTL_MODEM_DUMP_UPDATE (header collision,
 * modem_prj.h:78); misc_ioctl() implements only the DUMP_UPDATE meaning. */
#define IOCTL_LINK_CONNECTED		_IO('o', 0x33)	/* modem_prj.h:78 */
/* Argument: pointer to int, MV1_LINKDEV_SPI (BOOT image write) or
 * MV1_LINKDEV_LLI (everything else). Added 2026-10-30. */
#define IOCTL_MODEM_SET_TX_LINK		_IO('o', 0x37)	/* modem_prj.h:79 */
#define MV1_LINKDEV_SPI			3		/* modem_v1.h LINKDEV_SPI */
#define MV1_LINKDEV_LLI			10		/* modem_v1.h LINKDEV_LLI */

#define IOCTL_MODEM_RAMDUMP_START	_IO('o', 0xCE)	/* modem_prj.h:81 */
#define IOCTL_MODEM_RAMDUMP_STOP	_IO('o', 0xCF)	/* modem_prj.h:82 */

/* Returns -EINVAL on this board: link_attrs 0x3C9 has no XMIT_BTDLR, so
 * ld->xmit_boot is NULL (note added 2026-10-30). */
#define IOCTL_MODEM_XMIT_BOOT		_IO('o', 0x40)	/* modem_prj.h:84 */
/* modem_prj.h:86, defined under CONFIG_LINK_DEVICE_SHMEM only (not built
 * for this board; no handler reachable in misc_ioctl). */
#define IOCTL_MODEM_GET_SHMEM_INFO	_IO('o', 0x41)
#define IOCTL_DPRAM_INIT_STATUS		_IO('o', 0x43)	/* modem_prj.h:88 */
#define IOCTL_LINK_DEVICE_RESET		_IO('o', 0x44)	/* modem_prj.h:90 */

/* Added 2026-10-30: defined in later modem_v1 kernels (Exynos 8895/9810);
 * stock cbd sends GET after a failed BOOT_OFF and CLR after a successful one.
 * On this kernel's LLI link both return -EINVAL (no ld->ioctl): harmless. */
#define IOCTL_MODEM_GET_CP_BOOTLOG	_IO('o', 0x47)
#define IOCTL_MODEM_CLR_CP_BOOTLOG	_IO('o', 0x48)

/* ioctl command for IPC Logger. IOCTL_MIF_LOG_DUMP copies an unsigned long
 * (4 bytes on ARM32) and injects up to 512 KiB of log skbs into the calling
 * node's RX queue (modem_utils.c:103-125); the port restricts it to root on
 * umts_boot0 (note added 2026-10-30). */
#define IOCTL_MIF_LOG_DUMP		_IO('o', 0x51)	/* modem_prj.h:93 */
#define IOCTL_MIF_DPRAM_DUMP		_IO('o', 0x52)	/* modem_prj.h:94 */

/* ------------------------------------------------------------------ */
/* Constants — modem_prj.h:99-111                                      */
/* ------------------------------------------------------------------ */

#define MAX_IOD_RXQ_LEN		2048		/* modem_prj.h:99 */
#define CP_CRASH_INFO_SIZE	512		/* modem_prj.h:101 */
#define CP_CRASH_TAG		"CP Crash "	/* modem_prj.h:102 */
/* FORCE_CRASH_ACK_TIMEOUT is (10 * HZ) jiffies in-kernel (modem_prj.h:111);
 * jiffies are not visible to userspace — express as ~10 s at HZ=1000, or
 * use poll(2) timeouts instead. */

/* ------------------------------------------------------------------ */
/* modem_state / link_state — modem_prj.h:124-140                      */
/* Returned (as int) by IOCTL_MODEM_STATUS on /dev/umts_boot0 and      */
/* /dev/umts_ipc0 (modem_io_device.c:1145-1165).                       */
/* Note 2026-10-30: STATE_CRASH_RESET is never set on this kernel (no  */
/* emitter of MDM_EVENT_CP_FORCE_RESET); a pending SIM change is       */
/* returned once as 7/8 and consumed by whoever calls STATUS first.    */
/* ------------------------------------------------------------------ */

enum modem_state {
	STATE_OFFLINE = 0,
	STATE_CRASH_RESET,	/* silent reset		*/
	STATE_CRASH_EXIT,	/* CP ramdump		*/
	STATE_BOOTING,
	STATE_ONLINE,
	STATE_NV_REBUILDING,	/* <= rebuilding start	*/
	STATE_LOADER_DONE,
	STATE_SIM_ATTACH,
	STATE_SIM_DETACH,
};

enum link_state {
	LINK_STATE_OFFLINE = 0,
	LINK_STATE_IPC,
	LINK_STATE_CP_CRASH
};

/* Kernel-internal, NOT part of the userspace ABI (corrected 2026-10-30):
 * modem_prj.h:142-145 defines struct sim_state { bool online; bool changed; }
 * and never exchanges it with userspace. Kept only for source compatibility;
 * its field sizes do not match the kernel's bools. */
struct mv1_sim_state {
	mv1_u32 online;		/* bool in-kernel: SIM is online?	*/
	mv1_u32 changed;	/* bool: online changed since last read	*/
};

/* ------------------------------------------------------------------ */
/* Firmware argument structures                                        */
/* ------------------------------------------------------------------ */

/* modem_prj.h:147-151 — argument of IOCTL_MODEM_FW_UPDATE's sibling ioctls
 * that take a firmware blob reference (XMIT_BOOT path, -EINVAL here). */
struct modem_firmware {
	char   *binary;		/* userspace pointer to the image	*/
	mv1_u32 size;
};

/* modem_prj.h:153-157 — CONFIG_COMPAT variant (size as native long). */
struct modem_firmware_64 {
	char		*binary;
	unsigned long	size;
};

/* sipc5.h:244-248 — argument of IOCTL_MODEM_FW_UPDATE (12 bytes, packed).
 * Copied verbatim by mem_update_firm_info() via copy_from_user()
 * (link_device_bootdump.c:235-249). Informational: the kernel stores it and
 * never reads it (note 2026-10-30). One per STD_UDL stage:
 * {stage size, MV1_STD_UDL_MTU, ceil(size / MV1_STD_UDL_MSS)}. */
struct std_dload_info {
	mv1_u32 size;		/* total image size in bytes		*/
	mv1_u32 mtu;		/* max bytes per UDL frame		*/
	mv1_u32 num_frames;	/* number of frames the image was split into */
} __attribute__((packed));

/* modem_prj.h:165-172 — SIPC5 FMT-channel frame header (7 bytes, packed).
 * len includes the 7 header bytes (IPC 4.1, research/analysis/ipc41_catalogue.md). */
struct sipc_fmt_hdr {
	mv1_u16 len;
	mv1_u8  msg_seq;
	mv1_u8  ack_seq;
	mv1_u8  main_cmd;
	mv1_u8  sub_cmd;
	mv1_u8  cmd_type;
} __attribute__((packed));

/* ------------------------------------------------------------------ */
/* SIPC5 link-layer header — sipc5.h:22-60                             */
/* The kernel builds it; userspace never writes it.                    */
/* ------------------------------------------------------------------ */

#define SIPC5_START_MASK	0xF8	/* 0b11111000			*/
#define SIPC5_CONFIG_MASK	0x07	/* 0b00000111			*/
#define SIPC5_PADDING_EXIST	0x04	/* cfg bit 2			*/
#define SIPC5_EXT_FIELD_EXIST	0x02	/* cfg bit 1			*/
#define SIPC5_CTL_FIELD_EXIST	0x01	/* cfg bit 0			*/

#define SIPC5_CONFIG_OFFSET	0
#define SIPC5_CH_OFFSET		1
#define SIPC5_LEN_OFFSET	2
#define SIPC5_CTRL_OFFSET	4
#define SIPC5_EXT_LEN_OFFSET	4

#define SIPC5_MIN_HEADER_SIZE		4
#define SIPC5_HEADER_SIZE_WITH_CTL	5
#define SIPC5_HEADER_SIZE_WITH_EXT_LEN	6

/* Padding rule (added 2026-10-30): when PADDING_EXIST is set (boot channel
 * after DL_START), the kernel pads each frame to sizeof(size_t), which is 4
 * on ARM32 (sipc5.h:93-97). The CP's first stage advances by round-up-4, so
 * the padding must stay 4; an arm64 kernel would pad to 8 and break it. */
#define MV1_SIPC5_ALIGN		4

/* ------------------------------------------------------------------ */
/* SIPC5 channel IDs — include/linux/platform_data/modem_v1.h:114-196  */
/* ------------------------------------------------------------------ */

#define SIPC_CH_ID_PDP_0	10	/* modem_v1.h:126 … PDP_15 = 24 */
#define SIPC_CH_ID_BT_DUN	25	/* modem_v1.h:141 */
#define SIPC_CH_ID_CPLOG1	28	/* modem_v1.h:144 */
#define SIPC_CH_ID_CPLOG2	29	/* modem_v1.h:145 */
#define SIPC_CH_ID_LOOPBACK1	30	/* modem_v1.h:146 */
#define SIPC_CH_ID_LOOPBACK2	31	/* modem_v1.h:147 */

#define SIPC5_CH_ID_BOOT_0	215	/* modem_v1.h:151 (/dev/umts_boot0) */
#define SIPC5_CH_ID_DUMP_0	225	/* modem_v1.h:162 (/dev/umts_ramdump0) */
#define SIPC5_CH_ID_FMT_0	235	/* modem_v1.h:173 (/dev/umts_ipc0) */
#define SIPC5_CH_ID_RFS_0	245	/* modem_v1.h:184 (/dev/umts_rfs0) */
#define SIPC5_CH_ID_MAX		255	/* modem_v1.h:195 */

/* ------------------------------------------------------------------ */
/* Shared-memory doorbell masks/commands — link_device_memory.h:128-152 */
/* The AP2CP interrupt value carries: bits 7 (int valid), 6 (cmd valid),*/
/* bits 0-5 command/ack payload (see int2cmd()/cmd2int() :499-512).     */
/* ------------------------------------------------------------------ */

#define MASK_INT_VALID		0x0080	/* link_device_memory.h:127 */
#define MASK_CMD_VALID		0x0040	/* link_device_memory.h:129 */
#define MASK_CMD_FIELD		0x003F	/* link_device_memory.h:130 */
#define MASK_REQ_ACK_FMT	0x0020	/* link_device_memory.h:132 */
#define MASK_REQ_ACK_RAW	0x0010	/* link_device_memory.h:133 */
#define MASK_RES_ACK_FMT	0x0008	/* link_device_memory.h:134 */
#define MASK_RES_ACK_RAW	0x0004	/* link_device_memory.h:135 */
#define MASK_SEND_FMT		0x0002	/* link_device_memory.h:136 */
#define MASK_SEND_RAW		0x0001	/* link_device_memory.h:137 */

#define CMD_INIT_START		0x0001	/* link_device_memory.h:140 */
#define CMD_INIT_END		0x0002	/* link_device_memory.h:141 */
#define CMD_REQ_ACTIVE		0x0003	/* link_device_memory.h:142 */
#define CMD_RES_ACTIVE		0x0004	/* link_device_memory.h:143 */
#define CMD_REQ_TIME_SYNC	0x0005	/* link_device_memory.h:144 */
#define CMD_CRASH_RESET		0x0007	/* link_device_memory.h:145 */
#define CMD_PHONE_START		0x0008	/* link_device_memory.h:146 */
#define CMD_CRASH_EXIT		0x0009	/* link_device_memory.h:147 */
#define CMD_CP_DEEP_SLEEP	0x000A	/* link_device_memory.h:148 */
#define CMD_NV_REBUILDING	0x000B	/* link_device_memory.h:149 */
#define CMD_EMER_DOWN		0x000C	/* link_device_memory.h:150 */
#define CMD_PIF_INIT_DONE	0x000D	/* link_device_memory.h:151 */
#define CMD_SILENT_NV_REBUILD	0x000E	/* link_device_memory.h:152 */
#define CMD_NORMAL_POWER_OFF	0x000F	/* link_device_memory.h:153 */

/* Doorbell values as they appear on the wire (added 2026-10-30;
 * research/analysis/loader_spec_v2.md §7.1, radio_image.md §2.7). */
#define MV1_CMD2INT(c)		((c) | MASK_CMD_VALID | MASK_INT_VALID)
#define MV1_INT2CMD(x)		((x) & MASK_CMD_FIELD)
#define MV1_DB_INIT_START	0xC1	/* CP -> AP */
#define MV1_DB_INIT_END		0xC2	/* AP -> CP */
#define MV1_DB_CRASH_RESET	0xC7	/* CP -> AP */
#define MV1_DB_PHONE_START	0xC8	/* CP -> AP */
#define MV1_DB_CRASH_EXIT	0xC9	/* CP -> AP */
#define MV1_DB_PIF_INIT_DONE	0xCD	/* AP -> CP */
#define MV1_DB_BOOT_REPLY	0x83	/* CP -> AP during BOOT: INT_VALID|SEND_FMT|SEND_RAW */

/* magic values — link_device_memory.h:447-450 (MEM_IPC_MAGIC is 0xAA; the
 * map word is 32-bit, the kernel compares the full u32 against 0xAA) */
#define MEM_IPC_MAGIC		0x000000AA	/* healthy IPC map	*/
#define MEM_CRASH_MAGIC		0xDEADDEAD	/* CP crash marker	*/
#define MEM_BOOT_MAGIC		0x424F4F54	/* "BOOT"		*/
#define MEM_DUMP_MAGIC		0x44554D50	/* "DUMP"		*/

/* ------------------------------------------------------------------ */
/* 4 MiB legacy shared-memory window — link_device_memory.h:81-110     */
/* shmem_4mb_phys_map, total sizeof == 4 MiB (4096 KiB). Placed at the  */
/* start of the 8 MiB MIPI-LLI shared-memory region. BOOT/DUMP data are */
/* pushed through raw_tx_buff via the RAW TXQ (head/tail in u32). The   */
/* CP sees offset 0 at CP address 0x30000000 (radio_image.md §2.7).     */
/* ------------------------------------------------------------------ */

#define SHM_4M_RESERVED_SZ	4056		/* link_device_memory.h:81 */
#define SHM_4M_FMT_TX_BUFF_SZ	4096		/* :82 */
#define SHM_4M_FMT_RX_BUFF_SZ	4096		/* :83 */
#define SHM_4M_RAW_TX_BUFF_SZ	2084864		/* :84 */
#define SHM_4M_RAW_RX_BUFF_SZ	2097152		/* :85 */

struct shmem_4mb_phys_map {
	mv1_u32 magic;		/* MEM_IPC_MAGIC when IPC is healthy	*/
	mv1_u32 access;		/* == 1 when CP may touch the map	*/

	mv1_u32 fmt_tx_head;	mv1_u32 fmt_tx_tail;
	mv1_u32 fmt_rx_head;	mv1_u32 fmt_rx_tail;
	mv1_u32 raw_tx_head;	mv1_u32 raw_tx_tail;
	mv1_u32 raw_rx_head;	mv1_u32 raw_rx_tail;

	mv1_u8  reserved[SHM_4M_RESERVED_SZ];

	mv1_u8  fmt_tx_buff[SHM_4M_FMT_TX_BUFF_SZ];
	mv1_u8  fmt_rx_buff[SHM_4M_FMT_RX_BUFF_SZ];
	mv1_u8  raw_tx_buff[SHM_4M_RAW_TX_BUFF_SZ];
	mv1_u8  raw_rx_buff[SHM_4M_RAW_RX_BUFF_SZ];
} __attribute__((packed));

/* Field offsets (added 2026-10-30). */
#define MV1_SHM_MAGIC		0x000000
#define MV1_SHM_ACCESS		0x000004
#define MV1_SHM_FMT_TX_HEAD	0x000008
#define MV1_SHM_FMT_TX_TAIL	0x00000C
#define MV1_SHM_FMT_RX_HEAD	0x000010
#define MV1_SHM_FMT_RX_TAIL	0x000014
#define MV1_SHM_RAW_TX_HEAD	0x000018	/* AP writes; BOOT busy-polls it */
#define MV1_SHM_RAW_TX_TAIL	0x00001C
#define MV1_SHM_RAW_RX_HEAD	0x000020	/* CP writes; BOOT caches it once */
#define MV1_SHM_RAW_RX_TAIL	0x000024
#define MV1_SHM_BOOTLOG		0x000C00	/* later shmem kernels; SS333 use unknown */
#define MV1_SHM_FMT_TX_BUFF	0x001000
#define MV1_SHM_FMT_RX_BUFF	0x002000
#define MV1_SHM_RAW_TX_BUFF	0x003000
#define MV1_SHM_RAW_RX_BUFF	0x200000

#if defined(__GNUC__) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(struct shmem_4mb_phys_map) == 0x400000, "4 MiB map");
_Static_assert(__builtin_offsetof(struct shmem_4mb_phys_map, raw_rx_tail) == MV1_SHM_RAW_RX_TAIL, "raw_rx_tail");
_Static_assert(__builtin_offsetof(struct shmem_4mb_phys_map, fmt_tx_buff) == MV1_SHM_FMT_TX_BUFF, "fmt_tx_buff");
_Static_assert(__builtin_offsetof(struct shmem_4mb_phys_map, raw_tx_buff) == MV1_SHM_RAW_TX_BUFF, "raw_tx_buff");
_Static_assert(__builtin_offsetof(struct shmem_4mb_phys_map, raw_rx_buff) == MV1_SHM_RAW_RX_BUFF, "raw_rx_buff");
#endif

/* ------------------------------------------------------------------ */
/* STD_UDL boot protocol carried on /dev/umts_boot0 (added 2026-10-30) */
/* Samsung names (cbd v1 std_boot.h, values only); sequence and rules:  */
/* research/SYNTHESIS.md §2.6-§2.8. A word is 0xDS0T: D = 9 AP->CP or   */
/* A CP->AP, S = stage (bits 8-11), T = step (bits 0-3).                */
/* ------------------------------------------------------------------ */

#define MV1_STD_UDL_AP2CP	0x9000
#define MV1_STD_UDL_CP2AP	0xA000
#define MV1_STD_UDL_STAGE_SHIFT	8
#define MV1_STD_UDL_STAGE_START	0x0
#define MV1_STD_UDL_SEND	0x1
#define MV1_STD_UDL_CRC		0xC
#define MV1_STD_UDL_STAGE_DONE	0xD
#define MV1_STD_UDL_STAGE_FAIL	0xF	/* CP answer: stage rejected */
#define MV1_STD_UDL_WORD(dir, stage, step) \
	((dir) | ((stage) << MV1_STD_UDL_STAGE_SHIFT) | (step))

/* SS333 stage numbers (the TOC slot equals the stage number). */
#define MV1_STAGE_BOOT		0x0	/* sent raw over SPI; only 0x900D/0xA00D here */
#define MV1_STAGE_TOC		0x1	/* one frame of the 512-byte TOC; no CRC step */
#define MV1_STAGE_MAIN		0x2	/* frames + CRC step 0x920C */
#define MV1_STAGE_NV		0x3	/* 0x100000 bytes; never a CRC step */
#define MV1_STAGE_DUMP		0xD
#define MV1_STAGE_FIN		0xF	/* 0x9F00 -> 0xAF00, mandatory */

#define MV1_STD_UDL_MSS		2048	/* payload bytes per frame */
#define MV1_STD_UDL_HDR_LEN	16
#define MV1_STD_UDL_MTU		2064	/* 0x810 */

/* One write() per frame: header + len payload bytes (last frame unpadded). */
struct mv1_std_udl_frame_hdr {
	mv1_u32 cmd;		/* 0x9S01				*/
	mv1_u32 num_frames;	/* frames in this stage			*/
	mv1_u32 curr_frame;	/* 1-based				*/
	mv1_u32 len;		/* payload bytes, <= MV1_STD_UDL_MSS	*/
} __attribute__((packed));

/* One 8-byte write. */
struct mv1_std_udl_crc_frame {
	mv1_u32 cmd;		/* 0x9S0C				*/
	mv1_u32 crc;		/* zlib CRC-32 from the TOC		*/
} __attribute__((packed));

/* DUMP stage information sent by the CP (opt-in dump tool only). */
struct mv1_std_uload_info {
	mv1_u32 dump_size;
	mv1_u32 num_steps;
	mv1_u32 reason_len;
} __attribute__((packed));

/* ------------------------------------------------------------------ */
/* RFS on /dev/umts_rfs0 (added 2026-10-30;                            */
/* research/analysis/ril_runtime_rfs.md §5). Not an FMT header.        */
/* Replies echo cmd and id; the kernel truncates each write() to the    */
/* 2048-byte uplink slot, so replies are written in a short-write loop. */
/* ------------------------------------------------------------------ */

struct mv1_rfs_hdr {
	mv1_u32 length;		/* whole frame, header included		*/
	mv1_u8  cmd;
	mv1_u8  id;		/* echoed in the reply			*/
} __attribute__((packed));

#define MV1_RFS_NV_READ_ITEM		0x01
#define MV1_RFS_NV_WRITE_ITEM		0x02
#define MV1_RFS_READ_FILE		0x03
#define MV1_RFS_WRITE_FILE		0x04
#define MV1_RFS_LSEEK_FILE		0x05
#define MV1_RFS_CLOSE_FILE		0x06
#define MV1_RFS_PUT_FILE		0x07
#define MV1_RFS_GET_FILE		0x08
#define MV1_RFS_RENAME_FILE		0x09
#define MV1_RFS_GET_FILE_INFO		0x0A
#define MV1_RFS_UNLINK_FILE		0x0B
#define MV1_RFS_MAKE_DIR		0x0C
#define MV1_RFS_REMOVE_DIR		0x0D	/* stock: no reply */
#define MV1_RFS_OPEN_DIR		0x0E	/* stock: no reply */
#define MV1_RFS_READ_DIR		0x0F	/* stock: no reply */
#define MV1_RFS_CLOSE_DIR		0x10	/* stock: no reply */
#define MV1_RFS_OPEN_FILE		0x11
#define MV1_RFS_FTRUNCATE_FILE		0x12	/* stock: no reply */
#define MV1_RFS_GET_HANDLE_INFO		0x13
#define MV1_RFS_CREATE_FILE		0x14
#define MV1_RFS_NV_WRITE_ALL_ITEM	0x15
#define MV1_RFS_NV_BUFFER_MESSAGE	0x16
#define MV1_RFS_NV_RESTORE		0x17
#define MV1_RFS_MAX_FRAME		0x80000

#endif /* _MODEM_V1_UAPI_H */
