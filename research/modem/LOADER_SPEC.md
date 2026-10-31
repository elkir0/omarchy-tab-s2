# `shannon-loader` — Specification (superseded)

> **SUPERSEDED (2026-10-30).** This first specification is replaced by
> `research/analysis/loader_spec_v2.md` and by `research/SYNTHESIS.md` (§2.6-§2.8 for the
> sequence, §4 D4 for the loader design, §5 for the safety rules). Do not implement from this
> file. The statements that would be dangerous if followed (NV creation and padding, skipping the
> FIN stage, the missing `cp_status` wait, writing `lli_control`, the SPI4 address, unpinned BOOT
> bytes) were corrected in place on 2026-10-30; each corrected spot says so.

A minimal userspace loader that boots the SS333 (Shannon) CP from Linux, derived
from the static analysis in `CBD_RE.md` (corrected later by `loader_spec_v2.md`, which used
Samsung's public cbd v1 source and the CP-side analysis of BOOT, `radio_image.md`).

Goal: replace `cbd` on a non-Android Linux system. The loader performs **only** the
normal-boot path; ramdump capture and CP debug extraction are out of scope.

## Verdict on stock `cbd` on Arch Linux

Running the stock ARM32 `cbd` unmodified is **not realistic**: it is statically linked
against bionic and reaches into Android at every layer — bionic property area
(`property_get("ril.cbd.rfs_check_done")`, CBD_RE.md §6 step 1; the wait only costs a
5 s timeout but property support itself must exist), the Android logger
(`__android_log_print`, §9-5), `/dev/__kmsg__`-style logging fallbacks, the `system()`
calls in the dump/RFS paths, and the `system_server` cmdline guard (§8-8). A bionic
shim (property area + logdw socket + kmsg stubs) is a multi-week project on its own;
the independent loader needs far less. **Corrected 2026-10-30:** stock `cbd` must not be
run at all on this tablet: it creates `/efs/nv_data.bin` when missing and reopens it read-write
(SYNTHESIS.md §2.13, rules 4-5).

## Kernel prerequisites

* `modem_v1` driver with the ss333 DTS (creates `/dev/umts_boot0`,
  `/dev/umts_ramdump0`; CBD_RE.md §2).
* `mipi-lli` driver exposing `lli_control`. **Corrected 2026-10-30:** on the 6.12 port the path
  is `/sys/bus/platform/devices/10f24000.mipi-lli/lli_control`; the attribute is read-only and
  the loader only **reads** it (the CP masters the mount; never write `2`/`3`; SYNTHESIS.md
  rule 8). The `cp_status` attribute
  `/sys/bus/platform/drivers/mif_sipc5/mif_pdata/cp_status/value` is also required.
* RADIO partition accessible as a block device, opened read-only (stock uses `/dev/mbin0` as an
  init.rc symlink to it; the loader takes a plain path, e.g. `/dev/disk/by-partlabel/RADIO`).
* **Corrected 2026-10-30:** the BOOT image goes over **SPI4 at 0x14d00000** (TX link 3), not over
  LLI; `CONFIG_SPI` must be enabled (SYNTHESIS.md §2.1).

## Data inputs

* **image**: RADIO partition (`radio.img`) with the 512-byte TOC (CBD_RE.md §3):
  self-record at 0x00 (size 0x200), `BOOT`@0x20 (off 0x200, sz 0x29fc),
  `MAIN`@0x40 (off 0x2c00, sz 0x21271a0, crc 0x1e71169c), `NV`@0x60 (la 0x47ee0000,
  sz 0x100000, no payload), `OFFSET`@0x80 (ignored by cbd — ignored here too; never send
  stage 4).
* **nv**: **corrected 2026-10-30:** a verified, read-only copy of `nv_data.bin` whose size equals
  the TOC NV size exactly (0x100000). The loader **never creates, pads, truncates or writes**
  NV: a missing, short or blank file makes it refuse to boot (SYNTHESIS.md §4 D4, rule 4).

## Boot sequence (corrected 2026-10-30; the authoritative version is SYNTHESIS.md §2.6-§2.7)

1. **Parse TOC** — read first 0x200 bytes of the image; validate names
   `TOC/BOOT/MAIN/NV` in slots 0–3 (CBD_RE.md §3, §4). Abort on mismatch. Read the BOOT slice
   (0x200, 0x29fc bytes) once into memory and check CRC32 0x5DB1F04C and its pinned SHA-256:
   only these exact bytes may ever cross SPI (BOOT programs CP eFuses; SYNTHESIS.md rule 1).
2. **NV** — open the verified NV copy **read-only** and read it whole into memory; refuse if it
   is missing, not exactly 0x100000 bytes, or blank (corrected 2026-10-30: the earlier text said
   "open O_RDWR; if missing, create 0xFF-filled", which must never be done).
3. **Open `/dev/umts_boot0`** O_RDWR (CBD_RE.md §2; kernel `modem_io_device.c:1794`).
4. `ioctl(fd, IOCTL_MODEM_SET_TX_LINK=0x6f37, &10)` — link = `LINKDEV_LLI`
   (CBD_RE.md §6 step 4; `modem_io_device.c:1286-1311`).
5. `ioctl(fd, IOCTL_MODEM_ON=0x6f19, 0)` — power the CP (§6 step 5).
6. `ioctl(fd, IOCTL_MODEM_BOOT_ON=0x6f22, 0)` (§6 step 6).
7. `ioctl(fd, IOCTL_MODEM_DL_START=0x6f28, 0)` (§6 step 7).
8. `ioctl(fd, 0x6f37, &3)` — switch to SPI for the loader write (§6 step 8).
9. **Send BOOT** — one raw `write(boot_fd, buf, 0x29fc)` of the in-memory, verified BOOT
   buffer — **no framing**. **Corrected 2026-10-30:** then **wait for `cp_status/value` = 1**
   (≤ 5 s; stock: 10 reads 500 ms apart) **before** step 10. The post-write call 0xba70 in cbd is
   `wait_gpio_value(..., "cp_status/value", "1", 10)`; it is not optional. From `cp_status` = 1
   until the first `0xa00d` reply (or 10 s), never power the CP off: BOOT may be programming
   eFuses in that window (SYNTHESIS.md rule 1).
10. `ioctl(fd, 0x6f37, &10)` — back to LLI (§6 step 10).
11. **Wait LLI up** — poll-**read** `lli_control` until it starts with `MIPI-LLI 1`, ≤ 5 s;
    abort on timeout (§6 step 11). Never write this file.
12. **Framed download** (replaces `std_dl_send_bin`; CBD_RE.md §6.1). Drain stale words on
    `umts_boot0` first. Then process **all five stage records in order, none skipped**:
    | # | stage id | start | payload source | CRC step | done |
    |---|---|---|---|---|---|
    | 0 | 0 (BOOT) | no | — (went over SPI) | no | yes: `0x900d` → `0xa00d` |
    | a | 1 (TOC) | yes | image bytes 0x000–0x200 in **one** frame | **no** | yes |
    | b | 2 (MAIN) | yes | image 0x2c00 + 0x21271a0 | yes, CRC 0x1e71169c | yes |
    | c | 3 (NV) | yes | 0x100000 bytes from the in-memory NV copy | **never** | yes |
    | 4 | 0xF (FIN) | yes: `0x9f00` → `0xaf00` | — | no | no |

    For each record with a payload:
    1. `write(fd, {0x9000\|id<<8}, 4)`; `poll(fd, POLLIN, 30000)`; read 4 bytes;
       must equal `0xa000\|id<<8`.
    2. `ioctl(fd, IOCTL_MODEM_FW_UPDATE=0x6f29, {size, 0x810, frames})` where
       `frames = ceil(size/0x800)` — struct = kernel `std_dload_info`
       (`sipc5.h:240-248`); informational only.
    3. For each frame: next ≤0x800 bytes; a **16-byte header**
       `{0x9001\|id<<8, frames_total, frame_seq, frame_len}` — `frame_seq` 1-based up to
       `frames_total`; `frame_len` = this frame's payload byte count; header + payload in
       **one** `write()` (never split a frame; the kernel pads each ring frame to 4 bytes on
       ARM32, userspace never pads).
    4. No write: wait for the end-of-data reply `0xa001\|id<<8` (cbd sends nothing before
       polling; confirmed by the CP-side analysis).
    5. CRC step only for MAIN: `write(fd, {0x900c\|id<<8, crc}, 8)` (one 8-byte write);
       expect `0xa00c\|id<<8`. The value is ignored by this BOOT (secure flag) but still sent.
       Never send `0x930c` (NV) or `0x910c` (TOC).
    6. `write(fd, {0x900d\|id<<8}, 4)`; expect `0xa00d\|id<<8` (stage done).

    **FIN `0x9f00` → `0xaf00` is mandatory**: it is the only way BOOT jumps to MAIN
    (corrected 2026-10-30; the earlier text called record 4 skippable). Never send stage 4 or
    above. Any reply with low nibble 0xF (`0xa20f`, …) is a CP-side STAGE_FAIL. Any other
    protocol error makes BOOT hang silently forever (it has no timeouts): recovery is
    `IOCTL_MODEM_OFF` and the whole sequence again, BOOT over SPI included.
    All waits use **30000 ms** per expected word (§6.1; literal 0x7530 at 0x1e30e).
13. `ioctl(fd, IOCTL_MODEM_BOOT_OFF=0x6f23, 0)` (§6 step 13): returns once the CP's
    `PHONE_START` doorbell was handled (≤ 30 s). On failure cbd issues 0x6f47
    (`IOCTL_MODEM_GET_CP_BOOTLOG`), on success 0x6f48 (`CLR_CP_BOOTLOG`); both return `-EINVAL`
    on this kernel and are harmless (corrected 2026-10-30).
14. Open `/dev/umts_ipc0` and `/dev/umts_rfs0` **after** `BOOT_OFF` (the second open sends
    `INIT_END`), never between DL_START and BOOT_OFF; then
    `ioctl(fd, IOCTL_MODEM_BOOT_DONE=0x6f24, 0)` — CP is up (§6 step 14).
15. Supervise: `POLLHUP` on `umts_boot0` + `IOCTL_MODEM_STATUS` → silent reset =
    `IOCTL_MODEM_OFF` + full boot; bounded retries; **never** `IOCTL_MODEM_CP_UPLOAD` (panics the
    AP) and never `IOCTL_MODEM_DUMP_RESET` for a silent reset (added 2026-10-30).

## Risk notes (corrected 2026-10-30)

* The `0x9000`-family values are Samsung's STD_UDL protocol (`std_boot.h` in cbd v1); the
  kernel is agnostic to them.
* Step 12-4 (poll-only end-of-data ack) is confirmed by cbd v1 and by BOOT's code.
* ~~Record 4 can be skipped.~~ **Wrong**: record 4 is the FIN stage `0x9f00` → `0xaf00` and is
  mandatory (SYNTHESIS.md §2.7).
* ~~If nv_data.bin is shorter, pad 0xFF.~~ **Wrong and dangerous**: never pad, create or write
  NV; refuse to boot instead (SYNTHESIS.md rule 4).
