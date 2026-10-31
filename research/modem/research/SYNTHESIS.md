# SS333 modem under mainline Linux on the SM-T715: consolidated theory

**Version 2, 2026-10-30: reviews integrated** (`research/review/kernel_boot_review.md`,
`research/review/telephony_voice_review.md`; each finding and its disposition is in §10).
v1: 2026-10-29. Status: static analysis and web research, plus the first hardware observations of
the live mission (G0 and G1, §2.18). No Samsung binary was executed and no EFS, `nv_data` or
`m9kefs` content was opened for this document. It supersedes the four original dossier files
(§9 lists the corrections, applied to them on 2026-10-30) and is the reference for the mission.

## 0. Conventions

**Source keys.** Paths relative to `research/modem/` unless they start with a repository directory
(`src/`, `docs/`, `image/`, `out/`, `boot/`, `device/`, `dumps/`). The repository is
`omarchy-tab-s2`; `dumps/` is a link to the private dumps.

| Key | Document | Role |
|---|---|---|
| BR | `SS333_LLI_BRINGUP.md` | original dossier (corrected in place 2026-10-30) |
| CBD | `CBD_RE.md` | static RE of the stock `/sbin/cbd` binary (corrected) |
| LS1 | `LOADER_SPEC.md` | first loader spec (superseded, dangerous statements fixed) |
| UAPI | `modem_v1_uapi.h` | ABI header (corrected) |
| RI | `research/analysis/radio_image.md` | CP-side RE of BOOT |
| LS2 | `research/analysis/loader_spec_v2.md` | loader spec v2 |
| RR | `research/analysis/ril_runtime_rfs.md` | stock rild / libsec-ril runtime, RFS spec |
| IPC | `research/analysis/ipc41_catalogue.md` | IPC 4.1 message catalogue |
| KP | `research/analysis/kernel_port_design.md` | 3.10 → 6.12 port design |
| VA | `research/analysis/voice_audio_design.md` | WM1814 AIF2 voice design |
| KD, CB, FR, AR, LV | `research/research_notes/Modem Shannon SS333 sous Linux/` `kernel_drivers.md`, `cp_boot_firmware.md`, `samsung_ipc_free_rils.md`, `android_ril_reuse.md`, `linux_stack_voice.md` | web research notes |
| REP | `research/reports/Modem Shannon SS333 sous Linux.md` | French synthesis report |
| KR, TR | `research/review/kernel_boot_review.md`, `research/review/telephony_voice_review.md` | adversarial reviews of v1 |
| HO, DEPLOY, DR | `docs/journal/HANDOVER.md`, `docs/DEPLOY.md`, `device/README.md` | project rules and procedures |
| BL, CFG, IMG | `docs/hardware/boot-logs/boot1-2026-10-28.txt`; `out/mainline/.config`; `image/out/rootfs-omarchy.MANIFEST` | our mainline boot log, kernel config, image package list |
| MS | the bring-up log, not published | hardware results G0-G1 |
| COORD | project facts: TWRP EFS backup index (names and sizes only), stock `getprop` | |
| SYN | checked for this document: 3.10 and 6.12 source lines, BL, CFG, IMG, the private stock `dmesg.txt` reduced to LLI power-management lines and timestamps (no payload, no identifier) | |

`K/` = `src/kernel_universal5433/`, `ML/` = `src/linux-6.12/`.

