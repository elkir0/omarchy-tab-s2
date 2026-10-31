# `shannon-loader` — Specification v2 (SS333 over SPI + MIPI-LLI)

Target: Samsung Galaxy Tab S2 8.0 LTE (SM-T715), Exynos 5433, external Shannon SS333 CP.
Host: mainline Linux 6.12 (ARM32) + Arch Linux ARM, with the Samsung 3.10 `modem_v1` and
`mipi-lli` drivers ported to 6.12 **with their userspace ABI unchanged**.
This document replaces `research/modem/LOADER_SPEC.md`. It is a specification, not code.

Date: 2026-10-29. Analysis was read-only: no device was contacted, no Samsung binary was
executed, and no EFS / `nv_data` / `m9kefs` content was opened.

---

## 0. Conventions

### 0.1 Evidence tags

- **[P]** proven: directly readable in the cited source (`file:line` or URL).
- **[I]** inferred: derived by reasoning, which is given next to the tag.
- **[D]** design decision of this specification (not a fact about Samsung's code).

### 0.2 Source roots used in citations

| Key | What | Licence | Location |
|---|---|---|---|
| `K/` | Samsung 3.10 kernel (the ABI being ported) | GPL-2.0 | `src/kernel_universal5433/` |
| `ML/` | Linux 6.12 tree | GPL-2.0 | `src/linux-6.12/` |
| `RE` | Static RE of the stock `/sbin/cbd` of this device | project doc | `research/modem/CBD_RE.md` |
| `OLD` | Previous loader spec (superseded) | project doc | `research/modem/LOADER_SPEC.md` |
| `BR` | Bring-up dossier | project doc | `research/modem/SS333_LLI_BRINGUP.md` |
| `UAPI` | ABI header | GPL-2.0 | `research/modem/modem_v1_uapi.h` |
| `RN/` | Web research notes | project doc | `research/modem/research/research_notes/Modem Shannon SS333 sous Linux/` |
| `V1/` | Samsung "cpboot v1" (`cbd` C source) | **no licence header, `proprietary: true`** — used only to verify behaviour, described in our own words | https://github.com/samsungexynos7420/android_hardware_samsung_slsi-linaro_exynos/tree/lineage-19.1/cpboot (last commit touching `cpboot/`: 9e2e8b32, 2025-04-03). Local copy `scratchpad/src/cpboot/` was re-downloaded and is byte-identical for `boot_shannon333.c`, `std_boot.c`, `std_boot.h`, `util.c`, `main.c`, `shannon333.h`. |
| `V3/` | Samsung "cpboot_v3" | Apache-2.0 | https://github.com/LineageOS/android_hardware_samsung_slsi-linaro_exynos/blob/lineage-24.0/cpboot_v3/ProtocolSipc.cpp (local `scratchpad/src/cpboot3/`) |
| `LSI/` | libsamsung-ipc (Replicant upstream) | GPL-2.0-or-later | https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc, commit 81a412cb235a (2023-09-20), local `scratchpad/src/libsamsung-ipc/`; fork with TOC/herolte work: https://github.com/manoedinata/libsamsung-ipc/tree/shannon-lte-data |
| `MZ/` | Meizu Pro 5 (Exynos 7420 + SS333) kernel 3.10.61 | GPL-2.0 | https://github.com/meizuosc/m576 (`drivers/misc/mipi-lli/{exynos-mipi-lli.c, mipi-lli.c, mipi-lli-boot-spi.c}`), downloaded to `scratchpad/loader/meizu_m576/` and `scratchpad/web/m576_bootspi.c` |
| `RD/` | Stock ramdisk init scripts | — | `dumps/stock/ramdisk/` |
| `STR` | `strings` of the stock `libsec-ril.so` (extracted earlier, never executed) | — | `scratchpad/secril_strings.txt` |
| `TR-J7`, `TR-S6` | Public dmesg traces of stock cbd | — | https://github.com/pytorch/cpuinfo/blob/main/test/dmesg/galaxy-j7-prime.log ; https://github.com/yaxiaiyuting/zerofltectc-los20-fix/blob/main/evidence/dmesg-working.txt (local copies `scratchpad/src/misc/`) |

`scratchpad/` = a local working copy, not in this repository.

### 0.3 Which source wins (precedence rules)

1. **Kernel behaviour** (ioctl semantics, framing, states, timeouts inside the kernel): `K/` wins,
   because the port keeps this ABI; the userspace loader must match what `K/` does, not what a
   dossier says it does. [D]
2. **Userspace sequencing on this device**: the stock binary (`RE`) is ground truth. `V1/` is the
   public source of the same program family; its SS333 path matches `RE` call by call
   (compare `RE` §6 steps 4–14 with `V1/boot_shannon333.c:303-391`) [P]. `V1/` wins where `RE`
   marked something "undetermined" or where `RE`'s prose contradicts its own byte evidence.
   Where `V1/` and the binary genuinely differ (NV path, property name, NV reopen mode, getopt
   string), `RE` describes stock, and the loader chooses the option that is invisible to the CP
   and safer. [D]
3. Public runtime traces (`TR-J7`, `TR-S6`) and `LSI/` corroborate, they do not override. [D]
4. Dossiers and research notes (`BR`, `OLD`, `RN/`) are secondary; superseded wherever a primary
   source contradicts them (§12 lists every case). [D]
5. The project's safety rules override stock behaviour: no NV creation, no `CP_UPLOAD`. [D]

---

## 1. The ten most important corrections and findings (summary)

1. **cp_status wait after the SPI write is mandatory** (`OLD` step 9 dropped it). `cbd` polls
   `/sys/bus/platform/drivers/mif_sipc5/<mif_pdata dev>/cp_status/value` for `"1"`, 10 reads
   500 ms apart, *before* switching the TX link back to LLI. [P `V1/boot_shannon333.c:290-294`,
   `V1/shannon333.h:1-4`, `V1/util.c:757-833`; export in `K/drivers/misc/modem_v1/modem_main.c:506`]
2. **The FIN stage `0x9F00 → 0xAF00` is always sent** after the NV stage (`OLD` said skip it).
   [P `V1/boot_shannon333.c:90-99`, `V1/std_boot.c:852-941`; `LSI/samsung-ipc/devices/herolte/herolte.c:339-363`]
3. **Nobody in userspace mounts the LLI link.** The kernel does it from interrupts once the CP's
   first stage brings its M-PHY out of HIBERN8; the AP stays LLI *slave*. Userspace only reads
   `lli_control`. Writing `2`/`3` (as `BR` §3.2/§3.6 proposed) is not done by stock and must not
   be done. Resolves U-7. [P §5]
4. **`IOCTL_MODEM_BOOT_OFF` does not depend on rild.** It waits only for the CP's `PHONE_START`
   doorbell. `rild_ready` (both `umts_ipc0` and `umts_rfs0` open) only decides whether
   `INIT_END` is sent; opening the two nodes after `BOOT_OFF` sends `INIT_END` too.
   [P `K/.../modem_ctrl_ss333.c:405-429`, `K/.../link_ctrlmsg_command.c:119-168`,
   `K/.../link_device_memory_main.c:629-692`] (§7)
5. **NV is never created, never written, never padded.** Stock `cbd` (and `OLD`) create a
   0xFF-filled `nv_data.bin` on `ENOENT`; the loader refuses to boot instead and streams a
   verified, size-exact snapshot read-only. [P `V1/boot_shannon333.c:163-190`, `V1/util.c:497-540`; D §8]
6. **CP failure answers have low nibble 0xF** (`STD_UDL_STAGE_FAIL`). No Samsung AP code decodes
   them (they are just "unexpected response"); the loader decodes and reports them
   (e.g. `0xA20F` = MAIN rejected). [P constant `V1/std_boot.h:33`, `V3/ProtocolSipc.cpp:28`; meaning I]
7. **0x6F47/0x6F48 are `GET/CLR_CP_BOOTLOG`.** `cbd` sends GET after a failed `BOOT_OFF` and
   CLR after a successful one, ignoring the result; on this kernel both return `-EINVAL`.
   [P `V1/boot.h:116-117`, `V1/std_boot.c:943-961`, `K/.../modem_io_device.c:1310-1318`]
8. **The BOOT image travels as one `spi_sync` of the raw bytes**: the kernel strips a fixed
   4-byte SIPC5 header, SPI mode 0, 8 bits/word, 100 kHz, 10 µs post-transfer delay, hardware
   auto chip-select, no read-back. Two latent 3.10 bugs: an image ≥ 0xFFFC bytes would get 2
   header bytes prepended, and an SPI failure surfaces as `write() = -1, errno = EINTR`.
   [P `K/.../link_device_spi.c:63-131`; arithmetic I] (§6)
9. **Stage payloads go into the legacy RAW TX ring of the 4 MiB LLI map** as SIPC5 frames
   (`cfg 0xFC`, `ch 0xD7`, 16-bit length, 4-byte padding) with no doorbell; `FW_UPDATE` is
   informational only (the kernel stores the struct and never reads it).
   [P `K/.../link_device_bootdump.c:97-127,235-249`, `grep img_info` = 2 hits] (§6)
10. **`STATE_CRASH_RESET` is unreachable on this kernel** (no emitter of
    `MDM_EVENT_CP_FORCE_RESET`); a CP crash always ends in `STATE_CRASH_EXIT` and `POLLHUP` on
    `umts_boot0`. Silent recovery = `IOCTL_MODEM_OFF` + normal boot; `DUMP_RESET` is for the dump
    path only; `CP_UPLOAD` panics the AP and is forbidden. [P §9]

---

## 2. Constants and data formats

### 2.1 ioctls used (all `_IO('o', n)`, value `0x6Fnn`) [P `UAPI:39-80`, `K/.../modem_io_device.c:1089-1322`]

| Name | Value | Argument | Return on this kernel |
|---|---|---|---|
| `IOCTL_MODEM_ON` | 0x6F19 | none | 0 (GPIO power-on, LLI reset; ~1.0 s) |
| `IOCTL_MODEM_OFF` | 0x6F20 | none | 0 (no-op if state already OFFLINE) |
| `IOCTL_MODEM_BOOT_ON` | 0x6F22 | none | 0, state → BOOTING |
| `IOCTL_MODEM_BOOT_OFF` | 0x6F23 | none | 0 after `PHONE_START`, `-EAGAIN` after 30 s |
| `IOCTL_MODEM_BOOT_DONE` | 0x6F24 | none | 0 (wake unlock) |
| `IOCTL_MODEM_STATUS` | 0x6F27 | none | `enum modem_state` as the return value |
| `IOCTL_MODEM_DL_START` | 0x6F28 | none | 0; `-EINVAL` if the TX link is SPI; `-EFAULT` if the BOOT magic read-back fails |
| `IOCTL_MODEM_FW_UPDATE` | 0x6F29 | `struct std_dload_info *` (12 B) | 0; `-EINVAL` if TX link is SPI |
| `IOCTL_MODEM_SET_TX_LINK` | 0x6F37 | `int *` (3 = SPI, 10 = LLI) | 0; `-ENODEV` unknown link |
| `IOCTL_MODEM_GET_CP_BOOTLOG` | 0x6F47 | none | `-EINVAL` (no `ld->ioctl` on LLI) |
| `IOCTL_MODEM_CLR_CP_BOOTLOG` | 0x6F48 | none | `-EINVAL` |
| `IOCTL_MODEM_DUMP_RESET` | 0x6F36 | none | dump path only |
| `IOCTL_MODEM_DUMP_START` | 0x6F32 | none | dump path only |
| `IOCTL_MODEM_CP_UPLOAD` | 0x6F35 | — | **`panic()`** — never issue |
| `IOCTL_MODEM_FORCE_CRASH_EXIT` | 0x6F34 | — | not used by the loader |

`enum modem_state`: OFFLINE 0, CRASH_RESET 1, CRASH_EXIT 2, BOOTING 3, ONLINE 4,
NV_REBUILDING 5, LOADER_DONE 6, SIM_ATTACH 7, SIM_DETACH 8 [P `UAPI:99-109`]. `V1/boot.h:211`
adds `STATE_CRASH_WATCHDOG = 9`, which this kernel never returns [P: absent from `K/.../modem_prj.h`].

### 2.2 STD_UDL words (std_udl protocol carried in `umts_boot0` payloads)

Word layout (u32, little-endian on the wire): `0xD S 0 T`
- D = `0x9` AP→CP (`STD_UDL_AP2CP 0x9000`), `0xA` CP→AP (`STD_UDL_CP2AP 0xA000`);
- S = stage (bits 8–11): BOOT 0, TOC 1, MAIN 2, NV 3, DUMP 0xD, FIN 0xF;
- T = step (bits 0–3): STAGE_START 0x0, SEND 0x1, CRC 0xC, STAGE_DONE 0xD, STAGE_FAIL 0xF.
[P `V1/std_boot.h:21-33`; SS333 stage numbering `V1/shannon.h:15-25` (VSS only with `SUPPORT_SS310AP`)]

Payload frame (one `write()` each): 16-byte header `{u32 cmd, u32 num_frames, u32 curr_frame,
u32 len}` followed by `len` bytes, `len ≤ 2048` (MSS), `curr_frame` 1-based, the last frame is
**not padded** (written length = 16 + len). MTU constant `0x810` (2064). CRC frame: 8 bytes
`{u32 cmd, u32 crc}`. `struct std_dload_info {u32 size, u32 mtu, u32 num_frames}` packed, 12 B.
[P `V1/std_boot.h:14-19,46-63`, `V1/std_boot.c:185-295`, `K/.../include/sipc5.h:244-248`]

### 2.3 Image (RADIO partition) [P `RE` §3, byte-verified on `dumps/radio.img`]

512-byte TOC of 32-byte entries `{char name[12]; u32 offset; u32 load_addr; u32 size; u32 crc;
u32 index}`. Slot 0 is the TOC itself. On the stock image:

| slot | name | offset | load_addr | size | crc32 (zlib, matches payload) |
|---|---|---|---|---|---|
| 0 | TOC | 0x0 | 0x0 | 0x200 | 0 |
| 1 | BOOT | 0x200 | 0x0 | 0x29FC (10 748) | 0x5DB1F04C |
| 2 | MAIN | 0x2C00 | 0x40000000 | 0x21271A0 (34 763 168) | 0x1E71169C |
| 3 | NV | 0x0 (no payload) | 0x47EE0000 | 0x100000 | 0 |
| 4 | OFFSET | 0x7AA00 | 0 | 0x85600 | — (ignored by everyone) |

Partition size 92 274 688 B. `cbd` validates only names of slots 0–3 in the first 0x80 bytes
[P `V1/boot_shannon333.c:138-153`, `RE` §3]. The AP never uses `load_addr`; the CP learns it
from the TOC stage. [P no use in `V1/`; meaning I, `RN/cp_boot_firmware.md` Q1]

### 2.4 Kernel framing in the shared-memory ring (for kernel tests and the port)

Every `write()` on `umts_boot0` while the TX link is LLI becomes, in the RAW TX ring:
`cfg (1) | ch (1) | len (2, LE) | payload | padding to 4`, with `cfg = 0xF8 | 0x04 = 0xFC`
(start mask + `PADDING_EXIST` because `ld->aligned` is true after `DL_START`), `ch = 215 = 0xD7`,
`len = 4 + payload` (padding excluded). Extended 32-bit length only above 0xFFFF bytes (never
for std_udl). [P `K/.../modem_io_device.c:1324-1415,1706-1757`, `K/.../include/sipc5.h:93-97`,
`K/.../link_device_bootdump.c:194-222`] Padding granularity is `sizeof(size_t)` = 4 on the ARM32
3.10 kernel; the port must keep 4 even if ever built for arm64. [I: CP was built against the
ARM32 stock kernel]

Legacy 4 MiB map at the start of the 8 MiB LLI region (`struct shmem_4mb_phys_map`): magic @0,
access @4, fmt_tx head/tail @8/@0xC, fmt_rx @0x10/@0x14, raw_tx @0x18/@0x1C, raw_rx @0x20/@0x24,
fmt_tx_buff @0x1000 (4 KiB), fmt_rx_buff @0x2000 (4 KiB), raw_tx_buff @0x3000 (0x1FD000 B),
raw_rx_buff @0x200000 (0x200000 B). [P struct `UAPI:246-261` / `K/.../link_device_memory.h:81-110`;
offsets I: computed from the packed struct]

---

## 3. Loader architecture overview [D]

Single long-running process `shannon-loader` (systemd `Type=notify`), root, phases:

1. **Preflight** (no hardware side effect): resolve paths, parse TOC, NV policy (§8), check
   kernel ABI presence.
2. **Boot attempt** (§4): ioctls + SPI + LLI + stage engine + handshake.
3. **Online**: hold `umts_ipc0`/`umts_rfs0` open (§7), `sd_notify(READY=1)`.
4. **Supervisor** (§9): wait for `POLLHUP` on `umts_boot0`; silent restart on crash.

All device I/O goes through a thin injectable layer (boot device ops, sysfs reader, clock) so
the same code runs against the mock of §10. Logging goes to stderr (journal) and, optionally,
to `/dev/kmsg` with prefix `shannon-loader:` so that loader lines interleave with kernel lines
(stock does the same with `<3>mif: cbd: ` [P `V1/boot.h:42-71`]).

---

## 4. Q1 — Normal boot sequence (SS333, SPI boot link, LLI main link)

### 4.1 Preflight (no CP power change)

| # | Action | Exact values | Failure → |
|---|---|---|---|
| F1 | Resolve paths (configurable, first existing wins) | boot `/dev/umts_boot0`; holders `/dev/umts_ipc0`, `/dev/umts_rfs0`; image `/dev/disk/by-partlabel/RADIO` (stock used `/dev/mbin0` → by-name/RADIO, `RD/init.baseband.rc:3`, i.e. `mmcblk0p13`, `RE` §1); `lli_control`: `/sys/bus/platform/devices/10f24000.mipi-lli/lli_control`, then `/dev/mipi-lli/lli_control` (3.10 symlink, `RD/init.baseband.rc:6`), then `/sys/devices/10f24000.mipi-lli/lli_control`; `cp_status`: glob `/sys/bus/platform/drivers/mif_sipc5/*mif_pdata*/cp_status/value`, then `.../*mif_sipc5*/cp_status/value`, then `/sys/bus/platform/devices/mif_pdata*/cp_status/value` | exit 5 (ABI missing) |
| F2 | Open image `O_RDONLY\|O_CLOEXEC`, read bytes 0..0x1FF | — | exit 4 |
| F3 | TOC checks | slot names exactly `TOC`,`BOOT`,`MAIN`,`NV` (NUL inside 12 B); TOC.offset = 0; 0x80 ≤ TOC.size ≤ 0x200 (stock 0x200); every offset+size ≤ image size; BOOT.size > 0 and **BOOT.size ≤ 0xFFFB**; MAIN.size > 0; 0 < NV.size ≤ 16 MiB | exit 4 |
| F4 | BOOT CRC32 (zlib) == TOC BOOT.crc when crc ≠ 0 | stock 0x5DB1F04C | exit 4 |
| F5 | NV policy and snapshot (§8) | NV.size bytes into memory | exit 3 |
| F6 | `stat` char devices and sysfs files; read `lli_control` and `cp_status` once and log them | expect `MIPI-LLI 0`/`0` before power-on (not enforced) | exit 5 |
| F7 | Open `/dev/umts_boot0` `O_RDWR\|O_CLOEXEC` (blocking mode; keep this fd for the life of the process) | — | exit 5 |

Notes. [P F3 names: `V1/boot_shannon333.c:147-153`] [I F3 BOOT.size limit: `link_device_spi.c:92-93`
strips exactly 4 header bytes while `sipc5_build_config` switches to a 6-byte header when
`count + 4 > 0xFFFF` (`modem_io_device.c:1706-1723`), so a larger BOOT would reach the BootROM
with 2 extra bytes] [D F4: `cbd` never checks BOOT/MAIN CRC on the AP; the TOC CRCs match the
payload on the stock image, `RE` §3, so a local check catches a corrupt partition before the CP
is powered] [P F7 mode: `V1/std_boot.c:551`; `RE` §2]. `V1` uses a relative path
`dev/mipi-lli/lli_control` that relies on cwd `/` [P `V1/shannon333.h:7`]; the loader uses
absolute paths only. [D]

### 4.2 Boot attempt (CP powered from step B2 on)

Timeouts below equal stock unless marked [D]. "Attempt failure" → §4.5.

| # | Call | Exact arguments / bytes | Expected | Timeout / retry | Evidence |
|---|---|---|---|---|---|
| B1 | `ioctl(boot, 0x6F37, &link)` | `int link = 10` (LLI) | 0 | none | [P `V1/boot_shannon333.c:308-316`; `RE` §6 step 4; `K/.../modem_io_device.c:1286-1308`]. Needed because the per-device TX link survives a failed attempt (stock comment: boot failure may leave it on SPI). |
| B2 | `ioctl(boot, 0x6F19, 0)` | — | 0 | blocks ~1.0 s | GPIO sequence `cp_on 0` 100 ms, `cp_reset 0` 500 ms, `cp_on 1` 100 ms, LLI reset, `cp_reset 1` 300 ms [P `K/.../modem_ctrl_ss333.c:159-209`]; state → OFFLINE |
| B3 | `ioctl(boot, 0x6F22, 0)` | — | 0 | — | state → BOOTING, `cp_boot_done = 0`, pending TX skb queues purged, `ap_status = 1`, completions re-armed [P `modem_ctrl_ss333.c:382-403`, `link_device_memory_main.c:775-801`] |
| B4 | `ioctl(boot, 0x6F28, 0)` | — | 0 | — | ring indices reset, SBD deactivated, `aligned = true`, magic `0x424F4F54` written and read back [P `link_device_bootdump.c:194-222`]. Must run while TX link = LLI (SPI link has no `dload_start` → `-EINVAL`) [P `modem_io_device.c:1175-1181`, `link_device_spi.c:211-256`] |
| B5 | (optional sanity) `ioctl(boot, 0x6F27)` | — | 3 | log only | [D] |
| B6 | `ioctl(boot, 0x6F37, &link)` | `int link = 3` (SPI) | 0 | — | [P `V1/boot_shannon333.c:339-343`; `RE` §6 step 8] |
| B7 | `write(boot, BOOT, BOOT.size)` | bytes `image[BOOT.offset .. +BOOT.size)` (stock 0x200..0x2BFC), **one call** | returns BOOT.size | ≈0.86 s on the wire at 100 kHz; no retry inside the attempt | [P `V1/boot_shannon333.c:240-288`; `RE` §6 step 9]. On 3.10, an SPI failure returns −1/`EINTR` [I §6.1] |
| B8 | poll `cp_status` until value `"1"` | read file, strip whitespace, compare `1` | `1` | stock: 10 reads, 500 ms apart, first read immediate (≤ ~5 s). Loader: deadline 5 s, period 100 ms [D: same deadline, lower latency] | [P `V1/boot_shannon333.c:290-294`, `V1/util.c:802-833`]. Timeout = BootROM did not accept/run BOOT → attempt failure |
| B9 | `ioctl(boot, 0x6F37, &link)` | `int link = 10` | 0 | — | [P `V1/boot_shannon333.c:352-356`] |
| B10 | poll `lli_control` until it starts with `MIPI-LLI 1` | read-only, compare first 10 bytes | `MIPI-LLI 1\n` | stock: 10 reads × 500 ms (missing file counts as a try). Loader: deadline 5 s, period 100 ms [D] | [P `V1/boot_shannon333.c:358-366`, `V1/util.c:730-755`, `K/drivers/misc/mipi-lli/mipi-lli.c:251-259`]. **Never write this file** (§5). |
| B11 | drain stale RX | `poll(boot, POLLIN, 0)` + `read` until empty; log any word | empty | — | [D: rxq is per device and survives a failed attempt while the fd stays open; it is purged only on last close, `modem_io_device.c:1011-1012`] |
| B12 | stage engine | §4.3 | all OK | each response ≤ 30 s | [P `V1/std_boot.c:30,69-147,852-941`] |
| B13 | `ioctl(boot, 0x6F23, 0)` | — | 0 | blocks ≤ 30 s (`MIF_INIT_TIMEOUT`) | completes when the CP's `PHONE_START` doorbell arrives; state → ONLINE; phone_active IRQ enabled [P `modem_ctrl_ss333.c:28,405-429`; `link_ctrlmsg_command.c:119-168`]. On −1/`EAGAIN`: `ioctl(boot, 0x6F47, 0)` (ignore result) → attempt failure |
| B14 | open holders | `open("/dev/umts_ipc0")` and `open("/dev/umts_rfs0")`, `O_RDWR\|O_NONBLOCK\|O_CLOEXEC`, unless already held | both succeed | — | §7; the second open sends `INIT_END` [P `link_device_memory_main.c:656-683`] |
| B15 | `ioctl(boot, 0x6F48, 0)` | — | `-EINVAL` expected, ignored | — | parity with stock [P `V1/std_boot.c:955`]; one kernel line "undefined cmd 0x6F48" is expected |
| B16 | `ioctl(boot, 0x6F24, 0)` | — | 0 | — | releases the boot wake lock [P `modem_ctrl_ss333.c:431-442`] |
| B17 | (optional sanity) `ioctl(boot, 0x6F27)` | — | 4 | log only | [D] |
| B18 | `sd_notify("READY=1")`, enter supervisor | — | — | — | [D] |

Ordering constraints that must not change: B1 before B4 (link must be LLI for `DL_START`);
B4 before B6 (`DL_START` arms the ring); B8 before B9 (stock waits cp_status while still on
SPI); B10 before B12 (writes to the ring succeed even when LLI is down — `xmit_udl` has no mount
check, `link_device_bootdump.c:97-127` — so without B10 the loader would wait 30 s for a CP that
cannot see the ring). [P for stock order; I for the reasons]

### 4.3 Stage engine (B12)

Stage records, processed **in this order, none skipped** [P `V1/boot_shannon333.c:38-100`,
`V1/std_boot.c:852-941`; stage table bytes `RE` §4]:

| rec | stage S | start | download | validate | finish | source fd / offset / size | crc |
|---|---|---|---|---|---|---|---|
| 0 | 0 (BOOT) | 0 | 0 | 1 | 1 | — (already sent over SPI) | — |
| 1 | 1 (TOC) | 1 | 1 | 0 | 1 | image / TOC.offset (0) / TOC.size (0x200) | — |
| 2 | 2 (MAIN) | 1 | 1 | 1 | 1 | image / MAIN.offset / MAIN.size | TOC MAIN.crc |
| 3 | 3 (NV) | 1 | 1 | 0 | 1 | NV snapshot / 0 / TOC NV.size | — |
| 4 | 0xF (FIN) | 1 | 0 | 0 | 0 | — | — |

For each record, in order [P `V1/std_boot.c:866-935`]:

1. **start** (if set): write u32 `0x9000|S<<8`; expect `0xA000|S<<8`.
2. **download** (if set):
   1. `ioctl(boot, 0x6F29, &{size, 0x810, N})`, `N = ceil(size / 2048)`; must return ≥ 0
      [D: `V1` ignores the result (`std_boot.c:265`), `V3` checks it (`ProtocolSipc.cpp:366`)].
   2. for `i = 1..N`: `len_i = min(2048, remaining)`; write `{0x9001|S<<8, N, i, len_i}` +
      `len_i` payload bytes in **one** `write()`, which must return exactly `16 + len_i`
      [P `V1/std_boot.c:185-224,268-282`; kernel returns the payload count, `modem_io_device.c:1414`].
   3. response-only wait (no write): expect `0xA001|S<<8` [P `V1/std_boot.c:284-289`].
3. **CRC** (only if download **and** validate): write 8 bytes `{0x900C|S<<8, crc}`; expect
   `0xA00C|S<<8` [P `V1/std_boot.c:297-326,889-925`]. Only MAIN qualifies; BOOT has validate=1
   but download=0, so no CRC frame is ever sent for BOOT. `crc` is the TOC value, never a
   recomputed one [P `V1/boot_shannon333.c:77`]. The loader computes zlib CRC32 of MAIN while
   streaming and, if it differs from the TOC value, aborts **before** sending the CRC frame [D].
4. **finish** (if set): write `0x900D|S<<8`; expect `0xA00D|S<<8`.

**Request/response primitive** (`req_resp`) [P stock: `V1/std_boot.c:69-147`; D: refinements]:
- write 4 bytes (u32 LE) when there is a request; `write() != 4` → error.
- wait with `poll(boot, POLLIN, remaining)` against a 30 000 ms deadline per expected word.
  - `POLLIN` → `read(boot, buf, 16)`: return 4 → decode; return 0 → poll again (the kernel read
    returns 0 after 100 ms when the queue is empty, `modem_io_device.c:1425-1434`); return > 4 →
    protocol error (log hex) [D: stock reads exactly 4 and would silently leave the rest queued,
    `modem_io_device.c:1449-1451`]; return < 0 → error.
  - `POLLHUP`/`POLLERR` without `POLLIN` → CP crashed during download: `ioctl(0x6F27)`, log state,
    attempt failure [P `modem_io_device.c:1050-1061`: BOOT device returns `POLLHUP` in
    CRASH_EXIT/CRASH_RESET/NV_REBUILDING].
  - deadline → attempt failure ("TIMEOUT stage S step T").

**Response decoding** for an expected word `E = 0xA000|S<<8|T` and a received word `R`
[I: format from §2.2; the CP-side meaning of 0xF is inferred from the constant's name]:
- `R == E` → OK.
- `R & 0xFFFF_FFF0 == 0x0000_A000|S<<8` and `R & 0xF == 0xF` → **CP_STAGE_FAIL(S)**. Log
  `"CP rejected stage S (resp 0x%04X)"`. For S = 2 at the CRC step this is "MAIN rejected"
  (stock reacts with `"secure err: Invalid Main image"` and, on TMB/VZW only, a reboot into secure
  mode — not reproduced) [P `V1/std_boot.c:40-67,914-924`].
- anything else → PROTOCOL_MISMATCH (log expected and received).
Both are attempt failures.

Per-boot counts on the stock image: 17 497 writes on `umts_boot0` in the stage engine (1 + 3 +
16 978 + 514 + 1), 12 response reads, 3 `FW_UPDATE` ioctls; MAIN = 16 975 frames, last frame
len 416. [I: arithmetic from §2.3]

### 4.4 Total time budget [I]

B2 ≈ 1.0 s; B7 ≈ 0.9 s; B8, B10 ≤ 5 s each; stage engine bounded by 12 × 30 s worst case (the
MAIN stream itself depends on CP drain speed, unknown); B13 ≤ 30 s. A healthy boot is expected
to take seconds, not minutes; any single wait reaching its deadline is a failure.

### 4.5 Error handling and retries

| Failure | Stock `cbd` | Loader [D] |
|---|---|---|
| any step of the attempt | logs `ERR! <fn> fail`, returns; `main` sleeps 1 s and retries **forever**, re-running the 5 s NV-property wait each time [P `V1/main.c:1237-1343`, `V1/boot_shannon333.c:483-490`] — matches the ~6 s retry period in `TR-S6` [I] | log; if `STATUS` says CRASH_EXIT, record "crash during boot"; sleep 2 s; restart at B1 (B2 power-cycles the CP). Max 3 attempts per process start, then `IOCTL_MODEM_OFF` and exit 6. |
| `CP_STAGE_FAIL` at MAIN CRC | same as any failure | allow one more attempt; a second rejection → `IOCTL_MODEM_OFF`, exit 7 (image rejected; do not auto-restart) |
| preflight F1–F7 | — | no CP power change; exit 2/3/4/5 |
| `BOOT_OFF` `-EAGAIN` | GET_CP_BOOTLOG then failure | same (GET ignored) |

Exit codes: 0 clean stop, 2 config, 3 NV refused, 4 image/TOC invalid, 5 kernel ABI missing,
6 boot failed after retries, 7 image rejected by CP. systemd: `Restart=on-failure`,
`RestartSec=30`, `RestartPreventExitStatus=2 3 4 5 7`, `StartLimitBurst=3`,
`StartLimitIntervalSec=600`. On `SIGTERM`: close holders, `IOCTL_MODEM_OFF`, exit 0 (stock
`shutdown` callback = `IOCTL_MODEM_OFF` [P `V1/boot_shannon333.c:603-622`]). [D]

Known kernel limitation to carry into the port [P `modem_ctrl_ss333.c:226-230`]: `ss333_off`
returns early when the state is already OFFLINE, so after a failure *between* `MODEM_ON` and
`BOOT_ON` the CP stays powered with reset released. The port should make `modem_off` drive
`cp_reset`/`cp_on` low unconditionally. [I]

### 4.6 Reconciliation of all sources (Q1)

| # | Topic | `RE` (stock binary) | `OLD` | `V1` source | `K` kernel | Decision and why |
|---|---|---|---|---|---|---|
| 1 | Post-SPI wait | call `0xba70("mif_sipc5","mif_pdata","cp_status/value","1",…)`, "undetermined" (§6 step 9, §8-4) | "replaced by nothing" | `wait_gpio_value(...,"1",10)`, 500 ms | `cp_status` GPIO exported as `<dev>/cp_status` (`modem_main.c:506`, `modem_utils.c:1167-1191`) | **Wait** (B8). V1 names the call; arity 5 matches `RE`. |
| 2 | FIN record | rec4 id 0xF, start=1, no payload, no done (§4) | skip it | always sent, `0x9F00→0xAF00` | agnostic | **Send**. Also in `LSI` herolte and `TR-J7` ("OK!! resp 0xAF00"). |
| 3 | Record skipping | §6.1 intro "skip records whose payload flag is 0" vs §4 "rec0 closes stage 0" | bare done for rec0 | every record processed, only the payload step is skipped | — | **Process all records**; `RE` §6.1's intro sentence is a wording error contradicted by its own rec0 analysis. |
| 4 | 0x6F47/0x6F48 | "exist nowhere" (§8-3) | "do not reproduce" | GET on BOOT_OFF failure, CLR on success, results ignored | default case → `-EINVAL` | **Issue as stock, ignore result** (B13/B15); names from `V1/boot.h:116-117`, semantics from Exynos 8895/9810 kernels (`RN/kernel_drivers.md` Q1). |
| 5 | End-of-data ack | poll-only | "least verified" | response-only `req_resp(0, exp)` | — | **Confirmed**: no write before waiting for `0xA001|S<<8`. |
| 6 | Response failure handling | compare only | none | compare only; `STAGE_FAIL` defined but unused | — | **Decode 0xF nibble** (§4.3). |
| 7 | NV missing | `create_empty_nv` 0xFF, size = TOC NV size | same | same, `O_RDWR\|O_CREAT\|O_SYNC`, 0600 | — | **Refuse** (§8). Safety rule overrides stock. |
| 8 | NV open mode | O_RDONLY, then reopen **O_RDWR** (§5 step 4) | O_RDWR | O_RDONLY twice | — | **O_RDONLY** + in-memory snapshot. The fd is only read; the CP cannot tell. |
| 9 | NV shorter than TOC size | (abort on short read) | pad 0xFF | short read → `rcvd != len` → abort | — | **Refuse** before power-on (exact size required). |
| 10 | NV validity gate | waits `ril.cbd.rfs_check_done` 50×100 ms, proceeds on TIMEOUT | skip | same with `vendor.cbd.rfs_check_done` | — | **Replace by a blocking local check** (§8.3); never "timeout and proceed". |
| 11 | `lli_control` | read-only, "MIPI-LLI 1", 10×500 ms | read-only | read-only | show = `"MIPI-LLI %x\n"` of link state (0 unmounted, 1 mounted, 2 wait) | **Read-only**; `BR`'s "write 2 then 3" is wrong (§5). |
| 12 | TX-link default | — | — | first call forces LLI | `iod,tx_link = <10>` (`K/arch/arm/boot/dts/modem-ss333-pdata.dtsi:168-177`) | Keep B1 (state survives failures). |
| 13 | `FW_UPDATE` | one per stage, {size,0x810,frames} | same | same, result ignored | struct copied, never read (`img_info` unused) | **One per stage, check ≥ 0**; resolves U-8 (num_frames = frames of that stage). |
| 14 | Retry | — | — | infinite, 1 s | — | **Bounded** (§4.5). |
| 15 | Paths | `/dev/mbin0`, `/efs/nv_data.bin`, `/dev/mipi-lli/...` | `/sys/devices/10f24000.mipi-lli/...` | `/mnt/vendor/efs/nv_data.bin`, relative `dev/mipi-lli/...` | 6.12 names devices `10f24000.mipi-lli` and `mif_pdata` (`ML/drivers/of/device.c:288-319`) | **Configurable, resolved via `/sys/bus/platform/...`** (F1). For device facts, `RE` wins (`/efs/nv_data.bin`). |
| 16 | Property name | `ril.cbd.rfs_check_done` | — | `vendor.cbd.rfs_check_done` | — | Irrelevant (no property system); `RE` + `STR:27176` show the device used `ril.cbd.*`. |

---

## 5. Q2 — Who mounts the MIPI-LLI link (U-7, resolved)

**Answer: the kernel, automatically and interrupt-driven, initiated by the CP. Userspace does
nothing but observe `lli_control`.** [P chain below; the CP-side trigger is I]

1. `IOCTL_MODEM_ON` → `ss333_on` → `ld->reset` = `lli_link_reset` → `mipi_lli_intr_enable` +
   `mipi_lli_reset` → `exynos_lli_init`: enable all 18 LLI interrupt sources (`0x3FFFF`) and
   soft-reset the block. [P `modem_ctrl_ss333.c:197-198`, `link_device_lli.c:589-594`,
   `mipi-lli.c:217-226`, `exynos-mipi-lli.c:31,246-249,271-280`]
2. IRQ `INTR_SW_RESET_DONE` → `exynos_lli_setting`: state UNMOUNTED (or WAITFORMOUNT), PMU
   `LLI_PHY_CONTROL = 1`, PA/IAL configuration, shared-memory remap, M-PHY init/CMN/OVTM.
   [P `exynos-mipi-lli.c:282-385,911-924`]
3. The AP is **slave**: `is_master = false` at probe and nothing in the kernel changes it.
   [P `exynos-mipi-lli.c:1155`; `set_master` only reachable from the `lli_control` store,
   `mipi-lli.c:284-285`; grep shows no other caller]
4. After the BootROM runs BOOT (received over SPI), the CP side brings its M-PHY out of HIBERN8;
   the AP gets `INTR_MPHY_HIBERN8_EXIT_DONE` and, after 1 ms, writes `LLI_MOUNT_CTRL` into
   `DME_CSA_SYSTEM_SET`. [P handler `exynos-mipi-lli.c:926-932`; that the CP's first stage
   triggers it is I, consistent with B8→B10 ordering in stock and with `MZ`]
5. `INTR_LLI_MOUNT_DONE` → threaded handler waits up to `credit_cnt` = 10 × 1 ms for DL TX
   credits, then sets state `LLI_MOUNTED`, increments `mnt_cnt`, calls the PM `mount_cb`.
   No credits → `"ERR: Mount failed"` and the state stays unmounted.
   [P `exynos-mipi-lli.c:44,834-898,996-1001`]
6. `lli_control` show returns `"MIPI-LLI 1\n"` from then on. [P `mipi-lli.c:251-259`, `exynos-mipi-lli.c:428-432`]
7. The link-PM FSM is **not involved** in the first mount: it is stopped by `ss333_on` (`ld->off`
   → `stop_pm`) and started only by the `PHONE_START` handler (`start_pm`). While inactive, PM
   events just release `AP2CP_WAKEUP`. [P `link_device_lli.c:602-607`,
   `link_ctrlmsg_command.c:130-133`, `link_device_pm.c:375-394,795-844`]

Meizu Pro 5 (same CP on Exynos 7420) confirms the design: identical IRQ mount path
(`SW_RESET_DONE` → setting; `HIBERN8_EXIT_DONE` → `LLI_MOUNT_CTRL`; `is_master = false` at
probe) [P `MZ/drivers/misc/mipi-lli/exynos-mipi-lli.c:747-767,969`]; its in-kernel SPI boot
helper sends BOOT with one `spi_sync`, waits for `cp_status` (100 × 20 ms) and then for
`LLI_MOUNTED` (100 × 20 ms) without issuing any mount command [P
`MZ/drivers/misc/mipi-lli/mipi-lli-boot-spi.c:405-427,465-504`]; and with
`CONFIG_LINK_DEVICE_LLI` its `lli_control` show/store are disabled entirely
[P `MZ/drivers/misc/mipi-lli/mipi-lli.c:256-266`].

Consequences for the port and the loader [I/D]:
- `lli_control` store commands (0 debug, 1 init, 2 set_master, 3 link_startup_mount, 4 exit,
  5 signal test, 6 loopback, 98/99 dumps, `mipi-lli.c:261-311`) are debug-only. Command 2 would
  flip the AP to master and 1/4 would reset/exit the link under a running CP. The port should
  make the attribute read-only (0444) or root-only debug.
- The loader's only LLI duty is B10.
- In `BR` §3.5, `start_pm` was described from the non-FSM branch (`link_device_lli.c:497-511`,
  "pm_enable=0 just takes the wake lock"). This build sets `CONFIG_LINK_POWER_MANAGEMENT_WITH_FSM=y`
  (`K/arch/arm/configs/lineage_gts28ltexx_defconfig:1331`) and `pm_enable` defaults to 1
  (`link_device_lli.c:41`), so `start_pm` is `link_device_lli.c:213-233`: the FSM starts in
  `PM_STATE_CP_BOOTING`, asserting AP2CP_WAKEUP and AP2CP_STATUS. The module parameter
  `pm_enable=0` selects `PM_EVENT_LOCK_ON` (link held up) — a reasonable bring-up setting for the
  port. [P]

---

## 6. Q3 — Transports and what the kernel port must provide

### 6.1 BOOT over SPI (`link_device_spi.c`)

[P unless marked]
- Path: `write(umts_boot0)` with TX link = SPI → `misc_write` builds a SIPC5 header
  (`cfg 0xF8` because the SPI link is never `aligned`, `ch 0xD7`, `len = 4 + count`) →
  `spi_boot_send` (accepts only `IPC_BOOT` devices) → `spi_boot_tx_skb` skips exactly
  `SIPC5_MIN_HEADER_SIZE` (4) bytes → `spi_transmit_data`: **one** `spi_transfer` of the whole
  payload, `tx_buf` only, `delay_usecs = 10`, `spi_sync`. [`modem_io_device.c:1324-1415`;
  `link_device_spi.c:63-131`]
- Device setup: 8 bits per word, `SPI_MODE_0` [`link_device_spi.c:137-138`]; DT child of
  `spi_4: spi@14d00000` (not 0x14d30000), `compatible = "spi_boot_link"`, `reg = <0>`,
  `spi-max-frequency = <100000>`, `samsung,spi-chip-select-mode = <1>` (= hardware auto-CS,
  `K/drivers/spi/spi-s3c64xx.c:1098-1104,602-607`), pins overridden to gpv7-1/gpv7-2/gpv7-4
  with MISO gpv7-3 parked as input [`K/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:154-176`].
- No read-back, no flow control: the **only** acknowledgement is `cp_status` going high (B8).
- Return value: success → `skb->len` → `write()` returns `count`. Failure → `spi_boot_send`
  frees the skb and returns 0 → `misc_write` returns `0 - 4` computed in unsigned arithmetic →
  `-4` → userspace sees `-1`/`errno = EINTR`. [I: `link_device_spi.c:126-130` +
  `modem_io_device.c:1406-1414`, 32-bit `ssize_t`] On success the skb is never freed (leak of
  ~10.7 KiB per boot). [P: no free on the success path of `spi_boot_tx_skb`/`spi_boot_send`]
- `spi_boot_probe` reads `gpio_cp_status` but never uses it. [`link_device_spi.c:160-168`]

### 6.2 Stages over LLI shared memory (`link_device_bootdump.c`, `link_device_memory*.c`)

[P unless marked]
- `write(umts_boot0)` with TX link = LLI → `mem_send`: `IPC_BOOT` + boot channel → `xmit_udl`
  → `udl_write` into `mld->dev[IPC_RAW]` TX circular buffer (`raw_tx_buff`); space check
  (`-EIO` on corrupt indices, `-ENOSPC` when full); on `-ENOSPC` retry 20 × 50 ms (≈1 s) then
  fail; no AP→CP doorbell. [`link_device_memory_main.c:725-767`; `link_device_bootdump.c:21-127`]
  The CP polls the ring head. [I; U-6 is closed: stock sends no doorbell and the CP boots]
- `write()` returns the payload count (frame + header + padding were written atomically or not
  at all), so an `ENOSPC` error means **nothing** of that frame was queued. [I from
  `udl_write` all-or-nothing + `xmit_udl`] The loader treats `ENOSPC` as attempt failure (the CP
  stopped draining for ≥ 1 s). [D]
- CP → AP: the CP writes SIPC5 frames into the legacy RX rings and raises an LLI signal; the
  handler snapshots, `mem_irq_handler` accepts it in BOOTING/ONLINE/CRASH_EXIT, and while not
  ONLINE the RX work runs from a workqueue; `recv_ipc_frames` reads every RX ring, validates
  `cfg` start bits and length (bad frame → `MDM_EVENT_CP_FORCE_CRASH`), demuxes by channel; for
  ch 215 `rx_raw_misc` strips the header (padding is not trimmed) and queues one skb per frame
  on `umts_boot0` — **dropped if `umts_boot0` is not open**. `misc_read` returns one frame per
  call (partial reads push the remainder back). [`link_device_lli.c:640-663`;
  `link_device_memory_main.c:34-56,567-620`; `link_device_memory.c:38-302`;
  `modem_io_device.c:274-284,349-385,1417-1457`]
- Poll: `POLLIN` only in BOOTING/ONLINE with a non-empty queue; `POLLHUP` for the BOOT device in
  CRASH_EXIT/CRASH_RESET/NV_REBUILDING (and when a SIM state change is pending); nothing in
  OFFLINE. [`modem_io_device.c:1025-1087`]

### 6.3 Kernel port checklist (ABI-visible behaviour the loader relies on)

SPI path:
1. SPI4 @0x14d00000 enabled; board pin override (gpv7-1/2/4 SPI function, gpv7-3 input
   pull-down); child device at CS0, mode 0, 8 bpw, 100 kHz. Mainline `spi-s3c64xx` already
   uses hardware auto-CS (`S3C64XX_SPI_QUIRK_CS_AUTO`, NSC_CNT_2) for Exynos 5433
   (`ML/drivers/spi/spi-s3c64xx.c:362-372,1561-1571`), matching 3.10 `AUTO_CS_MODE`. [P]
2. Port `link_device_spi.c`: replace `.delay_usecs` with `.delay = {10, SPI_DELAY_UNIT_USECS}`
   (`ML/include/linux/spi/spi.h:1106`); strip `sipc5_get_hdr_len()` instead of a constant 4 (or
   reject writes > 0xFFFB); return a negative errno on failure; free the skb on success. [D]
3. `IOCTL_MODEM_SET_TX_LINK` per I/O device, `umts_boot0` links = LLI|SPI, default LLI. [P]
4. `cp_status`: keep `<mif_pdata device>/cp_status/value` via `gpiod_export()` +
   `gpiod_export_link()` (still in 6.12, `ML/drivers/gpio/gpiolib-sysfs.c:574,674`; needs
   `CONFIG_GPIO_SYSFS`, which stock had, defconfig:2223). A line requested by the driver cannot
   be read through the GPIO chardev by another process, so libgpiod is not an alternative. [P/I]
   Fallback: a read-only attribute printing `0\n`/`1\n`, path given to the loader by config. [D]

LLI path:
5. MIPI-LLI controller + M-PHY with the IRQ-driven mount of §5; `lli_control` show unchanged
   (`"MIPI-LLI %x\n"`), store removed or root-only. [D]
6. 8 MiB shared region, power-of-two aligned (remap register), programmed into
   `IAL_LL/BE_INIT_ADDR_REMAP`; on 6.12 a `reserved-memory` node mapped non-cacheable
   (stock vmaps with `pgprot_noncached`, `mipi-lli.c:40-60`). [P stock / I port]
7. `DL_START`, `FW_UPDATE`, `BOOT_ON`, `BOOT_OFF` (30 s), `BOOT_DONE`, `STATUS`, `OFF`, `ON`
   semantics exactly as §2.1/§4.2; `0x6F47/0x6F48` may stay `-EINVAL` or read/clear
   `shmem + 0xC00` (0x1FF bytes, u32 length first) as later Exynos kernels do — whether the
   SS333 CP writes a boot log there is unknown. [P later kernels via `RN/kernel_drivers.md` Q1; I]
8. `xmit_udl` framing of §2.4 (cfg 0xFC, ch 0xD7, len16, 4-byte padding), ENOSPC retry, no
   doorbell; RX demux to `umts_boot0` as §6.2; `misc_poll`/`misc_read` semantics unchanged. [D]
9. Control-message handlers `INIT_START` (→ SBD init + `PIF_INIT_DONE`), `PHONE_START`
   (→ IPC map reset, `INIT_END` if `rild_ready`, complete `init_cmpl`), `CRASH_EXIT`,
   `CRASH_RESET`, and the `mem_init_comm` late-`INIT_END` path. [P §7]
10. Recommended hardening (not ABI): `IOCTL_MODEM_CP_UPLOAD` must not `panic()` (return
    `-EPERM`); `modem_off` unconditional (§4.5). [D]

---

## 7. Q4 — Post-download handshake and the `rild_ready` condition

### 7.1 What the kernel does [P]

Doorbell values: AP→CP `cmd2int(c) = c | 0x40 | 0x80`; CP→AP command = `intr & 0x3F` when bit
0x40 is set (`K/.../link_device_memory.h:486-512`).

| CP→AP | Value | Kernel action | Evidence |
|---|---|---|---|
| `INIT_START` | 0xC1 | requires `sbd_ipc` (attr 0x3C9 has SBD_IPC); `init_sbd_link`, `aligned = false` (no IPC_ALIGNED), `sbd_activate`, reply `PIF_INIT_DONE` = **0xCD** | `link_ctrlmsg_command.c:86-116` |
| `PHONE_START` | 0xC8 | `start_pm`; if link already IPC: send `INIT_END` (0xC2) when `rild_ready`, exit; else `mem_reset_ipc_link` (magic 0xAA, access 1, verified), if `rild_ready` send `INIT_END` + `cp_boot_done = 1`, link → IPC, **`complete_all(init_cmpl)`** | `link_ctrlmsg_command.c:119-168` |
| `CRASH_EXIT` | 0xC9 | link → CP_CRASH, notify `MDM_CRASH_CMD_EXIT` → `ss333_force_crash_exit` | `link_ctrlmsg_command.c:185-201`; `modem_ctrl_ss333.c:477-517` |
| `CRASH_RESET` | 0xC7 | link → OFFLINE, notify `MDM_CRASH_CMD_RESET` → same | `link_ctrlmsg_command.c:170-183` |

- `rild_ready` = `umts_ipc0.opened > 0 && umts_rfs0.opened > 0`; nothing else.
  [`link_ctrlmsg_command.c:56-83`]
- `BOOT_OFF` waits on `init_cmpl` only; it returns 0 as soon as `PHONE_START` was handled,
  **whether or not `INIT_END` was sent**. [`modem_ctrl_ss333.c:405-429`]
- Late path: opening the second of `umts_ipc0`/`umts_rfs0` while `cp_boot_done == 0` sends
  `INIT_END` immediately and sets `cp_boot_done = 1` — in this build `__tx_iosm_message()` is a
  real doorbell (`send_ipc_irq(cmd2int(id))`) and `IOSM_A2C_INIT_END` = 0x02 = `CMD_INIT_END`.
  [`link_device_memory_main.c:629-692`; `link_ctrlmsg_command.c:49-53`;
  `link_ctrlmsg_iosm.h:42`; `CONFIG_LINK_CONTROL_MSG_COMMAND=y`, IOSM not set, `BR` §1.1]
- `cp_boot_done` is reset by `BOOT_ON` and when the **last** fd of `umts_boot0` is closed.
  [`link_device_memory_main.c:780,711-712`]
- The CP repeats `PHONE_START` until it receives `INIT_END`. [P: kernel comment
  `link_ctrlmsg_command.c:138-141`; CP behaviour itself I]
- An AP→CP doorbell while LLI is not mounted only logs `"LLI not mounted !!"` (no register
  write) but still toggles `gpio_ipc_int2cp`. [`exynos-mipi-lli.c:434-443`;
  `link_device_lli.c:45-67`]

### 7.2 Policy for the loader and the future telephony daemon [D]

1. **Never** open `umts_ipc0`/`umts_rfs0` for the first time between `DL_START` (B4) and the
   return of `BOOT_OFF` (B13): an `INIT_END` doorbell would reach a CP that is still in its
   download stages (LLI mounted). Also avoid opening them before B2 on a cold kernel (the
   `INIT_END` attempt would toggle `ipc_int2cp` towards an unpowered CP). [I: risks; CP effect unknown]
2. The loader opens both, `O_RDWR|O_NONBLOCK|O_CLOEXEC`, right after `BOOT_OFF` returns 0
   (B14). The second open sends `INIT_END` through the late path. It keeps them open for its
   whole life and **never reads them**; holding an fd does not consume data (readers dequeue a
   shared per-device queue; `modem_io_device.c:163-186,1417-1457`), and an unread queue is capped
   at 2048 skbs then drops (`MAX_IOD_RXQ_LEN`, no crash). [P mechanics; D policy]
3. On a later CP restart the held fds make `rild_ready` true, so the `PHONE_START` handler
   itself sends `INIT_END` (the path the kernel was designed for). [P/I]
4. The loader keeps `umts_boot0` open permanently (supervisor fd), so `cp_boot_done` is not reset
   behind its back. [P/D]
5. The telephony daemon must start **after** the loader is READY (`After=` +
   `Type=notify`), opens its own fds to `umts_ipc0`/`umts_rfs0`, and is the only reader. If the
   loader restarts, its holder fds are re-opened after the next `BOOT_OFF`. [D]
6. Expected checkpoints: first boot of a loader process → `lli: umts_rfs0->INIT_END->ss333`
   from the late path (`link_device_memory_main.c:675-676`); CP restart with holders held →
   `umts_ipc0.opened=1, umts_rfs0.opened=1` then `INIT_END -> ss333` from the `PHONE_START`
   handler. In both cases no periodic `CP_START <-` repeats afterwards; repeats mean `INIT_END`
   is not reaching the CP. [P strings `link_ctrlmsg_command.c:77-78,126,144,157`]
7. Without an RFS server, CP file/NV requests on `umts_rfs0` stay unanswered. Whether the CP
   tolerates that for long is **unknown**; reaching ONLINE does not depend on it. [I]

---

## 8. Q5 — NV safety

### 8.1 What stock does [P]

- `cbd`: opens `/efs/nv_data.bin` read-only; on `ENOENT` it **creates** a 0xFF-filled file of
  TOC NV size (`O_RDWR|O_CREAT|O_SYNC`, 0600, `fsync`) and boots with it; other errors abort;
  stage 3 streams TOC-NV-size bytes from offset 0, a short file aborts the boot.
  [`V1/boot_shannon333.c:160-190`, `V1/util.c:497-540`, `V1/std_boot.c:195-205`; `RE` §5]
- The "NV validity check" gate: `cbd` polls property `ril.cbd.rfs_check_done` 50 × 100 ms and
  proceeds even on timeout ("NV validation TIMEOUT", seen in `TR-S6`).
  [`V1/boot_shannon333.c:483-490`; `RE` §6 steps 1-2]. The property is set by `libsec-ril`
  after its `Nv::CheckNvDataValidity`: MD5 check (`nv_data.bin.md5`, checksum state file
  `.nv_state`), restore from `.nv_data.bak` or the core backup `.nv_core.bak`, an internal
  header checksum (`ReadHeader`, `Item Count`, `Checksum Offset`, `CompareCheckSum`), and as last
  resort **creation of default NV** ("No valid backup data. Create default Nv data.", "default
  (0xff) values"). [P `STR:26889-27100,27176`; behaviour from strings only, never executed]
- So the gate is not a check by `cbd`; it is synchronisation with RIL's read-**write** NV repair
  routine.

### 8.2 Loader rules (hard) [D]

1. The loader never opens any EFS path with `O_WRONLY`, `O_RDWR`, `O_CREAT` or `O_TRUNC`; NV
   is opened `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`. No code path creates, truncates, pads, renames,
   restores or deletes NV, its `.md5`, or its backups.
2. Missing NV (`ENOENT`) → exit 3 ("NV missing — refusing to create one"). Any other open error
   → exit 3.
3. The NV source must be a regular file whose size equals the TOC NV size exactly (0x100000).
   Shorter, longer (e.g. an XMM-era 2 MiB file) → exit 3.
4. Content sanity on the snapshot: all bytes 0xFF (a blank created by `create_empty_nv` or by
   RIL's default) or all 0x00 → exit 3 unless `--allow-blank-nv` (explicit, logged loudly).
5. The whole NV is read once into memory before B2; hashes are computed on that buffer and stage
   3 streams **from the buffer** (what was checked is what is sent; no TOCTOU).
6. Writes back to EFS are out of scope for the loader. Any future RFS server serves a sandbox
   copy (e.g. `/var/lib/shannon/rfs-root/`) and never writes the real EFS automatically.

### 8.3 NV source modes and the replacement of the property gate [D]

- **Mode A, verified copy (default for bring-up).** Provisioning (manual, once, offline): mount
  the EFS partition read-only, copy `nv_data.bin` (and `nv_data.bin.md5` if present) to
  `/var/lib/shannon/nv/`, root:root 0400, and record their SHA-256 in
  `/var/lib/shannon/nv/manifest`. Before each boot the loader recomputes SHA-256 of the copy
  and refuses on mismatch (exit 3). The real EFS need not be mounted at all.
- **Mode B, direct read-only.** NV is read from the mounted EFS only if `statvfs()` reports
  `ST_RDONLY` for its filesystem; a read-write mount → exit 3 unless `--allow-rw-efs`.
- **MD5 advisory check** (both modes): if `nv_data.bin.md5` exists (32 hex chars), compare it
  with MD5(nv) and with MD5(nv ‖ `"Samsung_Android_RIL"`) (the XMM-era salt implemented by
  `LSI/samsung-ipc/rfs.c:37-83`, read-only function); log which matches. Policy
  `--nv-md5={warn,require,off}`, default `warn`, because the Shannon scheme is unverified (the
  salt is XMM-era; `STR` shows an extra state file and an internal checksum). [I]
- **Replacement of `rfs_check_done`:** the checks above, run synchronously in preflight (F5),
  with failure = refuse. There is no "timeout and proceed". RIL's *repair* actions (restore from
  backup, create default) are deliberately not replicated; repairing NV is a manual, offline
  procedure from raw backups.

### 8.4 Before any hardware run [D]

Raw backups (with SHA-256, kept off-device) of EFS, m9kefs1-3, PARAM and RADIO; EFS not mounted
read-write on the tablet; no RFS server running; Mode A. (`RN/cp_boot_firmware.md` Q6 reaches
the same rules.)

---

## 9. Q6 — Crash handling and restart

### 9.1 How a crash becomes visible [P]

- ONLINE: `phone_active` rising edge → `cp_active_handler` → state CRASH_EXIT (both `umts_ipc0`
  and `umts_boot0` notified, waiters woken) → `POLLHUP` on `umts_boot0` and `umts_ipc0`.
  [`modem_ctrl_ss333.c:45-98`; `modem_io_device.c:925-950,1050-1061`]
- `CMD_CRASH_EXIT`/`CMD_CRASH_RESET` doorbells and kernel-detected errors (bad RX frame, PM
  failure…) → `ss333_force_crash_exit`: arms a 10 s timer, stops the link, raises
  `ap_dump_int`; the CP then raises `phone_active` (→ CRASH_EXIT), or the timer expires and sets
  CRASH_EXIT itself. [`modem_ctrl_ss333.c:290-336,477-517`; `modem_prj.h:111`]
- During BOOTING the `phone_active` IRQ is disabled (enabled by `BOOT_OFF`), so a crash in the
  download phase surfaces via the 10 s timer or as a stage timeout. [`modem_ctrl_ss333.c:165,418`]
- `STATE_CRASH_RESET` is never set on this kernel: its only setter is the
  `MDM_EVENT_CP_FORCE_RESET` case and nothing raises that event (grep over `K/drivers`,
  `K/include`). [P]
- `IOCTL_MODEM_STATUS` consumes a pending SIM change (returns 7/8 once) and converts
  NV_REBUILDING into ONLINE; a pending SIM change also makes `umts_boot0` report `POLLHUP`.
  [`modem_io_device.c:1145-1165,1040-1061`]

### 9.2 Stock behaviour [P `V1/main.c:658-835`]

Status loop: `poll(umts_boot0, POLLHUP, -1)`, then `IOCTL_MODEM_STATUS`:
- CRASH_RESET: sleep 3 s, `IOCTL_MODEM_OFF`, sleep 27 s, re-boot.
- CRASH_EXIT (and V1's WATCHDOG): low debug level → sleep 3 s, re-boot (the next normal boot's
  `MODEM_ON` power-cycles the CP); otherwise RAM dump (below) then `CP_UPLOAD` → AP panic.
- other values: "unknown Modem status", continue.
- `RD/init.rilchip.rc:14`: rild `onrestart restart cpboot-daemon`.

### 9.3 Supervisor specification [D]

1. Block in `poll(umts_boot0, POLLIN|POLLHUP, -1)` (`POLLHUP` is always reported).
2. On `POLLHUP`/`POLLERR`: `s = ioctl(boot, 0x6F27)`:
   - 7, 8 (SIM change consumed) or 5 → log, continue;
   - 3, 4 → spurious, sleep 100 ms (avoid a busy loop), continue;
   - 2 (CRASH_EXIT), 1 (CRASH_RESET, unreachable), 0 (OFFLINE, e.g. CP lost power) → **silent
     reset**: `sd_notify("STATUS=CP crashed, restarting")`; sleep 3 s (lets the telephony daemon
     see its own `POLLHUP` and drop state); `IOCTL_MODEM_OFF`; run the boot attempt of §4.2 from
     B1 (holders stay open, so `INIT_END` is sent by the `PHONE_START` handler).
3. Rate limit: at most 5 silent resets in 30 min; beyond → `IOCTL_MODEM_OFF`, exit 6.
4. Silent reset = `IOCTL_MODEM_OFF` + normal boot. **`IOCTL_MODEM_DUMP_RESET` is not used for
   it**: `ss333_dump_reset` sets CRASH_EXIT, pulses `cp_reset` only (no `cp_on` cycle) and
   re-initialises LLI so that a DUMP-mode boot can follow (`modem_ctrl_ss333.c:338-380`); the
   subsequent `MODEM_ON` of a normal boot makes it redundant.
5. **Never** `IOCTL_MODEM_CP_UPLOAD` (copies 512 B then `panic()`, `modem_io_device.c:1243-1256`).
   `FORCE_CRASH_EXIT` is not used either.
6. A crash during boot is an attempt failure (§4.5), not a supervisor event.

### 9.4 Optional RAM dump (opt-in tool, not in the default loader) [P sequence `V1/boot_shannon333.c:393-444,517-601`, `V1/std_boot.c:332-533,1101-1205`]

`SET_TX_LINK(10)` → `BOOT_ON` → `DUMP_RESET` → `DUMP_START` (`mem_start_upload`: SBD off, ring
reset, `aligned` from DUMP_ALIGNED, magic `0x44554D50`) → `SET_TX_LINK(3)` → BOOT resent over
SPI + `cp_status` wait → `SET_TX_LINK(10)` → on `/dev/umts_ramdump0`: `0x9D00 → 0xAD00`; read
`{dump_size, num_steps, reason_len}` (12 B) then the reason string; for each step k = 1..n write
`0x9D00|k` (no ack) and read 2064-B frames whose `cmd == 0xAD00|k` and `curr_frame` runs 1, 2, …;
check total == `dump_size`; `0x9D0D → 0xAD0D`. Then **`IOCTL_MODEM_OFF` + normal boot instead of
`CP_UPLOAD`**. A dump is CP RAM and may contain personal data (subscriber identity, messages):
root-only storage, never leaves the device. [D]

---

## 10. Q7 — Offline test plan

### 10.1 Test architecture [D]

- **Level 1, in-process unit tests** (portable, also on macOS): the loader's device layer is a
  table of operations (open/ioctl/read/write/poll on the boot device, open of holders, sysfs read,
  monotonic clock, sleep). Tests inject a C mock implementing §10.2 and a virtual clock, so 30 s
  timeouts run instantly.
- **Level 2, black-box on a Linux PC**: a CUSE character device emulates `/dev/umts_boot0`
  with the real ioctl numbers (CUSE must request unrestricted ioctls because `SET_TX_LINK` and
  `FW_UPDATE` are `_IO` commands with pointer arguments; supported in 6.12,
  `ML/fs/fuse/cuse.c:66,162,344`) plus two dummy CUSE nodes for `umts_ipc0`/`umts_rfs0`;
  `lli_control` and `cp_status` are plain files in a temp dir rewritten by the mock; the image is a
  regular file; the unmodified loader binary runs with paths from its config.
- **Level 3, kernel-port tests**: feed the §10.4 ring vectors to the ported `xmit_udl`/RX demux
  (KUnit or a userspace harness).
- **Safety tripwires** in every level: the mock aborts the test on `0x6F35` (CP_UPLOAD),
  `0x6F34`, `0x6F32`, `0x6F36` in normal mode, and on any write to `lli_control`; an `open()`
  interposer (LD_PRELOAD) fails the test if any NV/EFS path is opened with write/create flags; the
  NV fixture is chmod 0444 on a read-only bind mount.

### 10.2 Mock of `/dev/umts_boot0` (state machine) [D, behaviour mirrors §6 and §7]

State: `power ∈ {off, on}`, `kstate ∈ {OFFLINE, BOOTING, ONLINE, CRASH_EXIT}`, `txlink ∈ {3,10}`
(initial 10), `armed` (DL_START done), `spi_ok`, `cp_status`, `lli`, `expect` (cursor into the
golden transcript §10.3), `rxq` (FIFO of 4-byte words), `fw_info`, holder open counts.

| Input | Mock behaviour |
|---|---|
| `SET_TX_LINK(&n)` | n ∈ {3,10} → store, 0; else `-ENODEV` |
| `MODEM_ON` | reset everything; `kstate = OFFLINE`; `cp_status = "0"`, `lli_control = "MIPI-LLI 0"`; consume 1.0 s virtual time; 0 |
| `BOOT_ON` | `kstate = BOOTING`; 0 |
| `DL_START` | `txlink != 10` → `-EINVAL`; else `armed = 1`, 0 |
| `write` with `txlink == 3` | must be one write of exactly the BOOT bytes and `armed` (else record violation); returns count; schedule `cp_status = "1"` after 300 ms, `lli_control = "MIPI-LLI 1"` after 800 ms (configurable) |
| `FW_UPDATE(&info)` | `txlink != 10` → `-EINVAL`; check `{size, 0x810, ceil(size/2048)}` against the stage; 0 |
| `write` with `txlink == 10` | parse as std_udl request/frame/CRC; compare with the transcript; enqueue the scripted response; return count; a write before LLI is "mounted" is accepted but answered never (like the real ring) |
| `read(buf, n)` | queue empty → 0 after 100 ms virtual; else copy one word (4 B), return 4 |
| `poll` | `kstate ∈ {BOOTING, ONLINE}` and queue non-empty → `POLLIN`; `kstate == CRASH_EXIT` → `POLLHUP`; else wait |
| `BOOT_OFF` | if FIN was acknowledged → schedule PHONE_START after 200 ms, record `rild_ready` (holder counts) at that moment, `kstate = ONLINE`, 0; else after 30 s → `-EAGAIN` |
| open of 2nd holder | record "late INIT_END" with the current phase; flag a violation if phase ∈ [DL_START, BOOT_OFF) |
| `0x6F47`, `0x6F48` | `-EINVAL` |
| `BOOT_DONE` | 0 |
| `STATUS` | return `kstate` (and the scripted SIM/NV one-shot values) |
| `MODEM_OFF` | `kstate = OFFLINE`, power off |
| forbidden ioctls | abort the test |

### 10.3 Golden transcript (stock image geometry) [P values from §2.3/§4.3; I arithmetic]

AP word = what the loader writes; CP word = what the mock answers. All words u32 LE.

| # | Phase | AP → | CP → | Notes |
|---|---|---|---|---|
| 1 | BOOT done | `0x0000900D` | `0x0000A00D` | rec0: no start, no payload |
| 2 | TOC start | `0x00009100` | `0x0000A100` | |
| 3 | TOC info | ioctl `FW_UPDATE {0x00000200, 0x00000810, 0x00000001}` | — | |
| 4 | TOC frame | hdr `{0x00009101, 1, 1, 0x200}` + image[0..0x1FF] (528 B) | — | |
| 5 | TOC ack | — | `0x0000A101` | response-only |
| 6 | TOC done | `0x0000910D` | `0x0000A10D` | |
| 7 | MAIN start | `0x00009200` | `0x0000A200` | |
| 8 | MAIN info | `FW_UPDATE {0x021271A0, 0x810, 0x424F}` | — | 16 975 frames |
| 9 | MAIN frames | `{0x9201, 0x424F, i, 0x800}` i = 1..16 974; last `{0x9201, 0x424F, 0x424F, 0x1A0}` | — | last write = 432 B |
| 10 | MAIN ack | — | `0x0000A201` | |
| 11 | MAIN CRC | `{0x0000920C, 0x1E71169C}` (8 B) | `0x0000A20C` | failure case: `0x0000A20F` |
| 12 | MAIN done | `0x0000920D` | `0x0000A20D` | |
| 13 | NV start | `0x00009300` | `0x0000A300` | |
| 14 | NV info | `FW_UPDATE {0x00100000, 0x810, 0x200}` | — | 512 frames |
| 15 | NV frames | `{0x9301, 0x200, i, 0x800}` i = 1..512 | — | from the snapshot |
| 16 | NV ack | — | `0x0000A301` | |
| 17 | NV done | `0x0000930D` | `0x0000A30D` | |
| 18 | FIN | `0x00009F00` | `0x0000AF00` | |
| 19 | BOOT_OFF | ioctl 0x6F23 → 0 | (PHONE_START) | then holders open |

Byte vectors:
- req `0x900D`: `0D 90 00 00`; FIN: `00 9F 00 00`.
- TOC frame header: `01 91 00 00 01 00 00 00 01 00 00 00 00 02 00 00`.
- MAIN first header: `01 92 00 00 4F 42 00 00 01 00 00 00 00 08 00 00`.
- MAIN last header: `01 92 00 00 4F 42 00 00 4F 42 00 00 A0 01 00 00`.
- NV last header: `01 93 00 00 00 02 00 00 00 02 00 00 00 08 00 00`.
- CRC frame: `0C 92 00 00 9C 16 71 1E`.
- FW_UPDATE MAIN struct: `A0 71 12 02 10 08 00 00 4F 42 00 00`; TOC: `00 02 00 00 10 08 00 00
  01 00 00 00`; NV: `00 00 10 00 10 08 00 00 00 02 00 00`.

Fixtures: (a) the real `dumps/radio.img` (firmware, not personal data; local only, never
committed to a public repository) gives exact CRCs; (b) a synthetic image generator (reusing
`research/modem/radio_toc.py` for the TOC layout) with small sizes, e.g. BOOT 0x100,
MAIN 5001 B (3 frames, last 905 B → exercises ring padding), NV 0x1800; (c) a synthetic NV of
TOC size filled with a PRNG pattern (never a real NV).

### 10.4 Kernel ring vectors (for the port) [P framing §2.4; I values]

| Loader write | Ring bytes (header) | len field | padding |
|---|---|---|---|
| 4-byte request | `FC D7 08 00` + word | 8 | 0 |
| CRC frame (8 B) | `FC D7 0C 00` + 8 B | 12 | 0 |
| full frame (2064 B) | `FC D7 14 08` + 2064 B | 2068 | 0 |
| TOC frame (528 B) | `FC D7 14 02` + 528 B | 532 | 0 |
| last MAIN frame (432 B) | `FC D7 B4 01` + 432 B | 436 | 0 |
| synthetic last frame 16+905 = 921 B | `FC D7 9D 03` + 921 B | 925 | 3 bytes (total 928) |
| BOOT over SPI (10 748 B) | skb `F8 D7 00 2A` + BOOT; **SPI wire carries BOOT only** | 0x2A00 | — |

CP responses expected in an RX ring: `xx D7 08 00` + word (`xx` with start bits `0xF8` set).

### 10.5 Fault-injection matrix (each must give the stated loader result)

| Injected fault | Expected loader behaviour |
|---|---|
| TOC slot name wrong / truncated read | exit 4, no ioctl issued |
| BOOT.size = 0xFFFC | exit 4 (SPI header limit) |
| BOOT or MAIN CRC32 ≠ TOC | exit 4 (BOOT, preflight) / abort before CRC frame (MAIN) |
| NV missing / size ≠ TOC / all 0xFF / SHA-256 mismatch / rw mount in mode B | exit 3, no ioctl issued, no file created |
| `DL_START` → `-EFAULT` | attempt failure, retries, then exit 6 |
| SPI write → −1/`EINTR` | attempt failure |
| `cp_status` never 1 | attempt failure after 5 s |
| LLI never mounted | attempt failure after 5 s; no std_udl word written |
| no answer to any word | timeout 30 s (virtual), attempt failure |
| wrong answer (`0xA100` for `0xA200`) | PROTOCOL_MISMATCH |
| `0xA20F` at CRC (once / twice) | retry / exit 7 |
| read returns 8 bytes | protocol error |
| `POLLHUP` mid-MAIN with STATUS 2 | "crash during boot", attempt failure |
| write → `-ENOSPC` | attempt failure |
| `BOOT_OFF` → `-EAGAIN` | GET_CP_BOOTLOG issued, attempt failure |
| holders opened by a test "daemon" during download | mock flags violation; loader must never do it |
| supervisor: STATUS 7, then 2 | ignore SIM event; silent reset (OFF + boot) |
| 6 crashes in 30 min | `MODEM_OFF`, exit 6 |
| `SIGTERM` while ONLINE | holders closed, `MODEM_OFF`, exit 0 |

### 10.6 First hardware run: ordered checkpoints [D procedure; kernel strings P from `K/`]

Prerequisites: §8.4 backups done; loader in NV Mode A; no telephony daemon; serial or SSH
console; the loader's `--stop-after={preflight,power,spi,lli,stage0,toc,main,nv,fin,online}`
ladder run one rung at a time (each rung ends with `IOCTL_MODEM_OFF`). Kernel messages below are
the 3.10 texts (printed with the `mif: <function>: ` prefix); the 6.12 port should keep them.

| # | Watch | Expected | Stop if |
|---|---|---|---|
| 0 | `ls -l /dev/umts_boot0 /dev/umts_ipc0 /dev/umts_rfs0`; `lli_control`; `cp_status/value` | char devices; `MIPI-LLI 0`; `0` | any missing |
| 1 | open | `umts_boot0 (opened 1) by shannon-loader` (`modem_io_device.c:999-1000`) | — |
| 2 | B1 | `IOCTL_MODEM_SET_TX_LINK`, `cur link: 10, new link: 10` (`:1287-1292`) | error |
| 3 | B2 | `ss333: ss333_on: +++`, MC state lines, then from the LLI device `SW_RESET_DONE ++` (`exynos-mipi-lli.c:912`), `ss333_on: ---` ≈1 s later | no SW_RESET_DONE (LLI clocks/PMU/IRQ) |
| 4 | B3 | `ss333->state changed (OFFLINE -> BOOTING)` | — |
| 5 | B4 | `lli: magic == 0x424F4F54` (`link_device_bootdump.c:218`) | `ERR! magic` (shared memory mapping) |
| 6 | B6/B7 | `change link: 10 -> 3`; no `spi_sync() fail` | SPI error |
| 7 | B8 | `cp_status/value` = 1 within 5 s | stays 0 → SPI pins/mode/speed/CS, or BOOT rejected |
| 8 | B9/B10 | `HIBERN8_EXIT_DONE: rx=…, tx=…`, `Mount intr`, `Mount (ok:1 fail:0 roe:0 pa_err:0)` (`exynos-mipi-lli.c:927,998,891`); `lli_control` = `MIPI-LLI 1` | `ERR: Mount failed`, `Error sent`, `PA_REASON` |
| 9 | stage 0 | loader logs `0x900D → 0xA00D` | timeout = CP not reading the ring (remap address / memory window) |
| 10 | TOC, MAIN, NV | 3 × `IOCTL_MODEM_FW_UPDATE`; no `NOSPC in … TXQ`, `BAD CFG`, `No IOD for CH` | any of those |
| 11 | CRC | `0xA20C` | `0xA20F` (image rejected) |
| 12 | FIN | `0xAF00` | — |
| 13 | after FIN | `INIT_START <- ss333 (ss333.state:BOOTING cp_boot_done:0)`, `PIF_INIT_DONE -> ss333` (`link_ctrlmsg_command.c:92-115`) | missing → CP did not start MAIN |
| 14 | B13 | `CP_START <- ss333 …`, `umts_ipc0.opened=0, umts_rfs0.opened=0` (first boot: holders not open yet, so no INIT_END here), PM FSM start lines, `ss333->state changed (BOOTING -> ONLINE)`; `BOOT_OFF` returns 0 | `T-I-M-E-O-U-T` |
| 15 | B14 | `umts_rfs0->INIT_END->ss333` (late path, `link_device_memory_main.c:675-676`) | missing → `INIT_END` not sent (`cp_boot_done` was already 1); compare with row 14 |
| 16 | B15/B16 | `umts_boot0: ERR! undefined cmd 0x6F48` (harmless), `ss333->wake_lock unlocked` | — |
| 17 | steady | `IOCTL_MODEM_STATUS` = 4; no repeated `CP_START <-`; no `CRASH_EXIT` within 10 min | repeats or crash |

---

## 11. Q8 — Reuse from libsamsung-ipc vs written fresh

| Item | Source | Reuse? | Notes |
|---|---|---|---|
| TOC entry struct + name lookup | `LSI/samsung-ipc/partitions/toc/toc.{c,h}` | yes (trivial) | 512-byte TOC, `{name[12], offset, loadaddr, size, crc, entryid}` |
| NV MD5 computation / compare | `LSI/samsung-ipc/rfs.c:37-83` (`ipc_nv_data_md5_calculate`), `:207-287` (`ipc_nv_data_check`) | yes, read-only helpers only | parameterise size 0x100000 (herolte uses XMM626 specs, 2 MiB). **Never** call `ipc_nv_data_backup`, `ipc_nv_data_restore`, `ipc_nv_data_write` (`rfs.c:374-461,462-548,633-720`: unlink + rewrite EFS files) |
| Robust read/write helpers | `LSI/samsung-ipc/utils.c` (`data_read`, `data_write`) | optional | |
| FIN / BOOT-done handshake | `LSI/samsung-ipc/devices/herolte/herolte.c:304-363` | as corroboration only | herolte (Exynos 8890 integrated) uploads with `XMIT_BOOT` + `SECURITY_REQ`; no SPI, no stages, no CRC, blocking reads without poll — **not** an SS333 loader |
| FMT/RFS client over modem_v1 misc nodes | `LSI/samsung-ipc/modems/xmm626/xmm626_kernel_smdk4412.c` (`fmt_send/recv`, `rfs_send/recv`, `status_online_wait`), `LSI/include/rfs.h` | for the future telephony daemon | same misc-node semantics; SIPC5 vs XMM framing details to verify |
| SS333 sequence (SET_TX_LINK, SPI write, cp_status, LLI wait, 5-record stage engine, CRC, fail-nibble decoding) | — | **write fresh** | from this specification; `V1` only as behavioural reference, no code copied |
| Supervisor, NV policy, sysfs discovery, sd_notify, exit codes | — | write fresh | |
| Mock (C state machine + CUSE) and fixtures | — | write fresh | |

Licensing: anything linked from `LSI` makes the loader GPL-2.0-or-later (or GPLv3) territory;
`V3` is Apache-2.0 (compatible with GPLv3, not with GPLv2-only); `V1` has no licence and must
not be copied. Recommended: write the loader fresh under GPL-2.0-or-later and, if useful,
link `LSI` only for MD5/TOC helpers. [P licences: file headers / `RN/cp_boot_firmware.md` "Licence
caveat"; D recommendation]

---

## 12. Corrections to earlier project documents

| Document | Statement | Correction | Evidence |
|---|---|---|---|
| `OLD` step 2 / risk note | create 0xFF NV if missing; pad a short NV | refuse | §8 |
| `OLD` step 9 | post-SPI call "replaced by nothing" | wait `cp_status = 1` (≤ 5 s) before switching back to LLI | §4.2 B8 |
| `OLD` §risk "record 4… skip it" | FIN optional | FIN mandatory | §4.3 |
| `OLD` step 13 | 0x6F47/0x6F48 unknown | GET/CLR_CP_BOOTLOG, harmless `-EINVAL` | §4.6 #4 |
| `OLD` prerequisites | `/sys/devices/10f24000.mipi-lli/lli_control` | 6.12 path under `/sys/bus/platform/devices/10f24000.mipi-lli/` | `ML/drivers/of/device.c:288-319` |
| `RE` §6.1 intro | records with payload flag 0 are skipped | all five records processed; only the payload step is skipped | `V1/std_boot.c:866-935` |
| `RE` §8-2, §8-4, §8-7 | `fn3`, `0xba70`, `get_device_path` undetermined | `shutdown` (= `MODEM_OFF`), `wait_gpio_value`, `/sys/bus/platform/drivers/mif_sipc5/<first entry containing mif_sipc5 or mif_pdata>/` | `V1/boot_shannon333.c:603-622`, `V1/util.c:757-833` |
| `BR` §1.5 | boot SPI at `spi_4@14d30000`, "inactive" | SPI4 @0x14d00000, carries BOOT via `SET_TX_LINK(3)` | `K/.../exynos5433-modem-ss333.dtsi:154`; §6.1 |
| `BR` §3.2 step 4, §3.6 step 3 | userspace must write `2` then `3` to `lli_control` | never; IRQ-driven, AP slave | §5 |
| `BR` §3.5 | `start_pm` = non-FSM path, `pm_enable=0` | FSM path, `pm_enable` default 1 | §5 last bullet |
| `BR` §3.5 order, `RN/cp_boot_firmware.md` Q2 | `BOOT_OFF` needs rild's opens | `BOOT_OFF` needs only `PHONE_START`; opens only gate `INIT_END` | §7 |
| `BR` §4 | NV reaches the CP via RFS, not the boot image | NV is streamed whole in stage 3; RFS is the runtime path | `V1/boot_shannon333.c:79-88` |
| `BR` §5.1 | STD_UDL "not used on this board's BOOT path" | used end to end; the kernel is just agnostic to it | §4.3, §6.2 |
| `BR` §3.6 step 7, U-2/U-8 | chunk = mtu, `num_frames` semantics open | MSS 2048 payload + 16-B header, MTU 0x810, one `FW_UPDATE` per stage | §2.2 |

---

## 13. What remains unknown

1. CP-side semantics of the 0xF fail nibble (which conditions, which stages) — inferred only.
2. How long the CP tolerates a missing `INIT_END` and unanswered RFS requests; whether it needs an
   RFS server to stay ONLINE.
3. Effect on the SS333 of the `ipc_int2cp` GPIO toggle / early `INIT_END` when it happens before
   power-on or during the download (avoided by policy, not characterised).
4. Whether the SS333 CP writes a boot log at shared-memory offset 0xC00 (`GET_CP_BOOTLOG`).
5. The exact Shannon `nv_data.bin.md5` scheme and RIL's internal NV header checksum format.
6. CP drain throughput over LLI, hence the real duration of the MAIN stage.
7. BootROM tolerance to SPI clocks above 100 kHz or to CS toggling inside the transfer.
8. The CP-visible address window for the 8 MiB region on the 6.12 port (3.10 allocated it
   "anywhere" with memblock).
9. Effect of `IOCTL_MODEM_OFF` without a graceful IPC power-off (possible loss of pending NV
   writes on the CP side).
