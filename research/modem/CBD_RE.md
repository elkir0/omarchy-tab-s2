# `cbd` (CP Boot Daemon) — Static Reverse-Engineering Notes

Target: `dumps/stock/ramdisk/sbin/cbd` — Samsung/Shannon CP boot daemon,SS333 variant.
ELF32 little-endian, **ARM32 Thumb-2, static bionic, stripped**, 465,516 bytes.

> **Corrected 2026-10-30.** Samsung's cbd v1 source (public since 2025) and the CP-side analysis
> of BOOT (`research/analysis/radio_image.md`) settled the open items of §8 and corrected a few
> readings (record 4 is the mandatory FIN stage; every stage record is processed; the post-SPI
> call waits for `cp_status`). Fixes are marked "corrected 2026-10-30" below; see
> `research/SYNTHESIS.md` §9.2.

Analysis method: **static only**. Binary was never executed (not even under qemu) and
never probed on a device. Disassembly: objdump + capstone 5.0.7 with manual PC-relative
literal resolution; cross-checked against the kernel tree in `src/kernel_universal5433/`.

## 0. Address conventions used throughout this document

`cbd` is position-independent (PI). Every rodata/data reference is formed as
`ldr rX,[pc,#imm]` (literal pool word = 16-bit delta) followed by `add rX,pc`.
For the **entire file** (code, rodata, and the .data config tables at the tail) the
mapping **`va = file_offset + 0x8000`** holds; it was validated on code strings and on
the config table (entry pattern `[9, 0x61089]` = `"ss333"` found at file offset 0x70668).

All addresses below are given as `va`. Examples:
* string `"dev/mipi-lli/lli_control"`: file offset `0x6352d` → quoted as va `0x6b52d`
* literal `/dev/umts_boot0`: va `0x61a43` (file offset `0x59a43`)
* ioctl helper `ioctl()` PLT: `0x2d0ec`

Truncated-string caution: several long log lines share tails; string quotes below are
taken from resolved `add rX,pc` results, not from bare `strings` hits.

## 1. Command line / option parsing

The stock service line (from `dumps/stock/ramdisk/init.baseband.rc:25`):

```
service cpboot-daemon /sbin/cbd -d -t ss333 -b s -m l -p 13
    class main
    user root
    group radio cache inet misc audio sdcard_r sdcard_rw log shell
    seclabel u:r:cbd:s0
```

getopt string, va `0x68e41` (file offset `0x60e41`), byte-verified:

```
"hdt:b:m:o:p:P:c:"
```

Usage text (verbatim prefix, va near `0x69c79` region documents the switches):

```
-t : modem type     (d:ssd, h:xmm6360? , s:ss333, u:..., p:..., c:cmc222, m:...)
-b : boot link      (d,h,s,u,p,c,m,l — s = SPI, l = LLI)
-m : main link      (l = MIPI-LLI)
-o : dump option    (u,t,r)
-p : partition number of CP firmware image (13 → /dev/block/mmcblk0p13)
-P : alternate NV partition path
-c : config file
-h : help
```

(Full option table text exists in the binary but the *parser switch block itself* was
not pinned to a single function address in this pass — see §8.)

For the stock invocation the effect is (per config entry §1.1 and §2):

| option | value | effect |
|---|---|---|
| `-d` | daemonize / debug flag | enables `<3>mif: cbd:` logging style (also seen with `-t ss333` config entry index 9) |
| `-t ss333` | selects config entry index 9 (va `0x78668`) | see §1.1 |
| `-b s` | boot link = SPI (`LINKDEV_SPI` = 3, `include/linux/platform_data/modem_v1.h:82-93`) | required by `shannon_normal_boot`, else `ERR! BOOT link# %d not supported` |
| `-m l` | main link = LLI (`LINKDEV_LLI` = 10) | required by `shannon_normal_boot`, else `ERR! MAIN link# %d not supported` |
| `-p 13` | selects `/dev/block/mmcblk0p13` (= RADIO) as firmware image device | format string `/dev/block/mmcblk0p%s` va `0x614f2` region (file offset `0x594f2`) |

