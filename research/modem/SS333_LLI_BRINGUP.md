# SM-T715 (Galaxy Tab S2 8.0 LTE) — Shannon SS333 modem boot & MIPI-LLI bring-up dossier

Target: Samsung SM-T715 / gts28ltexx, Exynos 5433 (hw rev 9), Shannon SS333 (SEC_SS333, `modem_type = 15`).

Purpose: provide everything needed to (a) write a Linux userspace replacement for Samsung's
proprietary `cbd` CP-boot daemon, and (b) judge the feasibility of porting the modem stack to
mainline Linux 6.12.

> **Corrected 2026-10-30.** Later analyses found errors in this dossier (IRQ roles, the SPI4
> address and role, `lli_control` writes, the boot download path, link PM, NV delivery, RFS
> framing and more). They are fixed in place below, each marked "corrected 2026-10-30".
> The authoritative reference is `research/SYNTHESIS.md` (its §9.1 lists every correction).

**Citation convention.** `file.c:NNN` without prefix is relative to
`src/kernel_universal5433/`. Other roots are given explicitly
(`device_gts28ltexx/…`, `dumps/…`, `linux-6.12/…`). Every numeric value below is quoted from
source or DT; runtime-computed values are explicitly flagged. Statements are marked
**[proven]** (directly readable in the cited source) or **[inferred]** (derived, reasoning given).
The `cbd` binary and the RADIO partition image were **not available**; everything about the
userspace daemon beyond the kernel-facing ABI is inferred from `init.baseband.rc`, `cbd.te` and
`libsec-ril.so` strings (strings extracted read-only in a container; the binary was never
executed). No `dumps/` file other than `live_fdt.dts` and `lib/libsec-ril.so` was read.

Companion file: `modem_v1_uapi.h` (§9) — standalone C header with the full userspace ABI.

---

## 1. Device-tree binding (`mif_pdata`) and driver probing

### 1.1 Probe path [proven]

- platform_driver: `drivers/misc/modem_v1/modem_main.c:731-737` — `.name = "mif_sipc5"`,
  `.probe = modem_probe`, `.shutdown = modem_shutdown`, `.pm = &modem_pm_ops`.
- OF match: `modem_main.c:533-536` — `sec_modem_match[] = { { .compatible = "sec_modem,modem_pdata" } }`.
  DT node: `arch/arm/boot/dts/modem-ss333-pdata.dtsi:8` (`compatible = "sec_modem,modem_pdata"`).
- `modem_probe` (`modem_main.c:545`): bails out with `-EINVAL` when `lpcharge` (low-power
  charging boot), `modem_main.c:554-558`.
- Init flow inside probe: `create_modemctl_device` → link creation loop
  `modem_main.c:592-607`: `for (i = 0; i < LINKDEV_MAX; i++) if (pdata->link_types & LINKTYPE(i))`
  call `call_link_init_func` — sets `ld->link_type`, `ld->mc`, `ld->msd`,
  `ld->state = LINK_STATE_OFFLINE`. IO devices then attached via `create_io_device`
  (`modem_main.c:134`): `IPC_FMT`/id 235 → `mc->iod` (`:167-168`), `IPC_BOOT`/id 215 →
  `mc->bootd` (`:169-171`); `attach_devices` (`modem_main.c:196`) sets waketime
  `FMT_WAKE_TIME = HZ/2` (`:51`, applied `:230/:244`) and `RAW_WAKE_TIME = HZ*6` (`:52`,
  applied `:234/:248`).
- Modem/link dispatch: `drivers/misc/modem_v1/modem_variation.c:124` table
  `modem_init_func[MAX_MODEM_TYPE]` — `[SEC_SS333] = MODEM_INIT_CALL(ss333)` (`modem_variation.c:140`);
  `link_init_func[LINKDEV_MAX]` (`modem_variation.c:144`) —
  `[LINKDEV_LLI] = LINK_INIT_CALL(lli)` (`modem_variation.c:152`),
  `[LINKDEV_SPI] = LINK_INIT_CALL(spi)` (`modem_variation.c:154`).
- Defconfig (all [proven], `arch/arm/configs/lineage_gts28ltexx_defconfig:1322-1348`):
  `CONFIG_SEC_MODEM_V1=y`, `CONFIG_UMTS_MODEM_SS333=y`, `CONFIG_LINK_DEVICE_LLI=y`,
  `CONFIG_MIPI_LLI=y`, `CONFIG_EXYNOS_MIPI_LLI=y`, `CONFIG_EXYNOS_MIPI_LLI_MPHY=y`,
  `CONFIG_EXYNOS_MIPI_LLI_GPIO_SIDEBAND=y`, `CONFIG_LINK_DEVICE_SPI=y`
  (`# CONFIG_BOOT_DEVICE_SPI is not set` — `boot_device_spi.c` NOT built, Makefile:24),
  `CONFIG_LINK_DEVICE_MEMORY=y`, `CONFIG_LINK_POWER_MANAGEMENT=y`,
  `CONFIG_LINK_POWER_MANAGEMENT_WITH_FSM=y`,
  `CONFIG_LINK_CONTROL_MSG_COMMAND=y` (`# LINK_CONTROL_MSG_IOSM not set`),
  `CONFIG_LINK_DEVICE_WITH_SBD_ARCH=y` (`# LINK_DEVICE_NAPI not set`,
  `# LINK_DEVICE_SHMEM not set`). `CONFIG_ARGOS=y` at `:3829`.
  Build glue: `drivers/misc/modem_v1/Makefile:29` `obj-$(CONFIG_UMTS_MODEM_SS333) += modem_ctrl_ss333.o`.

### 1.2 Common properties parsed by `parse_dt_common_pdata` [proven]

Parser: `modem_main.c:259-274`. Consumer struct `modem_data`:
`include/linux/platform_data/modem_v1.h:383-466`.

| DT property | Parser | Value on this board | Meaning |
|---|---|---|---|
| `mif,name` | `modem_main.c:262` | `"ss333"` (pdata dtsi:11) | modem name |
| `mif,modem_net` | `:264` | `<0>` = `UMTS_NETWORK` (pdata dtsi:12) | network class |
| `mif,modem_type` | `:265` | `<15>` = `SEC_SS333` (pdata dtsi:13; enum `modem_v1.h:48`) | CP type |
| `mif,use_handover` | `:266` | `<0>` (pdata dtsi:14) | no 2-modem handover |
| `mif,ipc_version` | `:267` | `<50>` = `SIPC_VER_50` (pdata dtsi:15; enum `modem_v1.h:110`) | SIPC5 |
| `mif,link_types` | `:269` | `<0x408>` = `LINKTYPE(LINKDEV_LLI)|LINKTYPE(LINKDEV_SPI)` (pdata dtsi:16; `LINKDEV_LLI=10`, `modem_v1.h:92`, `LINKTYPE(m)=1u<<m` `modem_v1.h:95`) | link candidates |
| `mif,link_name` | `:270` | `"lli"` (pdata dtsi:17) | active link |
| `mif,link_attrs` | `:271` | `<0x3C9>` (pdata dtsi:18) — DT comment: `DUMP_ALIGNED(0x200) | BOOT_ALIGNED(0x100) | MEM_DUMP(0x80) | MEM_BOOT(0x40) | DPRAM_MAGIC(0x08) | SBD_IPC(0x01)` | link attribute set (enum `modem_v1.h:233-248`) |
| `mif,num_iodevs` | `:273` | `<13>` (pdata dtsi:20) | IO device count |

Critical observation [proven, consequences proven]: `0x3C9` does **not** contain
`LINK_ATTR_XMIT_BTDLR` (bit 11, `0x800`, `modem_v1.h:246`). In `mem_create_link_device`
(`link_device_memory_main.c:1030-1039`) `ld->boot_on = mem_boot_on` is unconditional, but the
`LINK_ATTR_MEM_BOOT` block only wires `ld->xmit_boot = mem_xmit_boot` when `XMIT_BTDLR` is set —
so **`ld->xmit_boot` stays NULL** for this board, while `ld->dload_start = mem_start_download`
and `ld->firm_update = mem_update_firm_info` ARE wired. Consequence:
`IOCTL_MODEM_XMIT_BOOT` returns `-EINVAL` (`modem_io_device.c:1167-1173`), and firmware
download must go through `IOCTL_MODEM_DL_START` + `IOCTL_MODEM_FW_UPDATE` + `write()` (§3.4).
(Corrected 2026-10-30: plus the raw BOOT write over the SPI link before the framed stages;
see the note at the top of §3.4.)

### 1.3 GPIO properties [proven]

Mandatory GPIO parser `__parse_dt_mandatory_gpio_pdata` (`modem_main.c:278-350`),
optional ones follow; link-PM GPIOs come from the `link_pm` sub-node
(`parse_dt_gpio_pdata` `modem_main.c:413` → node name `"link_pm"`, `modem_pm.h:23`;
parser `link_device_pm.c:1026-1093`).