**Confidence.** **P** proven (byte, instruction address, source line, primary document, or the
mission's hardware log). **I** inferred (reasoning given). **U** unknown (needs hardware).

**Precedence.** Hardware observation > local static analysis (RI, LS2, RR, IPC, KP, VA) > web notes >
original dossier; inside any source a cited line or byte beats prose. A reviewer's claim counts only
after its evidence was re-checked (§10 says how).

**STD_UDL word notation.** `0xDS0T`: D = 9 (AP→CP) or A (CP→AP), S = stage (0 BOOT, 1 TOC, 2 MAIN,
3 NV, D DUMP, F FIN), T = step (0 START, 1 SEND, C CRC, D DONE, F STAGE_FAIL). `0x920C` = AP sends
the MAIN CRC.

---

## 1. Executive summary

**What is known.** The **boot path** (RADIO → CP ONLINE) is specified with proven evidence from both
ends of the link: the stock cbd binary, Samsung's public cbd v1 source and the 3.10 kernel on the AP
side, the BOOT disassembly on the CP side; they agree word for word (LS2 §4, RI §2.5). **Above
ONLINE**, every message layout the mission needs is proven at the AP-side builders and parsers of the
stock RIL (IPC, RR), but several runtime behaviours remain I or U: the CP's reassembly of chunked RFS
replies, CALL_INCOMING's layout, the CLOCK_CTRL/WB_AMR report semantics, FLL2 behaviour before BCLK,
AIF2 slot use, and network acceptance of CS voice. MIPI-LLI has never been brought up on a mainline
kernel.

- **Hardware wiring** (P): 10 control GPIOs; SPI4 at 0x14d00000 for the CP BootROM; MIPI-LLI at
  0x10f24000 (IRQ SPI 184 link events, SPI 185 doorbell), M-PHY 0x10f20000, PMU word 0x720; an 8 MiB
  shared region in AP DRAM that the CP sees at CP 0x30000000 (KP §3, RI §2.4).
- **CP boot**: BOOT image raw over SPI → `cp_status` = 1 (which, from the stock runtime timing, very
  likely already implies the LLI mount, C25) → STD_UDL stages BOOT-done, TOC, MAIN (+CRC), NV, FIN
  over the LLI ring → `PHONE_START` → ONLINE. The CP masters the mount; FIN is mandatory; BOOT has no
  timeouts, so any protocol error hangs the CP until a power cycle.
- **Irreversible or invisible failure modes** found in review, each now guarded in the kernel and
  not only by procedure: BOOT programs CP **eFuse** key slots when blank or different (only the
  stock BOOT bytes may cross SPI, and nothing may cut power during BOOT's eFuse window); the 3.10
  driver mounts the link **without checking that the shared-memory remap was programmed** (a
  per-boot interlock is required); the 3.10 M-PHY runs **AFC only on the first reset after boot**,
  so an LLI test reset before the first CP boot corrupts the PHY setup of every later attempt in
  that boot.
- **Runtime IPC** is Samsung IPC 4.1 (protover 2) with the 7-byte FMT header; **RFS** uses the
  6-byte libsamsung-ipc header with 23 verbs; the kernel cuts each write to the SBD uplink slot
  (2 KiB on `umts_rfs0`), so replies need a short-write loop.
- **NV**: `nv_data.bin` is exactly 1 MiB (= TOC NV size); stock libsec-ril can regenerate it from
  defaults. Our software never creates or writes it; NV is extracted from the raw backup.
- **Desktop**: the image already carries the consumers (omarchy-mobile shell with a disabled
  cellular icon, NetworkManager 1.58.1); the omarchy-mobile project's `omamobile-mmd` is a tested
  ModemManager-API bridge to adapt. WirePlumber in the image (0.5.13) is too old for automatic call
  profiles; GNOME Calls needs a CallAudio service.
- **Voice** PCM runs CP↔WM1814 AIF2 (I2S, 2×16-bit, CP is clock master, FLL2 locked to AIF2 BCLK);
  mainline lacks three codec controls and the machine link.

**Critical path.** Backups (done, MS) → kernel series (CMU_CPIF clocks, PMU, LLI module with AFC fix
and remap interlock, modem_v1 module with `allow_hw` transitions and SPI tripwire, DT with guard
region, `CONFIG_SPI`) → offline kernel-logic tests (O8) → G2a/b/c → G3 (remap readback) → reboot →
G4-G7 (first ring round trip `0x900D/0xA00D`) → G8-G9 (ONLINE) → G9b/G11/G10. Everything above
ONLINE has public or local precedent; nothing below it after 2016.

**Outlook** (judgement; "conditional" assumes the previous row succeeded; "within the mission"):

| Capability (delivery order) | Conditional | Cumulative | What decides it |
|---|---|---|---|
| CP ONLINE | ~0.55 | ~0.55 | LLI/M-PHY first light on mainline clocks, remap address, SPI acceptance |
| Bar icon: registration + signal | ~0.85 | ~0.47 | IPC 4.1 NET/DISP layouts P-H; façade reuse |
| IPv4 data through NetworkManager | ~0.85 | ~0.40 | PDP/IP_CONFIGURATION layouts P-H; RAWIP netdev; LTE attach |
| SMS both ways | ~0.85 | ~0.34 | layouts P-H; SMS-over-SGs/CS availability; codec and spool work |
| Voice signalling (MO, MT) | ~0.80 | ~0.27 | CALL messages P-H; CS voice needs 2G/3G (CSFB) |
| Two-way call audio | ~0.60 | ~0.16 | codec patch, c2c link, CP clock behaviour, WirePlumber version |

**Horizon.** No IMS/VoLTE path exists. CS voice (CSFB) and possibly SMS depend on the operator's
2G/3G core and end with its sunset on dates that vary by country and operator (U27). Data does not depend on it.

**Top risks** (impact × likelihood): (1) the LLI never mounts on mainline clocks/M-PHY settings;
(2) wrong remap or memory type: the CP cannot see the rings, or writes outside the reserved region
(now interlocked per boot, guard region up to the end of DRAM); (3) persistent EFS/NV damage through
a loader, RFS server or stock RIL that writes; (4) eFuse damage from a wrong BOOT or a power cut in
BOOT's eFuse window; (5) bus hangs or IRQ storms on unclocked LLI blocks, ending in a watchdog reset
or in a frozen-but-pinged system that needs the owner's hands; (6) CP behaviour with the link held up
and with sandboxed RFS; (7) call audio (CP clock behaviour, codec clocking, WirePlumber);
(8) battery and heat with a powered CP; (9) subscriber data and secrets in logs.

---

## 2. Single source of truth fact sheet

### 2.1 AP-side hardware

| Item | Value | Source (and its evidence) | Conf |
|---|---|---|---|
| SoC / kernel | Exynos 5433, mainline 6.12 **ARM32** zImage, `CONFIG_ARM_LPAE=y`, `VMSPLIT_2G`, 64-bit `phys_addr_t`/`dma_addr_t`, `CONFIG_LOCALVERSION_AUTO=y`, `CONFIG_SUSPEND=y`; stock was 3.10 ARM32 without LPAE | KP §2.4; CFG | P |
| CP | Shannon SS333 (`SEC_SS333 = 15`), external, ARMv7-R, own DRAM controller | BR §1.2; RI §2.2-2.3 | P (core type I) |
| LLI controller | `reg` 0x10f24000+0x4000 (PA/DME/IAL/DL/TL), 0x10f34000+0x4000 (remote, unused with GPIO sideband), 0x10fd0000+0x2000 (SYSREG_CPIF, `CPIF_LLI_SIG_*` masks only) | BR §1.5; KP §3.2 | P |
| M-PHY | 0x10f20000+0x4000; init-gear `<2 2 1>` = HS, G2, rate A; shared ref clock; TX_HS_SYNC_LENGTH 0x45, TX_LCC 0, TX/RX_MODE 2, HSGEAR 2; CMN 0x1C = 0x41 (5433+SS333), 0x2E "changed by CP" | BR §1.5, §3.2; RI §2.6 | P |
| **M-PHY AFC** | `exynos_mphy_cmn_init` runs AFC (0x44 = 0, 0x31 = 0) only on its **first call after boot** (`static bool is_first`); later calls force AFC override (0x31 = 1) with code `phy->afc_val`, which is saved only at the **first `MOUNT_DONE`** (second static `is_first`); `afc_val` is zero-initialised. A second reset before any mount therefore programs AFC code 0 | SYN `K/drivers/misc/mipi-lli/exynos-mipi-lli-mphy.c:53-88`, `exynos-mipi-lli.c:841-858`, `exynos-mipi-lli-mphy.h:231`; KR D1-c | P |
| PMU | `LLI_PHY_CON` = PMU+0x720, written 1 at every `SW_RESET_DONE`; mainline: through the PMU syscon regmap (exynos-pmu claims 0x105c0000-0x105c5007; no 5433 write filter; MMIO regmap is spinlocked, so hard-IRQ writes are legal) | BR §3.2; KP §4.5; KR D1 (`regmap-mmio.c:398`) | P |
| **Remap write path** | the remap is written only in `exynos_lli_setting()` at `SW_RESET_DONE` (hard IRQ); on a remap error it returns after having written PMU and PA registers, and the caller ignores the return value; the `HIBERN8_EXIT_DONE` branch writes `LLI_MOUNT_CTRL` **unconditionally** after `mdelay(1)` | SYN `exynos-mipi-lli.c:282-312,911-914,926-932` | P |
| Error-sent path | `INTR_RESET_ON_ERROR_SENT` → soft reset and `return` before the W1C status clear (level IRQ can re-enter) | SYN `exynos-mipi-lli.c:951-955` | P |
| Unmount path | `INTR_LLI_UNMOUNT_DONE` → state UNMOUNTED, W1C, `exynos_lli_init()` (re-arm) when no `unmount_cb` | SYN `exynos-mipi-lli.c:1003-1007` | P |
| LLI IRQs | SPI 184 = index 0 = DME/link events (`exynos_mipi_lli_irq`, threaded); SPI 185 = index 1 = TL-signal doorbell (`mipi_lli_sig_irq`); ARGOS hwirq 217 = "IPC". Trigger level-high assumed | KP C-2; SYN | P (trigger I) |
| Doorbell registers | AP→CP: `TL_SIGNAL_SET_MSB` (LLI+0x2014) + toggle `ipc_int2cp`; refused with `-EIO` when unmounted, callers ignore it. CP→AP: `TL_SIGNAL_STATUS_LSB/MSB` (+0x2004/+0x2010), clear +0x200C/+0x2018 | SYN `exynos-mipi-lli.c:434-443,452,480-486` | P |
| LLI registers used | 0x134 = 0xF; 0x400 = 10 ns (assumes 100 MHz); `DME_CSA_SYSTEM_STATUS/SET/CLR` 0x908/0x90C/0x910 (bit0 mounted, bit1 master, bit2 mount ctrl); `DME_LLI_INTR_STATUS` 0x1010 (bit0 MOUNT_DONE, bit6 HIBERN8_EXIT_DONE, bit15 SW_RESET_DONE); `IAL_LL/BE_INIT_ADDR_REMAP` 0x1110/0x1114 | BR §1.6; RI §2.6 | P |
| LLI mount | AP is slave (`is_master = false`); BOOT writes `CSA_SYSTEM_SET = 6` and waits unbounded; AP writes `LLI_MOUNT_CTRL` on `HIBERN8_EXIT_DONE`; on `MOUNT_DONE` waits ≤ 10 × 1 ms for DL TX credits, then `LLI_MOUNTED` (else "ERR: Mount failed") | LS2 §5; RI §2.6 | P |
| LLI clocks | `div_aclk_cpif_200` must be 100 MHz; CMU_CPIF 0x10fc0000: `SRC_SEL_CPIF1` 0x0204 bits 4/8 select `phyclk_lli_tx0/rx0_symbol` (150 MHz); gates `ENABLE_IP_CPIF0` 0x0B00 bits 1-4, 7-11, `ENABLE_IP_CPIF1` 0x0B04 bit 0; bus gates `ENABLE_ACLK_CPIF` 0x0800 and `ENABLE_PCLK_CPIF` 0x0900 are not modelled by the planned clock patch (they come from reset/sboot; G1+ go/no-go). Mainline models none of the LLI clocks (new IDs 12-25; upstream ID 11 collision) | KP §4.1-4.3; KR §4.1 G1 | P |
| Probe-time hardware access (mainline) | the platform core applies `assigned-clocks` (mux parents, `div_aclk_cpif_200` → 100 MHz) and the pinctrl default state **before** probe; KP's probe then enables gates and clears `DME_LLI_INTR_*`. Loading the LLI module is the first CMU_CPIF/LLI access (G2b) | SYN `ML/drivers/base/platform.c:1367`, `dd.c:694`; KR D1-b | P |
| Kernel cmdline | from `CONFIG_CMDLINE` + `CMDLINE_EXTEND` (sboot replaces DT `bootargs`): `panic=5 oops=panic clk_ignore_unused pd_ignore_unused s3c2410_wdt.tmr_atboot=1`. The watchdog runs from boot and a kernel thread pings it: a hang ends either in a watchdog reset (sboot then boots RECOVERY) or, if one CPU stalls while the pinger runs, in a frozen-but-pinged system that only a forced restart or Download mode ends | CFG; `docs/hardware/WATCHDOG.md`; DEPLOY §4.3, §13 | P |
| SPI4 (boot link) | **0x14d00000**; GIC SPI 412; pdma0 25/24 (PIO without pl330); mode 0, 8 bit, 100 kHz, one `spi_sync`, TX only, 10 µs post-delay, hardware auto-CS; pins gpv7-1 CLK, gpv7-2 nCS, gpv7-4 MOSI (func 3, pull-up), gpv7-3 MISO parked input pull-down. `# CONFIG_SPI is not set` today | KD Q5; LS2 §6.1; KP §3.5; CFG | P |
| Shared region | 8 MiB, power-of-two size, size-aligned (remap register); stock-likely base **0xde000000**, the 8 MiB hole between the stock ION carveouts `common` (ends 0xde000000) and `mfc_sh` (0xde800000), kept by our DT; remap value for that base **0x0001BC97** | KP §3.1, §2.6; KR D3 (`dumps/live_fdt.dts:1911`) | base I; remap value P (arithmetic on proven code) |
| DRAM around it | 0xde000000-0xde7fffff ordinary RAM today (a separate 8 MiB bank in `/proc/iomem`, MS G1); 0xde800000-0xde91ffff ION carveout `no-map`; **0xde920000-0xde97ffff ordinary RAM (384 KiB)**; DRAM ends 0xde980000 | SYN BL:26-29,36; MS | P |
| Reserved-memory pitfalls | a failed reservation still prints the `OF: reserved mem: … nomap` line (BL:7 failure, BL:31 line for `sec-log`), and `of_reserved_mem_lookup()` still succeeds; `pfn_valid()` is true for NOMAP ranges on ARM32 6.12; ARM32 `ioremap` refuses ranges that are still map memory | SYN `ML/drivers/of/of_reserved_mem.c:183-197`, `ML/arch/arm/mm/init.c:126-145`, `ML/arch/arm/mm/ioremap.c:314-320` | P |
| CP-visible window | CP MPU region 3: CP 0x30000000, 256 MiB, strongly-ordered = shmem offset 0 through the LL/BE remap; whether the IAL masks CP accesses to the 8 MiB the remap word encodes is U | RI §2.4, §2.7 | P (CP side), U (masking) |

### 2.2 Control GPIOs

Mainline DT uses `GPIO_ACTIVE_HIGH` on every line (stock third cells were ignored by 3.10 and
would invert CP_ON/CP_RESET under gpiod; KP §3.3). **Pinctrl rule**: the default state sets no
normal-mode `samsung,pin-function` and no normal-mode `samsung,pin-pud` on any AP→CP output.
Stock never set a normal-mode pull on them (only `pin-con-pdn`/`pin-pud-pdn`) and drove them as
outputs at probe; with `allow_hw = 0` they stay as reset/sboot left them, and G1 shows CP_ON and
CP_RESET as **inputs pulled down** (MS): a `PULL_NONE` default would make them float (KR E2; SYN
`K/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:43-100`). Stock probe drives CP_ON = 0 then
CP_RESET = 0 as outputs (`modem_main.c:294-307`); `ss333_init` writes CP_RESET 0 then CP_ON 0
(`modem_ctrl_ss333.c:550-551`).

| Signal | Pin | Dir | Physical meaning | Used by | G1 state (MS) | Conf |
|---|---|---|---|---|---|---|
| CP_ON | gpr3-1 | out | 1 = CP power on | `ss333_on/off` | input, pull-down | P |
| CP_RESET | gpc0-5 | out | **0 = reset asserted** | `ss333_on/off`, `dump_reset` | input, pull-down | P |
| PDA_ACTIVE | gpg2-1 | out | 1 = AP active | `ss333_on` | input | P |
| PHONE_ACTIVE | gpa2-3 | in, IRQ rising | rising while ONLINE = crash; `ss333_off` waits for it **high** ≤ 3 s | `cp_active_handler` | input | P (level during boot U) |
| CP_STATUS = CP2AP_STATUS | gpa2-5 | in | 1 after BOOT runs (very likely after the mount, C25); exported as `cp_status/value` | loader B8 | input | P |
| IPC_INT2CP | gpa2-6 | out | toggled per AP→CP doorbell | `send_ap2cp_irq` | input | P |
| AP_DUMP_INT | gpr2-0 | out | 1 = force CP dump | `force_crash_exit` | input | P |
| CP2AP_WAKEUP | gpa3-1 | in | CP wants the link | link PM | input | P |
| AP2CP_WAKEUP | gpf5-0 | out | AP holds the link | link PM | **output 0** (left by the bootloader) | P |
| AP2CP_STATUS | gpf1-2 | out | raised by `ss333_boot_on`; BOOT waits for it (hypothesis) | `boot_on`, link PM | input | P (CP mapping I) |
| CP_PMIC_HOLD ("cp_off") | gpf1-1 | input, high-Z | not driven | pinctrl | input | P |

Inputs keep the stock settings (function 0xF on IRQ, pull none); requesting an IRQ switches the
pin to EINT (KP §2.3). The gpa banks share the muxed wakeup EINT with BT host-wake and MUIC
(KP §5.1), so floating CP2AP inputs with enabled IRQs are a storm risk (D2).

### 2.3 Power sequences (kernel 3.10; the port keeps order and delays)

| Op | Sequence | Source | Conf |
|---|---|---|---|
| `ss333_on` (`MODEM_ON`) | disable phone_active IRQ; state OFFLINE; PDA_ACTIVE = 1; wake lock; `ld->off`; CP_ON = 0, 100 ms; CP_RESET = 0, 500 ms; CP_ON = 1, 100 ms; `ld->reset` (LLI intr enable + soft reset, **with CP_ON = 1 and CP_RESET = 0**); AP_DUMP_INT = 0; CP_RESET = 1, 300 ms (≈ 1.0 s). Port adds: CP_RESET is released only after this reset's own `SW_RESET_DONE` and a matching remap readback (D3) | BR §3.1 (`modem_ctrl_ss333.c:159-209`); KD Q6 | P |
| `ss333_boot_on` | `cp_boot_done = 0`, link OFFLINE, purge TXQ; AP2CP_STATUS = 1; re-arm completions; BOOTING | `:382-403` | P |
| `ss333_boot_off` | wait `init_cmpl` ≤ 30 s, else `-EAGAIN`; enable phone_active IRQ; ONLINE | `:405-429` | P |
| `ss333_off` | stock: return if OFFLINE; return if CP_ON == 0; wait PHONE_ACTIVE high ≤ 3 s; `ld->off`; CP_RESET = 0; **CP_ON stays high**. **Port**: from every state, disable CP2AP IRQs, then CP_RESET = 0, then CP_ON = 0 | KP C-5, §5.2; LS2 §4.5; KR E1 | stock P; port D |
| stock `stop_link_pm` | disables the CP2AP IRQs; does **not** touch AP2CP_WAKEUP/STATUS (the port's `stop_pm` lowers them: deliberate deviation) | SYN `link_device_pm.c:846-872`; KR D2-c | P |
| `.shutdown` | `modem_shutdown` → `ss333_off` on `systemctl reboot/poweroff`; does **not** run after a panic, watchdog reset or forced restart | KP §2.3; KR F7 | P |
| `ss333_dump_reset` | dump boot only: CRASH_EXIT, CP_RESET pulse, LLI re-init, no CP_ON cycle | LS2 §9.3 | P |
| `ss333_force_crash_exit` | 10 s ack timer, `ld->off`, AP_DUMP_INT = 1 → CRASH_EXIT | BR §3.1; LS2 §9.1 | P |

### 2.4 CP-side view (BOOT)

| Item | Value | Source | Conf |
|---|---|---|---|
| CP memory map | BOOT SRAM 0; TCM 0x04000000/0x04800000; LLI window 0x30000000 (256 MiB); DRAM 0x40000000 (128 MiB, MAIN entry 0x40000000); staging 0x47000000-0x47F00000; NV load 0x47EE0000; peripherals 0x8xxxxxxx (UART 0x84000000, crypto 0x81003000, eFuse 0x8400C000, LLI 0x89004000) | RI §2.4 | P (identities I) |
| BOOT order | UART → caches → MPU → LLI + M-PHY init and **mount (unbounded)** → sideband: CP 0x83007100 bit 3 low→high (= CP_STATUS, hypothesis), wait unbounded for 0x83007200 bit 1 (= AP2CP_STATUS, hypothesis) → I2C → **eFuse compare and program** (HASH magic) → eFuse sense → read shmem magic **once** → download → FIN → jump 0x40000000 | RI §2.3 | P (code order); GPIO identities I |
| eFuse window | between `cp_status` = 1 and BOOT's first reply (`0xA00D`), BOOT may program eFuse slots 0/1/8/9 and slot 2 bit 0x4000 (each cycle toggles a PMIC rail over I2C); slots probably already match on this tablet, so nothing is written (I); the duration of a program cycle is U | RI §2.3 steps 7-11, §2.8; KR D4-a | P (code), I/U (state, duration) |
| Magic | `0x424F4F54` "BOOT" when BOOT reads it; "DUMP" = dump mode; other = hang | RI §2.3 | P |
| Polling | BOOT busy-polls `raw_tx_head`; no AP→CP doorbell needed; replies on the raw CP→AP ring with LLI signal 0x83 | RI §2.7 | P |
| Secure flag | BOOT+0x30 = "HSAH": eFuse provisioning; MAIN CRC over the decrypted MAIN against an internal CRC (the AP's CRC value is ignored; the step is optional) | RI §2.5, §2.8 | P |
| MAIN | encrypted (16-byte chained cipher, IV every 64 KiB); 272-byte trailer never sent | RI §3 | P |
| Debug | CP UART at CP 0x84000000; expected trace `\nS333 (Oct 21 2015) : CMSMTLeGiFsBoot\nRecvTOC TBL\nMAIN (CRC:Ok)>Done\nNV>Done\nRun\n`; failure markers `Unknown`, `XxX!`, `Nok)`; access on the T715 U | RI §2.10 | P/I/U |

### 2.5 Shared memory: legacy 4 MiB map at the start of the region

| Offset | Field | Use | Source | Conf |
|---|---|---|---|---|
| 0x00 | `magic` | "BOOT" written and read back by `DL_START`; BOOT reads it once; MAIN uses 0xAA after `PHONE_START` | RI §2.7; BR §3.3 | P |
| 0x04 | `access` | 1 when IPC healthy | BR §3.3 | P |
| 0x08-0x14 | fmt ring indices | unused by BOOT | RI §2.7 | P |
| 0x18 / 0x1C | `raw_tx_head` (AP) / `raw_tx_tail` (CP) | AP→CP boot ring | RI §2.7 | P |
| 0x20 / 0x24 | `raw_rx_head` (CP; cached once by BOOT) / `raw_rx_tail` (AP) | CP→AP boot ring | RI §2.7, C2 | P |
| 0x1000 / 0x2000 | `fmt_tx_buff` / `fmt_rx_buff` (4 KiB) | — | UAPI | P |
| 0x3000 | `raw_tx_buff`, 0x1FD000 B | AP→CP ring | RI §2.7 | P |
| 0x200000 | `raw_rx_buff`, 0x200000 B | CP→AP ring | RI §2.7 | P |
| 0xC00 | CP boot log in later shmem kernels | SS333 use U | KD Q1 | I |

The upper 4 MiB are unused until `INIT_START` (BOOT touches only the legacy rings), so they and the
guard region can carry a canary through `--stop-after=nv` (D3). The SBD rings used after
`INIT_START` have no established base (U).

### 2.6 Boot protocol: the exact ordered sequence (loader B-steps)

Open `/dev/umts_boot0` O_RDWR once and keep it (its last close resets `cp_boot_done`). `[rung]` =
`--stop-after` value. Every rung that ends after B7 honours the **eFuse settle** before `MODEM_OFF`:
no power-off before `0xA00D` or 10 s after `cp_status` = 1, whichever comes first (rule 1).

| # | Call / action | Exact values | Expected | Timeout | Source | Conf |
|---|---|---|---|---|---|---|
| F1-F7 | preflight, no CP power change: paths; TOC 0x200 B, names `TOC/BOOT/MAIN/NV`; BOOT.size ≤ 0xFFFB; **BOOT slice read once into memory, CRC32 0x5DB1F04C and pinned SHA-256 checked**; NV snapshot (§2.13); `allow_hw` = Y else refuse; if `cp_status` = 1 already, log and `MODEM_OFF` first | image `/dev/disk/by-partlabel/RADIO`; `lli_control` `/sys/bus/platform/devices/10f24000.mipi-lli/lli_control`; `cp_status` `/sys/bus/platform/drivers/mif_sipc5/mif_pdata/cp_status/value` | `MIPI-LLI 0`, `0` | — | LS2 §4.1; KR D4-b, D4-e | P / D |
| B1 | `ioctl(0x6F37, &10)` SET_TX_LINK = LLI | `int 10` | 0 | — | LS2 B1 | P |
| B2 `[power]` | `ioctl(0x6F19)` MODEM_ON | — | 0 after ≈ 1.0 s; one `SW_RESET_DONE ++`; interlock line `remap ok` | — | §2.3 | P / D |
| B3 | `ioctl(0x6F22)` BOOT_ON | — | 0; BOOTING; AP2CP_STATUS = 1 | — | §2.3 | P |
| B4 | `ioctl(0x6F28)` DL_START (TX link LLI) | — | rings reset, SBD off, `aligned = true`, magic "BOOT" read back | — | LS2 B4 | P |
| B6 | `ioctl(0x6F37, &3)` SET_TX_LINK = SPI | `int 3` | 0 | — | LS2 B6 | P |
| B7 `[spi]` | `write(boot, <in-memory BOOT buffer>, 0x29FC)` **one call**; the kernel tripwire refuses any other length or CRC and a second SPI write in the same `MODEM_ON` | wire carries BOOT only (4-byte SIPC5 header stripped) | returns 0x29FC; ≈ 0.86 s at 100 kHz | no retry | LS2 §6.1; KR D1-d | P / D |
| B8 | poll `cp_status/value` == "1" (TX link still SPI); record `lli_control` and the LLI IRQ log at the edge | — | `1`; `MIPI-LLI 1` very likely already (C25) | 5 s deadline, 100 ms period | LS2 B8 | P |
| B9 | `ioctl(0x6F37, &10)` | — | 0 | — | LS2 B9 | P |
| B10 `[lli]` | poll `lli_control` starts with `MIPI-LLI 1`; read only (the attribute is 0444) | — | `MIPI-LLI 1\n` | 5 s | LS2 B10, §5 | P |
| B11 | drain stale RX on `umts_boot0` | `poll(0)` + `read` | empty | — | LS2 B11 | D |
| B12 `[stage0..fin]` | stage engine (§2.7) | — | all OK | 30 s per expected word | LS2 §4.3 | P |
| B13 | `ioctl(0x6F23)` BOOT_OFF | — | 0 after `PHONE_START`; `-EAGAIN` after 30 s → `ioctl(0x6F47)` → attempt failure | 30 s | LS2 B13 | P |
| B14 `[online]` | open `/dev/umts_ipc0`, `/dev/umts_rfs0` (O_RDWR + O_NONBLOCK + O_CLOEXEC); holders, never read | — | `umts_rfs0->INIT_END->ss333` | — | LS2 §7 | P |
| B15 | `ioctl(0x6F48)` | — | `-EINVAL` | — | LS2 B15 | P |
| B16 | `ioctl(0x6F24)` BOOT_DONE | — | 0 | — | LS2 B16 | P |
| B17 | `ioctl(0x6F27)` STATUS; publish READY with a session number for the daemons (D5) | — | 4 | — | LS2 B17; TR D5-2 | D |

Ordering: B1 before B4; B4 and B3 before B7; B8 before B9; B10 before B12; no ring reset or magic
rewrite after B7; never open `umts_ipc0`/`umts_rfs0` for the first time between B4 and B13's
return. Attempts: `--attempts=1` through G9 (AFC, D1); later ≤ 3 per start.

### 2.7 Stage engine and golden transcript

Records in this order, none skipped; only the payload step is skipped when `download = 0`
(LS2 §4.3; RI §2.5).

| Rec | Stage | start | download | CRC | done | Payload |
|---|---|---|---|---|---|---|
| 0 | 0 BOOT | no | no | no | yes | — (BOOT went over SPI) |
| 1 | 1 TOC | yes | yes | no | yes | image[0 .. 0x200) in **one** frame |
| 2 | 2 MAIN | yes | yes | yes | yes | image[0x2C00 .. +0x21271A0), CRC 0x1E71169C |
| 3 | 3 NV | yes | yes | **never** | yes | NV snapshot, 0x100000 B |
| 4 | F FIN | yes | no | no | no | — (**mandatory**) |

Per stage: start `0x9S00` → `0xAS00`; `ioctl(0x6F29, &{size, 0x810, N})`, N = ceil(size / 2048)
(informational); frames `{0x9S01, N, i, len_i}` + payload, i = 1..N, len ≤ 2048, one `write()` each
returning 16 + len_i; response-only wait for `0xAS01`; CRC `{0x9S0C, crc}` (8 B) → `0xAS0C`; done
`0x9S0D` → `0xAS0D`.

| # | AP writes | CP answers | Notes |
|---|---|---|---|
| 1 | `0x900D` | `0xA00D` | first message (also ends the eFuse window) |
| 2-6 | `0x9100`; FW_UPDATE {0x200, 0x810, 1}; `{0x9101,1,1,0x200}` + TOC (528 B); —; `0x910D` | `0xA100`; —; —; `0xA101`; `0xA10D` | BOOT keeps the first 0x100 B |
| 7-12 | `0x9200`; FW_UPDATE {0x21271A0, 0x810, 0x424F}; 16 975 frames (last 0x1A0, write 432 B); —; `{0x920C, 0x1E71169C}`; `0x920D` | `0xA200`; —; —; `0xA201`; `0xA20C` (or `0xA20F`); `0xA20D` | CRC value ignored in secure mode |
| 13-17 | `0x9300`; FW_UPDATE {0x100000, 0x810, 0x200}; 512 frames; —; `0x930D` | `0xA300`; —; —; `0xA301`; `0xA30D` | never `0x930C` |
| 18 | `0x9F00` | `0xAF00` | FIN |

Byte vectors (LE): `0x900D` = `0D 90 00 00`; FIN = `00 9F 00 00`; CRC frame `0C 92 00 00 9C 16 71 1E`;
MAIN first header `01 92 00 00 4F 42 00 00 01 00 00 00 00 08 00 00`. Per boot: 17 497 writes,
12 response reads, 3 FW_UPDATE. Decoding: R = expected → OK; `0xAS0F` → CP_STAGE_FAIL(S); else
mismatch. BOOT answers `0xA?0F` only to a wrong frame command or a CRC mismatch; every other error is
silent and BOOT spins forever. Never send stage ≥ 4.

### 2.8 Framing and padding rule (boot channel)

| Rule | Value | Source | Conf |
|---|---|---|---|
| One message = one `write()` = one SIPC5 frame | 4-byte header; cfg 0xFC on LLI after DL_START (0xF8 start + `PADDING_EXIST`), ch 0xD7, `len = 4 + payload` (padding excluded); 6-byte header only above 0xFFFF; no CTL | LS2 §2.4; RI C7 | P |
| Padding | userspace never pads; the kernel pads to `sizeof(size_t)` = **4 on ARM32**; BOOT rounds up to 4; an arm64 kernel would pad to 8 and break BOOT. Port pins `SIPC5_ALIGN 4` | RI C8; KP §2.4 | P |
| Atomicity | data first, then head; `udl_write` all-or-nothing; `-ENOSPC` after 20 × 50 ms = nothing queued | RI C10; LS2 §6.2 | P |
| Ring vectors | request `FC D7 08 00`+word; CRC `FC D7 0C 00`+8 B (12-byte frame); full frame `FC D7 14 08`+2064 B; TOC `FC D7 14 02`+528 B; last MAIN `FC D7 B4 01`+432 B; CP replies `xx D7 08 00`+word | LS2 §10.4; RI §2.5 | P/I |
| No splitting | never split a request, CRC frame or data frame | RI C9 | P |
| IPC mode | after `INIT_START`, `aligned = false`: IPC frames not padded | BR §3.3 | P |

### 2.9 Kernel ABI (kept, with the port's changes marked)

**Device nodes**: **9 misc** + 4 netdevs (SYN `modem_io_device.c:1786-1840`).

| Node | ch | Format | UL slot | Role | Mode (D9) |
|---|---|---|---|---|---|
| `umts_ipc0` | 235 | FMT | 16 × 4096 | IPC 4.1 control | 0660 root:radio (`shannond`) |
| `umts_rfs0` | 245 | RFS | 16 × 2048 | CP file/NV server | 0660 root:rfs (`shannon-rfsd`) |
| `umts_csd` | 1 | RAW | 32 × 2048 | CS video-telephony data | 0600 root until needed |
| `umts_router` | 25 | RAW | 16 × 2048 | DUN "Data Router" (AT unverified; Samsung AT can reach NV) | **0600 root** |
| `umts_dm0` | 28 | RAW | 16 × 2048 | DIAG/SDM (can read/write NV on Shannon, I) | **0600 root** |
| `ipc_loopback0` | 244 | FMT | 16 × 2048 | loopback | 0600 root |
| `umts_boot0` | 215 | BOOT | — | boot (links LLI+SPI) | 0600 root (loader) |
| `umts_ramdump0` | 225 | DUMP | — | CP RAM dump | 0600 root |
| `multipdp` | 0 | dummy | — | flow control, `waketime` | 0600 root |
| `rmnet0-3` (net) | 10-13 | RAW, no link header | 256 × 2048 | bare IP | — |

Attributes: `mif,link_attrs = 0x3C9` (no `XMIT_BTDLR` → `XMIT_BOOT` = `-EINVAL`) (BR §1.2).

**ioctls** (`_IO('o', n)` = 0x6Fnn):

| ioctl | Value | Use / return | Rule |
|---|---|---|---|
| MODEM_ON / OFF / RESET | 0x6F19 / 0x6F20 / 0x6F21 | §2.3 | OFF unconditional in the port |
| BOOT_ON / BOOT_OFF / BOOT_DONE | 0x6F22 / 0x6F23 / 0x6F24 | §2.6 | — |
| STATUS | 0x6F27 | `enum modem_state`; consumes a pending SIM change (7/8 once); NV_REBUILDING read as ONLINE | SIM presence is taken from PIN_STATUS NOTIs, never from 7/8 |
| DL_START / FW_UPDATE | 0x6F28 / 0x6F29 | `-EINVAL` if TX link is SPI | — |
| SET_TX_LINK | 0x6F37 | `int*`: 3 SPI, 10 LLI | — |
| GET / CLR_CP_BOOTLOG | 0x6F47 / 0x6F48 | `-EINVAL` on LLI | harmless |
| PROTOCOL_SUSPEND / RESUME | 0x6F25 / 0x6F26 | multipdp only; RESUME condition inverted | — |
| FORCE_CRASH_EXIT | 0x6F34 | → CRASH_EXIT | crash gate only |
| DUMP_START / DUMP_RESET | 0x6F32 / 0x6F36 | dump path | never for silent reset |
| **CP_UPLOAD** | 0x6F35 | stock `panic()` | **never issue**; port returns without panic |
| XMIT_BOOT | 0x6F40 | `-EINVAL` | — |
| MIF_LOG_DUMP | 0x6F51 | injects up to 512 KiB of log skbs into the **calling node's RX queue**, copies an `unsigned long` | port: root on `umts_boot0` only, else `-EPERM` |

**States**: OFFLINE 0, CRASH_RESET 1 (unreachable), CRASH_EXIT 2, BOOTING 3, ONLINE 4,
NV_REBUILDING 5, LOADER_DONE 6, SIM_ATTACH 7, SIM_DETACH 8.

**File semantics** (BR §2.4; LS2 §6.2; SYN): `write` on an IPC channel is refused with `-EPERM`
unless ONLINE, returns `-EBUSY` when 1024 skbs are queued (`MAX_SKB_TXQ_DEPTH`), and **truncates the
skb to the SBD uplink slot** (`skb->len = min(skb->len, rb->buff_size)`), returning the short payload
count; callers must loop (stock `IoChannel::Write` does) and the port keeps this (C54). `read` waits
≤ 100 ms and returns 0 when empty (logging "NO data in RXQ"), one frame per call with push-back: read
only after POLLIN, with a buffer ≥ the downlink slot (64 KiB is safe). `poll`: `POLLIN` in
BOOTING/ONLINE with data; `POLLHUP` on BOOT/FMT devices in CRASH_EXIT/CRASH_RESET/NV_REBUILDING or
with a pending SIM change. RX for an unopened device is dropped; the RX queue is purged only when the
open count reaches 0, never on a crash (stale frames survive a CP restart while the loader holds the
nodes; TR D5-2). `rild_ready` = `umts_ipc0` and `umts_rfs0` both open. Sources:
`link_device_memory_main.c:296-303`, `link_device_memory.h:205`, `modem_io_device.c:1009-1012,1340-1345,1414,1425-1451`.

**Sysfs**: `lli_control` show `MIPI-LLI %x\n` (0 unmounted, 1 mounted, 2 waiting); the port makes it
0444 without store (stock store commands 0 reg dump of 5430 tables, 1 init, 2 set master, 3 mount,
4 exit are debug-only and dangerous; KR D1-f). `cp_status/value`. `multipdp/waketime`.
**Debug**: `dflags` stock default has the FMT bit set and mode `S_IWUSR|S_IWGRP` (hex dumps of FMT
frames); the port compiles 0 with mode 0644 (SYN `modem_utils.c:69-71`; with 0, `log_ipc_pkt` dumps
nothing, KR D9). debugfs `svnet/mem_dump` dumps the shared region: payload (D9).

### 2.10 Post-download handshake and doorbells

| CP→AP | Doorbell | Kernel action | Source | Conf |
|---|---|---|---|---|
| `INIT_START` | 0xC1 | init SBD, `aligned = false`, reply `PIF_INIT_DONE` 0xCD | LS2 §7.1 | P |
| `PHONE_START` | 0xC8 | `start_pm`; if already IPC: `INIT_END` 0xC2 when `rild_ready`; else reset IPC map (0xAA, access 1), `INIT_END` + `cp_boot_done = 1` if `rild_ready`, link IPC, **`complete_all(init_cmpl)`** | LS2 §7.1 | P |
| (late path) | — | second of ipc0/rfs0 opened while `cp_boot_done == 0` → `INIT_END` | LS2 §7.1 | P |
| `CRASH_EXIT` / `CRASH_RESET` | 0xC9 / 0xC7 | link CP_CRASH / OFFLINE, force crash exit | LS2 §7.1 | P |
| repeats | — | the CP repeats `PHONE_START` until `INIT_END` | LS2 §7.1 | P (comment), I |

AP→CP value = cmd + 0x40 + 0x80; CP→AP command = value AND 0x3F when bit 0x40 is set. During BOOT
the CP signals 0x83.

### 2.11 IPC (FMT) framing and the messages the mission needs

| Item | Value | Source | Conf |
|---|---|---|---|
| Header | 7 B `{u16 len; u8 mseq; u8 aseq; u8 main; u8 sub; u8 type}`, `len` includes the header; = libsamsung-ipc `ipc_fmt_header`; userspace writes header + payload | IPC §0; FR Q1 | P |
| Protocol | `IpcProtocol41`, protover 2 | IPC §0 | P |
| Types | AP→CP EXEC 1, GET 2, SET 3, CFRM 4, EVENT 5; CP→AP INDI 1, RESP 2, NOTI 3 | IPC §0 | P |
| Sequencing | AP `mseq` increments, `aseq` 0; CP RESP/GEN `aseq` = request `mseq`; NOTI `aseq` 0. Reset `mseq` and drain stale RX at every CP restart (D5) | IPC §0; TR D5-2 | P / D |
| Acks | GET → RESP; EXEC/SET → `GEN_PHONE_RES` 80/01 R `{group, index, type, u16 code}`, 0x8000 = OK; EVENT → none; unimplemented GET → GEN | IPC §0 | P |
| Start-up | **P** (code): AP answers SMS_DEVICE_READY N with SMS_DEVICE_READY S and MISC_IPC_LOOPBACK (0A/23) with CFRM; no PIN_STATUS GET before the first PIN_STATUS NOTI; RIL request processing starts at PWR_PHONE_PWR_UP N (type NOTI). **I**: that the CP then sends PWR_PHONE_STATE N, SEC_PIN_STATUS N, SEC_SIM_ICC_TYPE N, SMS_DEVICE_READY N (inferred from handlers; not in any captured log) | IPC §10; RR §6.1#7; TR E4-E5 | P / I |
| Bring-up order | PWR_PHONE_STATE E 0x0202 (0x0001 LPM); NET_REGIST G (domain 2 CS / 3 PS); NET_SERVING_NETWORK G; DISP_ICON_INFO G; SEC_PIN_STATUS / SIMAPPS_INFO G; NET_MODE_SEL G then S (bitmask, LTE+WCDMA+GSM = 0x0B); GPRS_LTE_ATTACH_APN_INFO S | IPC §10 | I-M |
| SMS | SEND_MSG 04/01 E {fmt 2, msg_type 2 single / 1 more-to-send, domain, len, SMSC+TPDU}; INCOMING 04/02 N; DELIVER_REPORT 04/06 E {2, u16 ack, id, 0} (ack 0 OK, 0x8080 memory full); SVC_CENTER_ADDR 04/0A; MEM_STATUS 04/0C | IPC §6 | P-H |
| Calls | OUTGOING 02/01 E 92 B (99-B frame; TON 0x21/0x11; p91); ANSWER 02/04, RELEASE 02/03 E; SS_MANAGE_CALL 0C/07 S 85 B; CALL_LIST 02/06 G; CALL_STATUS 02/05 N (1 dialing, 2 ignoring, 3 connected, 4 released, 5 connecting; no "alerting"); CALL_INCOMING 02/02 N (layout unverified); emergency = type 0x07; CALL_ECCLIST 02/16 N not decoded | IPC §5; TR D8-6 | P-H |
| Data | DEFINE_PDP_CONTEXT 0D/01 S 127 B; PDP_CONTEXT 0D/04 S 105 B (0x70-byte frame; flags p2-p5, user p6, password p38, auth p102); IP_CONFIGURATION 0D/09 N (IPv4 p3, DNS p7/p11, IPv6 p35, MTU p152 when flag 0x2000); CALL_STATUS 0D/10 N; LTE_ATTACH_APN_INFO 0D/14 S 194 B | IPC §8; TR D5 | P-H |
| Secrets in frames | PIN/PUK: SEC_PIN_STATUS S p3-p18, CHANGE_LOCKING_PW p3-p80, PHONE_LOCK S p3-p41; APN passwords: PDP_CONTEXT p6-p69, LTE_ATTACH_APN_INFO p127-p190 | TR D9-1 | P-H |
| libsamsung-ipc reuse | layouts are prefixes for most messages; IPC 4.1 variants for RSIM_ACCESS, LOCK_INFORMATION, CHANGE_LOCKING_PW, NET_MODE_SEL, TIME_INFO, SND_AUDIO_PATH, BURST_DTMF, PDP_CONTEXT, GPRS_PS, IP_CONFIGURATION, NET_REGIST (the daemon encodes from the catalogue, D5) | IPC §12 | P-H |

### 2.12 RFS (`/dev/umts_rfs0`, ch 245)

| Item | Value | Source | Conf |
|---|---|---|---|
| Header | 6 B `{u32 length (whole frame, LE); u8 cmd; u8 id}`; not an FMT header (FMT 0x15 RFS_CMD is a stub) | RR §5.1 | P |
| Reassembly (CP→AP) | first chunk gives `length`; > 0x80000 dropped; append reads until complete | RR §5.1 | P |
| Replies (AP→CP) | one logical reply per request, same header, `cmd` echoed, **`id` echoed**; ret/errno replies 14 B `{hdr, i32 ret @6, u32 errno @0xA}`. The kernel truncates each `write()` to the 2048-B uplink slot and returns the short count; stock `IoChannel::Write` loops (retrying EINTR/EAGAIN with 10 ms sleeps) until done. The server loops the same way and also retries `-EBUSY`; the CP-side reassembly of the chunks is U22 | RR §5.1-5.2; SYN; TR D6-2 (libsec-ril 0xe1f78) | P (AP side), U (CP side) |
| Commands | 0x01 NV_READ_ITEM {off, size ≤ 0x80000}; 0x02 NV_WRITE_ITEM; 0x03 READ_FILE {fd, size}; 0x04 WRITE_FILE; 0x05 LSEEK → 18 B; 0x06 CLOSE; 0x07 PUT_FILE; 0x08 GET_FILE; 0x09 RENAME; 0x0A GET_FILE_INFO → 32 B; 0x0B UNLINK; 0x0C MAKE_DIR; **0x0D-0x10, 0x12: no reply**; 0x11 OPEN_FILE {flags, pathlen, path} → {fd, errno}; 0x13 GET_HANDLE_INFO; 0x14 CREATE_FILE; 0x15 NV_WRITE_ALL_ITEM; 0x16 NV_BUFFER_MESSAGE; 0x17 NV_RESTORE | RR §5.2 | P |
| Stock quirks | READ_FILE clamps data and `n` to 0x40000 but computes `length` from the unclamped `n`; GET_FILE_INFO times are `localtime_r` | RR §5.2 | P |
| Paths | `..` → reject; `err*`/`/data/log*` → `/data/log/`; `Audio_OEM`/`Audio_IFX`/`CP_AUDIO_SLSI`/`RF_NVM` → `/system/etc/`; else `/efs/root/<path>`; dirs 0775, owner 1001:1000; CP flags passed through + O_SYNC; handles are raw AP fds | RR §5.3 | P |
| Stock files | none of the `/system/etc` names exist in the stock `/system` listing; `/efs/root` held one small file | SYN (names); COORD | P |
| NV semantics | byte windows into `nv_data.bin`; stock re-checks MD5 before writes, rewrites `.md5` after; backups on writes at 0x180014/0x181469 (outside 1 MiB: never here) | RR §5.4 | P |

### 2.13 NV facts

| Item | Value | Source | Conf |
|---|---|---|---|
| TOC NV row | offset 0 (no data in RADIO), load 0x47EE0000, size **0x100000** | CBD §3; RI §1 | P |
| Files | `/efs/nv_data.bin` 1 048 576 B, its backups and `.md5` files | COORD | P (sizes) |
| Core NV | `.nv_core.bak` = 0x85600 B = TOC OFFSET.size; OFFSET = [0x7AA00, 0x100000) of the NV; RIL's header checksum at 0x80000 lies inside | COORD + arithmetic | I (strong) |
| m9kefs1-3 | the three partitions have the same SHA-256 prefix `bb9f8df61474…`, which is the SHA-256 of 4 MiB of zero bytes (also the all-zero CDMA-RADIO image) → blank on this tablet | MS G0 hashes; RI §1; SYN (hash of zeros) | I (assumes 4 MiB partitions) |
| Boot delivery | stage 3 streams the whole 1 MiB raw to CP 0x47EE0000; BOOT does not parse or CRC it | RI §4 | P |
| Stock cbd | read-only open; on ENOENT **creates** a 0xFF file (O_RDWR, O_CREAT, O_SYNC, 0600); stock binary reopens O_RDWR; waits ≤ 5 s for `ril.cbd.rfs_check_done` | CBD §5; LS2 §8.1 | P |
| Stock RIL check | `.nv_state`; 16-bit header checksum at 0x80000; MD5(file + "Samsung_Android_RIL") vs `.md5`; restore from `.nv_data.bak`, `.nv_core.bak`, else **CreateDefaultNvData** (O_TRUNC, 0xFF, "default NV" from RADIO at the TOC NV offset = 0, rewrite `.md5`) | RR §3.2; CBD §3 | P (call sites), default source I |
| Our policy | never created or written; extracted on the Mac from a copy of the G0 raw EFS image (D4); stage 3 streams a verified in-memory snapshot | D4 | D |

### 2.14 Data path (rmnet)

| Item | Value | Source | Conf |
|---|---|---|---|
| Channels | rmnet0-3 = PDP_0-3 (ch 10-13), bare IP after the SIPC5 header | BR §5.4; KP §2.5 | P |
| cid mapping | interface n ↔ DataCall id n+1 (single-SIM branch) → cid 1-4 ↔ rmnet0-3 | IPC §8 (0x176348); TR D5 | P (AP rule); CP routing I |
| Netdev type | stock `ARPHRD_PPP`; port **`ARPHRD_RAWIP`** (519), `IFF_POINTOPOINT`, `IFF_NOARP`, `NET_NAME_PREDICTABLE`; `rmnet_type=ppp` A/B parameter | KP §2.5; LV §2 | P (gap), D |
| MTU | **min(IP_CONFIGURATION MTU, 1500)**: rmnet uplink slots are 2048 B and longer skbs are silently truncated | SYN `modem-ss333-pdata.dtsi:114-117`, `link_device_memory_main.c:301`; TR D7-7 | P |
| PDP sequence | LTE_ATTACH_APN_INFO S → DEFINE_PDP_CONTEXT S → PDP_CONTEXT S → GEN → CALL_STATUS N up + IP_CONFIGURATION N → rmnet(cid−1); teardown PDP_CONTEXT action 0. Whether PDP activation is needed after an LTE attach (default bearer) is U23 | IPC §8; TR §8 | I-M |
| Network manager | NetworkManager 1.58.1 (wpa_supplicant backend) | IMG:44; `image/rootfs/configure-system.sh:128-132` | P |

### 2.15 Voice audio

| Item | Value | Source | Conf |
|---|---|---|---|
| Codec | WM1814 = WM8998 variant; `gts28_wm1814.c` covers AIF1 only; it starts MCLK1 and FLL1 on BIAS_OFF → STANDBY, so FLL2's reference exists before a c2c PRE_PMU | LV §4; VA §0; TR D8 | P |
| Stock mixer | `mixer_paths_rev09.xml`; speakerphone uplink = sub mic IN1R (bias gpr3-2 + MICBIAS3) | VA §0.1, §1.4 | P |
| AIF2 format | I2S, NB_NF, no TDM; CP is clock provider (codec `CBC_CFC`); 8 kHz → BCLK 256 kHz, 16 kHz → 512 kHz (2 × 16-bit slots); RX uses AIF2RX1 on both interpolators; TX duplicates the mic | VA §2 | P (slot use from paths; margins U) |
| Clocks | SYSCLK = FLL1 49.152 MHz; ASYNCCLK = FLL2 49.152 MHz, REFCLK = MCLK1 24 MHz + SYNC = AIF2BCLK; `SAMPLE_RATE_1` = 48 kHz; `ASYNC_SAMPLE_RATE_2` = 48 kHz; `ASRC RATE 2` = ASYNC rate 2; `ISRC2 FSH` = ASYNC rate 2 (value 9), FSL = ASYNC rate. These four rates never change for voice and do not affect AIF1: the machine driver writes them once (D8) | VA §2; TR D8-2 | P |
| Mainline gaps | no `ASRC RATE 2`/`ASYNC Sample Rate 2` controls; `ISRC2 FSH` lacks value 9; `wm8998_asrc_ev` returns `-EINVAL` on reset values and DAPM enables the widget anyway; `SAMPLE_RATE_1` resets to 8 kHz | VA §3 | P |
| SND IPC | 09/01 SPKR_VOLUME_CTRL S {type 0x01/0x11/0x31/0x41, level}; 09/02 MIC_MUTE_CTRL S; **09/03 AUDIO_PATH_CTRL S 2 B {path, extra}** (9-byte frame): 0x01 handset, 0x02 headset, 0x04 BT, 0x05 stereo BT, **0x06 speaker, 0x07 headphone**, 0x08 BT NR-off, 0x09-0x0E …, out of range → 0x01; 09/08 RINGBACK_TONE N (play local ringback); 09/09 CLOCK_CTRL **E** {0 stop, 1 start} (8-byte frame; libsec-ril never sends STOP during an active call); 09/09 N {1..7, odd = on, NOTI only}; 09/0A WB_AMR_RPT N; 09/0B TWO_MIC, 09/0D AUDIO_MODE, 09/0E CLOCK_MODE | IPC §9; TR D5, D8 (0x33cc re-read) | P-H (report semantics I) |
| What the path byte does | AIF2 carries one PCM stream whatever the byte; the physical output is chosen by codec routing (UCM). The byte selects the CP's processing set (gains, AEC/NS tuning) | TR D8-5; VA §1.3, §2 | I (strong) |
| Stock HAL order | IN_CALL → wait CP clock-enable unsolicited → open voice PCMs → paths, path + volume → at end close PCMs, reset mixer, then stop-clock IPC | VA §6.1 | I-M |

### 2.16 Stock runtime evidence: LLI power management

From the private stock dmesg (686-942 s, LLI PM lines only, SYN, re-checked by KR): FSM active
(stock never writes `pm_enable`; the parameter defaults to 1 and is `S_IRUGO`,
`link_device_lli.c:41-42`). 25 mounts and 26 unmounts in 256 s; link up 0.31-0.97 s (median 0.48 s);
mount-to-mount interval 0.415-32.16 s (**median 2.83 s**); down-time 0.036-31.8 s (median 2.46 s).
The release is a CP-led handshake: the CP lowers CP2AP_WAKEUP (`ACTIVE→AP_FREE`); the AP drops
AP2CP_WAKEUP after `CP_HOLD_TIMEOUT` (~100 ms) with no pending TX (`→CP_FREE`); only then does the CP
lower CP2AP_STATUS (`→UNMOUNTING`, `HIBERN8_ENTER_DONE`, `Unmount`) (`link_device_pm.c:499-545`).
**0 of 26 unmounts happened while the AP held the link.** Remounts start with `CP2AP_WAKEUP_HIGH →
RESETTING` (10 spontaneous, 15 after an AP `CP_HOLD_REQUEST`); `RESETTING → MOUNTING` re-asserts
AP2CP_STATUS after `LINK_RESET` with 500 ms watchdogs, and `UNMOUNTED` releases it
(`link_device_pm.c:473-477,590-602`). In all 25 remounts `CP2AP_STATUS_HIGH` is logged 1.8-2.0 ms
after `HIBERN8_EXIT_DONE` and within 0.1 ms of `Mount intr` (8 before, 17 after): the CP raises
CP2AP_STATUS at mount completion. 8 AP suspends completed. LineageOS writes `pm_enable 0` from its
rc files, but the parameter is 0444, so the write very likely failed (I).

### 2.17 Desktop image and precedents

| Item | Value | Source | Conf |
|---|---|---|---|
| Packages | WirePlumber **0.5.13** (the voice-call fix for `unknown`-availability profiles is in 0.5.15); NetworkManager 1.58.1; python-gobject; no ModemManager, GNOME Calls, Chatty or callaudiod installed | IMG:38,44; MS; LV §4 (0.5.15 note) | P |
| ALARM armv7h | modemmanager/libmm-glib 1.24.2, gnome-calls 51.1 (depends on callaudiod), chatty 0.8.9, python-gobject 3.58.1, python-dbus-next 0.2.3, wireplumber 0.5.13 | TR §7 (package pages, 2026-10-29) | I (reviewer-read) |
| Shell consumers | `omamobile-shell` bar runs `omamobile-cell-watch` (cellular icon) and a call chip, and had a "Mobile data" tile; the tablet patches turned them off (`cellWatch`/`callWatch` false; tile removed) | `image/pkg/omamobile-shell/0004-tablet-quiet-pollers.patch`, `0001-tablet-quick-settings-tiles.patch` | P |
| ModemManager bridge precedent | omarchy-mobile's `omamobile-mmd` 0.1.0 (MIT, Python/PyGObject Gio) owns `org.freedesktop.ModemManager1` over its modem daemon's socket; offline conformance: mmcli, GNOME Calls 51.1, Chatty 0.8.9, 43 checks pass; found that listing `org.freedesktop.DBus.*` in `GetManagedObjects` crashes Calls | private copy of the omarchy-mobile plan (`modem-research-scratch-20261030/web/cheetah_modem_plan.md:2336-2397`); TR D7-1 | P (as reported there) |
| Client contracts | GNOME Calls and WirePlumber follow call state through `Call.StateChanged`, not `PropertiesChanged`; WirePlumber's module does not handle object removal or `CallDeleted` of an active call; active states DIALING, RINGING_OUT, ACTIVE | TR D7-4, §3.2 (upstream sources) | I (reviewer-read) |

### 2.18 Hardware observations so far (live mission, MS, 2026-10-29)

| Gate | Observation | Conf |
|---|---|---|
| G0 | EFS, m9kefs1-3, RADIO, CDMA-RADIO, PARAM set `blockdev --setro`; raw images on the Mac, SHA-256 equal on tablet and Mac; RADIO = the known hash | P |
| G1 | TOC CRCs OK on the device (BOOT 0x5DB1F04C, MAIN 0x1E71169C); CMU_CPIF: `SRC_SEL_CPIF0` 0x1, **`SRC_SEL_CPIF1` 0x0** (symbol muxes on oscclk), DIV 0x34, `ENABLE_IP_CPIF0` 0x000FFFFE, `ENABLE_IP_CPIF1` 0x37F; PMU 0x720 = 0; **`div_aclk_cpif_200` = 50 MHz** (stock 100); `fout_mphy_pll` 466 MHz, `sclk_mphy_pll` gated; pins as in §2.2; `/proc/iomem` shows 0xde000000-0xde7fffff as a separate 8 MiB RAM bank. `ENABLE_ACLK_CPIF`/`ENABLE_PCLK_CPIF` not yet recorded (G1+ go/no-go) | P |


### 2.19 Hardware results of the mission (2026-10-30)

Measured on the device with the `t715-modem` kernel series, `shannon-loader`, `shannond` and its
ModemManager facade (MS for the full log; operating summary in `docs/hardware/MODEM.md`). Every
row is **P** (mission hardware log). The innocuity hashes (EFS, `m9kefs1-3`, RADIO) never changed.

| Item | Result |
|---|---|
| SPI BOOT (U4) | accepted at 100 kHz, DMA, hardware auto-CS: 10 748 bytes in **1.29 s** (auto-CS idles ≈ 3-4 clocks per byte; mainline's s3c64xx DMA timeout had to take the vendor ×10 tolerance) |
| C25 / U3 | **resolved P**: `HIBERN8_EXIT_DONE: rx=3, tx=1` 22.6 ms after the SPI write, `Mount intr` 1.8 ms later, CP2AP_STATUS high 0.05 ms after the mount; `cp_status` = 1 implies the mount; `MIPI-LLI 1` already at B8 |
| U1, U28, U8 | mount on mainline clocks OK (`aclk_cpif_200` 100 MHz, symbol muxes, shared ref): mount ok 1, pa_err 0, AFC code 0xb saved at the first credited mount; no IRQ storm |
| Download | stage 0 answered at once; TOC 1 frame; MAIN 16 975 frames (34.7 MB) in 3.38 s, CRC check 3.3 s; NV 512 frames; FIN; **ONLINE 9.9 s after power-on** (U18: no ENOSPC) |
| Crash path (G12b) | FORCE_CRASH_EXIT → CRASH_EXIT after 171 ms (not the 10 s timer); POLLHUP to all holders; silent reset to ONLINE in ≈ 14 s; daemon restart contract as designed |
| U6, U22 | the CP opened `CP_AUDIO_SLSI.bin` and wrote the NV (NV_WRITE_ITEM up to 460 288 bytes) into the tmpfs sandbox; no CP complaint |
| Start-up IPC | PWR_PHONE_PWR_UP, SEC_SIM_ICCID/ICC_TYPE/PIN_STATUS, SMS_DEVICE_READY NOTIs seen; **the CP answers every SMS_DEVICE_READY SET with a new NOTI** (answer once per session); no MISC_IPC_LOOPBACK seen |
| Registration | NET_REGIST GET domains 2/3 as catalogued; NOTIs also carry **domain 1** for LTE (re-read both); LTE needs `GPRS_LTE_ATTACH_APN_INFO` before the attach (without it: accepted, then status 4/7, reject 0x0a, whatever the signal); UMTS registers in < 10 s; `NET_MODE_SEL` mask bit0 GSM, bit1 WCDMA, bit3 LTE confirmed |
| LTE (U23) | attach APN before radio on: LTE home in 16-20 s, 3 of 3, first connection in 0.3 s; tens of Mbit/s down, stable; band, 4G+ and calls or SMS on LTE not established (`docs/hardware/MODEM.md` §6.7) |
| Data (U23, U15) | cid 1 → `rmnet0`, IPv4 /32 + DNS + MTU 1500 from GPRS_IP_CONFIGURATION; **the first activation of a CP session fails with GEN 0x8005 and the CP then drops the definition (0x8001 until DEFINE is sent again)** |
| SMS (U24) | SMS-SUBMIT via SMS_SEND_MSG E → NOTI; SMS-DELIVER in SMS_INCOMING_MSG with the catalogued 6-byte header; SMS_DELIVER_REPORT answered by a NOTI, not GEN |
| SIM files | SEC_RSIM_ACCESS needs app selector 4 + the USIM AID (`A0000000871002` partial) for ADF files; selector 3 without AID returns 6A82/6986 |
| Calls (U19) | CS voice accepted: dialing → alerting → active → released; SND_CLOCK_CTRL NOTI (odd = on) and WB_AMR_RPT 0 (narrowband) at call start (U10) |
| Voice (U11) | FLL2 locks from MCLK1 and then on the CP's BCLK; ASRC1/2 lock; AIF2RX1 is the downlink slot; uplink and downlink proven through a voicemail deposit and playback; the CP's processing removes a stationary tone after ≈ 1.5 s |
| Forbidden | **SND_LOOPBACK_CTRL {02 06} stalls the CP's IPC until a power cycle** |
| Battery gate | the tablet runs at 44-48 °C on the desktop root while charging; the 40 °C gate then holds the CP off for long periods |

---

## 3. Contradiction log

| # | Topic | Source A | Source B | Resolution | Basis / settling experiment |
|---|---|---|---|---|---|
| C01 | LLI PM build and default | BR §3.5: `pm_enable=0` path | KP C-1, LS2 §5: FSM, `pm_enable = 1` | **B** | `link_device_lli.c:41-42,221-233`; stock dmesg (§2.16) |
| C02 | Is "link held up" safe? | KP: hold the link | stock: CP-led release every ~3 s | **needs hardware**; D2 locked-on, F1/F2 | 0/26 stock unmounts while the AP held the link; G10 counters |
| C03 | LLI IRQ roles | BR: 184 = signal, `CPIF_LLI_SIG_IN0` | KP C-2: 184 link, 185 doorbell, TL status | **B** | SYN |
| C04 | `lli_control` writes | BR §3.2/§3.6: write `2`, `3` | RI, LS2, KP, CB: CP master, read only | **never write**; port makes it 0444 | RI 0xfd0; cbd v1 |
| C05 | Misc node count | BR: 11 | KP: 9 | **9** | SYN |
| C06 | NV size | cbd config 0x80000; RR offsets > 1.5 MiB; libsamsung-ipc 0x200000 | TOC 0x100000 | **0x100000** | COORD file size |
| C07 | RFS header | BR §5.3: FMT with RFS_CMD | RR §5.1: 6-byte header | **B** | `Nv::ProcessRfsPacket` |
| C08 | Record 4 | LS1: skip | RI, LS2, CB: FIN mandatory | **send FIN** | RI 0x1740-0x1a18 |
| C09 | SPI4 address | BR: 0x14d30000 | KD: 0x14d00000 | **0x14d00000** | stock DT |
| C10 | SPI link role | BR: inactive | KP C-7, CB: carries BOOT | **B** | S6 trace |
| C11 | Image path | BR: image over LLI, one FW_UPDATE | LS2, RI: BOOT over SPI, stages over LLI | **B** | `img_info` unused |
| C12 | NV delivery | BR §4: RFS | LS2, CB: stage 3 | **B** | cbd v1 |
| C13 | STD_UDL | BR §5.1: unused | LS2, CB: used | **used** | — |
| C14 | `ss333_off` wait | BR: low | KP C-5: high | **high** | SYN |
| C15 | Reservation file | BR: espresso | KP: universal | **B** | defconfig |
| C16 | What BOOT_OFF waits for | BR, CB, REP: rild's opens | LS2: `PHONE_START` only | **B** | kernel code |
| C17 | When to open ipc0/rfs0 | KP S7, BR §3.6: before BOOT_OFF | LS2: after BOOT_OFF | **B** (stock rild order) | RR §6.1 |
| C18 | NV missing / short | LS1, stock: create / pad | LS2: refuse | **refuse** | rule 4 |
| C19 | NV open mode | stock: reopen O_RDWR | LS2: O_RDONLY snapshot | **snapshot** | — |
| C20 | 0x6F47/48 | CBD, LS1: unknown | KD, CB: GET/CLR_CP_BOOTLOG | **named, harmless** | 8895/9810 kernels |
| C21 | Record skipping | CBD §6.1 intro | CBD §4, V1 | **process all** | V1 |
| C22 | Post-SPI call | CBD: undetermined; LS1: nothing | CB, LS2: wait `cp_status` | **wait** | V1 `util.c` |
| C23 | `-b s` | BR: storage | CBD, CB: SPI | **SPI** | S6 trace |
| C24 | `fn3`, device path | CBD: undetermined | CB: `MODEM_OFF`; driver path | **B** | V1 |
| C25 | `cp_status` vs mount order | KP S4/S5: separate stages | RI: BOOT mounts before the sideband pulse | **resolved I (strong)**: `cp_status` = 1 implies the mount; G5 confirms | stock runtime: CP2AP_STATUS_HIGH within 0.1 ms of `Mount intr` in 25/25 remounts (§2.16). If B8 times out, read the LLI IRQ log before blaming SPI |
| C26 | RFS needed for boot | IPC §10: required | LS2, CB: ONLINE independent | **ONLINE independent**; CP health U | G9b/G10 observe log |
| C27 | Audio path bytes | VA, LV: 0x07/0x08 | IPC §9, TR re-read at 0x33cc: 0x06/0x07, 2 B | **0x06/0x07** | evidence at G20 = GEN 0x8000 + echo/level comparison, not "audible output" (C53) |
| C28 | SND numbering | VA §6.2: unproven | IPC §0/§9 | **proven** | vtable |
| C29 | Path payload size | LV: 5-byte OEM | VA: 6-byte OEM | OEM 6 B; **IPC 2 B** | `secril-client.cpp`; IPC §9 |
| C30 | Can the AP brick the CP? | CB Q6, REP: no NV write path | RI §2.8: eFuse programming | **RI** | rules 1, 12 |
| C31 | MAIN CRC meaning | CB Q1 | RI §2.5 | **RI** | — |
| C32 | OFFSET entry | CB, RI: speculative | COORD sizes | **I (strong)**: core NV | never stage 4 |
| C33 | Port approach | BR §7: rewrite, arm64 | KP: lift-and-shift, ARM32 | **KP** | — |
| C34 | Region placement | KD: dynamic | KP: static | **static** + guard (D3) | — |
| C35 | `cp_status` export | LS2: `gpiod_export` | KP: attribute group | **attribute group** | — |
| C36 | CRASH_RESET handling | CB | LS2 | moot (unreachable) | — |
| C37 | libsec-ril boots the CP? | BR | RR: `WaitForOnline` | **RR** | — |
| C38 | MODEM_ACTIVITY GETs | FR: unanswered | IPC: GEN | **IPC** | — |
| C39 | Voice on this SKU | AR gap | COORD props | **voice-capable firmware**; horizon U27 | G18 |
| C40 | Mixer source | generated UCM (`mixer_paths_0`) | VA: rev09 | **rev09** | — |
| C41 | Waiting for CP clocks | VA: stock HAL waits | LV: LineageOS never waits | **stock order**, START fallback | G20 |
| C42 | Pointer size | BR: arm64 | KP: ARM32 | **ARM32** | — |
| C43 | PM FSM "can be dropped" | BR §7 | C01 | design choice (D2) | — |
| C44 | rmnet control | BR: multipdp | FR, IPC: FMT GPRS | **B** | — |
| C45 | Remount cadence | mission brief: "every few hundred ms" | SYN (§2.16) | **measured values** (median interval 2.83 s; v1's 3.0 s was the upper median) | DM |
| C46 | Mapping default | KP §0.1/§2.6: `ioremap_wc` | v1/v2 D3: `device` first | **D3**, with the corrected rationale (Device keeps stock alignment and removes merging; it does not remove the need for barriers) | KR D3-d |
| C47 | Hang outcome | KP R-4: ends in the AP watchdog | DEPLOY §13: kernel pings, system frozen | **both happen**; rule 13 covers both | DEPLOY |
| C48 | CP_ON after off | v1 §2.3/G11: stays high | D1: port drives it low | **port**: CP_RESET 0 then CP_ON 0; G11 checks `current_now` | KR E1 |
| C49 | LLI reset electrical state | v1 G3: CP_ON = CP_RESET = 0 | stock `ld->reset` always ran with CP_ON = 1, CP_RESET = 0 | no stock precedent for G3's state; acceptable (AP slave stays in HIBERN8), but G3 consumes the first-boot AFC: reboot after G3 | KR C49, D1-c |
| C50 | `pfn_valid` on no-map | KP §2.1: false | ML `init.c:126-145`: true on ARM32 | **ML**; no design change (`ioremap` decides on map memory) | SYN |
| C51 | Blocklist duration | v1 rule 15/D1: until G9 | v1 G9 row: after G10 | **until G11** | KR E10 |
| C52 | samsungipcd data path | LV §1: forces PPP | FR Q5: PPP bypass on `rmnet0` since 0.3.0 | **FR**; rejection of samsungipcd stands for missing SIM unlock, hold/multiparty, USSD, volume | TR D5-3 |
| C53 | What the path byte selects | v1 C27/G20: output (diagnose "wrong output") | AIF2 is one PCM stream; output = codec routing | **CP processing set** | TR D8-5 |
| C54 | RFS reply framing | RR §5.1, v1 §2.12: one `write()` | kernel truncates to the SBD slot and returns a short count | **short-write loop**; keep the kernel behaviour; mocks emulate it | SYN `link_device_memory_main.c:301`; TR D6-2 |
| C55 | Call-profile switching | VA §5, v1 G21: WirePlumber ≥ 0.5.15 assumed | image ships 0.5.13 | package ≥ 0.5.15 (or override, `wpctl` fallback) | IMG:38 |
| C56 | callaudiod | LV §4, VA G21: disable it | gnome-calls hard-depends on it for speaker/mute | **CallAudio-compatible service** in `shannond`; mask callaudiod | TR D8-4 |
| C57 | Start-up announcements | IPC §10 / v1 §2.11: P | evidence is handler code only | replies and gates P; announcement order I | TR E4-E5 |
| C58 | Network manager | v1 D7: to check | image | **NetworkManager 1.58.1** | IMG:44 |
| C59 | `lli_control` store | v1 D1: keep store `0` | store `0` dumps 5430 CMU tables the port drops | **0444, no store** | KR D1-f |
| C60 | Link-PM fallback F1 | v1 D2: one `mipi_lli_reset()` | stock remount is a handshake (AP2CP_STATUS released at UNMOUNTED, re-asserted after LINK_RESET) | **replay the handshake** | KR D2-a; `link_device_pm.c:473-477,590-602` |
| C61 | LLI module and `allow_hw` | v1 D1: `allow_hw = 0` blocks every side effect | platform core applies assigned clocks and pinctrl before probe; probe enables gates | loading the LLI module **is** a hardware access: separate gate G2b | KR D1-b; SYN |
| C62 | Reservation proof | v1 D3/G2: `OF: reserved mem:` line | a failed reservation prints the same line | check for the `failed to reserve` line, `/proc/iomem`, `region_intersects` at probe | KR D3-b; SYN |

---

## 4. Design decisions

### D1. Kernel architecture

| | |
|---|---|
| **Options** | (a) minimal rewrite; (b) lift-and-shift the vendor code into two modules, as an in-tree patch series; (c) out-of-tree modules + DT overlay; (d) upstream redesign (wwan/mailbox/remoteproc) |
| **Decision** | **(b)**. Side series `kernel/patches/t715-modem/` on `t715-bringup`, commits local: CMU_CPIF IDs 12-25 and clocks, PMU define; `exynos5433-mipi-lli.ko`; `sec_modem_v1.ko`; `exynos5433-gts28ltexx-modem.dtsi`; config fragment (`CONFIG_SPI=y`, `SPI_S3C64XX=m`, `MIPI_LLI=m`, `SEC_MODEM_V1=m`). Keep 3.10 directory names for `diff -ru` review. |
| **ABI** | `modem_v1_uapi.h` unchanged, plus: rmnet `ARPHRD_RAWIP`; `CP_UPLOAD` without panic; `modem_off` unconditional (CP2AP IRQs off, CP_RESET 0, CP_ON 0); SIPC5 padding pinned to 4; SPI link fixes (strip the real header length or refuse > 0xFFFB, real errno, free skb); `lli_control` 0444 without store (debug commands, if any, in debugfs under `allow_hw`); **keep the SBD uplink truncation semantics** (short count, `-EBUSY`); `dflags` compiled 0, mode 0644; `MIF_LOG_DUMP` only for root on `umts_boot0`. |
| **`allow_hw`** | bool, default 0, with a `set` callback. At 0: GPIOs requested `GPIOD_ASIS`, no modem-side line driven, no IRQ requested on modem pins; side-effecting ioctls, `write()` and debugfs actions return `-EPERM`. **0→1** (state OFFLINE only): `gpiod_direction_output(…, 0)` on CP_ON, CP_RESET, PDA_ACTIVE, AP_DUMP_INT, AP2CP_STATUS, AP2CP_WAKEUP, IPC_INT2CP in this order (stock probe order), then request the PHONE_ACTIVE and CP2AP IRQs **disabled**, log the pin registers. **1→0** refused unless OFFLINE. |
| **LLI probe side effects** | stated, not hidden: assigned clocks (mux parents, 100 MHz), gate enable, `DME_LLI_INTR_*` clear; both IRQs (184, 185) requested with `IRQF_NO_AUTOEN` and enabled only after clocks and PMU; tested alone at G2b. |
| **M-PHY AFC** | replace both `is_first` statics by `phy->afc_valid`: AFC branch while it is false; set `afc_valid` and `afc_val` only at a `MOUNT_DONE` that obtained DL credits. Until O8 and the bench prove it: **reboot between G3 and G4**, and `--attempts=1`. |
| **Tripwires** | (i) SPI link: while the TX link is SPI, exactly one write per `MODEM_ON` (or per `DUMP_RESET` in the opt-in dump tool), of exactly 0x29FC bytes with CRC32 = `boot_crc` (parameter, default 0x5DB1F04C); anything else → `-EPERM` + `dev_err`. (ii) Remap/mount interlock (D3). |
| **Other kernel changes** | `RESET_ON_ERROR_SENT`: W1C before the soft reset, plus a reset rate limit; CP2AP IRQs disabled before any CP power change and guarded against storms (D2); `modem_suspend()` returns `-EBUSY` unless OFFLINE (and the mission masks `sleep.target`/`suspend.target`); ring copies through `memcpy_toio`/`memcpy_fromio` with `make C=1` clean; no `panic`, `BUG`, `machine_restart`, `emergency_restart` (checked on the object code). |
| **Dropped in phase 1** | link-PM FSM (replaced by locked-on, D2); ARGOS; `queue_work_on(7)`; `boot_device_spi.c`; IOSM/NAPI/SHMEM/C2C/HSIC/XMM/SS300; `set_fs` helpers; trace events; 5430 register-dump tables, loopback, `lli_control` store; `lpcharge`; `compat_ioctl`. **Kept**: debugfs `svnet/mem_dump` (payload, D9), new debugfs `ss333/status`, `ss333/lli_reset`, `ss333/canary`; `.shutdown`; no `remove()`, no `module_exit`, `suppress_bind_attrs`. |
| **Module iteration** | `CONFIG_LOCALVERSION_AUTO=y` changes the release string with every commit, and the initramfs replaces `lib/modules/<rel>` when BOOT's module tarball changes (`boot/initramfs/init:845-873`). Module-only fixes: build with `make M=` in the **same O= tree** that built the BOOT kernel, install under `/lib/modules/<rel>/updates/`, `depmod`, record `modinfo -F vermagic`. DT or clock changes need a new BOOT image. |
| **Blocking autoload** | the modules are blocklisted in `/etc/modprobe.d/` **and** by the BOOT knob `t715.modblacklist=exynos5433_mipi_lli,sec_modem_v1,spi_s3c64xx` before the first boot of a modem BOOT image, until G11 passes (rule 19). |
| **Rationale** | The vendor code is the only implementation proven against this CP firmware; keeping it verbatim confines risk to ~2.3 kLOC of drift. (c) fails because a `reserved-memory` region must be in the boot DTB (memory handed to the page allocator cannot be reserved later), the CMU_CPIF clocks are `CLK_OF_DECLARE` built-ins, and mainline has no userspace overlay loader (the v1 "no `__symbols__`" argument was weak: we build the DTB). (d) breaks the cbd-compatible ABI. The review added the hardware-facing guards that the vendor code lacked (AFC, remap, SPI payload, `allow_hw` transitions). |
| **Evidence** | KP §0-§4; KR D1; KD Q2; HO; SYN (AFC, remap, probe ordering). |

### D2. LLI power management

| | |
|---|---|
| **Options** | (a) FSM with `pm_enable = 1` (stock); (b) FSM with `pm_enable = 0` (`LOCK_ON`); (c) no FSM, ~80-line locked-on PM |
| **For (a)** | stock configuration; saves power. |
| **For (c)** | the stock release is a CP-led handshake in which the AP's hold is the second step: 0/26 unmounts while the AP held the link (§2.16; `link_device_pm.c:499-545`); stock pin behaviour up to `PHONE_START` is identical in both modes (`:388-394,809-820`); the FSM's 1 317 lines of level-flipping GPIO IRQs and workqueues would multiply failure modes at the riskiest gates. |
| **Against (b)** | with the FSM locked, `unmount_cb` stays registered and the LLI driver no longer re-arms after an unmount: dead link. |
| **Decision** | **(c) for phase 1.** Probe: nothing driven (`allow_hw`). `ss333_boot_on`: AP2CP_STATUS = 1, AP2CP_WAKEUP = 0. `start_pm` (from `PHONE_START`): AP2CP_WAKEUP = 1, AP2CP_STATUS = 1, hold a wakeup source. `stop_pm` (from `ld->off`): **disable both CP2AP IRQs first**, then lower AP2CP_WAKEUP/STATUS (stock leaves them: deliberate deviation), relax. `link_active()` = `cp_status` and `LLI_MOUNTED`. CP2AP_WAKEUP/STATUS: edge-both IRQs, requested disabled at the `allow_hw` 0→1 transition, enabled after `ss333_on`, **logged and counted, not acted on**; storm guard > 1000 edges in 1 s → `disable_irq_nosync` + one log line; counters in debugfs. On `LLI_MOUNTED`, wake TX waiters. `pm_mode=lockon` is the only phase-1 value. |
| **Fallback** | F1 (only if G10 counts an `Unmount`): replay the stock remount handshake, not a bare reset. On `INTR_LLI_UNMOUNT_DONE` the LLI driver has already re-armed itself. The PM code lowers AP2CP_STATUS and AP2CP_WAKEUP (stock `UNMOUNTING → UNMOUNTED`). On pending TX or a CP2AP_WAKEUP rise it raises AP2CP_WAKEUP and waits ≤ 500 ms for CP2AP_WAKEUP high, calls `mipi_lli_reload()`, raises AP2CP_STATUS at `SW_RESET_DONE`, waits ≤ 500 ms for `LLI_MOUNTED` (`remap_ok` still required). One try per event, ≥ 1 s apart; on failure CRASH_EXIT and the supervisor's silent reset. F2: if F1 fires more than once per hour, or for battery in phase 2, port the FSM verbatim with `pm_enable = 1`. Both prepared offline, compiled out by default. |
| **G10 signals** | count `Unmount`, `HIBERN8_ENTER_DONE`, `PLU_DETECT`, CP2AP_WAKEUP falling edges and `Error sent`: CP2AP_WAKEUP low with no unmount means the CP tries to sleep and is refused (power argument for F2). |
| **Cost accepted** | higher idle power during bring-up; sessions bounded by rule 23. |

### D3. Shared memory placement and mapping (ARM32)

| | |
|---|---|
| **Decision** | `reserved-memory` **`cp-shmem@de000000`, `reg = <0xde000000 0x800000>`, `no-map`**, plus **`cp-guard@de920000 { reg = <0xde920000 0x60000>; no-map; }`**, so all DRAM from 0xde000000 to the end of DRAM is no-map (0xde800000-0xde91ffff is already the no-map ION carveout). The base is 0xde000000; any other base needs `shmem_unsafe_base=1`, owner approval and all DRAM in [base, min(base + 256 MiB, DRAM end)) no-map. Mapping parameter `shmem_map` (`device` or `wc`): **phase-1 default `device`**, `wc` only after G17 and a ring-stress A/B. `dma_wmb()` before every producer index store and before the doorbell, `dma_rmb()` after every consumer index load, in both modes. `%pa` prints; checked `(u32)` cast into `exynos_lli_cal_remap`. |
| **Interlocks** (per boot, in the kernel) | (1) The LLI probe binds only if `memory-region` is base 0xde000000, size 0x800000 (or the unsafe-base conditions), `size == 2^n`, `base % size == 0`, and `region_intersects(base, size, IORESOURCE_SYSTEM_RAM, IORES_DESC_NONE) == REGION_DISJOINT` (exported, `ML/kernel/resource.c:629-640`). (2) At every `INTR_SW_RESET_DONE` the driver reads back `IAL_LL/BE_INIT_ADDR_REMAP` and PMU 0x720 and sets `remap_ok`; a setting error clears it. (3) On `HIBERN8_EXIT_DONE` the hard IRQ writes `LLI_MOUNT_CTRL` only if `remap_ok`, else logs `lli: mount refused (remap %08x/%08x)`. (4) `ss333_on` waits ≤ 100 ms for the `SW_RESET_DONE` of its own `ld->reset` and releases CP_RESET only if `remap_ok`; otherwise CP_ON → 0 and `-EIO`. Any refusal ends the session (rule 12). |
| **Checkpoints** | G2a: no `failed to reserve memory for node 'cp-shmem@de000000'` (or `cp-guard`) line; no System RAM in [0xde000000, 0xde980000) in `/proc/iomem` (the `OF: reserved mem:` line alone proves nothing, C62). G3: both remap registers 0x0001BC97, `remap_ok = 1`. G5, G7, G8 (`--stop-after=nv`): canary in the guard and in the upper 4 MiB of the region unchanged (debugfs `ss333/canary`, filled before B2). |
| **Rationale** | Static placement is reproducible and equals the inferred stock address in the stock ION hole; the guard removes the only ordinary RAM above it, so even a non-masking IAL window (U2) cannot reach live kernel memory upward. `no-map` removes the cacheable alias and makes `ioremap` legal on ARM32. `device` keeps the stock alignment semantics (stock mapped strongly-ordered) and removes write merging, which takes one variable out of G7-G12; it does **not** order accesses across the region, so the barriers stay (C46). |
| **Evidence** | KP §2.4, §2.6, §3.1; KR D3; RI §2.4, §2.7; BL; SYN. |

### D4. The loader

| | |
|---|---|
| **Decision** | **C11, one long-running `shannon-loader`**, GPL-2.0-or-later, written from LS2 (cbd v1 as behavioural reference only). Phases: preflight → boot attempt (B1-B17) → online (holds `umts_boot0`, `umts_ipc0`, `umts_rfs0`; `sd_notify READY=1`; publishes a CP session number and state, e.g. `/run/shannon/cp-state`, for the daemons) → supervisor (`POLLHUP` → STATUS 2/1/0 → silent reset = `MODEM_OFF` + full boot; ≤ 5 per 30 min; never `DUMP_RESET`, `CP_UPLOAD`, `FORCE_CRASH_EXIT`). Rungs `--stop-after={preflight,power,spi,lli,stage0,toc,main,nv,fin,online}`. Exit codes 0/2/3/4/5/6/7. All device I/O behind an injectable ops table; logs never contain NV bytes. |
| **BOOT bytes** | read once in preflight into a locked buffer; CRC32 0x5DB1F04C **and** a SHA-256 of the 0x29FC-byte slice pinned in the loader's config (computed offline from the backed-up `radio.img`); B7 writes that buffer; the kernel tripwire (D1) is the second line. |
| **eFuse settle** | after `cp_status` = 1, no `MODEM_OFF` until `0xA00D` or 10 s, whichever comes first (KR proposed 3 s; 10 s because the program-cycle duration is U and waiting costs nothing). |
| **Attempts and unit** | `--attempts=1` through G9 (AFC, D1); afterwards ≤ 3 per start. The systemd unit (`Type=notify`) is installed **disabled** until G11 passes. |
| **Preflight guards** | refuse unless `/sys/module/sec_modem_v1/parameters/allow_hw` = `Y`; if `cp_status` = 1 before B2, a CP is alive from an earlier session: log and `MODEM_OFF` first. |
| **NV policy** | default: `nv_data.bin` (+ `.md5`) extracted **on the Mac** from a **copy** of the G0 raw EFS image (`e2fsck -n` first; if a journal needs replay, replay it on a second copy; `debugfs -c -R 'dump …'`), handled as opaque bytes (hashes only, never printed or parsed), compared by hash with the TWRP EFS backup, pushed to `/var/lib/shannon/nv/` (root, 0400) with a SHA-256 manifest. The tablet never mounts EFS (fallback only with owner approval: `blockdev --setro` + `mount -o ro,noload`). Opened `O_RDONLY + O_NOFOLLOW + O_CLOEXEC`; exact size; all-0xFF/all-0x00 refused; whole file in memory before B2; MD5 advisory check against MD5(nv) and MD5(nv + "Samsung_Android_RIL"). No code path creates, truncates, pads, renames or deletes any EFS file. |
| **Offline tests** | O3 (unit + C mock + virtual clock, golden transcript, fault matrix), O4 (CUSE device backed by the O2 ring harness and CP model: loader → real ring code → CP model, golden transcript end to end), tripwires (forbidden ioctls, `lli_control` writes, LD_PRELOAD on EFS write flags). |
| **Rationale** | C matches the ABI header and runs in rescue contexts; a pinned in-memory BOOT and a verified NV snapshot make "only stock bytes" and "never write NV" structural. |

### D5. Telephony daemon

| | |
|---|---|
| **Options** | C: native IPC 4.1 daemon; A1: stock rild/libsec-ril in a bionic chroot (oracle); A2/B: rebuilt libril / HIDL container; AT on `umts_router`; samsungipcd |
| **Decision (order)** | **1. Native.** `shannond` (**Python**, memory-safe for CP-controlled input; FMT traffic is tens of frames per second) encodes from the IPC catalogue with golden vectors (libsamsung-ipc only as reference). It starts as `ipc-probe` (G9b: passive header log + mandatory replies) and grows. **2. One-shot AT probe** (G13, root, own gate, transcript private, report "answered/silent" only). **3. A1** only as a conditional oracle (G22). samsungipcd rejected (no SIM unlock, hold/multiparty, USSD, volume; every IPC 4.1 delta to patch into libsamsung-ipc; its PPP bypass exists since 0.3.0, C52). |
| **Precedent** | omarchy-mobile (Omarchy + Hyprland, Arch Linux ARM, Pixel 7 Pro) runs the same split: one modem daemon, `omamobile-mmd` as ModemManager-API bridge (§2.17). Its modem protocol (SIT) differs; the MM layer does not. |
| **Restart contract** | the loader holds `umts_ipc0`/`umts_rfs0` across CP restarts, so RX queues are not purged on a crash and STATUS consumes SIM events. On `POLLHUP` the daemon calls STATUS; on 2, 1 or 0 it (1) turns `Modem RX/TX Switch` off, (2) ends calls (`StateChanged → TERMINATED`, then `CallDeleted`) and bearers (`Connected = false`) on D-Bus, keeping the modem object path, (3) drains its RX queue until `read` returns 0, (4) resets `mseq`, (5) waits for the loader's next session READY, (6) discards everything before the next PWR_PHONE_PWR_UP NOTI, then re-syncs with GETs (PIN, REGIST, CALL_LIST). SIM presence comes from SEC_PIN_STATUS NOTIs only. A daemon restart while ONLINE changes nothing on the CP (G12c). |
| **A1 conditions** | throwaway chroot on tmpfs, own network namespace with `rmnet0-3` moved in (libsec-ril configures addresses and routes itself); `/efs` is a copy whose `nv_data.bin` is byte-identical to the loader's snapshot; RADIO read-only; our loader boots the CP; our daemons stopped; property service, inherited sockets, uid 1001, a client that never disconnects, own process group, CP reboot on rild exit; owner approval; captures private. |
| **Rationale** | The catalogue gives P-H layouts for everything needed; ztOS and omarchy-mobile reached data/SMS with their own clients; A1 needs a writable `/efs` with NV repair, a property store, and crashed under oFono on the other Exynos 5433 tried. |

### D6. RFS server

| | |
|---|---|
| **Decision** | **Separate process `shannon-rfsd`** (Python), started at the loader's READY (requests that arrive earlier are queued because the loader holds `umts_rfs0`). Phase 1 (G9b-G18): **observe mode**: NV verbs on a tmpfs copy re-seeded from the verified snapshot at every CP boot (writes accepted and discarded; NV_RESTORE re-seeds and returns 0); file verbs in an overlay (lower = read-only copy of `efs/root`, upper = tmpfs); `err*`/`/data/log*` → a sandbox log directory; `/system/etc` names → ENOENT. Phase 2: persistent sandbox `/var/lib/shannon/rfs/` with versioned snapshots, a write journal (offset, length, time) and `.md5` kept with the RIL formula; the loader uses a sandbox snapshot only by explicit operator action. Never the real EFS. |
| **Hardening** | own user and group (`umts_rfs0` 0660 root:rfs), `ProtectSystem=strict`, `ReadWritePaths=/run/shannon/rfs`, `PrivateNetwork=yes`, `NoNewPrivileges=yes`, `SystemCallFilter=@system-service`, NV snapshot passed by `LoadCredential=`; refuses to start unless the snapshot's SHA-256 equals the loader manifest. |
| **Protocol details** | 6-byte header, reassembly ≤ 0x80000, id echo, no reply for 0x0D-0x10 and 0x12; **every reply written with a short-write loop** retrying EINTR, EAGAIN and EBUSY; handles numbered from 3, at most 64 open, all dropped at every CP restart; NV windows limited to the snapshot size (no growth); READ_FILE clamping consistent (data, `n` and `length` agree); GET_FILE_INFO times kept as stock (`localtime`); paths canonicalised in the sandbox root, `O_NOFOLLOW`, no `..`; log `{cmd, id, offset, length, path}`, never content; record the largest NV_READ/READ_FILE size the CP requests (U22). |
| **Rationale** | The parser handles CP-controlled lengths and paths and touches the file system, so it gets its own sandbox; a crash of the FMT daemon never stalls RFS and vice versa; observe mode keeps every CP boot on the exact stock NV. |

### D7. Desktop integration and data

| | |
|---|---|
| **Options** | (1) own daemon + ModemManager D-Bus API; (2) samsungipcd + ModemManager; (3) oFono driver + ofono2mm; (4) native MM plugin; (5) MM generic AT on `umts_router` |
| **Decision** | **(1), built on omarchy-mobile's bridge.** `shannond` owns `umts_ipc0` (IPC 4.1), the codec's `Modem RX/TX Switch` and `Modem Rate`, and a CallAudio-compatible D-Bus service; it never owns `umts_rfs0` (D6). The MM façade is **`omamobile-mmd`** (MIT, Python/PyGObject Gio, API checked against MM 1.24.2's XML), packaged for armv7h like `omamobile-shell`, with its `sitd_link.py` replaced by a `shannond` link (or `shannond` speaking a compatible subset of the sitd socket protocol). ModemManager's daemon is not installed (`libmm-glib` only); no D-Bus activation file; its bus policy lets the service user own the name. |
| **Delivery order** | (a) Manager/ObjectManager, Modem, Modem3gpp for the shell's cellular icon (`cellWatch` on); (b) Sim, Simple, Bearer for NetworkManager 1.58 with the "Mobile data" tile restored; (c) Messaging/Sms; (d) Voice/Call; (e) Ussd. Everything else returns `Error.Core.Unsupported`. |
| **Client contract** | every property change emits `PropertiesChanged`; Modem and Call state changes also emit `StateChanged`; a call always reaches TERMINATED by `StateChanged` before `CallDeleted`; the modem object path is stable across CP restarts; the façade is never restarted during a call; no `org.freedesktop.DBus.*` interfaces in `GetManagedObjects`. CALL_STATUS → MM: 5/1 → DIALING, (local ringback) → RINGING_OUT, 3 → ACTIVE, 4 → TERMINATED; RINGING_IN, WAITING, HELD from CALL_LIST status. |
| **SMS** | GSM 7-bit (with national shift tables) and UCS-2; concatenation in (UDH IEI 0x00/0x08) and out (non-final parts `msg_type` 0x01); status reports; WAP push as `Sms.Data`; **persist before acknowledging** (spool 0600 under the daemon state dir), else answer memory-full (0x8080) and set SMS_MEM_STATUS full; spool entries deleted when a client deletes the message. |
| **Data** | rmnet `ARPHRD_RAWIP`; bearer `Interface = rmnet(cid−1)`, `Ip4Config` STATIC (address /32, DNS, MTU = min(network MTU, 1500)), `Ip6Config` DHCP with the network IID link-local; NetworkManager configures IP. |
| **Identifier policy** | `Modem.EquipmentIdentifier`, `Sim.Imsi`, `Sim.SimIdentifier` left empty by default (omarchy-mobile's choice; Calls/Chatty lose IMSI-based country normalisation); MCC+MNC only via `Sim.OperatorIdentifier`; `Modem.Location` sources disabled (no cell IDs on the bus). Owner may change this later. |
| **Offline proof** | O11: omamobile-mmd's conformance suite (mmcli, libmm-glib, GNOME Calls, Chatty under Xvfb) against a fake `shannond`; NetworkManager against a dummy `rmnet0` in a netns; a WirePlumber-contract test that fails if an active call is deleted. On the tablet: a libmm-glib Python probe (mmcli lives in `modemmanager`, which conflicts). |
| **Rationale** | A misc node is invisible to MM; the image already carries the consumers (shell icon, tile, call chip, NetworkManager); `omamobile-mmd` is tested against the exact client versions, which cuts WP10 from 6-10 to 2-4 days and removes hand-written-signature risk. |

### D8. Voice

| | |
|---|---|
| **Kernel** | (i) `wm8998.c` patch (~40 lines): `ASRC RATE 2`, `ASYNC Sample Rate 2`, ISRC FSH/FSL with value 9, `SAMPLE_RATE_2/3` = 8/16 kHz at probe. (ii) The machine driver's `late_probe` writes the constant clock plan once (`ASYNC_SAMPLE_RATE_2` 48 kHz, `ASRC RATE 2` = ASYNC rate 2, `ISRC2 FSH` = ASYNC rate 2, `ISRC2 FSL` = ASYNC rate), even with the codec patch; UCM never writes them. (iii) `gts28_wm1814.c` c2c "baseband" link: machine-registered modem DAI ↔ `wm8998-aif2`, `I2S + NB_NF + CBC_CFC`, `c2c_params` NB/WB via a `Modem Rate` enum (refused while powered), `Modem RX`/`Modem TX` pin switches off at boot, FLL2 started in the modem DAI `.hw_params` (REFCLK MCLK1 24 MHz, SYNC AIF2BCLK = rate × 32), refcounted per direction, stopped in `.hw_free` and `gts28_stop_sysclk`; `late_probe` moves AIF2 to ASYNCCLK; `ignore_suspend`. |
| **UCM** | one `"Voice Call"` verb with mainline names: routing, volumes and pin switches only (no rate controls); its devices pin AIF1 to 48 kHz (`PlaybackRate`/`CaptureRate` 48000, `SAMPLE_RATE_1` is shared with the ASRC sync side); devices `Speaker`, `Headphones`, `Mic`. |
| **Daemon ordering** | on DIALING (MO) or answer (MT): `AUDIO_PATH_CTRL` S {0x06 speaker or 0x07 headphone, 0x00}, `SPKR_VOLUME_CTRL` S {0x11 or 0x31, fixed level}, `TWO_MIC_SOL_CTRL` S {0, 0}, `MIC_MUTE_CTRL` S {0}. `Modem RX/TX Switch` go on only when **all** of: CP clock-on NOTI seen, `Modem Rate` matches the last WB report, the Voice Call verb applied (ALSA control check, e.g. `ISRC2INT1 Input == AIF2RX1`). Off at once on a clock-off NOTI (hold may stop BCLK), on POLLHUP/CRASH_EXIT, and on CALL_STATUS released **before** emitting `StateChanged → TERMINATED`; after the last call `CLOCK_CTRL` E {0}. Fallback if no clock NOTI within 3 s of connected: `CLOCK_CTRL` E {1} once. RINGBACK_TONE N → MM RINGING_OUT and a local tone on AIF1 (or ignored deliberately). |
| **Desktop** | WirePlumber ≥ 0.5.15 behaviour is required: package it for armv7h in `image/pkg/` (preferred), else an override of `find-voice-call-profile.lua` in a directory searched before `/usr/share` (lookup order to verify offline), else `wpctl set-profile` from `shannond`. A CallAudio-compatible service in `shannond` (`org.mobian_project.CallAudio`-style: `SelectMode` no-op, `EnableSpeaker` → UCM device + matching path/volume, `MuteMic` → `MIC_MUTE_CTRL`; interface to check against callaudiod's XML) replaces callaudiod, which is masked: GNOME Calls depends on it, and PipeWire mute never reaches AIF2. |
| **Diagnostics** | the path byte changes CP processing only: compare GEN 0x8000 and echo/level, never "which output plays". Phase 1 uses the main mic with the speaker path tuned for the sub mic: expect echo; phase 2 (sub mic, gpr3-2) follows closely. |
| **Rationale** | constant rates in the kernel remove the pin/verb race, mid-call verb re-runs and the UCM ordering constraint; gating on the CP's clock report reproduces the stock HAL; teardown before TERMINATED keeps WirePlumber's profile switch from racing the link. |

### D9. Security and privacy

| | |
|---|---|
| **Kernel** | `dflags` compiled 0, parameter mode 0644 (stock default dumps 16 bytes of each FMT frame, which include PIN digits in a PIN-verify frame); `MIF_LOG_DUMP` root on `umts_boot0` only; `mem_dump` and any shmem readout are payload. |
| **Nodes** | as §2.9: `umts_boot0`, `umts_ramdump0`, `umts_dm0`, `umts_router`, `ipc_loopback0`, `multipdp` 0600 root; `umts_ipc0` 0660 root:radio (`shannond`); `umts_rfs0` 0660 root:rfs (`shannon-rfsd`). DIAG and AT closed except in their named gate. |
| **Logs** | header tuples `{len, mseq, aseq, main, sub, type}` and RFS `{cmd, id, offset, length, path}` by default, journal volatile or rate-limited summaries (timing metadata). **Redaction table in every mode, including `--log-payload`**: PIN/PUK fields, APN user/password fields, SMS bodies and all numbers, IMEI/IMSI/ICCID, cell IDs/TAC/LAC with PLMN (§2.11 offsets). `--log-payload` writes to tmpfs, copied to `$T715_PRIVATE/` and deleted. `dflags ≠ 0` only with `journald Storage=volatile` and `systemd-pstore` masked, then reboot and clear pstore. |
| **SIM and PIN** | no SIM until G14; from G14 a test SIM with the PIN lock off. The daemon never stores a PIN and never submits one unattended while the retry counter (SEC_LOCK_INFORMATION) is below its maximum. |
| **SMS** | persist before acknowledging (D7). |
| **D-Bus** | identifier policy of D7; bus policy limits method calls to root and the desktop user. |
| **Emergency** | rule 16. |
| **Rationale** | HO (no identifiers); FMT carries identifiers, secrets and message contents; the CP is an untrusted peer with file access through RFS; journald on the persistent root and pstore would otherwise keep payloads. |

---

## 5. Safety rules for hardware work (ranked)

**A = absolute** (no exception; no note or agent can override). **S = strong** (exception only with
the owner's explicit approval for a named gate). **P = procedure**. §10 maps the reviewers' rule
numbers to these.

| # | Rule | Why | Class | Source |
|---|---|---|---|---|
| 1 | **Only the exact BOOT bytes of RADIO p13 cross SPI**: image[0x200 .. 0x2BFC), CRC32 0x5DB1F04C and the pinned SHA-256 of that slice, checked on the in-memory buffer that B7 writes. The kernel SPI link refuses any other payload (length ≠ 0x29FC or CRC32 ≠ `boot_crc`) and allows one SPI write per `MODEM_ON`. Never a modified BOOT/MAIN, a Meizu test loader or another RADIO image. **Never power off or reset the CP between `cp_status` = 1 and the first of `0xA00D` received or 10 s elapsed** (BOOT compares and programs eFuse slots in that window). Battery ≥ 50 % before any CP power-on | BOOT programs CP eFuse key slots when blank or different; OTP is irreversible | A | RI §2.3, §2.8; KD Q6; KR rule 1 |
| 2 | **Partitions are read-only except BOOT and RECOVERY**, written only with `device/write-part.sh` (allowlist, sha256, read-back) or heimdall. Never write the whole-disk device, never clear `/sys/block/mmcblk0boot*/force_ro`, never open `mmcblk0rpmb`. RECOVERY keeps the rescue (kernel 00021, no modem code) for the whole modem mission | device identity, firmware, recovery path; there is no BOOTLOADER partition in `by-name` (sboot is in the eMMC boot areas) | A | HO; DEPLOY §2; `dumps/by-name.txt`; KR rule 2 |
| 3 | **Raw backups before the first CP power-on**: EFS (p3), m9kefs1-3 (p4-6), RADIO (p13), CDMA-RADIO, PARAM, and BOOT (p9) and RECOVERY (p10), read by partlabel with EFS/RADIO unmounted (`findmnt`), SHA-256 on the tablet and on the Mac, stored in `$T715_PRIVATE/`, never the repo; RADIO must hash to the known `63a02cb6…a8cd` (done 2026-10-29 for all but BOOT/RECOVERY, MS) | only way back from an EFS/NV accident or a bad BOOT | A | KP §7.3; LS2 §8.4; KR G0 |
| 4 | **Never create, pad, truncate, rewrite or restore `nv_data.bin`** or its `.md5`, backups, `.nv_state`, `nv.log`; NV comes from a verified copy, `O_RDONLY`; missing, short or blank NV → refuse | cbd and RIL regenerate NV from defaults; IMEI/calibration loss | A | LS2 §8; RR §3.2 |
| 5 | **Never run stock rild/libsec-ril or stock cbd against the real `/efs`**; the oracle (G22) runs only in a chroot over a tmpfs copy, in its own network namespace, with an NV byte-identical to the loader's snapshot, with owner approval | RIL NV repair rewrites `nv_data.bin` | A | RR §3.2, §7; TR D5-4 |
| 6 | **EFS, m9kefs1-3, RADIO, CDMA-RADIO, PARAM, BOTA0/1 read-only at every boot**: `blockdev --setro` from a udev rule that also sets `UDISKS_IGNORE=1`, verified with `blockdev --getro` = 1 before each gate. EFS is never mounted on the tablet; NV is extracted on the Mac from a copy of the raw backup | a read-only mount can still replay a journal; nothing on the tablet needs EFS | A | KR rule 6; D4 |
| 7 | **Never issue `IOCTL_MODEM_CP_UPLOAD`** (stock panics the AP; `oops=panic` reboots) | unclean reboot | A | BR §2.2; LS2 §9.3 |
| 8 | **`lli_control` is never written**: structural in the port (0444, no store) | 2 flips the AP to master, 1/4 reset the link under a running CP | A | LS2 §5; KR D1-f |
| 9 | **No identifiers and no secrets in any log, file in the repo, message or commit**: IMEI/IMEISV, IMSI, ICCID, MSISDN and any phone number, SMS bodies, serials, MACs, Wi-Fi passwords, cell/location data, PIN/PUK, APN passwords. Redaction applies in every mode, including `--log-payload`; `dflags = 0` is the compiled default; raw logs only in `$T715_PRIVATE/` | privacy; stock `dflags` dumps 16 bytes of every FMT frame | A | HO; TR rule 22; D9 |
| 10 | **Leave Linux with `systemctl reboot` or `poweroff`** (runs `.shutdown`), never a watchdog reset as a procedure; **never write the RTC** (the daemon does not set the hardware clock from NITZ) | clean CP power-down; project rule | A | HO; mission brief |
| 11 | **One deployer, one owner of BOOT**: only the mission session (or one the owner hands the tablet to) deploys and tests; while a modem gate series is open only the modem mission writes BOOT, rebased on the daily kernel the Omarchy session last validated; every hand-over is recorded in `docs/journal/HANDOVER.md` with the BOOT sha256 | BOOT is a shared resource | A | HO; KR rule 23 |
| 12 | **Stage discipline and interlocks**: no CMU_CPIF/LLI/SYSREG access before G1+ recorded the CMU state and passed its go/no-go; the modem probe binds only if the shared region is base 0xde000000, size 8 MiB, disjoint from System RAM, and all DRAM above it is no-map (any other base: owner approval and all DRAM in [base, min(base + 256 MiB, DRAM end)) no-map); the LLI driver writes `LLI_MOUNT_CTRL` only when the remap readback matches; `ss333_on` releases CP_RESET only after its own `SW_RESET_DONE` and a matching readback. Any interlock refusal ends the session (`MODEM_OFF`, logs, no retry in that boot) | bus hang; CP DMA into kernel memory | A | KR rule 12; D3 |
| 13 | **Recovery path.** Before any W gate: the tablet on USB to an unlocked Mac; the running BOOT image and its sha256 on the Mac; the modem modules blocklisted in `/etc/modprobe.d/` **and** by `t715.modblacklist=` before the first boot of a modem BOOT image. After any unexpected reboot, hang or forced restart: (1) copy `/sys/fs/pstore/` to the private directory before anything reboots again; (2) read the CP lines (pinctrl debugfs: gpr3-1, gpc0-5, gpa2-3, gpa2-5) and `current_now`; if the CP may be powered and no modem module is loaded, drive **CP_RESET (gpc0-5) low, then CP_ON (gpr3-1) low** with `gpioset`, and confirm in pinctrl debugfs and `current_now`. BOOT rollback, in order: SSH up → `write-part.sh BOOT <previous>`; watchdog reset into the RECOVERY rescue → the same from the rescue; frozen (ping answers, no SSH banner) → the owner holds Power + Volume down about 10 s (on 2026-10-29 that did not recover) → Download mode (Power + Volume down + Home, then Volume up) → `heimdall flash --BOOT <previous>` | `.shutdown` does not run after a panic or forced restart; a frozen-but-pinged system needs hands | A | KR rule 22; DEPLOY §4.3, §13 |
| 13b | **Owner reachability**: the owner can reach the keys during W gates. The owner may waive this for a session; a hang then ends the session until the owner acts, so CP-powered steps stay short | recovery from a hang needs hands | S | KR rule 22 (moved to S, §10) |
| 14 | **Nodes and SIM**: `umts_boot0`, `umts_ramdump0`, `umts_dm0`, `umts_router`, `ipc_loopback0`, `multipdp` 0600 root; DIAG and AT stay closed except in their named gate. **No SIM until G14**; from G14 a test SIM with the PIN lock off. `dflags ≠ 0` only with a volatile journal and `systemd-pstore` masked | DIAG/AT can reach NV; subscriber data in logs before the privacy machinery is proven | A | KR rule 25; TR D9-2 |
| 15 | **Persist before acknowledging an SMS** (spool first, then DELIVER_REPORT `ack = 0`); otherwise answer memory-full (0x8080) and set SMS_MEM_STATUS full | the network deletes an acknowledged message | A | TR rule 24 |
| 16 | **Emergency calls**: never test with a real emergency number; until CALL_ECCLIST is decoded and the owner decides otherwise, the façade refuses emergency numbers at `CreateCall` with a clear error; the README states that this tablet is not an emergency phone (no IMS; CS ends with the operator's 2G/3G sunset) | safety; nobody should wait on a call that cannot connect | A | TR rule 25 |
| 17 | **Recovery from any CP state = power-off + full re-boot** (`MODEM_OFF`, unconditional in the port; `MODEM_ON` itself power-cycles). Never `DUMP_RESET` for a silent reset; never expect BOOT to time out. `--attempts=1` until the AFC fix is proven | BOOT spins forever; AFC state is per boot | S | RI C22; LS2 §9.3; KR D1-c |
| 18 | `FORCE_CRASH_EXIT`, `DUMP_START`, `DUMP_RESET`, RAM dumps: only in the crash gate (G12b) or the opt-in dump tool | side effects on CP state; dumps hold personal data | S | LS2 §9.4 |
| 19 | **Autoload and unit**: the modem modules stay blocklisted, and the loader unit installed **disabled**, until G11 passes; `allow_hw` defaults to 0, its 0→1 transition drives every AP→CP line low in stock order, 1→0 is refused unless OFFLINE; `sleep.target`/`suspend.target` masked during the mission | probe hangs; unattended CP power cycles | S | KR rule 15, E10, D1-i |
| 20 | Payload logging only to tmpfs, copied to the private directory and deleted; `mem_dump` is payload | privacy | S | D9 |
| 21 | RFS server in sandbox/observe mode only (D6) | EFS integrity | S | D6 |
| 22 | **No unattended PIN submission** while the SIM's retry counter is below its maximum; the daemon never stores a PIN | PUK lock | S | TR rule 23 |
| 23 | **Session limits**: log `capacity`, `temp` and `current_now` at 1 Hz during every W gate; abort the gate and `MODEM_OFF` below 30 % or at a gauge `temp` ≥ 42 °C (the gauge's own sensor, not the battery thermistor; also watch the AP thermal zones); `MODEM_OFF` counts as done only when `current_now` is back to the G1+ baseline ±30 mA within 3 s | battery, heat, proof that the CP is off | S | KR rule 24; `docs/hardware/BATTERY.md` |
| 24 | Bounded retries: loader ≤ 3 attempts per start (1 until AFC is proven); supervisor ≤ 5 silent resets / 30 min; `0xA20F` twice → stop | heat, battery, loops | P | LS2 §4.5, §9.3 |
| 25 | Reachability: Mac unlocked during USB-network sessions; `tssh` to 172.16.42.1; `t715-reboot-to recovery` or `t715-reboot-to download` while Linux runs | access | P | DR; HO |

---

## 6. Staged experimental plan

Every on-device gate: raw logs to `$T715_PRIVATE/` (the mission uses
`modem-mission/<date>/<gate>/`); pass only on the listed evidence; on failure run the listed
diagnostic, never improvise writes. "Tablet": **N** offline, **R** read-only on the tablet,
**W** writes BOOT/RECOVERY, loads modem code or powers the CP.

**Order.** O1-O11 (offline) → G0 → G0+ → G1 → G1+ → G2a → G2b → G2c → G3 → **reboot** → G4 → G5 →
(G6) → G7 → G8 → G9 → G9b → G11 → G10 → *(unblock the modules, enable the loader unit)* → G12 → G12b
→ G12c → G13 → G14 → G16a → G17 → G15 → G16 → G18 → G18b → G20 → G21 → (G22). G19 needs only O6 and a
BOOT image with the audio patches, so it can run any time after G2a.

### 6.1 Offline gates (all before the first W gate that depends on them)

| Gate | Prerequisites | Action | Success evidence | Failure → next step |
|---|---|---|---|---|
| O1 kernel build | WP1-WP4 | series on `t715-bringup@ed71dc803`; fragment build; `make W=1 C=1` on new files; checkpatch; `make M=` in the BOOT O= tree | clean; zero new sparse `__iomem` warnings; `objdump -dr` of both `.ko`: no call to `panic`, `__bug`/`BUG`, `machine_restart`, `emergency_restart`; `modinfo -F vermagic` = BOOT release; IDs 12-25 without renumbering; `SIPC5_ALIGN == 4` static assert | API drift (KP §2.1); ID collision |
| O1b DT checks | WP4 | script over the compiled DTB (optional YAML bindings + `dtbs_check`) | reserved ranges disjoint and inside the memory banks; `cp-shmem` aligned; all DRAM ≥ 0xde000000 no-map; every modem GPIO flag cell 0; IRQ cells `<0 184 4>`/`<0 185 4>`; no normal-mode `pin-pud`/`pin-function` on AP→CP outputs; `dtc` diff against the 00024 DTB shows additions only | — |
| O2 ring harness + CP model | WP5 | CP model written from RI §2.5-§2.7 (busy-poll `raw_tx_head`, round-up-4, replies copying cfg/ch with len 8, signal 0x83, the `0xA?0F` cases) driving the ported `xmit_udl`/RX demux compiled in userspace | LS2 §10.4 vectors byte-exact; CRC frame 12 bytes; wrap at 0x1FD000; ENOSPC all-or-nothing; single TOC frame | padding 8; EXT header below 0xFFFF |
| O3 loader unit | WP6 | L1 tests with the C mock and a virtual clock | golden transcript; every LS2 §10.5 fault row; BOOT pin (CRC + SHA-256), settle window, `--attempts=1`, `allow_hw` guard; tripwires silent | — |
| O4 loader black-box | WP7, O2 | CUSE `umts_boot0` backed by O2's harness and CP model, dummy holders, sysfs files | full transcript through real syscalls (17 497 writes, FIN); LD_PRELOAD sees no EFS write flags | CUSE unrestricted ioctls |
| O5 codecs + RFS | WP8, WP9, WP18 | encoder golden vectors for every TX message from a machine-readable catalogue (92/105/127/194/85/19/9/185/2/1 B); decoders against the stock tuple lengths (REGIST 19, SERVING 26, ICON 10, RSSI 9, GEN 5, CELL_INFO 548); RFS framing, reassembly, id echo, no-reply commands, SBD truncation and `-EBUSY` emulation; fuzzing of RFS framing and paths; redaction-table tests | all pass; fuzz finds no crash or escape; redaction leaves no secret | — |
| O6 audio offline | WP11, WP12 | build codec patch + machine link; `validate_ucm.py` level 1 (`Syntax` only at top level), **1b blocking** (every `cset` name and value exists in mainline), level 2 (`--card wm1814`) | clean; no rate controls in UCM; Voice Call devices at 48 kHz | downstream control names |
| O7 safety audit | all | userspace: write/create flags on EFS paths, `0x6F35`, `lli_control` writes; kernel: GPIO writes outside the `allow_hw` checks, LLI access outside clocked paths, CP_RESET release outside the interlock; DT values cite sources; the image ships `gpioset` (libgpiod) and a `devmem` (or use pinctrl/regmap debugfs); units, udev rules, `modprobe.d` packaged (dry run) | no hit | — |
| O8 kernel logic tests | WP16 | KUnit under `qemu-system-arm -M virt` (separate config) or a userspace harness with mocked `readl`/`writel` | `exynos_lli_cal_remap(0xde000000, SZ_8M) == 0x0001BC97`; interlock refuses a bad readback; AFC over reset → reset → mount → reset (AFC first, then the saved code); SPI tripwire (length, CRC, once per `MODEM_ON`); `allow_hw` transitions; `modem_off` from every state ends with CP_RESET 0 and CP_ON 0; reset rate limiter; IRQ storm guard | — |
| O9 debug kernel | WP16 | build-only fragment (`DEBUG_ATOMIC_SLEEP`, `PROVE_LOCKING`, `DEBUG_SPINLOCK`, `DEBUG_OBJECTS_TIMERS`); optional debug BOOT image for G2-G7 | builds; on device (optional): no "sleeping function called from invalid context", no lockdep report | production image from G8 |
| O10 fake-CP scenarios | WP17, WP9 | CUSE `umts_ipc0`/`umts_rfs0` with the real misc semantics (100 ms empty read, one frame per read with push-back, POLLHUP on crash and SIM change, `-EPERM` when not ONLINE, STATUS 7/8 consumption, stale queue across a reset, SBD truncation); replay of the stock header sequence (`mseq/aseq` pairing, unanswered EVENTs, GEN for unsupported GET) with synthetic payloads; scripts for MO/MT call, multipart SMS in/out, PDP up/down, CLOCK/WB NOTIs, CP crash mid-call, daemon restart | restart contract holds; no stale `aseq` match; spool written before every ack | — |
| O11 D-Bus conformance | WP10, O10 | private system bus + `omamobile-mmd` + fake `shannond`: mmcli, libmm-glib, GNOME Calls and Chatty under Xvfb (omarchy-mobile's suite); NetworkManager against a dummy `rmnet0` in a netns; WirePlumber-contract test (object manager + `ListCalls` + `StateChanged`) | suite passes; the contract test fails if an active call is deleted | — |

### 6.2 Device gates: baseline and kernel bring-up

| Gate | Prerequisites | Action | Success evidence | Likely failures → next diagnostic | Rollback | Tablet |
|---|---|---|---|---|---|---|
| **G0** backups | — | done 2026-10-29 (MS): EFS, m9kefs1-3, RADIO, CDMA-RADIO, PARAM read-only and backed up with matching hashes | — | — | — | R |
| **G0+** | G0 | back up BOOT p9 and RECOVERY p10 (compare with the known sha256s); `findmnt` (EFS/RADIO unmounted); `blockdev --getro` = 1 for the rule-6 set; record `/proc/cmdline`, `uname -r`; on the Mac: BOOT-slice SHA-256 from the backed-up `radio.img`, NV extraction (D4) compared with the TWRP backup by hash | hashes recorded; NV copy 1 048 576 B, manifest written | wrong partlabel → list `by-partlabel` first | — | R |
| **G1** baseline | — | done 2026-10-29 (§2.18) | — | — | — | R |
| **G1+** go/no-go | G1 | read `ENABLE_ACLK_CPIF` (0x10fc0800), `ENABLE_PCLK_CPIF` (0x10fc0900), CMU_MIF `DIV_MIF3` (0x105b060c), `ENABLE_ACLK_MIF3` (0x105b080c); pinctrl debugfs CON/DAT/PUD/DRV of the 12 modem pins; `/proc/iomem`; `current_now` baseline with the CP off | **go only if** `ENABLE_ACLK_CPIF` bits 1-4, 7, 9-11 and `ENABLE_PCLK_CPIF` bit 1 (`pclk_sysreg_cpif`) are set; otherwise WP1 models them as clocks first | never read 0x10f2xxxx-0x10f3xxxx or 0x10fdxxxx | — | R |
| **G2a** new BOOT, modules not loaded | O1-O9; rule 13 preconditions; blocklist checked on the daily kernel | `write-part.sh BOOT`; boot; non-modem regression (`device/final-interactive.sh`); repeat the G1+ reads | G1+ reads **byte-identical** (the clock patch changes no register at boot); no `failed to reserve memory for node 'cp-shmem@de000000'` or `cp-guard` line; no System RAM in [0xde000000, 0xde980000); regression passes | reservation failure → DT; register change → clock patch side effect | rule 13 order | W (BOOT) |
| **G2b** LLI module | G2a | `modprobe exynos5433-mipi-lli` | `clk_summary`: `aclk_cpif_200` = 100 MHz, symbol muxes on `phyclk_lli_*`, LLI gates on; IRQ 184/185 counts 0 and steady for 60 s; pins byte-identical; probe line "region ok" | bus abort → G1+ bits, clock order; IRQ count rising → INTR clear | reboot | W (clocks only) |
| **G2c** modem module | G2b | `modprobe sec_modem_v1` (`allow_hw = 0`) | 9 misc + rmnet0-3 (type 519); `lli_control` `MIPI-LLI 0`, mode 0444; `cp_status/value` 0; `MODEM_ON` → `-EPERM`; pins byte-identical to G1+; no IRQ on modem pins | probe deferral (`CONFIG_SPI`, SPI client) | reboot | W (no CP power) |
| **G3** LLI alone, CP unpowered | G2c; G1+ go | `allow_hw = 1` (lines driven low in stock order, logged); debugfs `ss333/lli_reset` once; SPI tripwire negative test (a wrong payload) | exactly one `SW_RESET_DONE ++`; remap 0x0001BC97 in both registers, `remap_ok = 1`; PMU 0x720 = 1; `PA_SYSTEM_CLK_PERIOD` = 10; mount bit clear; SPI 184 delta ≤ 2 and steady 60 s; SPI 185 delta 0; no `Error sent`/`PA_REASON`; wrong payload refused; record `IAL_LL/BE_TARG_ADDR_REMAP` (0x1108/0x110C) and `IAL_OVERLAP_ADDR_CTRL_EN` (0x1144) | bus hang → rule 13, pstore, G1+ dump; no `SW_RESET_DONE` → IRQ index/type, INTR_ENABLE; remap mismatch → stop the series | **reboot** (AFC), `allow_hw = 0` | W |

### 6.3 Device gates: CP boot (loader rungs, `--attempts=1`)

| Gate | Prerequisites | Action | Success evidence | Likely failures → next diagnostic | Rollback | Tablet |
|---|---|---|---|---|---|---|
| **G4** power | G3 + reboot; NV snapshot provisioned | `--stop-after=power` | `ss333_on +++/---` ≈ 1 s; one `SW_RESET_DONE`; interlock "remap ok"; `OFFLINE -> BOOTING`; `magic == 0x424F4F54`; levels CP_ON 1, CP_RESET 1, PDA_ACTIVE 1, AP2CP_STATUS 1, AP2CP_WAKEUP 0; `cp_status` 0; `current_now` steps at CP_ON and at reset release; after `MODEM_OFF`: CP_RESET 0, **CP_ON 0**, current at baseline (rule 23) | inverted polarity; pin glitch; `ERR! magic` (mapping); interlock refusal → G3 values | `MODEM_OFF` | W |
| **G5** SPI BOOT | G4 | canary fill; `--stop-after=spi` (honours the settle) | `write()` = 0x29FC in ≈ 0.9 s; `cp_status` = 1 within 5 s; **`MIPI-LLI 1` already at B8**, `HIBERN8_EXIT_DONE`/`Mount intr` timestamps against the gpa2-5 edge (C25); canary unchanged | `cp_status` stays 0: LLI IRQ log first (no HIBERN8 exit, mount refused by the interlock) → G6 diagnostics; then SPI (`CONFIG_SPI_S3C64XX`, nCS on gpv7-2, rate in `clk_summary`, BOOT offset, 4-byte strip); then the PMIC CP 32 kHz clock (U-list) | `MODEM_OFF` after the settle | W |
| **G6** mount (diagnostic rung) | only if G5 shows `cp_status` = 1 without `MIPI-LLI 1` | `--stop-after=lli` | `HIBERN8_EXIT_DONE: rx=3, tx=1` → `Mount intr` → `Mount (ok:1 fail:0 …)` | symbol muxes, 0x720, gear/series, `cmn_init` values, credits (`ERR: Mount failed`), `PA_REASON` storm (`aclk_cpif_200` ≠ 100 MHz) | `MODEM_OFF` after the settle | W |
| **G7** first ring round trip | G5 | `--stop-after=stage0` | `0x900D → 0xA00D` (ends the eFuse window); SPI 185 +1; canary unchanged (proves the window base, not its size masking, U2) | no answer: remap/window, magic order, doorbell RX (IRQ 185 type, TL clear), `shmem_map` A/B, padding 4 | `MODEM_OFF` | W |
| **G8** stages | G7 | `--stop-after=fin` first (rungs `toc`, `main`, `nv` only to bisect); one `--stop-after=nv` run for the canary | `0xA101`, `0xA10D`; MAIN duration logged; `0xA201`, `0xA20C`, `0xA20D`; `0xA301`, `0xA30D`; `0xAF00`; no `NOSPC` storms, `BAD CFG`, `No IOD for CH`; canary unchanged after `nv` | `0xA20F` once → retry after a reboot; twice → stop (image rejected); silent stop → compare with the golden transcript | `MODEM_OFF` | W |
| **G9** ONLINE | G8 | full run, holders after `BOOT_OFF` | `INIT_START <- ss333` → `PIF_INIT_DONE -> ss333` → `CP_START <- ss333 … opened=0` → `BOOTING -> ONLINE`; `BOOT_OFF` 0; `umts_rfs0->INIT_END->ss333`; `0x6F48` undefined-cmd line; STATUS 4; AP2CP lines 1; record `cp_status`, PHONE_ACTIVE, CP2AP edge counts, `current_now` | `T-I-M-E-O-U-T` (no INIT_START: MAIN did not start; PHONE_START lost; SBD layout); repeated `CP_START <-` → INIT_END not reaching the CP | `MODEM_OFF` | W |
| **G9b** first FMT | G9; O10 | within 2 min of ONLINE: `ipc-probe --passive` (header tuples) answering SMS_DEVICE_READY S and IPC_LOOPBACK CFRM; `shannon-rfsd` observe; no SIM | PWR_PHONE_PWR_UP NOTI; replies acknowledged if those NOTIs arrive; one GET round trip (DISP_ICON_INFO G → 10-B RESP); RFS requests answered and logged; no CRASH_EXIT for 10 min | nothing on `umts_ipc0`: SBD RX, IRQ 185, still BOOTING; garbled: `shmem_map` A/B | stop; `MODEM_OFF` | W |
| **G11** off and reboot paths | G9b | `MODEM_OFF` from ONLINE; boot again; `systemctl reboot` with the CP ONLINE; `systemctl poweroff` with the CP ONLINE, then power on | `.shutdown` runs; CP_RESET 0 → CP_ON 0; next boot shows the CP lines low and `current_now` at baseline before any module loads; the CP is not powered while the tablet is off | CP left powered → rule 13 kill | — | W |
| **G10** soak | G9b, G11 | 30 min ONLINE in the G12 configuration; D2 counters; 1 Hz battery/temp/current | no CRASH_EXIT; 0 `Unmount`; counters of D2; RFS log; rule 23 limits held | `Unmount` → D2 F1; crash → time and last RFS request (C26) | `MODEM_OFF` | W |

After G11 and G10: remove the blocklist, enable the loader unit (rule 19).

### 6.4 Device gates: IPC, data, voice (feature order: icon → data → SMS → calls → audio)

| Gate | Prerequisites | Action | Success evidence | Likely failures → next diagnostic | Rollback | Tablet |
|---|---|---|---|---|---|---|
| **G12** FMT/RFS traffic | G10 | `ipc-probe` + `shannon-rfsd` in normal operation; grep the private log for the absence of payload | PWR_UP NOTI; GET round trip; replies; RFS answering; no "NO data in RXQ" flood; header-only logging verified | — | stop | W |
| **G12b** crash path | G12 | `FORCE_CRASH_EXIT` (only here) | CRASH_EXIT via PHONE_ACTIVE or the 10 s timer; `POLLHUP`; silent reset to ONLINE; no AP panic; daemon: pins off, stale queue drained, `mseq` reset, façade (if present) keeps the modem path and terminates calls; RFS handles dropped | supervisor limits | — | W |
| **G12c** daemon restart | G12b | kill and restart `shannond` and `shannon-rfsd` while ONLINE and idle | no CP state change (fds held by the loader); state re-synced by GETs (PIN, REGIST, CALL_LIST) | — | — | W |
| **G13** AT probe | G12 | root, alone: `AT\r`, `ATI\r`, `AT+CGMR\r` on `umts_router` (2 s timeout), optionally after GPRS_PIN_CTRL DTR on | report "answered" or "silent" only; transcript private | — | close the node | W |
| **G14** radio, SIM, registration | G12c; test SIM, PIN lock off | PWR_PHONE_STATE E 0x0202 → GEN 0x8000; PIN status; NET_MODE_SEL G before any S; NET_REGIST G for CS and PS separately; SERVING_NETWORK G | CS and PS registration recorded separately; RSSI/ICON NOTIs | GEN error codes, reject cause | PHONE_STATE 0x0001 | W |
| **G16a** bar icon | G14; O11 | façade subset (a); `cellWatch` on in the tablet `shell.json` | the bar shows bars and RAT; libmm-glib probe sees the modem | object paths, `PropertiesChanged` | façade off | W |
| **G17** data | G16a | NetworkManager gsm connection; LTE_ATTACH_APN_INFO, DEFINE_PDP_CONTEXT, PDP_CONTEXT; bearer to NM; teardown; CP crash during data; "Mobile data" tile | CALL_STATUS up + IP_CONFIGURATION; `rmnet0` counters; ping and DNS; MTU ≤ 1500; IPv6 if offered; NM sees `Connected = false` after a crash | cid↔rmnet (U15), MTU, `NETDEV_TX_BUSY`; ring errors under load → `shmem_map` A/B | deactivate | W |
| **G15** SMS | G17; spool and NACK policy (O10) | send one SMS to an owner-provided number (never logged); receive one | SEND_MSG R ack; DELIVER_REPORT R `ack == 0`; no redelivery of the same message within 10 min; spool entry written before the ack | SMSC, domain byte | — | W |
| **G16** messaging client | G15 | Chatty or omatel Messages through the façade | send, receive, delete through MM | `Sms` properties | — | W |
| **G18** MO voice signalling | G16 | call a voicemail or announcement number; hang up | CALL_STATUS 5/1 → 3 → 4; MM DIALING → ACTIVE → TERMINATED through `StateChanged` | call type, TON, p91 | CALL_RELEASE | W |
| **G18b** MT call | G18 | incoming call from a second phone: reject, answer, missed | CALL_INCOMING → CALL_LIST → RINGING_IN → ANSWER; reject; missed call reported | CALL_INCOMING layout (U9) | — | W |
| **G19** audio dry run | O6; BOOT with the audio patches | HiFi regression; `alsaucm` Voice Call + Speaker + Mic; `Modem RX/TX Switch` on without CP clocks; rates already set by `late_probe` | controls listed; FLL2_CLOCK_OK with REFCLK; ASRC1/2 lock; no "ASRC … event failed" | rate fields, `SAMPLE_RATE_1` | pins off | W (codec) |
| **G20** call audio | G18, G19 | D8 ordering; log every SND NOTI; BCLK proof with the no-REFCLK debug build; hold | CLOCK_CTRL NOTI; FLL2 locks at 256/512 kHz; downlink; uplink; NB/WB switch; Speaker ↔ Headphones; mute at the CP; hold → clock-off → pins off | no clock NOTI → START fallback; silence → slot swap; poor quality → path byte (processing), sub mic | pins off; STOP after release | W |
| **G21** desktop end to end | G17, G20; WirePlumber ≥ 0.5.15 behaviour; CallAudio service; callaudiod masked | GNOME Calls + façade + WirePlumber; 20 call cycles; screen off; CP crash mid-call | profile switches to Voice Call and back; no leaked FLL2; a CP crash mid-call returns the profile to HiFi without restarting WirePlumber | WirePlumber hook, `StateChanged` | — | W |
| **G22** oracle (conditional) | owner approval; a named blocking question | D5 A1 conditions | captured header traffic that answers it | — | discard the chroot | W |

---

## 7. Work breakdown

Work packages run offline in parallel; device gates run one at a time. The live
mission's lots (MS) map as K1 → WP1, WP2, WP4 (LLI part); K2 → WP3, WP4 (modem part); L → WP6;
I1 → WP8, WP9, WP17; V → WP11, WP12; I2 → WP10.

| WP | Content | Inputs | Outputs | Depends | Parallel | Acceptance | Effort |
|---|---|---|---|---|---|---|---|
| WP0 | mission control: rule-13 kill and pstore scripts, G0+/G1+ scripts, BOOT-slice SHA-256, Mac-side NV extraction, private log layout | §5, §6 | `device/modem-*` scripts, checklists | — | yes | dry runs; no write path to EFS/RADIO | 1-2 d |
| WP1 | dt-bindings + CMU_CPIF clocks + PMU define (+ ACLK/PCLK CPIF gates if G1+ requires) | KP §4; G1+ | patches | — | yes | O1 | 1-2 d |
| WP2 | LLI module: AFC fix, remap interlock, `IRQF_NO_AUTOEN` on 184 and 185, W1C + reset rate limit, `lli_control` 0444, debugfs status/canary | KP §2.2; D1-D3 | patch | WP1 | yes | O1, O8 | 4-5 d |
| WP3 | modem_v1 module: `allow_hw` transitions, SPI tripwire, locked-on PM + storm guard (F1/F2 compiled out), `memcpy_toio`, `dflags` 0/0644, `MIF_LOG_DUMP` restriction, truncation kept, `modem_suspend` `-EBUSY`, RAWIP, `CP_UPLOAD`, `modem_off` | KP §2.3; D1-D2 | patch | WP2 API | partly | O1, O2, O8 | 7-10 d |
| WP4 | board DT (`cp-shmem`, `cp-guard`, pin defaults without normal-mode pull/function on outputs, IRQ cells) + fragment + blocklist knob | KP §3; D3 | patches | WP1 | yes | O1, O1b | 1-2 d |
| WP5 | ring harness + CP model | LS2 §10.4; RI §2.5-§2.7 | test harness | WP3 sources | yes | O2 | 2 d |
| WP6 | `shannon-loader` (C) + mock + fixtures | LS2; D4 | loader, tests, disabled unit | — | yes | O3 | 4-6 d |
| WP7 | CUSE harness backed by O2 | LS2 §10 | harness | WP5, WP6 | yes | O4 | 2 d |
| WP8 | `shannon-rfsd` (Python, sandbox, short-write loop, fuzzing) | RR §5; D6 | service + tests | — | yes | O5 | 3-4 d |
| WP9 | `shannond` core (Python): framing, sequencing, codecs with golden vectors, restart contract, `ipc-probe`, CallAudio service, ALSA control access | IPC; D5, D8 | service + tests | — | yes | O5, O10 | 6-9 d |
| WP10 | adapt `omamobile-mmd` (link to `shannond`) + revert the shell's tablet patches for `cellWatch` and the data tile | D7; omarchy-mobile | package + patches | WP9 API | after WP9 API | O11 | 2-4 d |
| WP11 | audio kernel: `wm8998.c` patch, c2c link, `late_probe` clock plan | VA §3-§4; D8 | patches | — | yes | O6 build, G19 | 3-4 d |
| WP12 | UCM Voice Call verb (routing only, 48 kHz devices) + validator fixes | VA §5; D8 | UCM, validator | WP11 | yes | O6 | 1-2 d |
| WP13 | packaging: units (loader disabled until G11), udev read-only rule with `UDISKS_IGNORE`, node modes and groups, journald volatile option, masks (callaudiod, sleep targets), libgpiod | D4, D7, D9 | overlay files | WP6, WP8-WP10 | late | O7 | 2 d |
| WP14 | static RE: `IpcTxSnd*`/`IpcRxSndClockCtrl` values, CALL_ECCLIST, RINGBACK_TONE, SMS_MEM_STATUS and INCOMING storage index, SAT minimum, INDI types needing a CFRM, `CalChecksum`, `MISC_AT_CMD_FWD`, CALL_INCOMING, IP_CONFIGURATION p15-p22 | private libsec-ril copy, never executed | notes | — | yes | addresses cited, no identifiers | 3-5 d |
| WP15 | original dossier corrections | §9 | patched files | — | — | done 2026-10-30 | done |
| WP16 | kernel logic tests (O8), DT checks (O1b), debug fragment (O9) | D1-D3 | tests, script, fragment | WP2-WP4 | yes | O8, O1b, O9 | 3-4 d |
| WP17 | fake-CP scenarios (O10) | TR §5; D5 | harness + scripts | WP7, WP9 | yes | O10 | 2-3 d |
| WP18 | SMS codec (GSM 7-bit, UCS-2, concatenation) + spool | D7 | library + tests | WP9 | yes | O5, O10 | 2-3 d |
| WP19 | WirePlumber ≥ 0.5.15 for armv7h (`image/pkg/`), or the script override | D8 | package | — | yes | profile selection test | 0.5-1 d |

Critical path offline: WP1 → WP2 → WP3 → WP4 → WP16 (O8) → O1/O1b/O2, alongside WP6 → O3/O4 and WP0;
WP8-WP12, WP14 and WP17-WP19 in parallel; WP10 after WP9's API. Rough total ~55-80 working days; the
device gates G2a-G9 are the calendar bottleneck.

---

## 8. Open unknowns, ranked by impact

| Rank | ID | Unknown | Impact if adverse | Resolving experiment | Cost |
|---|---|---|---|---|---|
| 1 | U1 | does the LLI mount on mainline clocks (symbol muxes, gates, 100 MHz `aclk_cpif_200`, shared M-PHY ref, CMN values)? | no CP ONLINE | G2b-G6 logs and register dumps against G1+ | iterative |
| 2 | U2 | AP addresses the CP can reach; does the IAL mask accesses to the 8 MiB encoded in the remap? | ring invisible, or CP writes beyond the region | G3 readback, G7 round trip, canaries in the guard and upper half (G5, G7, G8) | low |
| 3 | U30 | state of `ENABLE_ACLK_CPIF`/`ENABLE_PCLK_CPIF` after sboot | bus hang on the first LLI access | G1+ reads | free |
| 4 | U4 | BootROM SPI acceptance (100 kHz, PIO vs DMA, CS, PMIC CP 32 kHz clock) | `cp_status` never rises | G5 | low |
| 5 | U28 | does the first AFC run, done with the CP unpowered (G3) or powered (G4), calibrate correctly? | mount failures that look like clock problems | G4-G6 after the reboot; O8 logic | low |
| 6 | U5 | does the CP ever unmount while the AP holds the link? | dead link mid-session | G10 counters; D2 F1/F2 | low |
| 7 | U31 | does the CP remount when AP2CP_STATUS never falls (locked-on)? | F1 cannot work without F2 | only if G10 sees an unmount | low |
| 8 | U6 | CP tolerance of sandboxed RFS; which verbs and files it uses | CP crash or degraded service | G9b/G10/G12 observe logs | low |
| 9 | U22 | CP reassembly of chunked RFS replies | NV reads fail | log the largest NV_READ/READ_FILE requested (G10) | free |
| 10 | U7 | `device` vs `wc` mapping and barriers under load | ring corruption | G17 load + `shmem_map` A/B | low |
| 11 | U8 | GIC trigger type of SPI 184/185 | storms or lost doorbells | G3/G7 counters | free |
| 12 | U29 | duration of an eFuse program cycle (settle window) | power cut during OTP | none safe; settle 10 s | — |
| 13 | U9 | unseen payload details (CALL_INCOMING, IP_CONFIGURATION p15-p22, GPRS_CALL_STATUS p3-p8, SERVING p11-p17) | partial features | G14-G18b lengths; WP14; G22 if blocked | low-medium |
| 14 | U23 | LTE default-bearer cid; is PDP activation needed after attach? | data setup errors | G17 | low |
| 15 | U10 | CP AIF2 clock start (spontaneous, after AUDIO_PATH, after START); CLOCK/WB report semantics; CLOCK_MODE values | no call audio | G20 NOTI log; WP14 | medium |
| 16 | U11 | FLL2 REFCLK + SYNC before BCLK; AIF2 slot use and polarity | pops, no lock, silence | G19, G20 slot swap | low |
| 17 | U26 | CP clock behaviour on hold and swap | dead audio after hold | G20 | low |
| 18 | U12 | PHONE_ACTIVE level during BOOT/MAIN; meaning of `ss333_off`'s wait for high | wrong crash detection, slow off | G4-G9 levels | free |
| 19 | U24 | SMS routing (AP vs SIM storage, MEM_STATUS) | lost or duplicated SMS | G15; WP14 | low |
| 20 | U25 | INDI types requiring a CFRM; minimal SAT handling | CP waits or retries | G12-G16 logs; WP14 | low |
| 21 | U15 | cid↔rmnet in practice; IPv6/IPv4v6 | partial data | G17 | low |
| 22 | U14 | Shannon `.md5` formula match; RIL header checksum algorithm | phase-2 persistence only | loader advisory check (G4: match/no match, no content); WP14 | free |
| 23 | U16 | AT on `umts_router` | a fallback only | G13 | free |
| 24 | U17 | CP watchdog during a BOOT hang | CP resets instead of hanging | any failed G5-G8 | free |
| 25 | U18 | MAIN stage duration vs the ENOSPC budget | stage timeouts | G8 timing | free |
| 26 | U19 | network acceptance of CS voice for this SKU and subscription | no calls | G18 | free |
| 27 | U27 | the operator's 2G/3G sunset dates; SMS over SGs afterwards | voice (and maybe SMS) horizon | ask the operator; record before investing in G18+ | free |
| 28 | U32 | does a forced restart recover a frozen tablet? (it did not on 2026-10-29) | longer recovery | observe; rule 13 order | — |
| 29 | U33 | effect of the empty `Imsi` on Calls/Chatty number handling | number normalisation | G16-G21 | free |
| 30 | U13 | effect of an early `INIT_END` | none while the policy holds | not tested | — |
| 31 | U20 | CP boot log at shmem+0xC00 | debug convenience | debugfs read after a failed `BOOT_OFF` | free |
| 32 | U21 | SDM start magic for DIAG | no DIAG | out of scope | — |
| — | U3 | `cp_status` vs mount order | — | resolved I (strong), C25; confirm at G5 | free |

---

## 9. Corrections to the original dossier files

Applied in place on 2026-10-30 (each changed spot carries "corrected 2026-10-30, see SYNTHESIS.md
§…"). Line numbers are those of the files before the patch (±2; KR checked the anchors).

### 9.1 `SS333_LLI_BRINGUP.md`

| Location | Wrong statement | Correct statement | Source |
|---|---|---|---|
| §1.5 l.160-161 | SPI 184 = signal IRQ; handler `exynos_mipi_lli_irq` | SPI 184 = index 0 = DME/link IRQ (`exynos_mipi_lli_irq`); SPI 185 = index 1 = doorbell (`mipi_lli_sig_irq`) | KP C-2; SYN |
| §1.5 l.170-177 | `spi_4@14d30000`, inactive | SPI4 at **0x14d00000** (0x14d30000 is SPI1); carries BOOT on every boot (`SET_TX_LINK(3)`) | KD Q5; KP C-7 |
| §1.5 l.179-183 | reservation in `mach-espresso5433.c` | `mach-universal5433.c:58-68` | KP C-4 |
| §1.6 l.195 | `CPIF_LLI_SIG_IN0` = CP2AP doorbell read by the handler | doorbell value = `TL_SIGNAL_STATUS_LSB/MSB` (+0x2004/+0x2010); `CPIF_LLI_SIG_*` are SYSREG masks | KP C-2; SYN |
| §2.1 l.214 | 11 misc nodes | 9 misc devices + 4 netdevs | KP C-3; SYN |
| §2.2 table | 0x6F47/0x6F48 missing; CP_UPLOAD without rule | add GET/CLR_CP_BOOTLOG (`-EINVAL` on LLI); CP_UPLOAD: never issue | KD Q1; LS2 §2.1 |
| §3.1 l.318-319 | `ss333_off` waits phone_active **low** | waits for **high**; returns early if OFFLINE; leaves CP_ON high | KP C-5; SYN |
| §3.2 l.363-372 | userspace must write `2` then `3` to `lli_control`; AP = master | never written; CP is master; AP slave mounts from its IRQ handler; cbd only reads | RI §2.6; LS2 §5 |
| §3.3 l.432 | RX path reads `CPIF_LLI_SIG_IN0` | the SPI 185 handler reads TL signal status | KP C-2 |
| §3.4 l.438-459 | image streamed over LLI after one FW_UPDATE; doorbell U-6 open | BOOT raw over SPI; TOC/MAIN/NV STD_UDL stages over the LLI ring; FW_UPDATE per stage, informational; no doorbell needed | LS2 §4, §6; RI §2.7 |
| §3.5 l.465-467 | `start_pm` with `pm_enable=0` | FSM build, `pm_enable` default 1 (read-only parameter), `PM_EVENT_CP_BOOTING` | KP C-1; SYN |
| §3.5 l.477-481 | power-on order implying BOOT_OFF needs rild's opens | SYNTHESIS §2.6; BOOT_OFF waits only for `PHONE_START`; holders opened after BOOT_OFF | LS2 §7 |
| §3.6 l.483-518 | reconstructed cbd sequence (`-b s` = storage; `lli_control` writes; single image stream; opens before BOOT_OFF; CP_UPLOAD in crash path) | replaced by a pointer to LS2 §4 / SYNTHESIS §2.6-§2.7 with the key corrections | LS2; CB Q2 |
| §3.6 l.490-495 | libsec-ril's `DoModemBoot` can re-trigger the boot | `DoModemBoot` = `WaitForOnline` (STATUS polling); `DoModemSilentReset` = `exit(0)` | RR §6.1 (KR E13: this sits in §3.6, not §5.3) |
| §4 l.528-548 | TOC, mtu, load addresses unknown; NV via RFS; FW_UPDATE post-boot unknown | TOC known; MTU 0x810/MSS 0x800; load addresses travel in the TOC stage; NV streamed at stage 3; FW_UPDATE unused after boot | RI; LS2 §12 |
| §5.1 l.566-568 | STD_UDL not used | used end to end | LS2 §12 |
| §5.3 l.584 | `rild.libpath` `/vendor/lib64/…` | `/system/lib/libsec-ril.so` (32-bit) | AR Q4 |
| §5.3 l.597-604 | RFS frames FMT-style with `main_cmd = RFS_CMD` | 6-byte header `{u32 length, u8 cmd, u8 id}`, cmd 0x01-0x17; replies looped over short writes | RR §5.1; TR D6-2 |
| §5.4 l.611-613 | multipdp is rild's PDP control node | PDP via FMT GPRS messages; multipdp = flow control/`waketime`; cid n ↔ rmnet(n−1) | FR Q7; IPC §8 |
| §6 l.634-639 | unfinished `CBS_CFS` sentence | CP is clock provider; I2S NB_NF 2×16-bit; FLL2 REFCLK MCLK1 + SYNC AIF2BCLK; stock mixer `mixer_paths_rev09.xml` | VA §2 |
| §7 l.652-680 | arm64 port; FSM "can be dropped (pm_enable=0 already)"; rewrite 4-6 kLOC | ARM32 6.12 (padding 4); stock ran the FSM, dropping it is a design choice; lift-and-shift (KP) | KP; C01 |
| §8 l.695-712 | U-1..U-9 open | resolved except the NV item map (U-4) | RI §5.5; LS2 §12 |

### 9.2 `CBD_RE.md`

| Location | Wrong statement | Correct statement | Source |
|---|---|---|---|
| §1.1 l.81 | `fn3` undetermined | `shutdown` = `IOCTL_MODEM_OFF` | CB Q2 |
| §2 l.122-125, §8-7 | `get_device_path` undetermined | `/sys/bus/platform/drivers/mif_sipc5/<entry containing mif_sipc5 or mif_pdata>/` | CB Q2 |
| §4 l.234-236 | duplicated "Global state" line | delete the duplicate | editorial |
| §4 l.220-225 | rec4 a bare optional `stage_start(0xf)` | FIN `0x9F00 → 0xAF00`, mandatory | RI C20 |
| §6 step 9, §8-4 | call 0xba70 undetermined | `wait_gpio_value(..., "cp_status/value", "1", 10)`, 500 ms | CB Q2 |
| §6 step 13, §8-3 | 0x6F47/0x6F48 unknown | GET/CLR_CP_BOOTLOG, `-EINVAL` here | KD Q1 |
| §6.1 l.287 | records with payload flag 0 skipped | all records processed; only the payload step is skipped | LS2 §4.6#3 |
| §6.1 l.324-328 | 0x9000 family = raw magic | named STD_UDL (`std_boot.h`) | CB Q2 |
| §7 l.344-345 | `rfs_check_done` set "by RFS check" | set by libsec-ril `Modem::Init` after `Nv::Init` | RR §3.2 |

### 9.3 `LOADER_SPEC.md` (superseded by LS2 and this document; dangerous statements fixed in place)

| Location | Wrong statement | Correct statement | Source |
|---|---|---|---|
| top | no warning | superseded banner | — |
| prerequisites l.28-30 | `/sys/devices/10f24000.mipi-lli/lli_control` | `/sys/bus/platform/devices/10f24000.mipi-lli/lli_control`, read only | LS2 F1 |
| data inputs l.39-40, step 2 | create 0xFF NV if missing | refuse; verified read-only copy; exact size | LS2 §8; rule 4 |
| step 9 l.55-57 | post-write call "replaced by nothing" | wait `cp_status` = 1 (≤ 5 s) before step 10; BOOT bytes pinned (CRC + SHA-256); eFuse settle | LS2 B8; rule 1 |
| step 12 | framing gaps | one write per frame, kernel pads to 4, single TOC frame, no NV CRC, 0xF fail nibble, BOOT never times out, drain RX before stage 0 | RI C7-C22 |
| step 12.5 | CRC is the MAIN check | value ignored by this BOOT; still sent | RI §2.5 |
| step 13 | do not reproduce 0x6F47/0x6F48 | GET/CLR_CP_BOOTLOG, harmless | LS2 B13/B15 |
| after step 14 | missing | holders opened after BOOT_OFF; supervisor; bounded retries | LS2 §7, §9 |
| risk notes l.100-103 | record 4 can be skipped | FIN mandatory | RI C20 |
| risk notes l.104-105 | pad a short NV with 0xFF | refuse | LS2 §8.2 |
| SPI4 | (implicit) | SPI4 is at 0x14d00000; TX link 3 = SPI | KD Q5 |

### 9.4 `modem_v1_uapi.h`

| Location | Wrong / missing | Correction | Source |
|---|---|---|---|
| ioctl block | GET/CLR_CP_BOOTLOG missing | add `_IO('o',0x47)`/`_IO('o',0x48)`, `-EINVAL` on LLI | KD Q1 |
| `CP_UPLOAD` | no warning | stock `panic()`s; never issue | BR §2.2 |
| `XMIT_BOOT` | no note | `-EINVAL` on this board | BR §1.2 |
| `SET_TX_LINK` | argument values undefined | `MV1_LINKDEV_SPI 3`, `MV1_LINKDEV_LLI 10` | KR §9.4 |
| `MIF_LOG_DUMP` | no note | copies an `unsigned long` (4 bytes on ARM32); injects log frames into the caller's RX queue | KR §9.4; TR D9-5 |
| header comment | "arm32 kernel / arm32+arm64 userspace" | ARM32 kernel and userspace only (`struct modem_firmware` holds a `char *`) | KR §9.4 |
| enum | reachability | `STATE_CRASH_RESET` never set on this kernel | LS2 §9.1 |
| `mv1_sim_state` | presented as ABI | kernel-internal `{bool online; bool changed;}`, not exchanged: marked internal | SYN `modem_prj.h:142-145` |
| SIPC5 block | padding implicit | `SIPC5_ALIGN 4` | RI C8 |
| new | STD_UDL definitions | constants and frame structs | CB Q2; LS2 §2.2 |
| new | RFS header | `struct mv1_rfs_hdr` and cmd values | RR §5 |
| new | doorbell values | computed AP→CP/CP→AP values, boot reply 0x83 | LS2 §7.1; RI §2.7 |
| new | shmem offsets | offset macros | LS2 §2.4; RI §2.7 |

### 9.5 Analysis notes to annotate later (not patched in this pass)

| Note | Statement | Correction | Source |
|---|---|---|---|
| VA §0 item 6, §6.2, §6.3 row 1 | IPC SND numbering unproven; path 0x07/0x08; output change → AUDIO_PATH | numbering proven (IPC §9); path 0x06/0x07; the byte selects CP processing; rates move to `late_probe` | C27, C28, C53; TR D8 |
| VA §7 stage 8, G21-type text; LV §4 | disable callaudiod; WirePlumber ≥ 0.5.15 present | CallAudio service; package WirePlumber | C55, C56 |
| KP §0.1, §2.6 | `ioremap_wc` default | `device` first (D3) | C46 |
| KP §2.1 | `no-map` ⇒ `pfn_valid()` false | true on ARM32 6.12 | C50 |
| KP §2.2, §2.8 | `lli_control` store kept; `allow_hw` blocks all side effects | 0444; LLI probe touches clocks and registers | C59, C61 |
| KP §3.4 | `pin-pud = PULL_NONE` on CP outputs | no normal-mode pull/function on outputs | KR E2 |
| KP S3-S7, R-4 | S4 cp_status = SPI proof; opens before BOOT_OFF; G3 state; hang ends in watchdog | C25, C17, C49, C47 | KR |
| IPC §10 | RFS required at CP boot | ONLINE does not depend on it | C26 |
| RR §5.1 | replies are one `write()` | short-write loop over SBD truncation | C54 |
| LV §1 | samsungipcd forces PPP | PPP bypass since 0.3.0 | C52 |
| CB Q6; REP | no CP-side non-volatile write path | BOOT programs eFuses | C30 |

---

## 10. Review integration log

Verification method: every accepted claim was re-read at its cited source (3.10 and 6.12 lines, BL,
CFG, IMG, the shell patches, the private copy of the omarchy-mobile plan, the stock dmesg LLI lines
recomputed by script). Claims resting only on web pages the reviewers read are marked "I
(reviewer-read)". **K-** = kernel/boot review, **T-** = telephony/voice review.

| Finding | Summary | Disposition | Reason / verification | Landed in |
|---|---|---|---|---|
| K-D1-a | `allow_hw` 0→1 with ASIS lines drives nothing | accepted | gpiolib semantics; stock probe order verified (`modem_main.c:294-307`) | D1, O8, rule 19 |
| K-D1-b | LLI probe has real side effects (assigned clocks, pinctrl, gates) | accepted | `platform.c:1367`, `dd.c:694` verified | §2.1, D1, G2b, C61 |
| K-D1-c | M-PHY AFC first-init hazard (blocker) | accepted | statics verified (`mphy.c:53-88`, `lli.c:841-858`) | §2.1, D1, O8, G3, rule 17, U28 |
| K-D1-d | kernel tripwires (SPI payload, remap) | accepted with change | one write per `MODEM_ON` or per `DUMP_RESET` (opt-in dump tool) | D1, rule 1, G3 |
| K-D1-e | overlay argument weak | accepted | reserved-memory/`CLK_OF_DECLARE`/no overlay loader | D1 rationale |
| K-D1-f | `lli_control` store `0` depends on dropped tables | accepted | register-dump code verified | D1, §2.9, rule 8, C59 |
| K-D1-g | vermagic and module install rule | accepted | CFG and `init:845-873` verified | D1 |
| K-D1-h | `RESET_ON_ERROR_SENT` before W1C | accepted | `:951-955` verified | §2.1, D1 |
| K-D1-i | suspend not blocked | accepted | `CONFIG_SUSPEND=y` | D1, rule 19 |
| K-D1-j | IRQ request changes pin CON | accepted | IRQs requested at the 0→1 transition | D1, D2, G2c |
| K-D2-a | F1 skips the AP2CP_STATUS handshake | accepted | `link_device_pm.c:473-477,590-602` verified | D2, C60 |
| K-D2-b | CP2AP IRQs left enabled across power-off | accepted | stock pinctrl inputs pull none | D2, D1 |
| K-D2-c | `stop_pm` deviation from stock | accepted | `:846-872` verified | §2.3, D2 |
| K-D2-d | more G10 counters | accepted | — | D2, G10 |
| K-D3-a | remap protected once, not per boot (blocker) | accepted | `:282-312,911-932` verified | §2.1, D3, rule 12, O8 |
| K-D3-b | failed reservation looks good (blocker) | accepted | BL:7/BL:31 and `of_reserved_mem.c:183-197` verified | D3, G2a, C62 |
| K-D3-c | exposure beyond 8 MiB; guard region | accepted | BL:26-29 verified | D3, rule 12, canary |
| K-D3-d | Device ≠ strongly-ordered for ordering | accepted | ARMv7 memory model | D3, C46 |
| K-D3-e | plain `memcpy` on `__iomem` | accepted | — | D1, O1 |
| K-D3-f | `pfn_valid` true for NOMAP | accepted | `init.c:126-145` verified | §2.1, C50, §9.5 |
| K-D4-a | eFuse window | accepted with change | settle 10 s instead of 3 s (duration U) | §2.4, §2.6, D4, rule 1 |
| K-D4-b | pin BOOT bytes in memory | accepted | — | §2.6, D4 |
| K-D4-c | `--attempts=1`, unit disabled until G11 | accepted | — | D4, rules 17, 19 |
| K-D4-d | NV from the raw backup on the Mac | accepted with change | opaque handling, hashes only; fallback mount needs owner approval | D4, rule 6, §2.13 |
| K-D4-e | preflight guards | accepted | — | §2.6, D4 |
| K-D4-f | G8 `fin` first | accepted | — | D4, G8 |
| K-D9-a | DIAG/AT/ramdump node modes | accepted | — | §2.9, D9, rule 14 |
| K-D9-b | `mem_dump` is payload | accepted | — | D9, rule 20 |
| K-D9-c | journal and pstore keep dumps | accepted | — | D9, rule 14 |
| K-D9-d | SIM absent until G14 | accepted | merged with T-D9-2 | rule 14 |
| K-E1 | CP_ON stays high vs port | accepted | `:211-272` | §2.3, G11, C48 |
| K-E2 | floating CP_ON/CP_RESET from `PULL_NONE` | accepted | stock DT verified; G1 shows pull-down inputs (MS) | §2.2, O1b, G2a-c |
| K-E3 | cmdline source and `tmr_atboot` | accepted | CFG verified | §2.1 |
| K-E4 | hang outcomes | accepted | DEPLOY §13 verified | §1, §2.1, C47, rule 13 |
| K-E5 | base wording; remap value P | accepted | — | §2.1 |
| K-E6 | median 2.83 s | accepted | recomputed (24 intervals; down-time median 2.46 s) | §2.16, C45 |
| K-E7 | CP2AP_STATUS at mount completion | accepted | recomputed: 25/25 within 0.1 ms | C25, §2.16, G5 |
| K-E8 | SO vs Device ordering wording (= D3-d) | accepted | ARMv7 memory model | D3, C46 |
| K-E9 | overlay argument (= D1-e) | accepted | — | D1 |
| K-E12 | `pfn_valid` (= D3-f) | accepted | `init.c:126-145` | C50 |
| K-E10 | blocklist until G11 | accepted | — | rule 19, C51 |
| K-E11 | allowlist; BOTA; no BOOTLOADER partition | accepted | `by-name.txt` names verified | rules 2, 6 |
| K-E13 | §9 anchor label | accepted | — | §9.1 |
| K-C46 | mapping default KP vs D3 | accepted | — | C46 |
| K-C47 | hang outcome | accepted | DEPLOY §13 | C47 |
| K-C48 | CP_ON after off | accepted | — | C48 |
| K-C49 | G3 electrical state without stock precedent | accepted | `modem_ctrl_ss333.c:187-198` | C49 |
| K-C50 | `pfn_valid` | accepted | — | C50 |
| K-C51 | blocklist duration | accepted | — | C51 |
| K-§9.4 | UAPI additions | accepted | — | §9.4 (applied) |
| K-F1 | remap protected once; failed reservation looks good (= D3-a, D3-b) | accepted | see those rows | D3, rule 12 |
| K-F2 | G3 corrupts the AFC state (= D1-c) | accepted | see D1-c | D1, G3 |
| K-F3 | eFuse window; no SPI guard (= D4-a, D1-d) | accepted with change | 10 s settle | rule 1, D1 |
| K-F4 | floating CP_ON/CP_RESET (= E2) | accepted | MS G1 confirms pull-down inputs | §2.2 |
| K-F8 | `allow_hw` 0→1 drives nothing (= D1-a) | accepted | — | D1 |
| K-F11 | DIAG/AT node modes (= D9-a) | accepted | — | rule 14 |
| K-F12 | IRQ storms (= D2-b, D1-h, G3 bounds) | accepted | — | D1, D2, G3 |
| K-F13 | suspend not blocked (= D1-i) | accepted | — | rule 19 |
| K-F5 | rollback needs hands; pstore | accepted | DEPLOY §4.3, §13 | rule 13 |
| K-F6 | blocklist before the first modem BOOT | accepted | initramfs installs `lib/modules`; `t715.modblacklist` exists (`init:45,317`) | D1, rules 13, 19, G2a |
| K-F7 | no CP-kill procedure | accepted | — | rule 13 |
| K-F9 | BOOT is shared | accepted | — | rule 11 |
| K-F10 | battery/thermal thresholds | accepted with change | the gauge `temp` is the gauge's own sensor, not the battery thermistor; also watch AP zones | rule 23 |
| K-F14 | rules 6, 8 too strict / structural | accepted | — | rules 6, 8 |
| K-rule 1 | BOOT bytes, window, battery | accepted with change | 10 s settle | rule 1 |
| K-rule 2 | allowlist | accepted | — | rule 2 |
| K-rule 6 | read-only at every boot | accepted | — | rule 6 |
| K-rule 12 | interlocks | accepted | — | rule 12 |
| K-rule 22 | recovery path | accepted with change | kill order CP_RESET then CP_ON (assert reset before cutting power, as `ss333_init` and the port's `modem_off`); forced restart may fail (DEPLOY); owner presence split into rule 13b | rules 13, 13b |
| K-rule 23 | single owner of BOOT | accepted | merged with v1 rule 11 | rule 11 |
| K-rule 24 | session limits | accepted with change | sensor caveat | rule 23 |
| K-rule 25 | nodes and SIM | accepted | — | rule 14 |
| K-rule 15 | amend | accepted | — | rule 19 |
| K-O1 | sparse, objdump, vermagic | accepted | — | O1 |
| K-O1b | DT checks | accepted | — | O1b |
| K-O2 | CP model for the ring harness | accepted | — | O2 |
| K-O4 | CUSE backed by the O2 harness | accepted | — | O4 |
| K-O7 | kernel-side audit, `gpioset`/`devmem` in the image | accepted | — | O7 |
| K-O8 | kernel logic unit tests (blocker for D1-c/D3-a) | accepted | — | O8, WP16 |
| K-O9 | debug fragment "for G2-G7" | accepted with change | build mandatory, on-device use optional, production image from G8 | O9 |
| K-G0 | precondition gaps (BOOT/RECOVERY backups, `findmnt`, getro, NV on the Mac) | accepted | G0 already done by the mission (MS): complement G0+ | §6.2 |
| K-G1 | go/no-go on CPIF bus gates, pin registers, `current_now` baseline | accepted | G1 already done (MS): complement G1+ | §6.2 |
| K-G2 | split G2a/b/c (blocker F6) | accepted | — | §6.2 |
| K-G3 | bounded success criteria, tripwire negative test, reboot before G4 | accepted | — | G3 |
| K-G4 | `current_now` proof of CP power, CP_ON 0 after off | accepted | — | G4 |
| K-G5 | expect `MIPI-LLI 1` at B8; canary; settle | accepted | — | G5 |
| K-G6 | keep as diagnostic rung | accepted | — | G6 |
| K-G7 | canary after `0xA00D` | accepted | — | G7 |
| K-G8 | rungs only to bisect; canary after `nv` | accepted | — | G8 |
| K-G9 | record levels, edges, current | accepted | — | G9 |
| K-G9b | first FMT within 2 min of ONLINE | accepted | evidence merged with T-E4 (PWR_UP proven, others if they arrive) | G9b |
| K-G10 | after G9b and G11, in the G12 configuration | accepted | — | G10, §6 order |
| K-G11 | port behaviour, poweroff with CP ONLINE | accepted | — | G11 |
| K-G12 | header-only logging verified, SIM absent | accepted | — | G12 |
| T-D5-1 | omarchy-mobile precedent | accepted | plan copy (`:2336-2397`) and image packages verified | D5, D7, §2.17 |
| T-D5-2 | daemon/loader restart contract | accepted | `modem_io_device.c:1009-1012,1340-1345` verified | D5, §2.9, G12b, O10 |
| T-D5-3 | samsungipcd PPP | accepted | FR Q5 vs LV §1 | D5, C52 |
| T-D5-4 | A1 netns, identical NV | accepted | — | D5, rule 5 |
| T-D5-5 | AT transcripts private | accepted | — | D5, G13 |
| T-D6-1 | separate RFS process | accepted | — | D6 |
| T-D6-2 | SBD truncation, short-write loop | accepted | `link_device_memory_main.c:296-303`, `.h:205`, dtsi slots verified | §2.9, §2.12, D1, D6, O5, C54 |
| T-D6-3 | handle and range hygiene | accepted with change | **UTC times rejected**: stock uses `localtime`, the CP's use of the times is unknown and UTC gains no privacy (the CP knows network time); the rest accepted | D6 |
| T-D6-4 | memory-safe language | accepted | Python for `shannond` and `shannon-rfsd` (the mission chose Python too, MS); C stays for the loader | D5, D6 |
| T-D7-1 | adapt `omamobile-mmd` | accepted | — | D7, WP10 |
| T-D7-2 | first deliverable = bar icon | accepted | shell patches verified | D7, §1, G16a |
| T-D7-3 | NetworkManager established | accepted | IMG:44 verified | §2.14, D7, C58 |
| T-D7-4 | `StateChanged` contract | accepted | I (reviewer-read) | D7, §2.17 |
| T-D7-5 | packaging | accepted | — | D7 |
| T-D7-6 | SMS needs codec and spool | accepted | — | D7, WP18 |
| T-D7-7 | MTU clamp | accepted | rmnet slot 2048 verified | §2.14, D7 |
| T-D8-1 | WirePlumber 0.5.13 (blocker for G21) | accepted | IMG:38 verified; 0.5.15 note in LV §4 | D8, §2.17, C55, G21, WP19 |
| T-D8-2 | clock-plan rates in the kernel | accepted | — | §2.15, D8 |
| T-D8-3 | pin gating and teardown order | accepted | — | D8 |
| T-D8-4 | callaudiod dependency, CallAudio shim | accepted | interface name to check (I) | D8, C56, G21 |
| T-D8-5 | path byte = CP processing | accepted | one PCM on AIF2 | §2.15, D8, C53, G20 |
| T-D8-6 | ringback, CALL_STATUS mapping, MT gate | accepted | — | §2.11, D7, D8, G18b, WP14 |
| T-D8-7 | phase-1 mic echo | accepted | — | D8 |
| T-D9-1 | secret redaction; `dflags` default and mode | accepted | `modem_utils.c:69-71` verified | §2.11, D9, rule 9 |
| T-D9-2 | PIN handling, test SIM | accepted |  | D9, rules 14, 22 |
| T-D9-3 | SMS persist before ack | accepted | — | D7, rule 15 |
| T-D9-4 | identifiers on D-Bus | accepted, decided | empty identifiers, MCC+MNC only, no Location | D7 |
| T-D9-5 | node groups; `MIF_LOG_DUMP` | accepted | `mif_dump_log` verified | §2.9, D9 |
| T-D9-6 | metadata | accepted | — | D9 |
| T-E1 | replies are not one `write()` (= D6-2) | accepted | verified | §2.12, C54 |
| T-E2 | WirePlumber 0.5.13 (= D8-1) | accepted | IMG:38 | C55 |
| T-E3 | callaudiod needed by Calls (= D8-4) | accepted | — | C56 |
| T-E6 | NetworkManager established (= D7-3) | accepted | IMG:44 | C58 |
| T-E7 | samsungipcd PPP (= D5-3) | accepted | — | C52 |
| T-E8 | path byte diagnostic (= D8-5) | accepted | — | C53, G20 |
| T-E12 | MTU clamp (= D7-7) | accepted | — | §2.14 |
| T-E4 | only PWR_UP proven | accepted | — | §2.11, G9b, G12 |
| T-E5 | start-up row P → P/I | accepted | — | §2.11, C57 |
| T-E9 | VA needs patching | accepted | listed, not patched in this pass | §9.5 |
| T-E10 | §1 overstated | accepted | — | §1 |
| T-E11 | 2G/3G sunset horizon | accepted as I | reviewer-cited, not re-verified | §1, U27 |
| T-E13 | G15 evidence | accepted | — | G15 |
| T-E14 | WP14 additions | accepted | — | WP14 |
| T-E15 | WP10 effort | accepted | — | §7 |
| T-E16 | read buffer, read after POLLIN | accepted | — | §2.9 |
| T-§3.1 | architecture table | accepted | — | D7 |
| T-§3.3, §5.2 | feature order | accepted | — | §1, §6 |
| T-§3.4 | effort deltas | accepted | — | §7 |
| T-§4.1 | RFS sandbox and NV hygiene | accepted | — | D6, rule 21 |
| T-§4.2 | stock rild only in netns with identical NV | accepted | — | rule 5 |
| T-§4.3 | logging: redaction in every mode, `dflags` 0, logger ioctl | accepted | — | D9, rule 9 |
| T-§4.4 | SIM PIN policy | accepted with change | owner's SIM with lock disabled also allowed | rules 14, 22 |
| T-§4.5 | SMS loss before the spool exists | accepted | — | rule 15, G15 order |
| T-§4.6 | emergency-call policy | accepted | default refusal until ECC handling and an owner decision | rule 16 |
| T-§4.7 | CP crash mid-call | accepted | — | D5, D7, D8, G12b, G21 |
| T-§4.8 | network horizon | accepted as I | — | §1, U27 |
| T-O5 | golden vectors, tuple lengths, truncation emulation, fuzzing | accepted | — | O5 |
| T-O6 | level 1b blocking; 48 kHz devices; no rate controls in UCM | accepted | — | O6 |
| T-O8 | fake-CP scenarios | accepted, renumbered | O8 already used by the kernel review → O10 | O10 |
| T-O9 | D-Bus conformance | accepted, renumbered | O9 already used → O11 | O11 |
| T-G12 | evidence: PWR_UP, one GET, no RXQ flood | accepted | — | G9b, G12 |
| T-G12b | daemon assertions on crash | accepted | — | G12b |
| T-G12c | daemon restart gate (new) | accepted | — | G12c |
| T-G14 | test SIM, CS/PS separately, MODE_SEL G first | accepted | — | G14 |
| T-G16a | bar icon gate (new) | accepted | — | G16a |
| T-G17 | data before SMS | accepted | — | §6 order, G17 |
| T-G15 | SMS after data, spool first | accepted | — | G15 |
| T-G18 | MM state mapping check | accepted | — | G18 |
| T-G18b | MT call gate (new) | accepted | — | G18b |
| T-G19 | rates set by the kernel | accepted | — | G19 |
| T-G20 | no "wrong output" diagnostic; hold test | accepted | — | G20 |
| T-G21 | WirePlumber, CallAudio, crash mid-call evidence | accepted | — | G21 |
| T-rule 22 | secrets never logged | accepted, merged | → rule 9 | §5 |
| T-rule 23 | no unattended PIN submission | accepted | → rule 22 | §5 |
| T-rule 24 | persist SMS before ack | accepted | → rule 15 | §5 |
| T-rule 25 | emergency numbers | accepted | → rule 16 | §5 |
| T-U22 | CP reassembly of chunked RFS | accepted | — | §8 |
| T-U23 | LTE default-bearer cid | accepted | — | §8 |
| T-U24 | SMS routing | accepted | — | §8 |
| T-U25 | INDI types needing CFRM; SAT | accepted | — | §8 |
| T-U26 | CP clock on hold/swap | accepted | — | §8 |
| T-U27 | operator sunset dates | accepted | — | §8 |