### 1.1 Config table (per-modem entries)

Table of 12 entries × 0x44 bytes, base va `0x7841c`. Entry **index 9 = ss333** lives at
va `0x78668`; every field below was resolved from bytes (file offset `0x70668`):

```
+0x00: 0x00000009              ; entry index
+0x04: 0x00061089  -> "ss333"  ; name
+0x08: 0x00061aa7  -> "umts"   ; network name
+0x0c: 0x00022a39  -> shannon_normal_boot (thumb entry, even addr)
+0x10: 0x00023375  -> start_shannon_dump (thumb)
+0x14: 0x00023669  -> fn3 = shutdown (= ioctl IOCTL_MODEM_OFF; corrected 2026-10-30)
+0x18: 0x00061a43  -> "/dev/umts_boot0"
+0x1c: 0x00000000
+0x20: 0x00061a43  -> "/dev/umts_boot0"    (2nd open target)
+0x24: 0x00061aac  -> "/dev/umts_ramdump0"
+0x28: 0x00061a53  -> "/dev/mbin0"          (firmware image; see §3)
+0x2c: 0x00000000
+0x30: 0x00000000  ; CP debug dir (NULL for ss333 → std_cp_debug_file skipped)
+0x34: 0x00061ad5  -> "/efs/nv_data.bin"
+0x38: 0x00080000  ; default NV size constant (config), see §5 for actual size used
+0x3c/0x40: 0
```

`/dev/mbin0` is **not a kernel device**: it is created by the ramdisk as a symlink to
the RADIO partition (`dumps/stock/ramdisk/init.universal5433.rc:55`):

```
symlink /dev/block/platform/15540000.dwmmc0/by-name/RADIO /dev/mbin0
```

`/dev/mipi-lli` likewise (`init.baseband.rc:15`):
`symlink /sys/devices/10f24000.mipi-lli /dev/mipi-lli` — DT node
`mipi-lli@10F24000` (`arch/arm/boot/dts/exynos5433-t_common.dtsi:1466`).

## 2. Resource inventory (opens/flags)

All open(2) flags resolved from immediate loads in the code:

| path (va) | flags | where | notes |
|---|---|---|---|
| `/dev/umts_boot0` (0x61a43) | `2` = O_RDWR | `std_boot_prepare_args` `0x1e3bc`, via `[cfg+0x18]` | misc device, kernel `drivers/misc/modem_v1/modem_io_device.c:1794` (`misc_register`), DTS `iod,name = "umts_boot0"` `arch/arm/boot/dts/modem-ss333-pdata.dtsi:169` |
| `/dev/mbin0` (0x61a53) | `0` = O_RDONLY | `prepare_boot_args` `0x22fd2` (`ldr [sl,#0x28]; movs r1,#0; open`) | RADIO partition via symlink |
| `/efs/nv_data.bin` (0x61ad5) | `0` O_RDONLY first, then `2` O_RDWR | `prepare_boot_args` `0x23136`/`0x23184` | see §5 |
| `/efs/nv_data.bin` (create) | `0x101042` = O_RDWR\|O_CREAT\|O_SYNC, mode `0600` | `create_empty_nv` `0xb124` (`movw r1,#0x1042; movt r1,#0x10`, `mov.w r2,#0x180`) | flag values per `include/uapi/asm-generic/fcntl.h:41,79-81` (`O_DSYNC 010000`, `__O_SYNC 04000000`, `O_SYNC=(__O_SYNC\|O_DSYNC)`) |
| `/dev/mipi-lli/lli_control` (0x6b52d) | read-only attr poll | `wait_file_value` `0xb8a4` | kernel `drivers/misc/mipi-lli/mipi-lli.c:312-313` `DEVICE_ATTR(lli_control, 0644)`, created `:481` |
| `/dev/umts_ramdump0` (0x61aac) | (dump path only) | via config `+0x24` | not exercised in normal boot |