| Property | Parser | Board value (`arch/arm/boot/dts/exynos5433-modem-ss333.dtsi`) |
|---|---|---|
| `mif,gpio_cp_on` | `modem_main.c:284` | `&gpr3 1` (`:24`) |
| `mif,gpio_cp_reset` | `:297` | `&gpc0 5` (`:26`) |
| `mif,gpio_pda_active` | `:311` | `&gpg2 1` (`:27`) |
| `mif,gpio_phone_active` | `:325` | `&gpa2 3` (`:28`) — AP input, IRQ (`gpio_to_irq`, `modem_ctrl_ss333.c` init §3.2) |
| `mif,gpio_cp_status` | `:400` | `&gpa2 5` (`:30`) — also link-PM CP2AP status |
| `mif,gpio_ipc_int2cp` | `:339` | `&gpa2 6` (`:31`) — AP2CP doorbell (toggled per TX, §3.6) |
| `mif,gpio_ap_dump_int` | (optional block) | `&gpr2 0` (`:32`) — AP forces CP dump |
| `link_pm/gpio_cp2ap_wakeup` | `link_device_pm.c:1031` | `&gpa3 1` (`:35`) |
| `link_pm/gpio_ap2cp_wakeup` | `link_device_pm.c` | `&gpf5 0` (`:36`) |
| `link_pm/gpio_cp2ap_status` | | `&gpa2 5` (`:37`, same pin as cp_status) |
| `link_pm/gpio_ap2cp_status` | | `&gpf1 2` (`:38`) |

`gpio_ap_wakeup` (used by LLI PM) is parsed at `modem_main.c:386-387` and propagated in
`link_device_lli.c:891`. Pinctrl: outputs configured function 1 + `con-pdn 3` (output
prev-state) — cp_on `:43-48`, ap_dump_int `:50-55`, pda_active `:59-64`, cp_reset `:66-71`,
ap2cp_status `:102-107`, ap2cp_wakeup `:109-114`, `gpio_ipc_int2cp` function 1 pin-val 0
`:116-121`; IRQ pins function 0xf: phone_active `:75-80`, cp2ap_status `:82-87`,
cp2ap_wakeup `:89-94`; `cp_off` gpf1-1 function 0 (input) `:96-100`; sleep states `:183-215`
(gpf1-1 high-z, gpf1-2/gpf5-0/gpr2-0/gpr3-1/gpc0-5/gpg2-1 PREV, gpv7-3 CP_SPI_MISO).

`ss333_init_modemctl_device` (`modem_ctrl_ss333.c:519-587`) requires all 8 control GPIOs
(missing → `-ENXIO`), drives `gpio_cp_reset=0` and `gpio_cp_on=0` at init, takes wake lock
`"ss333_wake_lock"`, and registers `cp_active_handler` on `gpio_to_irq(gpio_phone_active)`
with `IRQF_TRIGGER_RISING | IRQF_NO_THREAD | IRQF_NO_SUSPEND` (`:571-575`).

### 1.4 IO-device table [proven]

Parsed by `parse_dt_iodevs_pdata` (`modem_main.c:441-483`): per child node
`iod,name/:459`, `iod,id/:460`, `iod,format/:461`, `iod,io_type/:462`, `iod,links/:463`,
`iod,tx_link/:464-465` (only read when `count_bits(links) > 1`), `iod,attrs/:466`,
`iod,app/:467`; when `attrs & ATTR_SBD_IPC` also the 4 buffer properties (`:468-475`).
`iod,format` values: `IPC_FMT=0, IPC_RAW=1, IPC_RFS=2, IPC_MULTI_RAW=3, IPC_BOOT=4,
IPC_DUMP=5` (`modem_v1.h:53-63`); `io_type`: `IODEV_MISC=0, IODEV_NET=1, IODEV_DUMMY=2`
(`modem_v1.h:71-75`). All 13 nodes in `arch/arm/boot/dts/modem-ss333-pdata.dtsi`
(node block start lines in last column):

| # | name | id (SIPC5 ch) | format | type | links | attrs | app | UL bufs×sz | DL bufs×sz | dtsi |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | umts_ipc0 | 235 (FMT_0, `modem_v1.h:173`) | 0 FMT | misc | 0x400 (LLI) | 0x82 = SBD_IPC(bit7)+SIPC5(bit1) | RIL | 16×4096 | 32×4096 | :29-41 |
| 1 | umts_rfs0 | 245 (RFS_0, `:184`) | 1 RFS | misc | 0x400 | 0x82 | RFS | 16×2048 | 512×2048 | :42-54 |
| 2 | umts_csd | 1 (CS_VT_DATA) | 1 RAW | misc | 0x400 | 0x82 | CSVT | 32×2048 | 64×2048 | :55-67 |
| 3 | umts_router | 25 (BT_DUN) | 1 RAW | misc | 0x400 | 0x82 | Data Router | 16×2048 | 16×2048 | :68-80 |
| 4 | umts_dm0 | 28 (CPLOG1) | 1 RAW | misc | 0x400 | 0x82 | DIAG | 16×2048 | 128×2048 | :81-93 |
| 5 | ipc_loopback0 | 244 (FMT_9) | 0 FMT | misc | 0x400 | 0x82 | CLD | 16×2048 | 32×2048 | :94-106 |
| 6 | rmnet0 | 10 (PDP_0) | 1 RAW | **net** | 0x400 | 0x180 = SBD_IPC(bit7)+NO_LINK_HEADER(bit8) | NET | 256×2048 | 512×2048 | :107-118 |
| 7 | rmnet1 | 11 | 1 | net | 0x400 | 0x180 | NET | 256×2048 | 512×2048 | :120-131 |
| 8 | rmnet2 | 12 | 1 | net | 0x400 | 0x180 | NET | 256×2048 | 512×2048 | :133-144 |
| 9 | rmnet3 | 13 | 1 | net | 0x400 | 0x180 | NET | 256×2048 | 512×2048 | :146-157 |
| 10 | multipdp | 0 | 3 MULTI_RAW | dummy | 0x400 | 0x02 = SIPC5 | RIL | — | — | :159-167 |
| 11 | umts_boot0 | 215 (BOOT_0, `modem_v1.h:151`) | 4 BOOT | misc | **0x408** (LLI+SPI) | 0x02 | CBD | — | — | :168-177 |
| 12 | umts_ramdump0 | 225 (DUMP_0, `:162`) | 5 DUMP | misc | 0x400 | 0x202 = NO_CHECK_MAXQ(bit9)+SIPC5 | CBD | — | — | :178-186 |

Attr bit positions: `ATTR_SIPC5=1, ATTR_SBD_IPC=7, ATTR_NO_LINK_HEADER=8,
ATTR_NO_CHECK_MAXQ=9` (`modem_v1.h:250-262`). `iod,app` is informational
("RIL", "CBD", …) — the actual access control is device-node permissions.

### 1.5 LLI / M-PHY / SPI-boot DT nodes [proven]

`mipi-lli@10F24000` (`exynos5433-modem-ss333.dtsi:124-151`; identical in the shipped FDT,
`dumps/live_fdt.dts:5503-5558`):

- `compatible = "samsung,exynos-mipi-lli"` → `exynos-mipi-lli.c:1230` (of_match); child
  `mphy` `compatible = "samsung,exynos-mipi-lli-mphy"` → `exynos-mipi-lli-mphy.c:283`.
- `reg = <0x10f24000 0x4000 0x10f34000 0x4000 0x10fd0000 0x2000 0x105c0720 0x04>` — CPIF-LLI
  register block, second block, third block, and one PMU word at `0x105c0720`
  (LLI_PHY_CONTROL inside the `samsung,exynos5433-pmu` syscon range, written as
  `writel(1, lli->pmu_regs)`, `exynos-mipi-lli.c:296`).
- `interrupts = <0 184 0>, <0 185 0>`. **Corrected 2026-10-30:** index 0 (SPI 184) is the
  DME/link-event IRQ, handler `exynos_mipi_lli_irq` plus its thread (`exynos-mipi-lli.c:1132,1162`);
  index 1 (SPI 185) is the TL-signal doorbell IRQ, handler `mipi_lli_sig_irq`
  (`exynos-mipi-lli.c:1139`, `mipi-lli.c:456`). See SYNTHESIS.md §2.1, C03.
- Clocks: 17 entries; `dout_aclk_cpif_200` is forced to 100 MHz at probe
  (`exynos-mipi-lli.c:1193-1200`).
- `modems/ss333 { shdmem_size = <8>; is_ion_alloc=<0>; scrambler=<0>; automode=<0>; }` —
  shdmem_size in MiB (`mipi-lli.c:467` sets `lli->shdmem_size = MIPI_LLI_RESERVE_SIZE`
  = `SZ_8M`, `include/linux/mipi-lli.h:23`).
- `mphy { reg = <0x10f20000 0x4000>; modems/ss333 { init-gear = <2 2 1>; shd-refclk = <1>;
  e1-patch = <0>; } }` — gear table `get_setting` (`exynos-mipi-lli-mphy.c:159-215`):
  opmode HS, gear 2, HS-rate A; `shd-refclk=1` → shared reference clock.
- **Corrected 2026-10-30:** the SPI boot link is **active**: it carries the BOOT image on every
  boot (cbd switches `IOCTL_MODEM_SET_TX_LINK` to 3 = SPI for one raw write, then back to 10 =
  LLI), and the controller is **SPI4 at 0x14d00000** (0x14d30000 is SPI1). The original text,
  kept for reference, read: "SPI boot link (inactive here, `LINKDEV_SPI` present in `link_types`
  but `tx_link=10` on umts_boot0 selects LLI): `spi_4@14d30000/spidev@0` with
  `compatible = "spi_boot_link"` (`exynos5433-modem-ss333.dtsi:154-169`; string is
  `MODEM_BOOT_DEV_SPI`, `modem_v1.h:476`, matched in `boot_device_spi.c:303` — but that
  driver is not compiled, §1.1). The generic SPI link device `spi_create_link_device`
  (`link_device_spi.c:211+`, `ld->name = "spi_boot"`) is also created because
  `LINKDEV_SPI` is set in `link_types` — [inferred] it stays idle while `tx_link` routes
  boot traffic to LLI." That inference was wrong (SYNTHESIS.md §2.1, C09-C10).