sysfs/sysctl paths referenced by the binary but **not** used in the ss333 normal boot
flow (legacy/other models): `/sys/class/sec/switch/check_cpboot` (0x59781),
`/sys/class/sec/linkpm/cp2ap_status/value` (0x62b36),
`/sys/class/sec/uart_cp/control` (0x5c96e), `/dev/spi_boot_link` (0x6209a),
`/dev/kmsg` (0x59b4e), `/sys/bus/platform/drivers` (0x627cc, used by
`get_device_path` 0xb94c which walks `opendir("/sys/bus/platform/drivers")` and
matches directory names `dentry+19` against its two args — composed final path
**undetermined**, §8; corrected 2026-10-30: it builds
`/sys/bus/platform/drivers/mif_sipc5/<first entry containing mif_sipc5 or mif_pdata>/`, used to
read `cp_status/value`).

## 3. Firmware container `radio.img` — TOC layout

The `-p 13` partition (`/dev/block/mmcblk0p13`, RADIO, 92,274,688 bytes = 0x5800000)
is opened O_RDONLY as `[cfg+0x28]` = `/dev/mbin0` and its first **0x80 bytes** are
read into `handle+0xc` (`prepare_boot_args` 0x23002–0x23014: `mov r1,r7(=h+0xc)`,
`movs r2,#0x80`, `read`). cbd then memcmp's **four** names within that buffer
(0x2301a–0x23056), at handle offsets `+0xc`, `+0x2c`, `+0x4c`, `+0x6c`:

```
"TOC"  @+0x0c   (image byte 0x00)
"BOOT" @+0x2c   (image byte 0x20)
"MAIN" @+0x4c   (image byte 0x40)
"NV"   @+0x6c   (image byte 0x60)
```

⇒ the first image bytes hold a **self-record** (byte-verified on `dumps/radio.img`):
name `"TOC"`, offset=0, load_addr=0, **size=0x200**, crc=0, index=1 — i.e. the TOC
declares itself as a 512-byte region. Entries are **32 bytes, contiguous from image
byte 0x20** (15 entries fill the 512-byte TOC):

```
struct toc_entry {          /* 32 bytes, image offset 0x20 + 0x20*i */
    char  name[12];         /* +0x00 NUL-padded                     */
    u32   offset;           /* +0x0c byte offset in image           */
    u32   load_addr;        /* +0x10 CP bus address                 */
    u32   size;             /* +0x14                                */
    u32   crc32;            /* +0x18 zlib CRC32, ~crc & 0xffffffff  */
    u32   index;            /* +0x1c                                */
};
```

Actual `radio.img` TOC (byte-verified; CRC32 recomputed with zlib matches for BOOT
and MAIN):

| entry@img | name | offset | load_addr | size | crc32 | idx | status |
|---|---|---|---|---|---|---|---|
| 0x00 | TOC (self) | 0x0 | 0x0 | 0x200 | 0x0 | 1 | header |
| 0x20 | BOOT | 0x200 | 0x00000000 | 0x29fc | 0x5db1f04c | 0 | ✔ crc recomputed OK |
| 0x40 | MAIN | 0x2c00 | 0x40000000 | 0x21271a0 | 0x1e71169c | 2 | ✔ crc recomputed OK |
| 0x60 | NV | 0x0 | 0x47ee0000 | 0x100000 | 0x0 | 3 | no data in image (NV lives in /efs) |
| 0x80 | OFFSET | 0x7aa00 | 0x0 | 0x85600 | 0x0 | 4 | crc not stored (computed 0x8e1bfe80) |
| 0xa0.. | — | all zero | | | | | 10 unused entries |

cbd validates only the four names above inside the first 0x80 bytes; it does **not**
check the `OFFSET` record or any entry beyond index 3.

## 4. Boot-time in-memory layout (from `prepare_boot_args` 0x22fa0)

`handle` is `std_boot_prepare_args`'s 0xc58-byte buffer at global `0x80218`
(memset @0x1e3bc). After §3's TOC read (buffer at `handle+0xc`, so **image byte N
appears at handle offset 0xc+N** — this identity is the key to every field below):

```
+0x04   boot fd          (/dev/umts_boot0)
+0x0c   "TOC"            (= img 0x00)
+0x18   TOC.offset 0     (= img 0x0c)
+0x20   TOC.size 0x200   (= img 0x14)
+0x28   TOC.idx 1        (= img 0x1c)
+0x2c   "BOOT"           (= img 0x20)
+0x38   BOOT.offset      (img 0x2c = 0x200)
+0x3c   BOOT.load_addr   (img 0x30)
+0x40   BOOT.size        (img 0x34 = 0x29fc)
+0x44   BOOT.crc32       (img 0x38)
+0x48   BOOT.idx 0       (img 0x3c)
+0x4c   "MAIN"           (= img 0x40)
+0x58   MAIN.offset      (img 0x4c = 0x2c00)
+0x5c   MAIN.load_addr   (img 0x50)
+0x60   MAIN.size        (img 0x54 = 0x21271a0)
+0x64   MAIN.crc32       (img 0x58)
+0x6c   "NV"             (= img 0x60)
+0x78   NV.offset 0      (img 0x6c)
+0x7c   NV.load_addr     (img 0x70 = 0x47ee0000)
+0x80   NV.size          (img 0x74 = 0x100000)   ← definitive, see §5
+0x84   NV.crc32 0       (img 0x78)
+0x10   nv fd            (after §5)
+0x20c… stage table: 5 records × 0x2c (44) bytes — see below
```

### Stage table (byte-reconstructed from the template stores at 0x231ac–0x23258)

Each record is built from a 16-byte NEON template (`vld1` from pools at 0x232c0/
0x232d0/0x232e0/0x232f0 = {0,0,0,1}/{1,1,1,0}/{2,1,1,1}/{3,1,1,0}) followed by
scattered `str`/`strd`. Template→record assignment (vst1 targets): A→rec0,
B→rec1, C→rec2, D→rec3. Final contents:

| rec | base | id | start | payload | crc-flag | done | fd | offset | size | crc |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 0x20c | 0 | 0 | 0 | 1 | 1 | binfd | BOOT.off | BOOT.size | 0 |
| 1 | 0x238 | **1** | 1 | 1 | 0 | 1 | binfd | TOC.off (0) | TOC.size (0x200) | 0 |
| 2 | 0x264 | **2** | 1 | 1 | 1 | 1 | binfd | MAIN.off | MAIN.size | MAIN.crc |
| 3 | 0x290 | **3** | 1 | 1 | 0 | 1 | **nvfd** | 0 | NV.size (0x100000) | 0 |
| 4 | 0x2bc | **0xf** | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

Download-plan reading: BOOT is **not** framed here (rec0 payload=0 — it was already
sent raw by `shannon_boot_xmit_loader`, §6 step 9); rec0 only closes stage 0 with
`stage_done(0)`. Stage 1 = the 512-byte **TOC region itself** (image bytes 0–0x200).
Stage 2 = MAIN **with** the 0x900c CRC handshake. Stage 3 = 0x100000 bytes **read
from the /efs NV fd**. rec4 emits only a bare `stage_start(0xf)` (`[rec+0x04]`=1,
payload=0, done=0). (Corrected 2026-10-30: that bare start is the **FIN** stage, `0x9F00` →
`0xAF00`, and it is **mandatory**: BOOT jumps to MAIN only on FIN.) (Evidence: template `vst1` targets at 0x231cc/0x231ee/0x2320c/
0x2322e, field stores at 0x231d0–0x23254.)

Field offsets consumed by `std_dl_send_bin` 0x1e7bc (all pinned): `[rec+0x00]` id,
`[rec+0x04]` do-stage_start flag, `[rec+0x08]` has-payload flag, `[rec+0x0c]` crc
flag (CRC step requires payload-flag ≠ 0 **and** crc-flag ≠ 0, 0x1e9a0–0x1e9b6),
`[rec+0x10]` do-stage_done flag, `[rec+0x14]` fd, `[rec+0x18]` offset,
`[rec+0x20]` size, `[rec+0x24]` crc value.

Global state at `0x81ab8` = `{1, handle, binfd, nvfd}` (store seq 0x231ac–0x231ca).