Shared memory reservation [proven, address runtime-computed] (corrected 2026-10-30: the board
builds `MACH_UNIVERSAL5433`, so the code that runs is the identical
`arch/arm/mach-exynos/mach-universal5433.c:58-68`, made before the ION carveouts; the
espresso file named here is not built):
`arch/arm/mach-exynos/mach-espresso5433.c:50-51` —
`lli_phys_addr = memblock_alloc_base(MIPI_LLI_RESERVE_SIZE, MIPI_LLI_RESERVE_SIZE,
MEMBLOCK_ALLOC_ANYWHERE)` — **the physical base is chosen at runtime by memblock, not a DT
constant**; `drivers/misc/mipi-lli/mipi-lli.c:38` defines `lli_phys_addr`, consumed in
`mipi-lli.c:466-467`. The LLI hardware learns the region through the remap register
(`exynos_lli_cal_remap`, `exynos-mipi-lli.c:68`, power-of-two size, result written to
`EXYNOS_IAL_LL_INIT_ADDR_REMAP 0x1110` and `EXYNOS_IAL_BE_INIT_ADDR_REMAP 0x1114`
(`exynos-mipi-lli.h:167-168`) in `exynos_lli_setting` `:311`).

### 1.6 LLI register map essentials [proven]

From `drivers/misc/mipi-lli/exynos-mipi-lli.h`:

| Register | Offset | Use |
|---|---|---|
| `CPIF_LLI_SIG_IN0` | 0x1000 (`:37`) | SYSREG_CPIF register (reg[2], 0x10fd0000); corrected 2026-10-30: **not** the doorbell value, only the SIG masks are written; the CP2AP doorbell is read from `TL_SIGNAL_STATUS_LSB/MSB` 0x2004/0x2010 (`exynos-mipi-lli.c:480-481`) |
| `CPIF_LLI_SIG_INT_MASK0` | 0x1030 (`:44`) | interrupt mask |
| `EXYNOS_PA_DRIVE_TACTIVATE_DURATION` | 0x134 (`:65`) | written `0xf` (`exynos-mipi-lli.c:302`) |
| `EXYNOS_PA_SYSTEM_CLK_PERIOD` | 0x400 (`:84`) | written `SYSTEM_CLOCK_PERIOD = 10` — comment `= 1000MHz / System Clock` (`exynos-mipi-lli.c:36-38`, write `:299`) |
| `EXYNOS_DME_CSA_SYSTEM_STATUS/_SET/_CLR` | 0x908/0x90C/0x910 (`:141-143`) | master bit `1<<1`, mount bit `1<<2` |
| `EXYNOS_DME_LLI_INTR_STATUS` | 0x1010 (`:151`) | polled for `INTR_MPHY_HIBERN8_EXIT_DONE` |
| `EXYNOS_IAL_LL_INIT_ADDR_REMAP` / `_BE_INIT_` | 0x1110/0x1114 (`:167-168`) | shared-mem remap address |
| `TL_SIGNAL_STATUS/SET/CLR LSB/MSB` | 0x2004-0x2018 (`:194-199`) | doorbell set/clear (`send_signal` writes `TL_SIGNAL_SET_MSB` under GPIO_SIDEBAND, `exynos-mipi-lli.c:452`) |

Interrupt bits: `INTR_SW_RESET_DONE 1<<15` (`:223`), `INTR_MPHY_HIBERN8_EXIT_DONE 1<<6`
(`:232`), `INTR_LLI_MOUNT_DONE 1<<0` (`:238`). Mount control bits: `LLI_MOUNT_CTRL 1<<2`
(`:241`), `MASTER_NOT_SLAVE 1<<1` (`:242`), `LLI_MOUNTED 1<<0` (`:243`).

---

## 2. Userspace ABI

### 2.1 Device nodes

Created at probe (corrected 2026-10-30: **9** misc devices, i.e. the 8 `IODEV_MISC` nodes plus
the `multipdp` dummy, `modem_io_device.c:1786-1840`; the original said 11): misc nodes (`misc_register`, `modem_io_device.c:1794`; fops
`misc_io_fops` `modem_io_device.c:1466-1476` — `.open=misc_open, .release=misc_release,
.poll=misc_poll, .unlocked_ioctl/.compat_ioctl=misc_ioctl, .write=misc_write, .read=misc_read`)
+ 4 netdevs (`register_netdev`, `modem_io_device.c:1819`). ueventd permissions
(`device_gts28ltexx/rootdir/etc/ueventd.universal5433.rc:129-130`):
`/dev/umts* 0660 system radio`, `/dev/umts_csd 0660 loop_radio`.

### 2.2 ioctl numbers [proven, verbatim from `modem_prj.h:54-94`]

All commands are `_IO('o', n)` — numeric value `0x6Fnn`, no argument size encoding.

| Command | nr | Handler (misc_ioctl `modem_io_device.c:1089-1322`) | Argument |
|---|---|---|---|
| `IOCTL_MODEM_ON` 0x6F19 | :54 | case :1099 → `mc->ops.modem_on` = `ss333_on` | none |
| `IOCTL_MODEM_OFF` 0x6F20 | :55 | case :1107 → `ss333_off` | none |
| `IOCTL_MODEM_RESET` 0x6F21 | :56 | case :1115 → `ss333_reset` | none |
| `IOCTL_MODEM_BOOT_ON` 0x6F22 | :57 | case :1123 → `ss333_boot_on` | none |
| `IOCTL_MODEM_BOOT_OFF` 0x6F23 | :58 | case :1131 → `ss333_boot_off` | none |
| `IOCTL_MODEM_BOOT_DONE` 0x6F24 | :59 | case :1139 → `ss333_boot_done` (wake unlock) or 0 | none |
| `IOCTL_MODEM_PROTOCOL_SUSPEND` 0x6F25 | :61 | case :1258 — **only** when `iod->format == IPC_MULTI_RAW`, else `-EINVAL`; stops all netdevs | none |
| `IOCTL_MODEM_PROTOCOL_RESUME` 0x6F26 | :62 | case :1266 — condition is inverted (`format != IPC_MULTI_RAW`) [proven; upstream bug] | none |
| `IOCTL_MODEM_STATUS` 0x6F27 | :64 | case :1145 — returns `int` phone_state; one-shot SIM attach/detach override; `STATE_NV_REBUILDING` read converts to `ONLINE` | returns int |
| `IOCTL_MODEM_DL_START` 0x6F28 | :66 | case :1175 → `ld->dload_start` = `mem_start_download` | none |
| `IOCTL_MODEM_FW_UPDATE` 0x6F29 | :67 | case :1183 → `ld->firm_update` = `mem_update_firm_info` | user pointer to `struct std_dload_info` (12 B) |
| `IOCTL_MODEM_NET_SUSPEND` 0x6F30 | :69 | **no handler** in misc_ioctl → falls to `default` (`:1310-1316`): `ld->ioctl` (unset on LLI) → `-EINVAL` | — |
| `IOCTL_MODEM_NET_RESUME` 0x6F31 | :70 | same, no handler → `-EINVAL` | — |
| `IOCTL_MODEM_DUMP_START` 0x6F32 | :72 | case :1208 → `mc->ops.modem_dump_start` else `ld->dump_start` | none |
| `IOCTL_MODEM_DUMP_UPDATE` 0x6F33 | :73 | case :1227 → `ld->dump_update` | pointer (link-specific) |
| `IOCTL_MODEM_FORCE_CRASH_EXIT` 0x6F34 | :74 | case :1191 → `ss333_force_crash_exit` | none |
| `IOCTL_MODEM_CP_UPLOAD` 0x6F35 | :75 | case :1243-1256 — writes `"CP Crash "` + 512 B user info into `cp_crash_info`, then **`panic()`**. **Never issue it** (corrected 2026-10-30: with `oops=panic` it reboots the tablet; SYNTHESIS.md rule 7) | user buffer ≤ `CP_CRASH_INFO_SIZE` 512 |
| `IOCTL_MODEM_DUMP_RESET` 0x6F36 | :76 | case :1200 → `ss333_dump_reset` | none |
| `IOCTL_LINK_CONNECTED` 0x6F33 | :78 | **collides numerically with DUMP_UPDATE**; no distinct handler | — |
| `IOCTL_MODEM_SET_TX_LINK` 0x6F37 | :79 | case :1286-1310 — `copy_from_user` int link_type, switches `iod` current link | pointer to int |
| `IOCTL_MODEM_RAMDUMP_START` 0x6FCE | :81 | case :1219 → `ld->dump_start` | none |
| `IOCTL_MODEM_RAMDUMP_STOP` 0x6FCF | :82 | case :1235 → `ld->dump_finish` | pointer |
| `IOCTL_MODEM_XMIT_BOOT` 0x6F40 | :84 | case :1167 → `ld->xmit_boot` — **NULL on this board → `-EINVAL`** (§1.2) | pointer to `struct modem_firmware` |
| `IOCTL_MODEM_GET_SHMEM_INFO` 0x6F41 | :86 | defined only `#ifdef CONFIG_LINK_DEVICE_SHMEM` — not built | — |
| `IOCTL_DPRAM_INIT_STATUS` 0x6F43 | :88 | no handler here → `-EINVAL` | — |
| `IOCTL_LINK_DEVICE_RESET` 0x6F44 | :90 | no handler here → `-EINVAL` | — |
| `IOCTL_MIF_LOG_DUMP` 0x6F51 | :93 | case :1274 — dumps mif log, copies out `unsigned long` size | user pointer |
| `IOCTL_MIF_DPRAM_DUMP` 0x6F52 | :94 | no handler here → `-EINVAL` | — |
| `IOCTL_MODEM_GET_CP_BOOTLOG` 0x6F47 | (added 2026-10-30; defined in later modem_v1 trees, not here) | no handler on the LLI link → `-EINVAL`; cbd sends it after a failed `BOOT_OFF` | none |
| `IOCTL_MODEM_CLR_CP_BOOTLOG` 0x6F48 | (added 2026-10-30) | same → `-EINVAL`; cbd sends it after a successful `BOOT_OFF` | none |