## 5. NV data handling

> **Note 2026-10-30.** This section describes what the stock binary does. A replacement loader
> must **not** reproduce it: it never creates, reopens read-write, pads or writes `nv_data.bin`,
> and refuses to boot when NV is missing, short or blank (`research/SYNTHESIS.md` rule 4, D4).

`prepare_boot_args` (0x23136–0x2318e):

1. `open("/efs/nv_data.bin", O_RDONLY)` ([cfg+0x34]).
2. If that fails with `errno == 2` (ENOENT): log `ERR! no NV(%s) file`, then
   `create_empty_nv(path, size)` where **size = `[handle+0x80]`** — the NV record's
   **`size` field as read from the image TOC** (image byte 0x74 = 0x100000;
   handle+0x80 ↔ img[0x74] verified by the buffer identity of §4). This is *not* the
   config constant `[cfg+0x38]` = 0x80000 — that word sits in the config table entry
   but the store path uses the TOC-derived value (0x23172–0x2317a, 0x2323a).
3. `create_empty_nv` (0xb124, verified line-by-line): logs `create NV(%s)`;
   `open(path, 0x101042, 0600)`; size check `ERR! wrong size(%ld)`;
   `malloc(size)`; `memset(buf, 0xFF, size)`; `write(fd, buf, size)`; `fsync`;
   returns -1 on failure with `ERR! NV(%s) open fail` / `malloc(%ld) fail` /
   `cbd: (ERR! %s) %s: ERR! fsync(nv_fd) fail : %s` (0x623bb).
4. Reopen O_RDWR → fd stored at `handle+0x10`, log `NV(%s) opened (fd %d)`.

During the download (§6.1) the **stage-3 record reads from this fd**: the CP receives
a copy of the NV region (id 3, size 0x100000) streamed from `/efs/nv_data.bin`.

The NV **content** is never parsed by cbd; the NV record in the TOC exists so that
stage 3 (see §4) hands its *size* to the CP. `/efs` contents were **not** read for
this analysis (they hold the IMEI and are out of scope by instruction).

## 6. Ordered boot sequence (`shannon_normal_boot` 0x22a38, fully traced)

Entry: config entry 9, `+0x0c` = 0x22a39 (thumb). Calls, in order, with the failure
tag each logs (`ERR! <step> fail`):

| # | va | call | effect (kernel side) |
|---|---|---|---|
| 1 | 0x22b7a | `property_get("ril.cbd.rfs_check_done" 0x645bd, buf, "0")` (0x2bc64) | bionic property; on stock Android set by RFS check |
| 2 | 0x22b88 | `usleep(100000)` loop ×50 (`r5=0x32`), until `buf[0]=='1'` | 50 × 100 ms timeout ⇒ log `NV validation %s` = "TIMEOUT"/"done" |
| 3 | 0x22bce | `prepare_boot_args(sl, 0)` (0x22fa0) | §4/§5 |
| 4 | 0x22bda | `ioctl(boot_fd, 0x6f37, {10})` | `IOCTL_MODEM_SET_TX_LINK` = LLDEV_LLI (`modem_io_device.c:1286-1311`: `copy_from_user` int → `set_current_link`) |
| 5 | 0x22bf6 | `std_boot_modem_on` 0x1e5e8 | `ioctl(fd, 0x6f19 IOCTL_MODEM_ON, 0)` (`modem_io_device.c:1099` → `ops.modem_on`) |
| 6 | 0x22c06 | `std_boot_dload_on` 0x1e74c | `ioctl(fd, 0x6f22 IOCTL_MODEM_BOOT_ON, 0)` |
| 7 | 0x22c16 | `std_boot_dload_start` 0x1e784 | `ioctl(fd, 0x6f28 IOCTL_MODEM_DL_START, 0)` (`:1175` → `ld->dload_start`) |
| 8 | 0x22c26 | `ioctl(boot_fd, 0x6f37, {3})` | switch TX link to SPI for the BOOT loader write |
| 9 | 0x22c3e | `shannon_boot_xmit_loader` 0x236f4 | raw `lseek(bin_fd, BOOT.off)` + `read(bin_fd, buf, BOOT.size)` + single `write(boot_fd, buf, size)`; then call `0xba70("mif_sipc5" 0x6b59e, "mif_pdata" 0x6b5a8, "cp_status/value" 0x6b5b2, "1", …)` — 5-arg call; corrected 2026-10-30: it is `wait_gpio_value(drv, key, "cp_status/value", "1", 10)`, which polls the CP_STATUS GPIO up to 10 times 500 ms apart: a mandatory wait before step 10 |
| 10 | 0x22c4e | `ioctl(boot_fd, 0x6f37, {10})` | back to LLI |
| 11 | 0x22c66 | `wait_file_value("/dev/mipi-lli/lli_control"... wait "MIPI-LLI 1", 10 retries)` 0xb8a4 | **read-only** poll of the sysfs attr (`mipi-lli.c:251-259` prints `MIPI-LLI %x`); 500 ms sleep between reads; success ⇒ `LLI STATUS mount` |
| 12 | 0x22c8e | `std_dl_send_bin` 0x1e7bc | framed download, see below |
| 13 | 0x22c9e | `std_boot_dload_off` 0x1ecb0 | `ioctl(fd, 0x6f23 IOCTL_MODEM_BOOT_OFF, 0)`; on success **also** issues `0x6f48`, on failure `0x6f47` — **neither exists in this kernel tree** (§8); corrected 2026-10-30: they are `IOCTL_MODEM_CLR_CP_BOOTLOG` / `GET_CP_BOOTLOG` of later modem_v1 kernels and return a harmless `-EINVAL` here |
| 14 | 0x22cae | `std_boot_finalize` 0x1ecfc | `ioctl(fd, 0x6f24 IOCTL_MODEM_BOOT_DONE, 0)` (`:1139`) |

### 6.1 `std_dl_send_bin` framed download (0x1e7bc, fully traced)

For each of the 5 stage records (§4), skipping records whose `[rec+0x08]` == 0
(corrected 2026-10-30: no record is skipped; only the payload step of a record with
`[rec+0x08]` == 0 is skipped, so rec0 still sends its done exchange and rec4 its FIN start):

1. `[rec+0x00]` = stage id; if `[rec+0x04]` ≠ 0 → `std_udl_stage_start(fd, id)` 0x1e700:
   req `0x9000 | id<<8`, expect `0xa000 | id<<8` (via `std_udl_req_resp` 0x1fd28).
   Failure: `ERR! [stage %d] START fail (req:0x%X exp:0x%X)`.
2. If `[rec+0x08]` == 0 skip payload. Else memset 0x810-byte buffer;
   `lseek64([rec+0x14] fd, [rec+0x18] off, SEEK_SET)` (0x36190);
   `frames = (size + 0x7ff) / 0x800` (ceil, computed via `lsr #0xb` trick 0x1e874);
   store frame header word `0x9001 | id<<8` at `handle+0x448`; log
   `cmd = 0x%x / stage = %d / size = %d (0x%X) / mtu = 0x810 / mss = 0x800 / frames = %d`;
   `ioctl(fd, 0x6f29 IOCTL_MODEM_FW_UPDATE, {size, 0x810, frames})`
   (`modem_io_device.c:1183` → `ld->firm_update`; the struct matches
   `struct std_dload_info {u32 size, mtu, num_frames} __packed`,
   `drivers/misc/modem_v1/include/sipc5.h:240-248`).
3. Frame loop: `read(fd, buf+0x10, min(0x800, remaining))`, then
   `write(boot_fd, buf, len + 0x10)` — every frame carries a **16-byte header**
   built at `handle+0x448` (0x1e856–0x1e928): `{0x9001|id<<8, frames_total,
   frame_seq, frame_len}` at +0x448/+0x44c/+0x450/+0x454, payload at +0x458.
   `frame_seq` is incremented *before* each frame (0x1e90a–0x1e91e) ⇒ 1-based
   (first frame = 1, last = frames_total); `frame_len` ≤ 0x800 = this frame's
   payload byte count.
   Errors: `ERR! read fail`, `ERR! rcvd %d != frm->len %d`, `ERR! write fail`,
   `ERR! sent %d != frm_len %d` (tag `std_dl_tx_frame`).