`default` case (`modem_io_device.c:1310-1316`): forwards to `ld->ioctl` if the link defines
one (LLI does not) else `-EINVAL`.

### 2.3 Structures [proven]

```c
struct modem_firmware {          /* modem_prj.h:147-151 */
    char *binary;                /* user pointer to image      */
    u32   size;
};                               /* + modem_firmware_64 :153-157 under CONFIG_COMPAT */

struct std_dload_info {          /* sipc5.h:244-248, __packed, 12 bytes */
    u32 size; u32 mtu; u32 num_frames;
};

struct sipc_fmt_hdr {            /* modem_prj.h:165-172, __packed, 7 bytes */
    u16 len; u8 msg_seq, ack_seq, main_cmd, sub_cmd, cmd_type;
};
```
All three are reproduced in `modem_v1_uapi.h` (§9).

### 2.4 read/write/poll semantics on `/dev/umts_boot0` during boot [proven]

- **open** (`misc_open`, `modem_io_device.c:976-1003`): `atomic_inc(&iod->opened)`, then
  `ld->init_comm` per connected link. On LLI `init_comm = mem_init_comm`
  (`link_device_memory_main.c:629-692`): if `cp_boot_done` already 1 → return (IOSM
  open-ch path not built); when FMT ch 235-244 opened and the paired RFS is opened too →
  `__tx_iosm_message(IOSM_A2C_INIT_END)` + `cp_boot_done = 1`. **Opening both
  `/dev/umts_ipc0` and `/dev/umts_rfs0` is what satisfies `rild_ready`**
  (`link_ctrlmsg_command.c:56-83`: `fmt_iod->opened > 0 && rfs_iod->opened > 0`).
- **write** (`misc_write`, `modem_io_device.c:1324-1415`): rejects `format <= IPC_RFS &&
  id == 0` with `-EINVAL` (`:1338`); rejects when `!cp_online(mc) && sipc5_ipc_ch(iod->id)`
  with `-EPERM` (`:1340`) — note `sipc5_ipc_ch()` covers FMT/RAW-IPC/RFS channels but **not**
  ch 215/225, so boot writes are allowed in any state. Builds SIPC5 header
  (headroom = header size; tailroom = padding to `sizeof(size_t)` when `ld->aligned`), then
  `ld->send`. Return value is `ret - headroom - tailroom` (`:1414`) — i.e. the *payload*
  length consumed.
- **read** (`misc_read`, `:1417-1457`): waits up to 100 ms (`wait_event_timeout`) for RXQ
  data, dequeues one skb, copies min(len, skb->len); on partial copy the remainder is pushed
  back (`skb_pull` + `skb_queue_head`).
- **poll** (`misc_poll`, `:1025-1088`): in `STATE_BOOTING`/`STATE_ONLINE` → `POLLIN` when
  RXQ non-empty; in `CRASH_*`/`NV_REBUILDING` → `POLLHUP` for FMT/BOOT devices, DUMP device
  gets `POLLIN` if data, else sleeps 20 ms. `cbd` can (and ramdump tools do) `poll()` umts_boot0
  for the `STATE_*` transitions delivered through `modem_state_changed` → wake-up.

---

## 3. Boot sequence: power-off → STATE_ONLINE

Kernel state machine: `enum modem_state` (`modem_prj.h:124-134`) — OFFLINE, CRASH_RESET,
CRASH_EXIT, BOOTING, ONLINE, NV_REBUILDING, LOADER_DONE, SIM_ATTACH, SIM_DETACH.
Link states `LINK_STATE_OFFLINE/IPC/CP_CRASH` (`modem_prj.h:136-140`).

### 3.1 Kernel-side power control (`modem_ctrl_ss333.c`) [proven]

- **`ss333_on`** (`:159-209`): disable `irq_cp_active`; `iod → STATE_OFFLINE`;
  `gpio_pda_active = 1`; wake_lock; `ld->off` (LLI: `mipi_lli_intr_disable + stop_pm`,
  `link_device_lli.c:602-606`); **`gpio_cp_on = 0`, msleep(100); `gpio_cp_reset = 0`,
  msleep(500); `gpio_cp_on = 1`, msleep(100); `ld->reset` (LLI: `mipi_lli_intr_enable +
  mipi_lli_reset`, `link_device_lli.c:589-593`); `gpio_ap_dump_int = 0`;
  `gpio_cp_reset = 1`, msleep(300)**. Exact GPIO order and delays — quoted, not invented.
- **`ss333_off`** (`:211-272`): disable irq; if already OFFLINE exit; state → OFFLINE;
  del crash_ack_timer; `ld->close_tx`; if `cp_on==0` exit; wait for `phone_active` **high**
  (≤150 × 20 ms; corrected 2026-10-30, the loop breaks when the line reads 1,
  `modem_ctrl_ss333.c:251-256`); `ld->off`; `gpio_cp_reset → 0`. CP_ON is left high.
- **`ss333_reset`** (`:274`): calls `ss333_on` after `ss333_off`.
- **`ss333_boot_on`** (`:382-403`): `ld->boot_on` = `mem_boot_on`
  (`link_device_memory_main.c:775-801`: `cp_boot_done=0`, link state → OFFLINE,
  purge TXQ; `sbd_deactivate` only under `CONFIG_LTE_MODEM_XMM7260` — **not** compiled for
  SS333); `gpio_ap_status = 1`; `INIT_COMPLETION(init_cmpl)`, `INIT_COMPLETION(off_cmpl)`;
  bootd + iod → **STATE_BOOTING**.
- **`ss333_boot_off`** (`:405-429`): `wait_for_completion_timeout(&mc->init_cmpl,
  MIF_INIT_TIMEOUT = 30*HZ)` (`:28`) — timeout → `-EAGAIN`; then `mif_enable_irq(cp_active)`;
  bootd + iod → **STATE_ONLINE**; `forced_cp_crash = 0`. **`init_cmpl` is completed by
  `cmd_phone_start_handler` (`link_ctrlmsg_command.c:164`), i.e. by the CP's own
  PHONE_START doorbell — this is the kernel<->CP handshake that gates STATE_ONLINE.**
- **`ss333_boot_done`** (`:431-441`): wake_unlock only.
- **`ss333_force_crash_exit`** (`:312-337`): arms `crash_ack_timer`
  (`FORCE_CRASH_ACK_TIMEOUT = 10*HZ`, `modem_prj.h:111`; expiry →
  `handle_no_response_cp_crash` `:290`), wake_lock, `ld->off`, `gpio_ap_dump_int = 1`.
- **`ss333_dump_reset`** (`:338-380`): disable irq; → STATE_CRASH_EXIT; wake_lock; `ld->off`;
  `gpio_cp_reset=0`; `udelay(200)`; `ld->reset`; `gpio_cp_reset=1`; msleep(300);
  `gpio_ap_status=1`.
- **`cp_active_handler`** (phone_active rising IRQ, `:45-101`): ignored unless
  `cp_online`; if `cp_reset == 0` exit; `phone_active` high + `cp_on == 0` →
  STATE_OFFLINE; high + was ONLINE → **STATE_CRASH_EXIT** (CP crash signal), deleting the
  ack timer and calling `ld->close_tx` (`:88-97`). Both `iod` and `bootd` are notified on
  every transition (`:84-91`).

### 3.2 LLI / M-PHY hardware bring-up [proven]

Called via `ld->reset` inside `ss333_on`:

1. `mipi_lli_intr_enable()` + `mipi_lli_reset()` (`link_device_lli.c:589-593`).
2. `mipi_lli_reset` (`mipi-lli.c:217-226`) → `exynos_lli_init` (`exynos-mipi-lli.c:271`):
   `set_intr_enable` + `exynos_lli_soft_reset` (`:266`).
3. IRQ `INTR_SW_RESET_DONE (1<<15)` triggers `exynos_lli_setting` (`exynos-mipi-lli.c:900+`,
   handler → `:282-315`): state → `LLI_UNMOUNTED`/`LLI_WAITFORMOUNT` (`:285-289`);
   `exynos_lli_system_config`; **`writel(1, lli->pmu_regs)`** — enable LLI_PHY_CONTROL at
   PMU `0x105c0720` (`:296`); `writel(10, EXYNOS_PA_SYSTEM_CLK_PERIOD 0x400)` (`:299`,
   define `exynos-mipi-lli.c:36-38`); `writel(0xf, EXYNOS_PA_DRIVE_TACTIVATE_DURATION
   0x134)` (`:302`); remap calc → `EXYNOS_IAL_LL_INIT_ADDR_REMAP 0x1110` +
   `EXYNOS_IAL_BE_INIT_ADDR_REMAP 0x1114` (`:311`).