4. After the last frame: `std_udl_req_resp(fd, 0, 0xa001 | id<<8)` — write nothing,
   poll & read the 4-byte ack.
5. If `[rec+0x0c]` crc-flag ≠ 0: cmd `0x900c | id<<8`, crc = `[rec+0x24]`,
   `write(fd, {cmd, crc}, 8)`, then `std_udl_req_resp(fd, 0, 0xa00c | id<<8)`
   (tag `std_dl_send_crc`, log `cmd = 0x%x, crc = 0x%x`). In the stock table only
   the MAIN record carries a non-zero crc action (crc value slot `[handle+0x288]` =
   TOC MAIN.crc32).
6. If `[rec+0x10]` ≠ 0 → `std_udl_stage_done(fd, id)` 0x1e6b4:
   req `0x900d | id<<8`, expect `0xa00d | id<<8`.

`std_udl_req_resp` (0x1fd28): optional 4-byte write, then `poll(fd, POLLIN, 30000)`
(timeout literal `0x7530` at 0x1e30e, `std_udl_poll` 0x1e308), then 4-byte read,
compare; `OK!! resp 0x%X == exp` / `ERR! std_udl_poll fail` / `ERR! write fail`.

The constants `0x9000/0xa000/0x9001/0xa001/0x900c/0xa00c/0x900d/0xa00d` appear
**nowhere** in the kernel tree (grep across `drivers/`, `include/`); the kernel's
`sipc5.h` only defines `STD_UDL_STEP_MASK 0xF`, `STD_UDL_SEND 0x1`, `STD_UDL_CRC 0xC`
(`sipc5.h:240-246`). They are consumed by the CP-side or by the umts_boot0 char-req
path; for a loader they must be treated as raw magic values. (Corrected 2026-10-30: they are
Samsung's **STD_UDL** protocol, named in cbd v1 `std_boot.h`: AP2CP 0x9000, CP2AP 0xA000, stage
in bits 8-11, steps START 0x0, SEND 0x1, CRC 0xC, DONE 0xD, STAGE_FAIL 0xF; the kernel only
carries them.)

## 7. After-boot: crash / ramdump / RFS behavior

* Dump entry point: config `+0x10` = `start_shannon_dump` 0x23375 (thumb) —
  dispatches the dump flow (tag `start_shannon_dump`,
  `ERR! shannon_dump_boot fail`); triggered from cbd's main loop when the link
  reports CP crash (exact trigger point in main **not pinned**, §8).
* Dump artifacts (strings, va): `%s/%s_info_%s_%s.log` 0x62fac,
  `cat /d/svnet/mem_dump > %s/mem_dump_%s.log` 0x68cf0,
  `logcat -bradio -vthreadtime -t2000  > %s/logcat_radio_%s.log` 0x62e39,
  `%s/%s_dump_%s.log` 0x68d1b.
* `std_cp_debug_file` 0x1ed34: if `[cfg+0x30]` non-NULL (NULL for ss333), formats
  `%s/%s` with dir + `CP_Debug_symbol.dbg`, test-opens it, then
  `snprintf("cat %s > %s")` + `system()`; logs `Get CP_Debug file: %s`.
  For ss333 this is skipped (`CP debug path wasn't configured` 0x68b9c).
* RFS check: cbd *waits* for the Android property `ril.cbd.rfs_check_done == 1`
  (§6 step 1-2) but never sets it; a non-Android port can simply skip the wait.
  (Corrected 2026-10-30: libsec-ril's `Modem::Init` sets it after its NV check `Nv::Init`,
  a read-**write** repair routine that can regenerate NV; a port replaces the wait by a
  read-only verification of a copy and never runs that repair.)

## 8. Open questions / not determined