4. Master role & mount: `exynos_lli_set_master` (`:387-391`) writes
   `is_master << 1` to `DME_CSA_SYSTEM_SET 0x90C`; `exynos_lli_link_startup_mount`
   (`:396-426`): as master, if `LLI_MOUNTED` skip, else set `LLI_MOUNT_CTRL (1<<2)`; as
   slave, poll `DME_LLI_INTR_STATUS 0x1010` for `INTR_MPHY_HIBERN8_EXIT_DONE (1<<6)`
   (1000 loops, fail → "HIBERN8 Exit Failed"), then set `LLI_MOUNT_CTRL`.
   **Who drives steps 4**: the ops are reachable only through the debugfs-style sysfs
   attribute `/sys/devices/…mipi-lli/lli_control` (`mipi-lli.c:312-313`, mode 0644,
   `device_create_file` `:481`): command `2` = `set_master(true)`, command `3` =
   `link_startup_mount` (`store_mipi_lli_control`, `mipi-lli.c:261-311`).
   **Corrected 2026-10-30 — the inference that stood here was wrong and is dangerous:**
   userspace must **never** write `lli_control`. The CP is the LLI **master**: its first stage
   (BOOT) writes `MASTER_NOT_SLAVE | LLI_MOUNT_CTRL` and waits for the mount; the AP stays
   **slave** (`is_master = false`, `exynos-mipi-lli.c:1155`) and its hard-IRQ handler writes
   `LLI_MOUNT_CTRL` itself on `INTR_MPHY_HIBERN8_EXIT_DONE` (`:926-932`). cbd only **reads**
   `lli_control` until it shows `MIPI-LLI 1`. Command `2` would flip the AP to master and
   commands `1`/`4` reset the link under a running CP (SYNTHESIS.md §2.1, C04; `radio_image.md`
   §2.6).
5. M-PHY: `exynos_mphy_init` (`exynos-mipi-lli-mphy.c:26-48`) — TX_HS_SYNC_LENGTH 0x45,
   TX_LCC_ENABLE 0x0, TX/RX_MODE 0x2, TX/RX_HSGEAR 2 (matches `init-gear = <2 2 1>`);
   `cmn_init` (`:53-90`) SS333-specific CMN register writes (0x4f=0x00 shared clk,
   0x1C=0x41 under `CONFIG_SOC_EXYNOS5433 && CONFIG_UMTS_MODEM_SS333`, 0x19=0xD6,
   0x46=0x2c, AFC first-boot 0x44=0/0x31=0, …); `ovtm_init` (`:96-125`) OVT/TX/RX trim.
   Register 0x2E carries the comment *"It should be changed by CP. (0x2E)"* (`:124` area) —
   **CP-owned value; do not change** [proven comment].

### 3.3 Shared-memory layout & handshake [proven]

8 MiB region (`MIPI_LLI_RESERVE_SIZE = SZ_8M`, `mipi-lli.h:23`), runtime address (§1.5).
`mem_register_ipc_rgn(mld, mipi_lli_get_phys_base(), mipi_lli_get_phys_size())`
(`link_device_lli.c:852-870`) then `mem_setup_ipc_map` (`link_device_memory_main.c:892-918`):
region < `SZ_4M` → `-EINVAL`; vmap + memset 0; `remap_4mb_map_to_ipc_dev`
(`link_device_memory.c:355-436`) wires the first 4 MiB as the legacy IPC map:

```
struct shmem_4mb_phys_map {          /* link_device_memory.h:89-110, __packed */
    u32 magic, access;               /* MEM_IPC_MAGIC 0xAA (:447), access==1 */
    u32 fmt_tx_head, fmt_tx_tail, fmt_rx_head, fmt_rx_tail;
    u32 raw_tx_head, raw_tx_tail, raw_rx_head, raw_rx_tail;
    u8  reserved[4056];              /* SZ_4M - ... (:81) */
    u8  fmt_tx_buff[4096];           /* :82 */
    u8  fmt_rx_buff[4096];           /* :83 */
    u8  raw_tx_buff[2084864];        /* :84 */
    u8  raw_rx_buff[2097152];        /* :85 */
};
```
Magics (`link_device_memory.h:447-450`): `MEM_IPC_MAGIC 0xAA`, `MEM_CRASH_MAGIC
0xDEADDEAD`, `MEM_BOOT_MAGIC 0x424F4F54 ("BOOT")`, `MEM_DUMP_MAGIC 0x44554D50 ("DUMP")`.
`mld->dpram_magic = true` for this board (`memory_main.c:1065-1069`, from
`LINK_ATTR_DPRAM_MAGIC` in 0x3C9) → `set_magic/get_magic` validation active.

Reset/handshake: `mem_reset_ipc_link` (`link_device_memory.c:318-353`) clears
magic+access, resets all heads/tails, purges queues, then writes `magic = 0xAA`,
`access = 1` and verifies by read-back (fail → `-EACCES`). Called from
`cmd_phone_start_handler` (`link_ctrlmsg_command.c:150`).
`ipc_active` (`link_device_memory_main.c:66-95`): `cp_online && !forced_cp_crash &&
(dpram_magic → magic==0xAA && access==1)`.

SBD rings (the SIPC5-IPC transport over LLI): `CONFIG_LINK_DEVICE_WITH_SBD_ARCH`;
`create_sbd_link_device` (`link_device_memory_sbd.c:410-448`, `sl->version = 1` `:428`);
layout (`include/sbd.h:59-71`): CMD_DESC_RGN @0 (64K), CTRL_RGN @0 (1K), CMD_RGN @0x400
(1K), DESC_RGN @0x800 (62K), BUFF_RGN @0x10000. Descriptors `sbd_rb_desc` (`sbd.h:77-110`,
signaling=1, sig_mask = `MASK_INT_VALID|MASK_SEND_DATA = 0x81`,
`link_device_memory_sbd.c:103-118`). Ring map `sbd_global_desc` (`sbd.h:133-158`),
`rb_ch[32]`, write pointers array ordered UL-rp, UL-wp, DL-rp, DL-wp
(`link_device_memory_sbd.c:254-257`). Initialized when CP sends `CMD_INIT_START`:
`cmd_init_start_handler` (`link_ctrlmsg_command.c:86-117`) — requires `ld->sbd_ipc`,
`init_sbd_link` (`memory_sbd.c:391-403`), `ld->aligned` from `LINK_ATTR_IPC_ALIGNED`
(**not set** in 0x3C9 → `aligned = false`), `sbd_activate` (`sbd.h:359`), then AP answers
`CMD_PIF_INIT_DONE` (`:115`).

Doorbell: AP2CP interrupt value `cmd2int(cmd) = (cmd | 0x40) | 0x80`
(`link_device_memory.h:509-512`; mask/cmd fields `:127-137`), CP2AP parsed with
`int2cmd(x) = x & 0x3F` (`:504`).
`send_ap2cp_irq` (`link_device_lli.c:45-67`) with `CONFIG_EXYNOS_MIPI_LLI_GPIO_SIDEBAND`:
`mipi_lli_send_interrupt(mask)` (write `TL_SIGNAL_SET_MSB 0x2014`,
`exynos-mipi-lli.c:452`) **plus toggle `gpio_ipc_int2cp`** under `sig_lock`.
RX path (corrected 2026-10-30: the doorbell IRQ is SPI 185, handler `mipi_lli_sig_irq`, which
reads `TL_SIGNAL_STATUS_LSB/MSB` 0x2004/0x2010, not `CPIF_LLI_SIG_IN0`; the original wording
follows): `exynos_mipi_lli_irq` reads `CPIF_LLI_SIG_IN0 0x1000` → `mipi_lli_sig_irq`
(`mipi-lli.c:315-322`) → registered `lli_irq_handler` (`link_device_lli.c:640-674`) →
`mem_take_snapshot` + `mem_irq_handler` (`link_device_memory_main.c:34-56`) → tasklet →
`ipc_rx_func` (`:563-591`): `cmd_valid(intr)` → `mld->cmd_handler = mem_cmd_handler`
(wired `memory_main.c:1077`); else `recv_sbd_ipc_frames` (`:535`) for SBD channels.

### 3.4 Boot image download path [proven; this is the load-bearing finding]

> **Corrected 2026-10-30.** The BOOT image does **not** go over this path: it is written raw over
> **SPI** (`SET_TX_LINK(3)`, one `write()`, then wait for `cp_status` = 1). The `write()` path
> below carries the **STD_UDL stage frames** (`0x900D` BOOT-done, then TOC, MAIN + CRC, NV, and
> the mandatory FIN `0x9F00`), each stage announced by its own `FW_UPDATE` (informational: the
> kernel stores `img_info` and never reads it). No AP→CP doorbell is needed (BOOT busy-polls the
> ring head; U-6 resolved). Exact sequence: SYNTHESIS.md §2.6-§2.8.

With `link_attrs = 0x3C9` (no `XMIT_BTDLR`): `ld->xmit_boot == NULL` (§1.2) →
`IOCTL_MODEM_XMIT_BOOT` unusable. The working sequence, all wired for this board:

1. **`IOCTL_MODEM_DL_START`** → `mem_start_download` (`link_device_bootdump.c:194-222`):
   `reset_ipc_map`; `LINK_ATTR_MEM_BOOT` set → `sbd_deactivate(&mld->sbd_link_dev)`;
   `LINK_ATTR_BOOT_ALIGNED` (0x100, set) → `ld->aligned = true`; `dpram_magic` →
   `set_magic(MEM_BOOT_MAGIC 0x424F4F54)` + read-back verify (fail → `-EFAULT`).
2. **`IOCTL_MODEM_FW_UPDATE`** → `mem_update_firm_info` (`:235-249`):
   `copy_from_user(&mld->img_info, arg, sizeof(struct std_dload_info))` — 12-byte
   `{size, mtu, num_frames}` descriptor of the image about to be streamed.
3. **`write(fd_umts_boot0, chunk, n)`** → `misc_write` → `mem_send`
   (`link_device_memory_main.c:725-767`): `IPC_BOOT` + `sipc5_udl_ch(215)` →
   `xmit_udl` (`link_device_bootdump.c:97-127`): writes into the **legacy RAW TXQ**
   (`mld->dev[IPC_RAW]`) circular buffer via `udl_write` (`:59-91`,
   `check_udl_space` `:22-47` → `-EIO`/`-ENOSPC`, `circ_write`, `smp_mb`); on
   `-ENOSPC` retries up to **20 × 50 ms** (`:110-121`, `mdelay` in interrupt context,
   else `msleep`). Receiver: CP polls `raw_tx_head/tail`; AP never raises a doorbell for
   boot traffic [inferred — xmit_udl contains no `send_ap2cp_irq` call; whether CP needs a
   doorbell to poll faster is **unknown** U-6].
4. `IOCTL_MODEM_BOOT_OFF` → `ss333_boot_off` waits ≤30 s for CP `PHONE_START` (§3.1).

### 3.5 CP↔AP command handshake [proven]

`mem_cmd_handler` (`link_ctrlmsg_command.c:209-236`):
- `CMD_INIT_START (0x1)` → init SBD + reply `CMD_PIF_INIT_DONE (0xD)` (`:86-117`).
- `CMD_PHONE_START (0x8)` → `cmd_phone_start_handler` (`:119-168`): `start_pm`
  (corrected 2026-10-30: this board builds `LINK_POWER_MANAGEMENT_WITH_FSM=y` and `pm_enable`
  defaults to **1** (a read-only module parameter, `link_device_lli.c:41-42`), so `start_pm` is
  the FSM path `link_device_lli.c:213-233`, `PM_EVENT_CP_BOOTING`, which raises AP2CP_WAKEUP and
  AP2CP_STATUS; the stock log shows the FSM unmounting and remounting the link; the original
  wording was "with `pm_enable=0`, `link_device_lli.c:497-511` just takes `lli_ap_wlock`");
  if link already IPC and `rild_ready` → re-send `CMD_INIT_END (0x2)` (CP retries
  periodically otherwise); else `mem_reset_ipc_link`, then if `rild_ready` (FMT_0 and
  RFS_0 both open, `:56-83`) send `CMD_INIT_END` + `cp_boot_done = 1`;
  `ld->state = LINK_STATE_IPC`; **`complete_all(&mc->init_cmpl)`** (`:164`) →
  `ss333_boot_off` proceeds to STATE_ONLINE.
- `CMD_CRASH_RESET (0x7)` → link OFFLINE, notify `MDM_CRASH_CMD_RESET`
  (`modem_debug.h:43`) (`:170-183`).
- `CMD_CRASH_EXIT (0x9)` → `LINK_STATE_CP_CRASH`, del crash_ack_timer, notify
  `MDM_CRASH_CMD_EXIT` (`:185-207`).

Corrected 2026-10-30: `BOOT_OFF` waits **only** for the CP's `PHONE_START`; whether
`umts_ipc0`/`umts_rfs0` are open decides only whether `INIT_END` is sent then or later (the
second open sends it through `mem_init_comm`). Stock rild opens them after `STATE_ONLINE`, and a
loader must not open them between `DL_START` and the return of `BOOT_OFF`. The real order is
`SET_TX_LINK(10)` → `MODEM_ON` → `BOOT_ON` → `DL_START` → `SET_TX_LINK(3)` → BOOT over SPI →
wait `cp_status` = 1 → `SET_TX_LINK(10)` → wait `MIPI-LLI 1` → STD_UDL stages incl. FIN →
`BOOT_OFF` → open ipc0/rfs0 → `BOOT_DONE` (SYNTHESIS.md §2.6). The original one-line order,
kept for reference: Power-on order in one line: `IOCTL_MODEM_ON` (GPIO sequence §3.1, LLI reset+phy init)
→ `IOCTL_MODEM_BOOT_ON` (STATE_BOOTING) → DL_START → FW_UPDATE → write()×N →
(CP runs bootloader→MAIN, sends INIT_START → AP answers PIF_INIT_DONE; CP sends
PHONE_START) → AP sends INIT_END once rild has umts_ipc0+umts_rfs0 open →
`IOCTL_MODEM_BOOT_OFF` (returns after init_cmpl; STATE_ONLINE) → `IOCTL_MODEM_BOOT_DONE`.

### 3.6 Inferred `cbd` userspace sequence [inferred throughout]

> **Corrected 2026-10-30: superseded.** The real sequence (from the stock binary, Samsung's
> public cbd v1 source and the CP-side analysis) is in `research/analysis/loader_spec_v2.md` §4
> and `research/SYNTHESIS.md` §2.6-§2.7. The reconstruction below was wrong on: `-b s` (it means
> boot link = **SPI**, not "storage"); step 3 (never write `lli_control`); steps 5-7 (BOOT goes
> over SPI, then framed stages); step 8 (ipc0/rfs0 are opened after `BOOT_OFF`); the missing
> `cp_status` wait and FIN stage; and the crash path (`IOCTL_MODEM_CP_UPLOAD` must never be
> issued). The dangerous steps are also fixed in place.

Ground truth: `init.baseband.rc:44-52` — `service cpboot-daemon /vendor/bin/cbd
-d -t ss333 -b s -m l -p 13`, root, started once `ro.modemloader.done=1`; `-p 13` =
partition 13 = RADIO (`/dev/block/platform/15540000.dwmmc0/by-name/RADIO` symlinked to
`/dev/mbin0`, `init.baseband.rc:2`; `cbd.te:25-29` read access to `mbin0`/`mmcblk0p13`);
`-b s` [inferred] = boot from storage (RADIO partition), vs `-b r` ram (corrected 2026-10-30:
`-b s` selects the **SPI** boot link, `LINKDEV_SPI` = 3; CBD_RE.md §1); `-m l` =
link lli; `-d` = debug logging. cbd may also write `/sys/.../lli_control`
(corrected 2026-10-30: SELinux allows it, but cbd only reads the file)
(`cbd.te:43-44`) and `/proc/cmdline` + `overcommit_memory` (read, `cbd.te:40-41`).
`libsec-ril.so` exports `DoModemBoot`/`DoModemCrash`/`DoModemSilentReset`
(mangled at 0x1bf9b0/0x1bf9fc/0x1bf9c0) and opens `/dev/umts_boot0`
("Can't open modem boot (%s) with %d") — so RIL can re-trigger boot/crash paths.
(Corrected 2026-10-30: it cannot re-trigger the boot. `DoModemBoot()` is `WaitForOnline()`, which
only polls `IOCTL_MODEM_STATUS` on `umts_boot0`; `DoModemSilentReset()` is `exit(0)`; only
`DoModemCrash()` acts, through `IOCTL_MODEM_FORCE_CRASH_EXIT` on `umts_ipc0`;
`research/analysis/ril_runtime_rfs.md` §6.)

Reconstructed sequence (to be validated against the real cbd in the follow-up task):

1. Open `/dev/umts_boot0` (block until created by udev/ueventd).
2. `ioctl(boot0, IOCTL_MODEM_ON)` — kernel GPIOs CP on, resets LLI+M-PHY.
3. ~~Write `"2\n"`, `"3\n"` to `/dev/mipi-lli/lli_control`~~ — **corrected 2026-10-30: never.**
   The CP mounts the link as master; userspace only reads `lli_control` (after the BOOT write
   and the `cp_status` wait), and the port makes the attribute read-only.
4. `ioctl(boot0, IOCTL_MODEM_BOOT_ON)` → kernel state BOOTING, mem map reset.
5. Read RADIO image from `/dev/mbin0`; `ioctl(boot0, IOCTL_MODEM_DL_START)`.
6. `ioctl(boot0, IOCTL_MODEM_FW_UPDATE, &std_dload_info{size, mtu, num_frames})`.
7. Stream image: repeated `write(boot0, chunk, n)` respecting ≤20×50 ms retry
   (chunk size = `mtu` from step 6) [inferred].
8. ~~Wait for CP `INIT_START`, then open `/dev/umts_ipc0` and `/dev/umts_rfs0`~~ —
   **corrected 2026-10-30:** do not open them before `BOOT_OFF` returns; `BOOT_OFF` does not need
   them, and opening them earlier sends `INIT_END` to a CP that may still be downloading.
9. `ioctl(boot0, IOCTL_MODEM_BOOT_OFF)` — blocks ≤30 s for `PHONE_START`, then ONLINE.
10. `ioctl(boot0, IOCTL_MODEM_BOOT_DONE)`.
11. Hand off: rild (`/vendor/bin/hw/rild -c 1 -l $rild.libpath`, `rild.rc:2`) opens
    umts_ipc0/umts_rfs0/rmnet* — already open in step 8 [inferred: cbd may open them
    transiently only to satisfy rild_ready during boot; releases later].

Crash handling: `poll(umts_boot0, POLLHUP)` or `IOCTL_MODEM_STATUS` polling →
STATE_CRASH_EXIT → read dump from `/dev/umts_ramdump0` (ch 225), then
`IOCTL_MODEM_DUMP_RESET` (= silent reset) or `IOCTL_MODEM_CP_UPLOAD` (panics AP with
"CP Crash " + 512 B info for bugreport). **Corrected 2026-10-30:** a silent reset is
`IOCTL_MODEM_OFF` followed by a full normal boot (`DUMP_RESET` only prepares a DUMP-mode boot),
and `IOCTL_MODEM_CP_UPLOAD` must never be issued.

---

## 4. Firmware image expectations

> **Corrected 2026-10-30.** The unknowns below are resolved by `research/analysis/radio_image.md`
> and `loader_spec_v2.md`: the TOC is known (BOOT 0x29FC at 0x200, MAIN 0x21271A0 at 0x2C00,
> NV 0x100000 loaded at CP 0x47EE0000, OFFSET never sent); chunking is MTU 0x810 / MSS 0x800,
> one `FW_UPDATE` per stage; load addresses travel to the CP in the TOC stage; **NV is streamed
> whole (1 MiB) at stage 3 of the boot download**, RFS is only the runtime path; `FW_UPDATE` is
> not used after boot. `nv_data.bin` must never be created or written (SYNTHESIS.md rule 4).