> **Status 2026-10-30** (from cbd v1, `research/research_notes/…/cp_boot_firmware.md` Q2):
> item 2 `fn3` = `shutdown` (`IOCTL_MODEM_OFF`); item 3 0x6f47/0x6f48 = GET/CLR_CP_BOOTLOG
> (harmless `-EINVAL` here); item 4 call 0xba70 = `wait_gpio_value(..., "cp_status/value", "1",
> 10)`; item 6 record fields = `{stage, start, download, validate, finish, b_fd, b_offset,
> m_offset, b_size, crc, dl_once}`; item 7 `get_device_path` =
> `/sys/bus/platform/drivers/mif_sipc5/<entry>/`. Items 1, 8 and 9 remain as written.

1. **Option-parsing switch block** — getopt string (0x68e41) and usage text are
   byte-verified, but the `case` code that maps `-t ss333` → entry 9 was not pinned
   to a single function address in this pass. Confidence in §1's effect table is high
   (config table + entry 9 contents are byte-proven) but the parser location is
   unstated.
2. **`fn3` (config `+0x14` = 0x23669)** — never called on the normal-boot path;
   role undetermined.
3. **ioctl `0x6f47` / `0x6f48`** (`std_boot_dload_off` 0x1ecb0) — no
   `_IO('o', 0x47/0x48)` definition exists anywhere in this kernel tree (searched
   `modem_prj.h` v1+v2, mipi-lli, all of `include/`). Values and semantics are
   reported raw from the binary.
4. **Call `0xba70` in `shannon_boot_xmit_loader`** — 5 arguments including two
   strings `mif_sipc5`/`mif_pdata`, path `cp_status/value`, value `"1"`. A prior
   pass labeled 0xba70 `property_set` (2-arg bionic API) — inconsistent with the
   observed 5-arg call; treated as **undetermined**, raw args documented.
5. ~~NV size slot~~ — resolved: `handle+0x80` ↔ image byte 0x74 = NV record `size`
   (0x100000). Removed from the open list (kept here so section numbering stays
   stable).
6. **Stage-record template words** — the four 16-byte templates (0x232c0..0x232f0)
   and all scattered stores are byte-pinned, and the download-plan reading in §4 is
   consistent with every `std_dl_send_bin` branch; the *semantic labels* of the
   unused middle words are inferred, not proven.
7. **`get_device_path` (0xb94c) composed path** — the function walks
   `/sys/bus/platform/drivers/<dir>` matching two caller-supplied names and appends
   `"%s/%s/"`; neither of its four call sites on the normal-boot path was resolved
   to a full literal path.
8. **main() and crash-trigger wiring** — the dump trigger, `system_server` cmdline
   guard (entry 0x8130, string `/proc/%d/cmdline` "system_server"), and the ioctl
   that signals CP death were not traced to closure in this pass.
9. Android-env list from earlier passes (property area, `/dev/socket/logdw`,
   `/dev/__kmsg__`) was **not re-verified** byte-for-byte in this pass; treat as
   indicative only (see §9 verdict for what cbd minimally needs).

## 9. Android dependencies & portability verdict (summary)

Hard runtime requirements observed in the ss333 normal-boot path:

1. `/dev/umts_boot0` misc char device (kernel `modem_v1` driver with ss333 DTS).
2. `/dev/mbin0` → RADIO block device (created by init.rc, trivially reproduced).
3. `/dev/mipi-lli/lli_control` sysfs attr readable and printing `MIPI-LLI 1`
   (`mipi-lli.c:251-259`).
4. bionic `property_get`/`property_set` on `ril.cbd.*` (only `ril.cbd.rfs_check_done`
   is *read* in the boot path; the wait can time out after 5 s and cbd proceeds).
5. Android logger (`__android_log_print` 0x2a050) — non-fatal if it fails.
6. `/efs` writable, root uid, `radio`-group style perms (mode 0600 file created).
   (Note 2026-10-30: this is why stock cbd must never run on this tablet; the independent loader
   needs no writable `/efs`.)

Whether stock `cbd` runs unmodified on non-Android Linux is discussed in
`LOADER_SPEC.md` §"Verdict"; the short answer is "only with a shim set", and the
independent replacement avoids cbd entirely.