**[The RADIO partition image and `cbd` were not available. Everything below is the
kernel-side contract only; `nv_data.bin` / `m9kefs*` contents were NOT accessed and must
not be.]**

- The kernel performs **no TOC/CRC/signature parsing of the boot image**. `mem_send` →
  `xmit_udl` writes opaque bytes; the only checks are space (`check_udl_space`) and the
  magic words above [proven]. Any TOC/header layout inside the RADIO image is a CP-side
  contract — **unknown U-1**. (Samsung TOC formats on other SoCs use `toc_count` +
  per-image {name "BOOT"/"MAIN", binary, size, mmaps, signatures}; treat as hypothesis.)
- Image descriptor supplied by userspace: `std_dload_info {size, mtu, num_frames}`
  (§3.4 step 2) — so chunking is decided in userspace; `mtu` must fit the RAW TXQ free
  space behavior (qsize 2 084 864 B) [proven sizes; practical mtu unknown U-2].
- Load addresses: not visible to the AP. CP RAM base/load addresses are **unknown U-3**;
  `link_device_memory.h:323-325` `boot_base/boot_size` fields exist but are only used by
  the SHMEM link (not built).
- NV data: `cbd.te:47-50` grants read on `/efs` dirs and rw on
  `/efs/nv_data.bin` (+`.md5` chmod 770, `init.baseband.rc:20-21`); RFS verbs
  `RFS_NV_READ_ITEM / RFS_NV_WRITE_ITEM / RFS_NV_WRITE_ALL_ITEM / RFS_NV_RESTORE /
  RFS_NV_BUFFER_MESSAGE` exist in `libsec-ril.so` strings — NV is delivered to CP via
  RFS commands on ch 245 at runtime, not through the boot image [inferred from strings;
  exact item map unknown U-4]. `m9kefs1-3` partitions referenced by name in ueventd
  (`ueventd.universal5433.rc`) — contents not accessed.
- Firmware update flow (runtime, post-boot): `IOCTL_MODEM_FW_UPDATE` re-used with
  `IOCTL_MODEM_DL_START` while ONLINE — same primitives [proven wiring; usage by cbd
  unknown U-5].

---

## 5. Runtime IPC (SIPC5), RIL, RFS, rmnet

### 5.1 Framing [proven]

`include/sipc5.h`: link header `sipc5_link_header` (`:22-29`) `__packed`
`{u8 cfg; u8 ch; u16 len; union {ctrl, ext_len}}`; `SIPC5_START_MASK 0b11111000`,
`CONFIG_MASK 0b111`, cfg bits `PADDING_EXIST 4 / EXT_FIELD_EXIST 2 / CTL_FIELD_EXIST 1`;
header sizes 4 / +ctl 5 / +ext_len 6 (`sipc5_get_hdr_len` `:104-115`); padding to
`sizeof(size_t)` when `PADDING_EXIST` (`sipc5_calc_padding_size` `:93-101`).
TX (`misc_write`, `modem_io_device.c:1706-1758`): `sipc5_build_config` sets
`START_MASK | PADDING_EXIST (if ld->aligned) | EXT_LENGTH_CFG (if len > 0xFFFF)`;
`sipc5_build_header` writes cfg/ch, 16- or 32-bit len. Classifiers (`:155-209`):
`sipc5_fmt_ch` (235-244), `sipc5_boot_ch` (215-224), `sipc5_dump_ch` (225-234),
`sipc5_ipc_ch` (`ch > 0 && (ch < 215 || ch > 234)`).
FMT payload = `sipc_fmt_hdr` (7 B) + data. `STD_UDL_STEP_SEND 0x1`, `STD_UDL_CRC 0xC`
(`:240-242`) — legacy UDL control steps; **not** used on this board's BOOT path (raw
streaming, §3.4) [inferred from absence of STD_UDL writes in xmit_udl]. **Corrected
2026-10-30:** STD_UDL is used end to end: userspace writes the STD_UDL words and frames
(`0x9S0T`), the kernel only carries them; see SYNTHESIS.md §2.7.

### 5.2 RX demux and queues [proven]

`rx_demux` (`modem_io_device.c:349-385`): ch 0 → `-ENODEV`; FMT ch → `rx_fmt_ipc` (`:266`);
PDP ch → `rx_multi_pdp` (`:286`, netdevs); other → `rx_raw_misc` (`:274`); unopened iod →
`-ENODEV`. RXQ cap `MAX_IOD_RXQ_LEN = 2048` (`modem_prj.h:99`); per-read wait 100 ms
(§2.4). Flow control: `IOCTL_MODEM_PROTOCOL_SUSPEND/RESUME` via multipdp; wake time
FMT `HZ/2`, RAW `HZ*6` (§1.1).

### 5.3 rild / libsec-ril.so [proven from strings; never executed]

- Sockets/services (`device_gts28ltexx/rootdir/etc/rild.rc`): `ril-daemon` `-c 1 -l
  ${rild.libpath}` (`:2`), sockets `rild` (stream 660 system radio `:4`),
  `sap_uim_socket1` (660 bluetooth `:5`), `rild-debug` (`:6`); second slot `ril-daemon1`
  (`:12-19`, disabled unless `ro.multisim.simslotcount=2` `:32-33`).
  `rild.libpath` → `/vendor/lib64/libsec-ril.so`-class library [inferred; 32-bit ELF here].
  (Corrected 2026-10-30: `rild.libpath=/system/lib/libsec-ril.so`, 32-bit.)
- libsec-ril.so (ELF32 LE ARM DYN; survey via `arm-linux-gnueabihf-strings -n 6` in a
  throwaway container, binary not executed): opens `/dev/umts_ipc0`
  ("open error: errno %d"), `/dev/umts_rfs0`, `/dev/umts_boot0`, plus
  `/dev/mbin0`, `/dev/alarm`, `/dev/block/param`, `/dev/esoc-0`, `/dev/modem_br`,
  `/dev/qmi_dump`, `/dev/ramdump_memshare`, `/dev/tun`; sysfs
  `/sys/devices/virtual/misc/multipdp/waketime`,
  `/sys/module/rmnet_usb/parameters/dump_ctrl_msg`; error string
  `"IOCTL_MODEM_FORCE_CRASH_EXIT Failed."` (proves it issues ioctl 0x6F34); properties
  `gsm.sim.operator.numeric`, `gsm.operator.*`, `gsm.sim.*`,
  `persist.radio.roaming_iptype`, `net.temp.mtu`; exports `RIL_Init` @0x0e346c,
  `RIL_SAP_Init` @0x0e37c0, `_Z11DoModemBootv` @0x1bf9b0, `_Z12DoModemCrashv`,
  `_Z18DoModemSilentResetv`; logging `"IpcModem::%s msg->mObj=%p, modem type=%d
  MainCmd=%d SubCmd=%d CmdType=%d"` (maps 1:1 onto `sipc_fmt_hdr`).
- Full RFS verb set (strings): `RFS_OPEN_FILE, RFS_CLOSE_FILE, RFS_READ_FILE,
  RFS_WRITE_FILE, RFS_GET_FILE, RFS_PUT_FILE, RFS_GET_FILE_INFO, RFS_GET_HANDLE_INFO,
  RFS_LSEEK_FILE, RFS_FTRUNCATE_FILE, RFS_CREATE_FILE, RFS_RENAME_FILE, RFS_UNLINK_FILE,
  RFS_MAKE_DIR, RFS_OPEN_DIR, RFS_READ_DIR, RFS_CLOSE_DIR, RFS_NV_READ_ITEM,
  RFS_NV_WRITE_ITEM, RFS_NV_WRITE_ALL_ITEM, RFS_NV_RESTORE, RFS_NV_BUFFER_MESSAGE,
  RFS_CMD`. RFS frames are FMT-style `sipc_fmt_hdr` on ch 245 with `main_cmd = RFS_CMD`
  and path/payload in the data [inferred mapping; CP-side handler not in tree].
  **Corrected 2026-10-30:** RFS frames on `umts_rfs0` use a 6-byte header
  `{u32 length (whole frame); u8 cmd; u8 id}` with commands 0x01-0x17 and the request id echoed
  in the reply; the FMT `RFS_CMD` (0x15) handler is a stub. The kernel cuts each `write()` to
  the 2048-byte uplink slot, so replies are written with a short-write loop
  (`research/analysis/ril_runtime_rfs.md` §5; SYNTHESIS.md §2.12).

### 5.4 Data path / PDP [proven]

`rmnet0-3` (DT) ↔ `SIPC_CH_ID_PDP_0..3` (ch 10-13), format RAW, `ATTR_NO_LINK_HEADER`
→ payload is bare IP (no extra header beyond SIPC5 link header), netdevs created by
`sipc5_init_io_device`/`register_netdev` (`modem_io_device.c:1819`).
(Corrected 2026-10-30: PDP contexts are controlled by FMT GPRS messages on `umts_ipc0`;
`multipdp` is only a flow-control and `waketime` node; cid n maps to rmnet(n−1).)
`multipdp` (dummy, MULTI_RAW ch 0) is rild's control node for PDP enable/disable
(ioctl `IOCTL_MODEM_PROTOCOL_SUSPEND/RESUME` + per-PDP multipdp ioctls — the legacy
`multiformat` ioctls live on that node [inferred; not part of this ABI dump]).
`init.baseband.rc:9-17` pins rps_cpus=1 and netdev_max_backlog 8192 for rmnet0-7 —
**rmnet4-7 don't exist in DT (only 0-3)** → those writes fail harmlessly [inferred].
ARGOS (`CONFIG_ARGOS=y`) sets RX masks to `hmp_slow_cpu_mask` with a hard-coded cpu3
comment (`link_device_memory_main.c:920-935`).

---

## 6. Voice-call PCM path (CP ↔ WM1814)

[proven unless noted] Codec is **Wolfson WM1814** (`compatible = "wlf,wm1814"`,
`arch/arm/boot/dts/exynos5433-gts28_ww_open_09.dts:50`; live FDT `:1974`) — **not WM5110**
(the task brief's guess; the ASoC machine driver is Samsung "pacific"/"vegas", whose
fallback-compatible string is `samsung,pacific-arizona`). The baseband dai_link
(`exynos5433-gts28_ww_open_09.dts:1221-1226`, `samsung,pacific-arizona` machine):

- cpu: `snd-soc-dummy-dai`; codec_dai: **`vegas-aif2`** (`sound/soc/codecs/vegas.c:1180`);
  ops `pacific_aif2_ops` (`sound/soc/samsung/pacific_arizona.c:1180-1183`), `ignore_suspend`.
- **No CPU DAI / I2S controller in the link** — PCM samples flow CP↔codec over dedicated
  PCM pins (AIF2), so the AP only configures clocks. The I2S0 controller exists
  (`exynos5433.dtsi` equivalent) but is used for AIF1 media, not voice.
- `pacific_aif2_hw_params` (`pacific_arizona.c:1078-1180`): 8000 Hz → BCLK 256000,
  16000 Hz → 512000, default warns + 256000; `aif2mode=0` → `CBS_CFS` (codec slave: the
  **CP provides BCLK/LRCLK**; corrected 2026-10-30: I2S, NB_NF, two 16-bit slots; FLL2 uses
  MCLK1 24 MHz as reference and is synchronised to AIF2BCLK; the stock mixer file is
  `mixer_paths_rev09.xml`; SYNTHESIS.md §2.15); TDM when `aif_format[1] & 0x10`.
- Clocking: `FLL2` reference = `ARIZONA_FLL_SRC_MCLK1` at `PACIFIC_DEFAULT_MCLK1`
  24 000 000 (`pacific_arizona.c:51`), asyncclk 49 152 000 (`:102-113`); FLL2 source =
  AIF2BCLK → locks 256k/512k to 48k family; `SAMPLE_RATE_1 = 48000`.
- Mainline reference: `linux-6.12/sound/soc/samsung/tm2_wm5110.c:133-186`
  `tm2_aif2_hw_params` (8k/12k/16k → 49 152 000 asyncclk; 11025 → 45 158 400) and the
  "WM5110 Voice" dai_link `CBM_CFM`, `ignore_suspend` (`:457-462`) — structurally
  identical voice link on a sibling SoC.

Power/sequence caveats: codec driver is out-of-tree ("vegas"); AIF2 is owned by the CP
side during calls — a userspace `cbd` replacement does not touch PCM [inferred].

---

## 7. Mainline 6.12 port feasibility

Gap [proven]: **no** `mipi-lli`, `exynos-mipi-lli*`, `modem_v1`, `sipc5`, `ss333` files or
Kconfig symbols exist anywhere in `src/linux-6.12/`. Exynos5433 base is present:
PMU syscon `samsung,exynos5433-pmu` @0x105c0000 len 0x5008
(`linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi:916`), pinctrl `:850-874`,
I2S0 `:1921-1927`; boards tm2/tm2e only. The modem stack is arm32 code; a 5433 mainline
port is arm64 — pointer-size and dma addressing must be audited. (Corrected 2026-10-30: the
project's mainline kernel is **ARM32** (LPAE), as is its userspace; SIPC5 padding must stay at
4 bytes, which an arm64 kernel would change to 8.)

Dependency map (kernel components, LOC from `wc -l`):

| Component | Files | LOC | Mainline effort |
|---|---|---|---|
| mif core (probe/iod/ioctl) | modem_main/modem_io_device/modem_variation/modem_utils | 748+1872+173+1306 | rewrite against modern tty/misc/net APIs; big |
| SS333 power ctrl | modem_ctrl_ss333.c | 587 | small, GPIO+irq; nearly portable as-is |
| memory link + SBD | memory*.c + sbd.h | 437+1110+665+290+211+184+361 | mid: circ-buffer code, tasklets→threaded irq |
| ctrl-msg FSM | link_ctrlmsg_command.c | 242 | trivial |
| LLI link glue | link_device_lli.c, link_device_pm.c | 915+1095 | PM FSM can be dropped (corrected 2026-10-30: stock ran the FSM with `pm_enable=1`; dropping it is a design choice, SYNTHESIS.md D2) |
| **MIPI-LLI HW driver** | mipi-lli.c + exynos-mipi-lli.c + .h | 498+1252+324 | core port: new DT binding, regmap over PMU syscon, clocks; no upstream precedent |
| **M-PHY** | exynos-mipi-lli-mphy.c | 304 | port as PHY provider or fold into LLI driver |
| wake/PM, spi link, bootdump | link_device_pm/bootdump/spi* | 1095+285+283 | mostly deletable for a minimal port |

Minimal viable port order [inferred]: (1) `exynos-mipi-lli` platform driver + M-PHY init +
memblock-reserved-region DT node (replace runtime `memblock_alloc_base` with a
`reserved-memory` node — cleaner than upstream `mach-*`); (2) memory-link + SBD +
ctrl-msg core as one driver exposing the 4 misc + 4 net nodes (keep the existing UAPI —
`modem_v1_uapi.h` is userspace-compatible by construction); (3) ss333 power control with
gpio/pinctrl described in DT; (4) drop link_pm FSM (hold link awake, matching
`pm_enable=0` behavior), drop ARGOS, drop SPI link (corrected 2026-10-30: the SPI link must
be **kept**, it carries BOOT; the port design that replaced this paragraph is
`research/analysis/kernel_port_design.md` with SYNTHESIS.md D1-D3). Estimated net new code ≈ 4-6 kLOC
(vs 13 256 LOC in-tree incl. headers). Userspace: rild replacement can reuse
libsec-ril.so initially — only `cbd` must be reimplemented (§3.6).
Alternative framing for upstream: expose the channels through the existing `wwan`
subsystem (`linux-6.12/include/linux/wwan.h` port types, `IFLA_WWAN_LINK_ID` in
`include/uapi/linux/wwan.h:10`) — but that breaks the drop-in-cbd goal; keep legacy nodes
first, wwan later.

Out-of-tree module constraints: the LLI driver needs PMU writes (syscon OK),
`dout_aclk_cpif_200` gate (present in 5433 CCF), and SPI 184/185 interrupts; all
expressible in DT. No constraint forces a full kernel fork; everything fits as an
out-of-tree module set once the reserved-memory + syscon + clocks are described.

---

## 8. Unknowns and next steps

> **Status 2026-10-30.** Resolved: U-1 (TOC/BOOT/MAIN layout, `radio_image.md`), U-2 and U-8
> (MTU 0x810, MSS 0x800, one `FW_UPDATE` per stage, `num_frames` = frames of that stage), U-3
> (CP load addresses come with the TOC stage), U-5 (no post-boot `FW_UPDATE`), U-6 (no AP→CP
> doorbell needed: BOOT busy-polls the ring), U-7 (`lli_control` is never written: the CP mounts
> as master), U-9 (the SPI link carries BOOT on every boot). Partly open: U-4 (NV item map; NV
> itself is streamed at stage 3). Current unknowns: SYNTHESIS.md §8.

- **U-1** RADIO image internal layout (TOC/BOOT/MAIN, CRC/sign offsets). Next: obtain the
  RADIO partition image and `cbd`; dissect with binwalk + the SS333 bootrom docs.
- **U-2** practical `std_dload_info.mtu` / frame pacing. Next: strace `cbd` on-device or
  instrument `xmit_udl` retry counter.
- **U-3** CP RAM load addresses. Next: SS333 bootrom/baseport docs; or infer from dump
  headers once RADIO image is available.
- **U-4** NV item numbering / `m9kefs*` roles. Next: dissect cbd's RFS traffic
  (`/proc/kmsg` + IPC logger), never read the partitions directly.
- **U-5** whether cbd ever drives `IOCTL_MODEM_FW_UPDATE` post-boot (FOTA path).
- **U-6** whether CP requires an AP2CP doorbell to poll BOOT data in `raw_tx_buff`
  (xmit_udl sends none). Next: single experiment — boot with/without a `send_ap2cp_irq`
  poke after each write.
- **U-7** lli_control commands 2/3 as the real mount trigger (§3.2 step 4) — confirm by
  tracing cbd sysfs writes.
- **U-8** `num_frames` semantics (descriptor count vs frame count) if cbd sends
  per-frame `FW_UPDATE` calls.
- **U-9** whether the SPI boot link (`link_types` bit for LINKDEV_SPI) is used as
  fallback at all on this SKU.

## 9. `modem_v1_uapi.h`

See companion file `modem_v1_uapi.h` (same directory): standalone GPL-2.0 SPDX C header —
all 26 ioctl `_IO('o', …)` numbers with `modem_prj.h:54-94` provenance comments,
`modem_state`/`link_state` enums, `struct modem_firmware`, `struct std_dload_info`,
`struct sipc_fmt_hdr`, SIPC5 header constants, channel IDs, doorbell masks/commands,
magic words, and the 4 MiB `shmem_4mb_phys_map`. Compiles clean with
`arm-linux-gnueabihf-gcc (Debian 14.2.0-19) -fsyntax-only`.

