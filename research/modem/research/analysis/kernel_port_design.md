# SS333 modem stack: port design from Samsung 3.10 to mainline 6.12 (ARM32, SM-T715)

Design note, 2026-10-29. Read-only analysis: nothing was built, flashed or run, and the
tablet was not contacted.

**Roots used in citations.**
- `K310/` = `src/kernel_universal5433/` (Samsung 3.10 tree).
- `ML/` = `src/linux-6.12/` (branch `t715-bringup` at `ed71dc803`).
- `BRD/` = `ML/arch/arm/boot/dts/samsung/` (our board DT).
- `DUMP/` = `dumps/`.
- `RN/` = `research/modem/research/research_notes/Modem Shannon SS333 sous Linux/`.
- `SP/` = a local working copy of the downloaded public sources, not in this repository.
- `BUP` = `research/modem/SS333_LLI_BRINGUP.md`.
- `CBD_RE` / `LOADER_SPEC` = the two files beside it.

**Tags.**
- **[proven]**: read in the cited file and line.
- **[inferred]**: derived; the reasoning is given.
- **[unknown]**: needs a measurement on the device.

---

## 0. Executive summary

### 0.1 Main decisions

1. **In-tree patch series, two loadable modules.** A side series
   `kernel/patches/t715-modem/` on top of `t715-bringup` holds:
   - the CMU_CPIF clock additions (built in);
   - the board DT;
   - `exynos5433-mipi-lli.ko` (LLI controller with the M-PHY folded in);
   - `sec_modem_v1.ko` (the modem_v1 core, memory link, SBD, ctrl-msg, LLI link, SPI boot
     link and SS333 control).

   It is a lift-and-shift of the vendor code. About 13.5 kLOC end up in the tree, of which
   about 2 kLOC are new or modified relative to 3.10.
2. **No link-PM FSM in phase 1.** The AP holds the link up ("locked-on"). Stock ran the FSM
   with `pm_enable = 1` (proven by the stock dmesg, §0.2). The locked-on mode reproduces
   stock pin behaviour up to `PHONE_START`. The FSM is a phase-2 port.
3. **Shared memory.** A static `no-map` reserved-memory region of 8 MiB at `0xde000000`,
   mapped with `ioremap_wc`, with explicit `dma_wmb()`/`dma_rmb()` at every ring index update.
   The stock kernel mapped struct pages strongly-ordered, which a `no-map` region cannot do.
   The address is the hole the stock ION layout leaves; it is [inferred] to be the address
   stock used.
4. **Clocks.** A small patch to `clk-exynos5433.c` adds the CMU_CPIF LLI muxes and IP gates
   (new IDs 12-25), and `assigned-clock-rates` sets `div_aclk_cpif_200` to 100 MHz. Direct
   writes are acceptable only as a first-light fallback, and only to CMU_CPIF registers that
   mainline's clock driver never touches. The PMU LLI_PHY_CON write (0x720) goes through the
   PMU syscon regmap, never a `reg` entry.
5. **Safety gates.**
   - A module parameter `allow_hw` (default 0) blocks every GPIO, LLI or SPI action.
   - No `panic()` or `BUG()` anywhere, including `IOCTL_MODEM_CP_UPLOAD`.
   - No `remove()` and no `module_exit`.
   - `dflags` defaults to 0, so no IPC payload (IMEI, IMSI, SMS) reaches dmesg.
   - The kernel enables `CONFIG_SPI`, which is **not set** in today's build.

### 0.2 Corrections to the existing dossier (BUP) found during this analysis

| # | BUP claim | What the sources say | Tag |
|---|---|---|---|
| C-1 | §3.5: "`start_pm` (with `pm_enable=0`, `link_device_lli.c:497-511` just takes `lli_ap_wlock`)" | The board builds `CONFIG_LINK_POWER_MANAGEMENT_WITH_FSM=y` (`K310/arch/arm/configs/lineage_gts28ltexx_defconfig:1331`), so the FSM branch `link_device_lli.c:106-260` is compiled, not `:497-511`. `pm_enable` defaults to **1** (`link_device_lli.c:41`), giving `pm->start(pm, PM_EVENT_CP_BOOTING)` (`:221-229`). The stock runtime log shows the FSM cycling: `DUMP/dmesg.txt:9-16` (`ACTIVE->AP_FREE->CP_FREE->UNMOUNTING->UNMOUNTED`, `HIBERN8_ENTER_DONE`, `Unmount`) and `:93-104` (remount). | proven |
| C-2 | §1.5/§3.3: "SPI 184 = LLI signal IRQ"; "handler reads `CPIF_LLI_SIG_IN0 0x1000`" | IRQ index 0 (SPI 184) is the DME/link IRQ `exynos_mipi_lli_irq` plus its thread (`K310/drivers/misc/mipi-lli/exynos-mipi-lli.c:1132,1162-1163`). Index 1 (SPI 185) is the doorbell IRQ `mipi_lli_sig_irq` (`:1139,1145` → `mipi-lli.c:456`). The doorbell value is `TL_SIGNAL_STATUS_LSB/MSB` at LLI+0x2004/0x2010 (`exynos-mipi-lli.c:480-481`). `CPIF_LLI_SIG_*` live in the SYSREG block (reg[2], 0x10fd0000); only the masks are written (`:237-244`). ARGOS pins hwirq **217 = SPI 185+32** with the label "IPC" (`link_device_memory_main.c:939`). | proven |
| C-3 | §2.1: "11 misc nodes" | The 13 iodevs are 4 netdevs (rmnet0-3) and **9 misc devices**: `umts_ipc0`, `umts_rfs0`, `umts_csd`, `umts_router`, `umts_dm0`, `ipc_loopback0`, `multipdp` (dummy, no fops), `umts_boot0`, `umts_ramdump0` (`modem-ss333-pdata.dtsi`; `modem_io_device.c:1760-1872`). | proven |
| C-4 | §1.5: reservation in `mach-espresso5433.c` | The board builds `CONFIG_MACH_UNIVERSAL5433=y` (defconfig:406) and `# CONFIG_MACH_ESPRESSO5433 is not set` (:405). The reservation is `K310/arch/arm/mach-exynos/mach-universal5433.c:58-68`, with identical code, made **before** `init_exynos_ion_contig_heap()`. | proven |
| C-5 | §3.1: `ss333_off` waits for `phone_active` **low** | It waits for `phone_active` **high** (`modem_ctrl_ss333.c:251-256`: `if (gpio_get_value(...phone_active)) break;`). | proven |
| C-6 | §3.2 step 4: "userspace must write 2 then 3 to `lli_control`" | cbd v1 only **reads** `lli_control` (`SP/src/cpboot/boot_shannon333.c:358-366`, `shannon333.h:7-9`). The AP stays a slave (`is_master = false`, `exynos-mipi-lli.c:1155`). On `INTR_MPHY_HIBERN8_EXIT_DONE` the hard-IRQ handler writes `LLI_MOUNT_CTRL` itself (`:926-932`). The stock log shows `HIBERN8_EXIT_DONE: rx=3, tx=1` then `Mount intr` (`DUMP/dmesg.txt:97-103`). | proven (code + log); boot-time order inferred |
| C-7 | §1.5: SPI link "inactive" | The SPI link carries BOOT on every boot. cbd runs `SET_TX_LINK(3)` → raw write → `wait cp_status/value == "1"` (`SP/src/cpboot/boot_shannon333.c:290-293,339-354`; RN `cp_boot_firmware.md` Q2). | proven |
| C-8 | Input "stock kernel config" | `DUMP/stock/running_kernel.config` is **0 bytes**. This note uses `K310/arch/arm/configs/lineage_gts28ltexx_defconfig` instead. | proven |

---

## 1. Architecture choice

### 1.1 Out-of-tree module set or in-tree patch series

**What must be in-tree whatever the choice** [proven]:
- The board DT is compiled into the DTB packed in BOOT (`BRD/exynos5433-gts28ltexx.dts`). Our
  dtc cannot apply phandle-carrying overlays: omarchy-mobile hit the same wall, "base DTB has
  no `__symbols__`… cannot give a new node GPIO or memory-region phandles"
  (`SP/web/cheetah_modem_plan.md:223-226`).
- The CMU_CPIF clocks are registered by `CLK_OF_DECLARE` in the built-in
  `ML/drivers/clk/samsung/clk-exynos5433.c:910-915`.
- `CONFIG_SPI` must change: it is `# CONFIG_SPI is not set` in the daily build
  (`out/mainline/.config`).

**Decision: in-tree series** `kernel/patches/t715-modem/`, based on `t715-bringup`, the same
way `t715-g3d-abb` is handled (`kernel/README.md`). Reasons [inferred]:
- One source of truth: the repository rule is that the kernel is the patch series.
- `vermagic` always matches the BOOT kernel.
- Fast iteration is not lost. `make M=drivers/misc/modem_v1 modules` rebuilds one `.ko`,
  which can be pushed to the root filesystem without reflashing BOOT. Only DT or clock
  changes need a new BOOT image.

Planned patches:
1. `dt-bindings: clock: exynos5433: add CMU_CPIF LLI clock IDs`
2. `clk: samsung: exynos5433: add CMU_CPIF LLI muxes and IP gates` (§4)
3. `misc: mipi-lli: Exynos5433 MIPI-LLI controller and M-PHY (from Samsung 3.10)`
4. `misc: modem_v1: Samsung SIPC5 modem interface for the SS333 (from Samsung 3.10)`
5. `ARM: dts: gts28ltexx: SS333 modem: shared memory, MIPI-LLI, SPI4 boot link, modem node`
   - a new `exynos5433-gts28ltexx-modem.dtsi`, included by the board as a section 18.
6. `ARM: configs: gts28ltexx_modem.config fragment`
   - contents: `CONFIG_SPI=y`, `CONFIG_SPI_S3C64XX=m`, `CONFIG_MIPI_LLI=m`, `CONFIG_SEC_MODEM_V1=m`;
   - merged by `scripts/kbuild-mainline.sh --fragment`, as for the GPU fragment;
   - folded into the defconfig once stage S7 (§6) passes.

Keep the 3.10 directory names (`drivers/misc/mipi-lli/`, `drivers/misc/modem_v1/`) so that
`diff -ru K310/drivers/misc/modem_v1 ML/drivers/misc/modem_v1` stays the review tool.

### 1.2 Modules and files

| Module | Source files (port) | Exports / consumes |
|---|---|---|
| `exynos5433-mipi-lli.ko` (`CONFIG_MIPI_LLI`, tristate) | `mipi-lli.c` (core API + `lli_control`), `exynos-mipi-lli.c` (controller, clocks, PMU, IRQs, remap), `exynos-mipi-lli-mphy.c` (M-PHY tables, **no longer a platform driver**), `exynos-mipi-lli.h`, `exynos-mipi-lli-mphy.h`, `include/linux/mipi-lli.h` | Exports the 3.10 API (`mipi_lli_register_handler`, `mipi_lli_send_interrupt`, `mipi_lli_reset`, `mipi_lli_get_link_status`, `mipi_lli_get_phys_base/size`, …) plus a new `mipi_lli_get_from_node()` used for `-EPROBE_DEFER` |
| `sec_modem_v1.ko` (`CONFIG_SEC_MODEM_V1`, tristate, `depends on MIPI_LLI && SPI && OF`) | `modem_main.c`, `modem_variation.c`, `modem_io_device.c`, `modem_utils.c`, `modem_ctrl_ss333.c`, `link_device_memory.c`, `link_device_memory_main.c`, `link_device_memory_sbd.c`, `link_device_bootdump.c`, `link_device_memory_snapshot.c`, `link_device_memory_flow_control.c`, `link_device_memory_debug.c`, `link_ctrlmsg_command.c`, `link_device_lli.c`, `link_device_spi.c`, plus the private headers (`modem_prj.h`, `modem_utils.h`, `modem_variation.h`, `link_device_memory.h`, `include/{sbd,sipc5,circ_queue,link_device_memory_config}.h`, and `platform_data/modem_v1.h` moved under `drivers/misc/modem_v1/include/`) | `platform_driver` "mif_sipc5" plus an `spi_driver`; the SPI boot client lives in the same module |

The two modules keep the 3.10 split. `link_device_lli.c` calls the `mipi_lli_*` API. Merging
them would mean rewriting that glue; keeping them apart keeps the diff small [inferred].

### 1.3 Keep, drop, simplify

| Item | Decision | Reason |
|---|---|---|
| Link-PM FSM `link_device_pm.c` (1095) + `modem_pm.h` (222) | **Drop in phase 1; port in phase 2** | With the FSM present and `pm_enable = 0`, the state is `PM_STATE_LOCKED_ON`, and `run_pm_fsm()` exits early when `fsm_locked()` (`link_device_pm.c:396-397`). It also registers `unmount_cb` (`:1011`), and with that callback set the LLI driver no longer re-initialises itself after an unmount (`exynos-mipi-lli.c:1006-1007`). A CP-initiated unmount would then leave the link dead. Without the FSM, the LLI driver re-arms itself on `INTR_LLI_UNMOUNT_DONE`. [proven code; consequence inferred] |
| Locked-on PM (replaces the FSM) | **Write anew (~80 lines in `link_device_lli.c`)** | Mirror the stock FSM pin behaviour until ONLINE (§2.7). |
| ARGOS (`link_device_memory_main.c:931-940`, `modem_utils.h`) | **Drop** | It pinned IRQ 217 to cpu3 and RX to the slow cluster. Affinity can be set from userspace (`/proc/irq/*/smp_affinity`). |
| `queue_work_on(7, …)` (`link_device_memory.c:185`) | **Replace** by `queue_work()` | CPU 7 is an A57 in our topology; a hard-coded CPU is wrong in general. |
| SPI boot link (`link_device_spi.c`, 257) | **Keep, simplified** | BOOT always goes over SPI (C-7). Keep `IOCTL_MODEM_SET_TX_LINK` semantics. Register the `spi_driver` at `module_init`, not inside `spi_create_link_device()` (`:241`). |
| `boot_device_spi.c` | Drop | Not built on stock (`K310/drivers/misc/modem_v1/Makefile:24`, defconfig:1327). |
| IOSM, NAPI, SHMEM, C2C, HSIC, XMM7260, SS300 code and `#ifdef`s | Drop | Not configured on stock (defconfig:1332-1347). |
| `/proc/baseband` (`modem_utils.c:1194-1300`) | Keep (`proc_ops`) or drop | Informational only. |
| debugfs `svnet/mem_dump` (`link_device_lli.c:759-772`) | **Keep** | cbd's dump path runs `cat /d/svnet/mem_dump` (CBD_RE §7); also useful for bring-up. |
| IPC logger ring (`mif_ipc_log` …), `IOCTL_MIF_LOG_DUMP` | Keep | ABI. |
| `dflags` default `1<<DEBUG_FLAG_FMT` (`modem_utils.c:69`) | **Default 0** | FMT payload hex dumps (`IOD-RX`/`LNK-RX`, seen in `DUMP/dmesg.txt:1-2,100-106`) can contain IMEI, IMSI, numbers and SMS. Project rule: no identifiers in logs (`docs/journal/HANDOVER.md`, "Rules that stay"). |
| `mif_open_file`/`mif_save_file` (`set_fs`, `modem_utils.c:1122-1165`) | Drop | `set_fs` no longer exists. |
| Trace events (`include/trace/events/modem_if.h`, 77) | Drop (use `dev_dbg`) | Avoids an out-of-place `TRACE_INCLUDE_PATH`. |
| LLI debug dump tables, loopback test, `lli_control` commands 5/6/98/99 | Drop or move under `allow_hw` + debugfs | The register dump reads statically mapped 5430 CMU VAs (`exynos-mipi-lli.h:254-263`), which would crash on mainline. |
| `lpcharge` (`modem_main.c:556`) | Drop | Our initramfs ignores charger mode (`docs/journal/HANDOVER.md`, last section). |

### 1.4 LOC estimate

Base: the stock build set is 15 089 LOC for modem_v1 with its headers, and 2 802 for
mipi-lli (`wc -l`, this session).

| Unit | 3.10 LOC | After port | New/changed lines |
|---|---|---|---|
| `mipi-lli.c` + `include/linux/mipi-lli.h` | 498 + 180 | ~440 | ~120 |
| `exynos-mipi-lli.c` + `.h` | 1252 + 324 | ~1 090 | ~270 |
| M-PHY `.c` + `.h` (folded) | 304 + 244 | ~330 | ~60 |
| **LLI module** | 2 802 | **~1.85 k** | **~450** |
| `modem_main.c` | 748 | ~650 | ~250 |
| `modem_variation.c/.h` | 328 | ~90 | ~90 |
| `modem_io_device.c` | 1 872 | ~1 750 | ~120 |
| `modem_utils.c/.h` | 1 858 | ~1 350 | ~150 |
| memory link (`*_memory*.c`, bootdump, ctrl-msg) | 3 424 | ~3 300 | ~150 |
| `link_device_lli.c` | 915 | ~380 | ~200 |
| `link_device_spi.c` + `.h` | 283 | ~200 | ~100 |
| `modem_ctrl_ss333.c` | 587 | ~540 | ~120 |
| headers (`modem_prj.h`, `link_device_memory.h`, `sbd.h`, `sipc5.h`, `circ_queue.h`, config, `platform_data/modem_v1.h`, `link_pm.h`, `modem_debug.h`) | ~3 700 | ~3 300 | ~150 |
| **Modem module** | 15 089 (incl. FSM + trace) | **~11.6 k** | **~1.33 k** |
| Clock patch + dt-bindings | – | ~150 | ~150 |
| DT (`-modem.dtsi`) | – | ~260 | ~260 |
| Kconfig/Makefiles/fragment | – | ~70 | ~70 |
| **Total phase 1** | | **~13.9 k** | **~2.3 k** |
| Phase 2 (FSM port; optional NAPI; optional wwan front end) | 1 317 | +1.3 k / +0.1 k / +0.8 k | ~+0.25 k / +0.1 k / +0.8 k |

[inferred estimates.] BUP §7's "4-6 kLOC net new" assumed a rewrite. This design keeps the
vendor code mostly verbatim (stock-proven against this exact CP firmware) and pays only in
changed lines.

---

## 2. File-by-file port plan (3.10 → 6.12)

### 2.1 API changes that recur (verified in `ML/`)

| 3.10 construct | 6.12 replacement | Where | Proof |
|---|---|---|---|
| `struct wake_lock`, `wake_lock_init/wake_lock/wake_unlock/wake_lock_timeout/wake_lock_active` (`<linux/wakelock.h>`) | `wakeup_source_register(dev, name)`, `__pm_stay_awake`, `__pm_relax`, `__pm_wakeup_event(ws, jiffies_to_msecs(t))`, `ws->active` | `modem_main.c:226`, `modem_io_device.c:159-160,939-941`, `modem_ctrl_ss333.c:30,177,557`, `link_device_lli.c:553-555`, `link_device_memory.h:408-409` | `ML/include/linux/pm_wakeup.h:102,206` |
| `init_timer`/`.function`/`.data`/`add_timer` (`mif_add_timer`, `modem_utils.c:594-605`); `del_timer` | `timer_setup(&mc->crash_ack_timer, cb, 0)` + `from_timer()`; `mod_timer`; `timer_delete_sync` | `modem_ctrl_ss333.c:290,319`, `link_ctrlmsg_command.c` (`del_timer`) | `ML/include/linux/timer.h:120,132,167` |
| `INIT_COMPLETION(x)` | `reinit_completion(&x)` | `modem_ctrl_ss333.c:393-394` | `ML/include/linux/completion.h:97` |
| `tasklet_init(&t, fn, (unsigned long)mld)` | `tasklet_setup(&t, fn)` + `from_tasklet()` (keep the tasklet in phase 1) | `link_device_memory_main.c:1091` | `ML/include/linux/interrupt.h:676,763` |
| `system_nrt_wq`, `WQ_NON_REENTRANT` | `system_wq`; flag removed (now the default) | `link_device_lli.c:344,457` (non-FSM branch), `link_device_pm.c:980` (FSM, phase 2) | absent from `ML/include/linux/workqueue.h` |
| `of_get_named_gpio` + `gpio_request` + `gpio_direction_*` + `gpio_set/get_value` + `gpio_to_irq` | `devm_gpiod_get(dev, "cp-on", GPIOD_ASIS / GPIOD_OUT_LOW / GPIOD_IN)`, `gpiod_set_value`, `gpiod_get_value`, `gpiod_to_irq` (non-sleeping: Samsung banks) | `modem_main.c:284-410`, `link_device_pm.c:1026-1092`, `modem_ctrl_ss333.c` (29 uses), `link_device_lli.c` (26) | gpiod builds `<con_id>-gpios` names, so the legacy `mif,gpio_*` names cannot be looked up (§3.4) |
| `gpio_export` + `gpio_export_link` (`board_gpio_export`, `modem_utils.c:1167-1190`) creating `…/mif_pdata/cp_status/value` | a read-only attribute group `.name = "cp_status"`, attr `value`, in `driver.dev_groups` | `modem_main.c:506` | cbd reads that path (`SP/src/cpboot/util.c:802-833`, `shannon333.h:2-4`); `CONFIG_GPIO_SYSFS` is not needed |
| `devm_request_and_ioremap` | `devm_platform_ioremap_resource_byname` | `exynos-mipi-lli.c:1089-1128`, mphy probe | – |
| `#include <linux/clk-private.h>`; `clk->enable_count`, `clk->rate` | `devm_clk_bulk_get` + `clk_bulk_prepare_enable` once; `clk_get_rate()` | `exynos-mipi-lli.c:14,542-561,1200-1201` | `struct clk` is opaque in mainline |
| `memblock_alloc_base(SZ_8M, SZ_8M, ANYWHERE)` in the machine file | a `reserved-memory` node (`no-map`) + `memory-region` + `of_reserved_mem_lookup()` | `mach-universal5433.c:62`, `mipi-lli.c:38,461-467` | `ML/drivers/of/of_reserved_mem.c:769` (exported) |
| `vmap(phys_to_page…, pgprot_noncached)` (`mem_vmap`, `link_device_memory_main.c:826-838`; `mipi_lli_vmap`, `mipi-lli.c:40-60`) | `devm_ioremap_wc(dev, rmem->base, rmem->size)` (`__iomem`, keeps the 3.10 `ioread32`/`iowrite32` typing) | §2.6 | `no-map` ⇒ `pfn_valid()` false ⇒ no struct pages to vmap [inferred]; no-map ranges are not "System RAM" (`ML/arch/arm/kernel/setup.c:866` iterates `for_each_mem_range`, which skips NOMAP) so WC mapping is allowed (`ML/kernel/iomem.c:103-113`) |
| `misc_register` (unchanged); `unsigned int misc_poll()`; `device_create_file()` after registration | `__poll_t` + `EPOLLIN/EPOLLHUP`; `miscdev.groups` for `waketime/loopback/txlink` (no uevent race); do not set `.llseek` | `modem_io_device.c:1025-1088,1466-1476,1835-1860` | `no_llseek` is gone in 6.12 (`ML/include/linux/fs.h:3332`: only `noop_llseek`) |
| `alloc_netdev(sz, name, setup)` | `alloc_netdev(sz, name, NET_NAME_PREDICTABLE, setup)` (fixed DT names `rmnet0-3`, not renamed by udev) | `modem_io_device.c:1803-1807` | `ML/include/linux/netdevice.h:4643`, `uapi/linux/netdevice.h:44` |
| `netif_rx_ni()` | `netif_rx()` | `modem_io_device.c:335-338` | `ML/include/linux/netdevice.h:3976` (no `netif_rx_ni`) |
| `random_ether_addr` | not needed (`use_handover = 0`, so `vnet_setup_ether` is dead) | `modem_io_device.c:1683-1693` | – |
| `getnstimeofday`, `struct timespec` | `ktime_get_real_ts64`, `timespec64`, `time64_to_tm` | `modem_utils.c:82-100,214-231`, `link_device_memory.h:228` | – |
| `cpu_clock(smp_processor_id())` under `raw_local_irq_save` | `local_clock()` | `modem_utils.c:128-141`, `link_device_lli.c:438` | – |
| `proc_create_data(…, &file_operations)` | `struct proc_ops` | `modem_utils.c:1264-1281` | `ML/include/linux/proc_fs.h:33` |
| `set_fs/get_fs` | removed: drop the file helpers | `modem_utils.c:1122-1165` | – |
| `strlcpy` | `strscpy` | `modem_utils.c` (`mif_init_irq` uses `strncpy`) | no `strlcpy` in `ML/include/linux/string.h` |
| `%pf`/`%pF` (`CALLER`) | `%ps`/`%pS` | 6 files | `ML/lib/vsprintf.c:2460-2461`: `%pf` now means fwnode and prints an error string otherwise |
| `struct spi_transfer.delay_usecs = 10` | `.delay = { .value = 10, .unit = SPI_DELAY_UNIT_USECS }` | `link_device_spi.c:72` | `ML/include/linux/spi/spi.h:113-126` (no `delay_usecs`) |
| `spi_register_driver()` from inside a platform probe | `module_init` registers both drivers; the modem probe finds the client with `bus_find_device_by_of_node(&spi_bus_type, np)` and returns `-EPROBE_DEFER` until it is bound | `link_device_spi.c:211-256` | `ML/drivers/spi/spi.c:471-480`, `ML/include/linux/device/bus.h:174` |
| `hrtimer_init` + `.function` | unchanged in 6.12 (`hrtimer_setup` came later) | `link_device_memory_main.c:1093-1094` | `ML/include/linux/hrtimer.h:229` |
| `panic()`, `BUG()`, `BUG_ON(1)` | `dev_err` + `-EINVAL`/`-EIO`; `WARN_ONCE` at most | `modem_io_device.c:1254`, `modem_main.c:223`, `link_device_memory_main.c:467,747`, `link_device_pm.c:364` | the cmdline has `panic=5 oops=panic` (`BRD/exynos5433-gts28ltexx.dts:114`), so any oops reboots |

### 2.2 LLI module, file by file

**`include/linux/mipi-lli.h`** (180 → ~110):
- Drop `struct mipi_lli_dump` (16.5 KiB embedded, `:64-70`) and the `clk-private` assumptions.
- Replace the 17 `struct clk *` with a `clk_bulk_data` array.
- `phy_addr` becomes `phys_addr_t`. With `CONFIG_ARM_LPAE=y`, `phys_addr_t`/`dma_addr_t` are
  64-bit (`CONFIG_PHYS_ADDR_T_64BIT=y`, `CONFIG_ARCH_DMA_ADDR_T_64BIT=y` in
  `out/mainline/.config`).
- Keep the exported prototypes (`:144-175`).

**`mipi-lli.c`** (498 → ~330):
- Drop `mipi_lli_vmap` and its use in `store_mipi_lli_control` (`:40-60,271-308`).
- `lli_control` becomes `DEVICE_ATTR_RW` in `driver.dev_groups`. Keep the **exact** show
  format `"MIPI-LLI %x\n"` (`:257`); the loader polls for `MIPI-LLI 1`
  (`SP/src/cpboot/shannon333.h:9`).
- Store keeps command 0 (debug) and command 1 (re-init), the latter only when
  `allow_hw = 1`. Commands 2 and 3 stay available for experiments, behind `allow_hw`.
- `request_irq(irq_sig, mipi_lli_sig_irq, 0, …)` (`:456`) becomes `devm_request_irq` with
  `IRQF_NO_AUTOEN`. Enable the IRQ only after clocks and PMU are on.
- Fix the LPAE printk at `:474-476`: `%x` with a 64-bit `dma_addr_t` → `%pa` [proven bug
  under LPAE: a 64-bit vararg shifts the following arguments].
- `g_lli` stays a single-instance global (one LLI block per SoC) [inferred acceptable].

**`exynos-mipi-lli.c`** (1252 → ~850):
- Probe (`:1071-1208`) becomes:
  1. map regs by name;
  2. get the PMU regmap with `exynos_get_pmu_regmap_by_phandle(np, "samsung,pmu-syscon")`
     (`ML/drivers/soc/samsung/exynos-pmu.c:297-329`, exported `:329`);
  3. look up `memory-region`;
  4. check `size == 2^n` and `base % size == 0` at probe, and refuse to bind otherwise
     (3.10 only found out in IRQ context, `:304-308`);
  5. get the clocks with `devm_clk_bulk_get` (the 3.10 `IS_ERR` chain `:214-232` is never
     acted on: probe ignores the return value at `:1182`);
  6. `clk_bulk_prepare_enable` once (3.10 enables at probe and only gates in suspend,
     `:1191`, `:623`);
  7. clear `DME_LLI_INTR_ENABLE`/`STATUS` before the IRQs are requested.
- Muxes and rate come from DT `assigned-clocks` (§3.3), so `exynos_lli_clock_init`
  (`:502-515`) disappears.
- The `clk_set_rate` check at `:1196-1198` is inverted (`if (!ret) dev_err("failed…")`);
  replace it with `clk_get_rate()` logging [proven bug].
- `writel(1/0, lli->pmu_regs)` (`:296,626,637,744`) becomes
  `regmap_write(pmu, 0x720, 1/0)`. The syscon regmap is spinlock-based, so this is safe in
  IRQ context [inferred from the syscon `fast_io` default].
- Remove the `dev_err/dev_info/dev_dbg` redefinitions (`exynos-mipi-lli.h:316-322`) but keep
  the `"lli: "` message texts. Bring-up compares them to the stock log.
- The hard-IRQ handler (`:900-1022`) keeps its logic. Move the `mdelay(1)` +
  `LLI_MOUNT_CTRL` write (`:926-932`) to the thread if latency matters; keep it as-is in
  phase 1 (stock-proven).
- `RESET_ON_ERROR_SENT` → soft reset (`:951-955`): add a rate limit (more than N resets
  within 1 s stops re-arming and logs). This prevents a reset/IRQ storm [inferred].
- `INTR_LLI_UNMOUNT_DONE` → `exynos_lli_init()` when no `unmount_cb` (`:1003-1016`): keep.
  Phase 1 relies on it.
- `is_first` statics (`:841`, M-PHY `:55`) become per-device fields.
- Suspend/resume (`:610-703`): no FSM, so `pm_svc->dev_pm_ops` is false and suspend is
  already a no-op (`:659-660`). Keep it that way. System suspend is not used on the tablet
  ("No cpufreq, no suspend", `docs/journal/HANDOVER.md`).
- `of_platform_populate` + `exynos_get_mphy()` (`:1167-1180`) are replaced by a fourth
  `reg` ("mphy") parsed in the same driver.

**`exynos-mipi-lli-mphy.c/.h`** (548 → ~330):
- Keep `exynos_mphy_init/cmn_init/ovtm_init` verbatim (`:26-152`), including the
  `CONFIG_SOC_EXYNOS5433 && CONFIG_UMTS_MODEM_SS333` branch (`:63-66`), which becomes
  unconditional, and the "should be changed by CP (0x2E)" write (`:120-121`).
- Drop the platform driver. Gear, rate and shared-refclk come from DT properties (§3.3)
  instead of the `modems/ss333` sub-node lookup (`:159-222`).

### 2.3 Modem module, file by file

**`modem_main.c`** (748 → ~650):
- `parse_dt_common_pdata` and `parse_dt_iodevs_pdata` keep the legacy `mif,*` / `iod,*`
  properties verbatim (`:259-276,441-483`). They are software configuration, not hardware.
- GPIO parsing (`:278-439`) becomes one `ss333_get_gpios()`:
  - 10 descriptors, plus `cp-status` shared by `mif,gpio_cp_status` and
    `link_pm/gpio_cp2ap_status` (the same pin gpa2-5; gpiolib refuses two exclusive
    requests).
  - `allow_hw = 0` → `GPIOD_ASIS` for every line.
  - `allow_hw = 1` → outputs `GPIOD_OUT_LOW`, which is exactly the stock probe state
    (`:294,307,321,347`; `link_device_pm.c:1058,1088`), inputs `GPIOD_IN`.
- `board_gpio_export(dev, cp_status, …)` (`:506`) becomes the `cp_status/value` attribute
  group.
- Probe defers until the LLI device is bound (via phandle `samsung,mipi-lli`) and the SPI
  client is bound (phandle `samsung,boot-spi`). In 3.10, `lli_create_link_device` →
  `mipi_lli_get_phys_base()` dereferences `g_lli` (`mipi-lli.c:67-70`), a NULL dereference if
  the LLI driver has not probed.
- `attach_devices`: `BUG()` (`:223`) becomes `-EINVAL`.
- Remove `lpcharge` (`:54,556-559`).
- Keep `.shutdown = modem_shutdown` (`:658-667`). It drives `ss333_off` on
  `systemctl reboot`. Our kernel has no such hook today.
- Keep `.suppress_bind_attrs = true` (`:738`). Add no `.remove` and no `module_exit`: the
  module stays until reboot, the omarchy lesson (`SP/web/cheetah_modem_plan.md:190,254-256`).
- `modem_suspend/resume` (`:669-724`) are the non-FSM variants (`:678-713`): keep. They only
  toggle `pda_active` and `mipi_lli_suspend/resume`. They are never invoked, since there is
  no suspend.

**`modem_variation.c/.h`** (328 → ~90): reduce the tables to
- `modem_init_func[SEC_SS333] = ss333_init_modemctl_device`;
- `link_init_func[LINKDEV_LLI] = lli_create_link_device`;
- `link_init_func[LINKDEV_SPI] = spi_create_link_device`.

Keep the enum values (`SEC_SS333 = 15`, `LINKDEV_LLI = 10`, `LINKDEV_SPI = 3`): they are part
of the DT and the `SET_TX_LINK` ABI (`BUP` §1.2, §2.2).

**`modem_io_device.c`** (1872 → ~1750):
- `misc_poll` → `__poll_t`.
- `misc_io_fops`: drop `.compat_ioctl`. It is not needed on ARM32 (32-bit userspace, no
  `CONFIG_COMPAT`); `compat_ptr_ioctl` would also do.
- `IOCTL_MODEM_CP_UPLOAD` (`:1243-1256`):
  - stock: copy the 512 B crash text, then `panic()`;
  - port: copy, `dev_err`, notify `STATE_CRASH_EXIT`, return 0;
  - a module parameter `cp_upload_panics` (default 0) keeps the stock behaviour for those who
    want it.
- `rx_multi_pdp`: `netif_rx_ni` → `netif_rx` (`:333-338`).
- `vnet_setup` (`:1671-1681`): `ARPHRD_PPP` → **`ARPHRD_RAWIP`** (§2.5).
- `alloc_netdev` takes `NET_NAME_PREDICTABLE`.
- The `IODEV_DUMMY` (`multipdp`) attributes move to `miscdev.groups` (`:1835-1860`).
- `waketime` handling (`:159-160`) uses a per-iod `wakeup_source`.
- Every other ioctl stays as in `BUP` §2.2 (ABI), including the numeric collision
  `IOCTL_LINK_CONNECTED == IOCTL_MODEM_DUMP_UPDATE`. 0x6f47/0x6f48 keep returning `-EINVAL`
  (harmless; RN `cp_boot_firmware.md` Q2).

**`modem_utils.c/.h`** (1858 → ~1350):
- Timer, `proc_ops`, `timespec64` and `local_clock` changes (§2.1).
- Drop the file helpers, `board_gpio_export` and `make_gpio_floating` (`:1122-1196`).
- `mif_request_irq` (`:1051-1074`) calls `enable_irq_wake` unconditionally. Harmless, keep.
- `dflags` default 0 (§1.3).
- `calc_offset()` (`modem_utils.h:293`) returns `unsigned int` from pointer arithmetic.
  Fine on 32-bit and must stay 32-bit: SBD offsets are 32-bit fields in shared memory
  [proven type; inferred constraint].

**`link_device_memory.c`, `link_device_bootdump.c`, `link_device_memory_sbd.c`,
`link_device_memory_snapshot.c`, `link_device_memory_flow_control.c`** (~1 900, nearly
unchanged):
- Add DMA barriers at the producer index stores, and at the consumer between reading the
  index and reading the data (§2.6):
  - `udl_write` (`link_device_bootdump.c:73-83`);
  - the legacy IPC TX in `link_device_memory.c` (`:85`);
  - `tx_frames_to_rb` / `rx` in `link_device_memory_sbd.c` (`:509-524`);
  - `mem_take_snapshot`.
- `queue_work_on(7, …)` → `queue_work`.
- `msb_init` (`kmem_cache_create`, snapshot `:40-47`) runs once per link; the module is
  never unloaded, so no destroy is needed.

**`link_device_memory_main.c`** (1110 → ~1050):
- `mem_vmap/mem_vunmap/mem_register_ipc_rgn` (`:826-881`) → `devm_ioremap_wc`.
- `memset(base, 0, size)` (`:908`) → `memset_io`.
- `tasklet_setup` (`:1091`).
- Drop ARGOS (`:931-940`).
- `panic("skb alloc failed.")` under `CONFIG_SEC_MODEM_DEBUG` (`:466-467`): drop.
- `BUG_ON(1)` (`:747`) → `-EINVAL`.
- `sbd_tx_timer_func` (`:162-260`) runs in hard-IRQ (hrtimer) context. It calls
  `forbid_cp_sleep` / `send_ipc_irq`, which must stay non-sleeping. They are with Samsung
  GPIOs and MMIO [inferred from `gpiod_cansleep() == false` for pinctrl-samsung banks].

**`link_ctrlmsg_command.c`** (242, unchanged except timers): `INIT_START`, `PHONE_START`,
`CRASH_*` handlers as in `BUP` §3.5.

**`link_device_lli.c`** (915 → ~380):
- Keep `send_ap2cp_irq` (`:45-67`): TL signal plus `gpio_ipc_int2cp` toggle, under
  `sig_lock`. This is the `CONFIG_EXYNOS_MIPI_LLI_GPIO_SIDEBAND=y` path (defconfig:1325).
- Replace both PM branches (`:69-587`) by the locked-on PM of §2.7.
- Keep `lli_link_reset/reload/off/unmounted/suspended` (`:589-617`) and `lli_irq_handler`
  (`:640-663`).
- `lli_create_link_device` (`:777-914`) gets the region from the LLI driver, maps it, builds
  the SBD and registers the handler.
- debugfs `svnet/mem_dump` (`:759-772`): keep; the blob points into WC memory, which is
  fine for reads.

**`link_device_spi.c`** (257 → ~170):
- `spi_driver` with `of_match` `"spi_boot_link"` (`:193-209`), registered at `module_init`.
- `spi_transmit_data` (`:63-83`) uses `spi_delay`.
- Fix two 3.10 bugs:
  - `spi_boot_send` returns `skb->len` without freeing the skb on success (`:109-131`): a
    leak [proven];
  - on error it frees and returns **0** (`:126-130`), so `misc_write` returns `0 - 4 - 0`
    (`modem_io_device.c:1415`) [proven]. Return the real error code.
- Drop the `mif,gpio_cp_status` lookup in `spi_boot_probe` (`:148-168`): unused.

**`modem_ctrl_ss333.c`** (587 → ~540):
- Keep the sequences of `ss333_on/off/reset/boot_on/boot_off/boot_done/force_crash_exit/
  dump_reset` **with the same order and delays** (`:159-441`).
- Port the GPIOs to gpiod; `INIT_COMPLETION` → `reinit_completion`.
- `crash_ack_timer` → `timer_setup`; the wake lock becomes a wakeup source.
- Every op that drives a GPIO or the LLI first checks `allow_hw` and otherwise returns
  `-EPERM`.
- `cp_active_handler` on `gpiod_to_irq(phone_active)` keeps
  `IRQF_TRIGGER_RISING | IRQF_NO_THREAD | IRQF_NO_SUSPEND` (`:571-575`). Request it with
  `IRQF_NO_AUTOEN`; `ss333_boot_off` enables it, as stock does (`:418`).
- Requesting an IRQ on a GPIO switches the pin to EINT (0xF) by itself
  (`ML/drivers/pinctrl/samsung/pinctrl-exynos.c:248-251`), so the DT needs no
  `samsung,pin-function = <0xf>`.
- `dt_gpio_config` (`:456-475`) moves into `ss333_get_gpios()`.

### 2.4 ARM32-specific concerns

| Topic | Analysis | Tag |
|---|---|---|
| 32-bit pointers | The vendor code was written for, and shipped on, a 32-bit kernel (`# CONFIG_ARM_LPAE is not set`, `CONFIG_VMSPLIT_3G=y`, `CONFIG_HIGHMEM=y`, defconfig:453,538,559). It casts pointers to `int`/`unsigned int` (`calc_offset`; `(int)sl->rbps`, `link_device_memory_sbd.c:241`). All of it stays correct on our ARM32 kernel. **Do not import Google cpif code**, which is 64-bit oriented. | proven / inferred |
| LPAE | Ours is `CONFIG_ARM_LPAE=y`, `CONFIG_VMSPLIT_2G=y` (`PAGE_OFFSET 0x80000000`), `CONFIG_PHYS_ADDR_T_64BIT=y`, `CONFIG_ARCH_DMA_ADDR_T_64BIT=y` (`out/mainline/.config`). Values stay below 4 GiB (DRAM ends at 0xde980000, `BRD/exynos5433-gts28ltexx.dts` memory node). Every `%x`/`%lx` print of a `phys_addr_t`/`dma_addr_t` must become `%pa` (`mipi-lli.c:474-476`). `exynos_lli_cal_remap(u32 base…)` (`exynos-mipi-lli.c:68`) gets a checked `(u32)` cast. | proven config; inferred fix |
| `sizeof(size_t)` = 4 | SIPC5 padding aligns frames to `sizeof(size_t)` (`include/sipc5.h:93-97`). On ARM32 that is 4, as on the stock kernel, so BOOT/DUMP frames are byte-identical on the wire (`BOOT_ALIGNED` makes `ld->aligned = true` after `DL_START`, `link_device_bootdump.c:203-206`). On arm64 the padding would become 8 and change the framing seen by the CP. Pin it to 4 explicitly in the port (`#define SIPC5_ALIGN 4`). | proven code; inferred hazard |
| Highmem and vmalloc | With `no-map` + `ioremap_wc`, highmem does not matter. The 8 MiB mapping takes vmalloc space, which is fine with the 2G/2G split. | inferred |
| `unsigned long` in the ABI | `IOCTL_MIF_LOG_DUMP` copies an `unsigned long` (`modem_io_device.c:1280`); `struct modem_firmware` holds a `char *`. Both are 4 bytes on ARM32 with ARM32 userspace (Arch Linux ARM armv7h). No compat layer is needed. | proven / inferred |
| Cache coherency | The CP reaches AP DRAM through LLI → CPIF. 3.10 mapped the region non-cacheable (`pgprot_noncached`, `link_device_memory_main.c:829`), so it treats CPIF as **non-coherent**. The port must never map the region cacheable, and the region must not stay in the linear map (cacheable alias + speculative prefetch). `no-map` guarantees both. Stock was safe by another route: its region was in highmem with no linear alias (§3.1). | proven 3.10 type; inferred rest |
| Memory type and barriers | `pgprot_noncached` is **strongly-ordered** on ARM32 (`L_PTE_MT_UNCACHED`, `ML/arch/arm/include/asm/pgtable.h:115-116`), so 3.10's `barrier()`/`smp_mb()` sufficed. `ioremap_wc` is Normal non-cacheable bufferable (`MT_DEVICE_WC`, `ML/arch/arm/mm/mmu.c:252`; `L_PTE_MT_BUFFERABLE`, `pgtable.h:118-119`), which may reorder or merge stores. Hence `dma_wmb()` (= `dmb(oshst)`) before every index store and `dma_rmb()` (= `dmb(osh)`) after every index load (`ML/arch/arm/include/asm/barrier.h:63-68`). `smp_mb()` is only `dmb(ish)` (`:75`), the wrong domain for an external master. The doorbell `writel` already starts with `wmb()` = `dsb(st)` (`ML/arch/arm/include/asm/io.h:301`, `:175-176`), so data is visible before the doorbell. | proven primitives; inferred placement |
| Unaligned access | WC (Normal) memory tolerates unaligned access; strongly-ordered or Device memory faults on it. One more reason to use WC. | inferred |
| Outer cache | `CONFIG_CACHE_L2X0=y` is built (ARCH_EXYNOS) but no L2X0 node exists in our DT, so `outer_sync()` in `wmb()` is a no-op. | proven config; inferred no-op |

### 2.5 rmnet type

- Stock: `ndev->type = ARPHRD_PPP`, `IFF_POINTOPOINT | IFF_NOARP | IFF_MULTICAST`, no header
  (`modem_io_device.c:1671-1681`).
- Mainline `addrconf_dev_config` auto-configures IPv6 only for ETHER, FDDI, ARCNET,
  INFINIBAND, IEEE1394, TUNNEL6, 6LOWPAN, TUNNEL, NONE and RAWIP
  (`ML/net/ipv6/addrconf.c:3502-3518`). A PPP-type rmnet gets no link-local address and no
  SLAAC [proven].

**Decision: `ARPHRD_RAWIP`**, with `IFF_POINTOPOINT | IFF_NOARP`, `addr_len = 0`,
`hard_header_len = 0`, MTU 1500, `NET_NAME_PREDICTABLE`. RAWIP is what the mainline WWAN
drivers use (RN `linux_stack_voice.md:82`). RX already sets `skb->protocol` from the IP
version nibble (`modem_io_device.c:310-315`) and the payload is bare IP
(`ATTR_NO_LINK_HEADER`, `BUP` §5.4), so nothing else changes. A module parameter
`rmnet_type=ppp` can keep the stock type for A/B tests [inferred].

### 2.6 Shared-memory mapping

- **Owner.** The LLI driver resolves `memory-region` (`of_reserved_mem_lookup`) and programs
  `IAL_LL_INIT_ADDR_REMAP` / `IAL_BE_INIT_ADDR_REMAP` from it (`exynos-mipi-lli.c:304-314`).
  The modem driver gets `phys/size` through the existing
  `mipi_lli_get_phys_base/size()` and maps them with `devm_ioremap_wc`. The legacy 4 MiB map
  stays where `remap_4mb_map_to_ipc_dev` puts it (`BUP` §3.3).
- **Expected remap value** for base 0xde000000, size 8 MiB (bit_pos 23):
  `(0xde000000 >> 23) << 8 | 23 | 0x80` = **0x0001BC97**. Arithmetic from
  `exynos-mipi-lli.c:68-90` and `exynos-mipi-lli.h:245-246` [inferred value]. It is a bring-up
  checkpoint (§6 S2).
- **Barrier placement** [inferred]:

  | Side | Barrier sequence |
  |---|---|
  | Producer (AP → CP) | data `memcpy_toio`/`skb_copy_from_linear_data` → `dma_wmb()` → `size_v[]` → `dma_wmb()` → `*wp` / `set_txq_head` → doorbell (`writel`) |
  | Consumer (CP → AP) | doorbell IRQ → read `*wp` / head → `dma_rmb()` → read `size_v` + data → `dma_wmb()` → `*rp` / tail store |

- **Debug A/B.** A module parameter `shmem_map=wc|device` lets `device` use `ioremap()`
  (`MT_DEVICE`, ordered, no merging) to rule out an ordering bug quickly [inferred].

### 2.7 Locked-on link PM (phase 1)

Stock pin behaviour from `BOOT_ON` to `PHONE_START` is the same under `pm_enable = 1` and
`pm_enable = 0` [proven code]:
- `ss333_boot_on` raises AP2CP_STATUS (`modem_ctrl_ss333.c:391`).
- While the FSM is inactive, every FSM event lowers AP2CP_WAKEUP
  (`link_device_pm.c:389-394`), so AP2CP_WAKEUP stays low during the download.
- At `PHONE_START`, `start_link_pm()` raises **both** AP2CP_WAKEUP and AP2CP_STATUS, for
  `CP_BOOTING` as for `LOCK_ON` (`:809-816`), then enables the CP2AP IRQs (`:826-832`).

Phase-1 implementation [inferred design]:
- At probe (with `allow_hw = 1`): all outputs low (the stock probe state).
- `ss333_boot_on`: AP2CP_STATUS = 1. AP2CP_WAKEUP stays 0.
- `start_pm` (called from `cmd_phone_start_handler`, `link_ctrlmsg_command.c`):
  AP2CP_WAKEUP = 1 and AP2CP_STATUS = 1, then hold a wakeup source, and never release them
  while ONLINE.
- `stop_pm` (from `ld->off`): both 0, relax the wakeup source.
- `link_active()` = `cp_status == 1 && mipi_lli_get_link_status() == LLI_MOUNTED`
  (non-FSM variant, `link_device_lli.c:303-312`). `sbd_tx_timer_func` keeps retrying every
  `TX_PERIOD_MS` while it is false (`link_device_memory_main.c:194-198`).
- CP2AP_WAKEUP (gpa3-1) and CP2AP_STATUS (gpa2-5): `IRQ_TYPE_EDGE_BOTH`, **log and count
  only**, requested after `ss333_on`. Edge mode avoids the 3.10 level-flipping scheme
  (`link_device_pm.c:646-674`), which storms if a line floats while the CP is off.
- `mount_cb` equivalent: on `LLI_MOUNTED`, `wake_up_all(&mld->wq)` as `link_mount_cb` did
  (`link_device_pm.c:753-762`).

Whether the CP ever unmounts the link while AP2CP_WAKEUP stays high is **[unknown]**. In the
stock log, `Unmount` always follows the AP releasing AP2CP_WAKEUP
(`ACTIVE->AP_FREE->CP_FREE`, `DUMP/dmesg.txt:9-16`). If it does unmount, the LLI driver
re-arms itself (`exynos-mipi-lli.c:1003-1007`).

### 2.8 Bring-up safety features (new code, ~150 lines) [inferred design]

- `allow_hw` (`bool`, default `false`, writable at runtime by root):
  - `0`: probe completes, nodes appear, no GPIO, LLI register or SPI write happens, and
    `IOCTL_MODEM_ON/RESET/BOOT_ON/DL_START/…`, `write()` and `lli_control` commands return
    `-EPERM`;
  - this mirrors omarchy's `allow_hw=1` gate (`SP/web/cheetah_modem_plan.md:147-157,256-257`).
- debugfs `ss333/status` (read-only):
  - GPIO levels;
  - LLI state;
  - `DME_CSA_SYSTEM_STATUS`, `INTR_STATUS`;
  - the remap registers (read only when clocks are on);
  - PMU 0x720;
  - IRQ counters.
- debugfs `ss333/lli_reset` (requires `allow_hw`): runs `mipi_lli_intr_enable()` +
  `mipi_lli_reset()` with the CP held in reset (stage S2).
- Ship a `modprobe.d` file that blocklists both modules until stage S7 passes, so OF
  autoloading cannot load them at boot behind the tester's back.

---

## 3. DT additions for the board

New file `BRD/exynos5433-gts28ltexx-modem.dtsi`, included at the end of
`exynos5433-gts28ltexx.dts` as section 18. Every value cites its source, as the board rules
require (`docs/journal/HANDOVER.md`, "Never guess a register, GPIO…").

### 3.1 Reserved memory

```dts
/ {
	reserved-memory {
		/*
		 * MIPI-LLI shared memory for the SS333 CP.
		 * Size: MIPI_LLI_RESERVE_SIZE = SZ_8M (K310 include/linux/mipi-lli.h:23).
		 * Alignment = size: the remap register needs a power-of-two size and a
		 * size-aligned base (K310 exynos-mipi-lli.c:68-90).
		 * Address: stock allocates it top-down at boot
		 * (K310 mach-universal5433.c:62, mm/memblock.c:113-122), before its ION
		 * carveouts (:68). The highest free 8 MiB block below the end of DRAM
		 * (0xde980000) is 0xde000000, exactly the hole the stock ION layout
		 * leaves between 0xcf900000-0xde000000 and 0xde800000
		 * (dumps/live_fdt.dts:1911); our carveouts
		 * ion-carveout@cf900000 / @de800000 leave the same hole.
		 * no-map: no cacheable linear alias of memory the CP writes over LLI.
		 */
		cp_shmem: cp-shmem@de000000 {
			reg = <0xde000000 0x800000>;
			no-map;
		};
	};
};
```

- The address is **[inferred]**. The AP side works at any 8 MiB-aligned DRAM address. The
  unknown is which addresses the CP can reach (U-3), and choosing the stock-likely address
  minimises that risk.
- A static `reg` is reserved by the early FDT scan before any allocator runs [inferred from
  `of_reserved_mem.c`]. The alternative `size` + `alignment` + `alloc-ranges` with top-down
  placement would very likely land on the same block
  (`ML/drivers/of/of_reserved_mem.c:36-60`), but is less reproducible.
- Check on the device (S1): dmesg `OF: reserved mem: 0xde000000..0xde7fffff (8192 KiB) nomap
  non-reusable cp-shmem@de000000`, and the range absent from `/proc/iomem` "System RAM".

### 3.2 MIPI-LLI controller with the M-PHY folded in

```dts
&soc {
	/*
	 * MIPI-LLI controller of the CP interface (stock
	 * K310 arch/arm/boot/dts/exynos5433.dtsi:2128-2172, identical in
	 * dumps/live_fdt.dts:5503-5558). The stock 4th reg <0x105c0720 0x4>
	 * (PMU LLI_PHY_CON) is replaced by the PMU syscon: exynos-pmu already
	 * requests 0x105c0000-0x105c5007 (ML exynos-pmu.c:338), so a second
	 * request would fail with -EBUSY. The stock child "mphy" (0x10f20000)
	 * becomes reg[3].
	 */
	mipi_lli: mipi-lli@10f24000 {
		compatible = "samsung,exynos5433-mipi-lli";
		reg = <0x10f24000 0x4000>,	/* PA/DME/IAL/DL/TL (exynos-mipi-lli.h:49-208) */
		      <0x10f34000 0x4000>,	/* remote window; unused with GPIO sideband */
		      <0x10fd0000 0x2000>,	/* SYSREG_CPIF: CPIF_LLI_SIG_* (:17-47) */
		      <0x10f20000 0x4000>;	/* M-PHY (stock mphy child) */
		reg-names = "lli", "remote", "sysreg", "mphy";
		/* Stock <0 184 0>, <0 185 0>: index 0 = DME/link events
		 * (exynos_mipi_lli_irq), index 1 = TL signal doorbell (mipi_lli_sig_irq);
		 * exynos-mipi-lli.c:1132-1163. Level-high is inferred: every
		 * GIC SPI in the mainline 5433 dtsi is level-high. */
		interrupts = <GIC_SPI 184 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 185 IRQ_TYPE_LEVEL_HIGH>;
		interrupt-names = "lli", "signal";
		samsung,pmu-syscon = <&pmu_system_controller>;	/* LLI_PHY_CON 0x720 */
		memory-region = <&cp_shmem>;
		/* Stock clock-names and order (exynos5433.dtsi:2135-2162) minus the
		 * mux/rate entries, which become assigned-clocks. New CMU_CPIF IDs: §4.3. */
		clocks = <&cmu_mif CLK_ACLK_CPIF_200>,
			 <&cmu_cpif CLK_GATE_CPIFNM_200>,
			 <&cmu_cpif CLK_GATE_LLI_SVC_LOC>, <&cmu_cpif CLK_GATE_LLI_SVC_REM>,
			 <&cmu_cpif CLK_GATE_LLI_LL_INIT>, <&cmu_cpif CLK_GATE_LLI_BE_INIT>,
			 <&cmu_cpif CLK_GATE_LLI_CMN_CFG>,
			 <&cmu_cpif CLK_GATE_LLI_TX0_CFG>, <&cmu_cpif CLK_GATE_LLI_RX0_CFG>,
			 <&cmu_cpif CLK_GATE_LLI_TX0_SYMBOL>, <&cmu_cpif CLK_GATE_LLI_RX0_SYMBOL>;
		clock-names = "aclk_cpif_200", "gate_cpifnm_200",
			      "gate_lli_svc_loc", "gate_lli_svc_rem",
			      "gate_lli_ll_init", "gate_lli_be_init",
			      "gate_lli_cmn_cfg",
			      "gate_lli_tx0_cfg", "gate_lli_rx0_cfg",
			      "gate_lli_tx0_symbol", "gate_lli_rx0_symbol";
		/* Stock: clk_set_parent(mout_*_symbol_user, phyclk_*_symbol)
		 * (exynos-mipi-lli.c:509-512) and dout_aclk_cpif_200 = 100 MHz
		 * (:1196). SYSTEM_CLOCK_PERIOD = 10 ns assumes 100 MHz (:34-38). */
		assigned-clocks = <&cmu_mif CLK_DIV_ACLK_CPIF_200>,
				  <&cmu_cpif CLK_MOUT_PHYCLK_LLI_TX0_SYMBOL_USER>,
				  <&cmu_cpif CLK_MOUT_PHYCLK_LLI_RX0_SYMBOL_USER>;
		assigned-clock-parents = <0>,
					 <&cmu_cpif CLK_PHYCLK_LLI_TX0_SYMBOL>,
					 <&cmu_cpif CLK_PHYCLK_LLI_RX0_SYMBOL>;
		assigned-clock-rates = <100000000>, <0>, <0>;
		/* Stock modems/ss333 and mphy/modems/ss333 sub-nodes
		 * (exynos5433-modem-ss333.dtsi:124-152): scrambler 0, automode 0,
		 * init-gear <2 2 1> = HS, gear 2, series A; shd-refclk 1.
		 * shdmem_size/is_ion_alloc are replaced by memory-region. */
		samsung,mphy-init-gear = <2 2 1>;
		samsung,mphy-shared-refclk;
	};
};
```

- **Device name**: `10f24000.mipi-lli`, unchanged. The sysfs path changes from 3.10's
  `/sys/devices/10f24000.mipi-lli/` to `/sys/devices/platform/soc@0/10f24000.mipi-lli/`
  [inferred from the 6.12 bus layout].
- The loader should read `/sys/bus/platform/devices/10f24000.mipi-lli/lli_control`, or a udev
  rule should recreate `/dev/mipi-lli` as stock `init.baseband.rc:15` did (CBD_RE §1).
- Nothing in the mainline SoC dtsi lives at 0x10f20000-0x10f37fff or 0x10fd0000; the
  neighbours are `cmu_cpif` @0x10fc0000 and `pinctrl_cpif` @0x10fe0000
  (`ML/arch/arm64/boot/dts/exynos/exynos5433.dtsi:384-391,867-871`) [proven].

### 3.3 Modem node (SS333 control + iodevs)

```dts
/ {
	/*
	 * Node name kept as stock: the loader waits on
	 * /sys/bus/platform/drivers/mif_sipc5/mif_pdata/cp_status/value
	 * (cpboot v1 util.c:802-833, shannon333.h:2-4). A root node without reg
	 * is named "mif_pdata" by of_device_make_bus_id.
	 * GPIO flags: all GPIO_ACTIVE_HIGH. The stock third cells (0x1, 0xf in
	 * exynos5433-modem-ss333.dtsi:24-38; live_fdt.dts:2582-2603) are ignored by
	 * 3.10 of_get_named_gpio(); mainline would read 0x1 as ACTIVE_LOW and invert
	 * CP_ON/CP_RESET. The driver works in physical levels, as 3.10 did.
	 */
	mif_pdata {
		compatible = "samsung,ss333-modem", "sec_modem,modem_pdata";
		pinctrl-names = "default";
		pinctrl-0 = <&cp_ctrl_out &cp_ctrl_out_fsys &cp_ctrl_out_peric
			     &cp_ctrl_in &cp_pmic_hold>;

		/* modem-ss333.dtsi:24-38 (mif,*, link_pm/*) */
		cp-on-gpios        = <&gpr3 1 GPIO_ACTIVE_HIGH>;	/* :24 */
		cp-reset-gpios     = <&gpc0 5 GPIO_ACTIVE_HIGH>;	/* :26, 0 = reset */
		pda-active-gpios   = <&gpg2 1 GPIO_ACTIVE_HIGH>;	/* :27 */
		phone-active-gpios = <&gpa2 3 GPIO_ACTIVE_HIGH>;	/* :28, rising = crash */
		cp-status-gpios    = <&gpa2 5 GPIO_ACTIVE_HIGH>;	/* :30 and link_pm :37 */
		ipc-int2cp-gpios   = <&gpa2 6 GPIO_ACTIVE_HIGH>;	/* :31 */
		ap-dump-int-gpios  = <&gpr2 0 GPIO_ACTIVE_HIGH>;	/* :32 */
		cp2ap-wakeup-gpios = <&gpa3 1 GPIO_ACTIVE_HIGH>;	/* :35 */
		ap2cp-wakeup-gpios = <&gpf5 0 GPIO_ACTIVE_HIGH>;	/* :36 */
		ap2cp-status-gpios = <&gpf1 2 GPIO_ACTIVE_HIGH>;	/* :38 */

		samsung,mipi-lli = <&mipi_lli>;
		samsung,boot-spi = <&cp_boot_spi>;

		/* Verbatim from K310 modem-ss333-pdata.dtsi:15-27 */
		mif,name = "ss333";
		mif,modem_net = <0>;
		mif,modem_type = <15>;		/* SEC_SS333 */
		mif,use_handover = <0>;
		mif,ipc_version = <50>;		/* SIPC_VER_50 */
		mif,link_types = <0x408>;	/* LLI | SPI */
		mif,link_name = "lli";
		mif,link_attrs = <0x3C9>;
		mif,num_iodevs = <13>;

		iodevs {
			/* io_device_0 .. io_device_12 copied verbatim from
			 * modem-ss333-pdata.dtsi:28-186 (table in BUP §1.4) */
		};
	};
};
```

### 3.4 Pin configuration

Ordering matters:
- pinctrl-samsung applies the **mux before the configs** (`ML/drivers/pinctrl/samsung/
  pinctrl-samsung.c:224-236`).
- `gpio_direction_output` writes the value **before** the direction (`:693-695`).
- So the default state must not set `pin-function = OUTPUT` on CP_ON or CP_RESET. Stock did
  (`exynos5433-modem-ss333.dtsi:43-71`); if DAT happens to be 1 it glitches the line high
  for the time between the two writes. The driver sets those directions through gpiod
  instead [proven order; inferred hazard].
- The power-down cells reproduce the stock sleep states (`:183-215`). They are harmless
  without suspend.

```dts
&pinctrl_alive {
	/* AP2CP_STATUS gpf1-2, AP2CP_WAKEUP gpf5-0: outputs, no pull, keep level
	 * in power-down (modem-ss333.dtsi:102-114, 193-194). Alive gpa banks
	 * have no PDN fields (ML pinctrl-exynos-arm64.c:38-41). */
	cp_ctrl_out: cp-ctrl-out-pins {
		samsung,pins = "gpf1-2", "gpf5-0";
		samsung,pin-pud = <EXYNOS_PIN_PULL_NONE>;
		samsung,pin-con-pdn = <EXYNOS_PIN_PDN_PREV>;
		samsung,pin-pud-pdn = <EXYNOS_PIN_PULL_NONE>;
	};

	/* PHONE_ACTIVE gpa2-3, CP2AP_STATUS gpa2-5, CP2AP_WAKEUP gpa3-1 (EINT
	 * set by request_irq), IPC_INT2CP gpa2-6 (output): no pull, drv 0
	 * (modem-ss333.dtsi:75-94, 116-121). */
	cp_ctrl_in: cp-ctrl-in-pins {
		samsung,pins = "gpa2-3", "gpa2-5", "gpa3-1", "gpa2-6";
		samsung,pin-pud = <EXYNOS_PIN_PULL_NONE>;
		samsung,pin-drv = <EXYNOS5433_PIN_DRV_FAST_SR1>;
	};

	/* CP_PMIC_PWR_HOLD gpf1-1 ("cp_off"): input, high-Z, as the stock
	 * pinctrl_0 initial and sleep states (modem-ss333.dtsi:96-100, 186-191). */
	cp_pmic_hold: cp-pmic-hold-pins {
		samsung,pins = "gpf1-1";
		samsung,pin-function = <EXYNOS_PIN_FUNC_INPUT>;
		samsung,pin-pud = <EXYNOS_PIN_PULL_NONE>;
		samsung,pin-con-pdn = <EXYNOS_PIN_PDN_INPUT>;
		samsung,pin-pud-pdn = <EXYNOS_PIN_PULL_NONE>;
	};
};

&pinctrl_fsys {
	/* CP_ON gpr3-1, AP_DUMP_INT gpr2-0 (modem-ss333.dtsi:43-55, 198-203) */
	cp_ctrl_out_fsys: cp-ctrl-out-fsys-pins {
		samsung,pins = "gpr3-1", "gpr2-0";
		samsung,pin-pud = <EXYNOS_PIN_PULL_NONE>;
		samsung,pin-con-pdn = <EXYNOS_PIN_PDN_PREV>;
		samsung,pin-pud-pdn = <EXYNOS_PIN_PULL_NONE>;
	};
};

&pinctrl_peric {
	/* CP_RESET gpc0-5, PDA_ACTIVE gpg2-1 (modem-ss333.dtsi:59-71, 206-212) */
	cp_ctrl_out_peric: cp-ctrl-out-peric-pins {
		samsung,pins = "gpc0-5", "gpg2-1";
		samsung,pin-pud = <EXYNOS_PIN_PULL_NONE>;
		samsung,pin-con-pdn = <EXYNOS_PIN_PDN_PREV>;
		samsung,pin-pud-pdn = <EXYNOS_PIN_PULL_NONE>;
	};

	/* CP_SPI_MISO gpv7-3 parked: input, pull-down (modem-ss333.dtsi:206-215) */
	cp_spi_miso: cp-spi-miso-pins {
		samsung,pins = "gpv7-3";
		samsung,pin-function = <EXYNOS_PIN_FUNC_INPUT>;
		samsung,pin-pud = <EXYNOS_PIN_PULL_DOWN>;
		samsung,pin-con-pdn = <EXYNOS_PIN_PDN_INPUT>;
		samsung,pin-pud-pdn = <EXYNOS_PIN_PULL_DOWN>;
	};
};

/* SPI4 TX-only group: CLK gpv7-1, nCS gpv7-2, MOSI gpv7-4, function 3,
 * pull-up, drv 0 (modem-ss333.dtsi:170-174; live_fdt.dts:6331-6338).
 * Mainline default is gpv7-1/3/4 (ML exynos5433-pinctrl.dtsi:727-732). */
&spi4_bus {
	samsung,pins = "gpv7-1", "gpv7-2", "gpv7-4";
};
```

Bank owners: gpr2/gpr3 in FSYS, gpv7/gpc0/gpg2 in PERIC, gpa2/gpa3/gpf1/gpf5 in ALIVE
(`ML/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c:65-75,103-111,126-144`); the bank labels
are already used by our board (`&gpa2`, `&gpa3`, `&gpr3`, `&gpc0`) [proven].

### 3.5 SPI4 boot link

```dts
/*
 * SPI4 @0x14d00000 carries the CP first stage (BOOT, 0x29fc bytes) to the
 * SS333 BootROM: SPI mode 0, 8 bit, single transfer (K310 link_device_spi.c:
 * 63-83, 137-138), 100 kHz (modem-ss333.dtsi:154-169; live_fdt.dts:1747-1772).
 * The mainline node is disabled by default (ML exynos5433.dtsi:1535-1553).
 * DMA (pdma0 25/24) needs pl330.ko; without it the controller falls back to
 * PIO (ML spi-s3c64xx.c:386-401, 829-837).
 */
&spi_4 {
	status = "okay";
	pinctrl-names = "default";
	pinctrl-0 = <&spi4_bus &cp_spi_miso>;

	cp_boot_spi: modem-boot@0 {
		compatible = "samsung,ss333-boot-spi", "spi_boot_link";
		reg = <0>;
		spi-max-frequency = <100000>;
		controller-data {
			samsung,spi-feedback-delay = <0>;	/* modem-ss333.dtsi:164-167 */
		};
	};
};
```

- The stock `samsung,spi-chip-select-mode = <1>` has no mainline equivalent. The 5433 port
  config already uses `S3C64XX_SPI_QUIRK_CS_AUTO` (`ML/drivers/spi/spi-s3c64xx.c:1561-1571`).
- The stock live tree had an empty `controller-data` (`live_fdt.dts:1769-1770`).
- Clock: `sclk_spi4` comes from `mout_sclk_spi4` {oscclk 24 MHz, bus_pll_user} through two
  dividers, 4 and 8 bits (`ML/drivers/clk/samsung/clk-exynos5433.c:383-384,569-572`).
  The controller divides by 2 (`clk_div`, `:1568`). 200 kHz is reachable (24 MHz / 120, or
  800 MHz / 4096 ≈ 195 kHz) [inferred]. Read the real rate in
  `/sys/kernel/debug/clk/clk_summary` at S4.

### 3.6 Sleep states

None in phase 1: the tablet does not suspend, though `CONFIG_SUSPEND=y` is built
(`out/mainline/.config`; `docs/journal/HANDOVER.md`). The `pin-con-pdn` / `pin-pud-pdn`
cells above already encode the stock sleep levels. A separate `"sleep"` pinctrl state is only
needed with system suspend (phase 2).

---

## 4. Clock and PMU support

### 4.1 What the LLI needs, from the 3.10 clock code [proven]

CMU_CPIF base 0x10FC0000 (`K310/arch/arm/mach-exynos/include/mach/regs-clock-exynos5433.h:29`);
CMU_MIF base 0x105B0000 (`:41`).

| Register (offset) | Bits | 3.10 clock | Parent / meaning | Source |
|---|---|---|---|---|
| CPIF `SRC_SEL_CPIF1` (0x0204) | [4] | `mout_phyclk_lli_tx0_symbol_user` | {oscclk, `phyclk_lli_tx0_symbol`} | `clk-exynos5433.c:1471,1168`; reg `regs-clock…h:161` |
| | [8] | `mout_phyclk_lli_rx0_symbol_user` | {oscclk, `phyclk_lli_rx0_symbol`} | `:1472,1169` |
| | [0] | `mout_phyclk_ufs_mphy_to_lli_user` | {oscclk, `phyclk_ufs_mphy_to_lli`} | `:1474,1171` |
| CPIF `SRC_SEL_CPIF2` (0x0208) | [0] | `mout_sclk_mphy` | {`dout_sclk_mphy`, `mout_phyclk_ufs_mphy_to_lli_user`} | `:1475,1172` |
| – (fixed) | – | `phyclk_lli_tx0_symbol`, `phyclk_lli_rx0_symbol` | 150 MHz, from the M-PHY | `:1334-1335` |
| CPIF `ENABLE_ACLK_CPIF` (0x0800) | [0..16] | `aclk_mdma0`, `aclk_lli_svc_loc/svc_rem/ll_init/be_init/ll_targ/be_targ` (1-6), `aclk_cpifnm_200` (7), `aclk_cpifnp_200` (8), `aclk_xiu_cpifsfrx` (9), `aclk_xiu_llix` (10), `aclk_ahb2apb_cpifp` (11), `aclk_axius_lli_ll/be` (12-13), `aclk_bts_mdma0` (14), `aclk_ppmu_llix` (15), `aclk_smmu_mdma0` (16) | parent `aclk_cpif_200`, all `CLK_IGNORE_UNUSED` | `:2417-2433`; reg `:456` |
| CPIF `ENABLE_PCLK_CPIF` (0x0900) | [0..6] | `pclk_mdma0`, `pclk_sysreg_cpif`, `pclk_pmu_cpif`, `pclk_gpio_cpif`, `pclk_bts_mdma0`, `pclk_ppmu_llix`, `pclk_smmu_mdma0` | `aclk_cpif_200`, `IGNORE_UNUSED` | `:2434-2440`; `:457` |
| CPIF `ENABLE_SCLK_CPIF` (0x0A00) | [0..2] | `sclk_lli_cmn_cfg`, `sclk_lli_tx0_cfg`, `sclk_lli_rx0_cfg` | `aclk_cpif_200`, `IGNORE_UNUSED` | `:2441-2443` |
| | [3] | `sclk_lli_mphy` | `mout_sclk_mphy`, `IGNORE_UNUSED` | `:1882` |
| | [4], [9] | `sclk_ufs_mphy`, `sclk_mphy_pll` | already in mainline | `ML/…/clk-exynos5433.c:886-891` |
| CPIF `ENABLE_IP_CPIF0` (0x0B00) | 1,2,3,4 | `gate_lli_svc_loc`, `_svc_rem`, `_ll_init`, `_be_init` | **used by the LLI driver** | `:2537-2540` (bits), enum IDs 2071-2074 (`:285-287`) |
| | 7,8,9 | `gate_lli_cmn_cfg`, `_tx0_cfg`, `_rx0_cfg` | used | `:2532-2534`, IDs 2062-2064 |
| | 10,11 | `gate_lli_tx0_symbol`, `_rx0_symbol` | used | `:2530-2531`, IDs 2060-2061 |
| | 0,5,6,12-19 | `gate_mdma0`, `gate_lli_ll_targ/be_targ`, `gate_sysreg_cpif` (IGN), `gate_pmu_cpif` (IGN), `gate_gpio_cpif` (IGN), `gate_lli_mphy`, `gate_ufs_mphy`, `gate_freq_det_mphy_pll`, `gate_mphy_pll_mif`, `gate_mphy_pll` | not requested by the LLI driver | `:2522-2541` |
| CPIF `ENABLE_IP_CPIF1` (0x0B04) | 0 | `gate_cpifnm_200` | **used** (ID 2093) | `:2553`; enum `:290-293` |
| | 1-9 | `cpifnp_200`, `xiu_cpifsfrx`, `xiu_llix`, `ahb2apb_cpifp`, `axius_lli_ll/be` (all IGN), `bts_mdma0`, `ppmu_llix`, `smmu_mdma0` | not requested | `:2544-2552` |
| MIF `DIV_MIF3` (0x060C) | [2:0] | `dout_aclk_cpif_200` | parent `mout_aclk_mifnm_200`; **forced to 100 MHz** | `:1711`; `exynos-mipi-lli.c:1193-1198` |
| MIF `ENABLE_ACLK_MIF3` (0x080C) | [0] | `aclk_cpif_200` | `IGNORE_UNUSED` | `:1871` |

The DT consumer IDs map one to one onto this list: `<&clock 320>` = `aclk_cpif_200`;
2093/2074/2073/2072/2071/2064/2063/2062/2061/2060 = the gates; 3103/3104 = the muxes;
5014/5015 = the 150 MHz PHY clocks; 4114/4104 = `dout_aclk_cpif_200`/`dout_mif_pre`
(`K310/arch/arm/boot/dts/exynos5433.dtsi:2135-2162`; enum `clk-exynos5433.c:236-293,
652-656,813-821,906-907`) [proven by counting enum positions].

### 4.2 What mainline already has [proven]

- CMU_CPIF only knows `MPHY_PLL_LOCK/CON0/CON1/FREQ_DET`, `MUX_SEL_CPIF0`, `DIV_CPIF` and
  `ENABLE_SCLK_CPIF`. Clocks: `fout_mphy_pll`, `mout_mphy_pll`, `div_sclk_mphy`, and the gates
  `sclk_mphy_pll` (bit 9, `CLK_IGNORE_UNUSED`) and `sclk_ufs_mphy` (bit 4)
  (`ML/drivers/clk/samsung/clk-exynos5433.c:839-915`).
- **Upstream ID bug**: `CLK_SCLK_MPHY_PLL` and `CLK_SCLK_UFS_MPHY` are both **11**
  (`ML/include/dt-bindings/clock/exynos5433.h:198-199`), and `CLKS_NR_CPIF =
  CLK_SCLK_UFS_MPHY + 1` (`clk-exynos5433.c:26`). New IDs must start at 12 and the existing
  ones must not be renumbered (DT ABI).
- CMU_MIF has `div_aclk_cpif_200` (`DIV_MIF3[2:0]`, `:1257-1258`) and `aclk_cpif_200`
  (`ENABLE_ACLK_MIF3[0]`, `CLK_IGNORE_UNUSED | CLK_SET_RATE_PARENT`, `:1439-1441`).
- Mainline never writes 0x0204, 0x0208, 0x0800, 0x0900, 0x0B00 or 0x0B04. They are absent
  from `cpif_clk_regs` (`:849-857`), so they stay as reset or sboot left them.
- Our kernel boots with `clk_ignore_unused pd_ignore_unused` (`gts28ltexx_defconfig`
  `CONFIG_CMDLINE`; `BRD/exynos5433-gts28ltexx.dts:114`), so no unused CPIF gate is turned
  off today.

### 4.3 Target: patch to `clk-exynos5433.c` (~130 lines + ~20 in dt-bindings)

- `cpif_clk_regs[]`: add `SRC_SEL_CPIF1 0x0204`, `SRC_SEL_CPIF2 0x0208`,
  `ENABLE_ACLK_CPIF 0x0800`, `ENABLE_PCLK_CPIF 0x0900`, `ENABLE_IP_CPIF0 0x0b00` and
  `ENABLE_IP_CPIF1 0x0b04`, for save/restore.
- `cpif_fixed_clks[]`: `FRATE(CLK_PHYCLK_LLI_TX0_SYMBOL, "phyclk_lli_tx0_symbol", NULL, 0,
  150000000)` and the RX twin.
- `cpif_mux_clks[]`: `MUX(CLK_MOUT_PHYCLK_LLI_TX0_SYMBOL_USER,
  "mout_phyclk_lli_tx0_symbol_user", {"oscclk","phyclk_lli_tx0_symbol"}, SRC_SEL_CPIF1, 4, 1)`
  and the RX twin at bit 8.
- `cpif_gate_clks[]`: `ENABLE_IP_CPIF0` bits 1-4 and 7-11, `ENABLE_IP_CPIF1` bit 0.
  - Flags 0, so they gate when unused if `clk_ignore_unused` is ever dropped: correct, since
    the LLI driver holds them while in use.
  - Parents follow 3.10's `NULL` (`:2522-2553`) [inferred to be harmless: the gates only
    gate].
- Optional, recommended: model `ENABLE_ACLK/PCLK/SCLK_CPIF` bits with `CLK_IGNORE_UNUSED` as
  in 3.10, for visibility in `clk_summary` without changing behaviour.
- New IDs (in `ML/include/dt-bindings/clock/exynos5433.h`, CMU_CPIF block), then
  `CLKS_NR_CPIF = CLK_GATE_CPIFNM_200 + 1`:

  | ID | Name |
  |---|---|
  | 12 | `CLK_PHYCLK_LLI_TX0_SYMBOL` |
  | 13 | `CLK_PHYCLK_LLI_RX0_SYMBOL` |
  | 14 | `CLK_MOUT_PHYCLK_LLI_TX0_SYMBOL_USER` |
  | 15 | `CLK_MOUT_PHYCLK_LLI_RX0_SYMBOL_USER` |
  | 16-19 | `CLK_GATE_LLI_SVC_LOC`, `_SVC_REM`, `_LL_INIT`, `_BE_INIT` |
  | 20-22 | `CLK_GATE_LLI_CMN_CFG`, `_TX0_CFG`, `_RX0_CFG` |
  | 23-24 | `CLK_GATE_LLI_TX0_SYMBOL`, `_RX0_SYMBOL` |
  | 25 | `CLK_GATE_CPIFNM_200` |

### 4.4 First-light fallback: direct register writes (only if §4.3 slips)

- The LLI driver maps CMU_CPIF with plain `devm_ioremap(0x10fc0000, 0x1000)`. It must not
  use `devm_ioremap_resource`: the clock driver maps it with `of_iomap` and requests nothing,
  so a plain map works [inferred].
- It writes only registers the clock driver never touches (§4.2):
  - `SRC_SEL_CPIF1 |= BIT(4) | BIT(8)`;
  - `ENABLE_IP_CPIF0 |= BIT(1..4) | BIT(7..11)`;
  - `ENABLE_IP_CPIF1 |= BIT(0)`.
- It must log each register before and after the write.
- It must **not** touch `ENABLE_SCLK_CPIF` (0x0A00): the clock driver owns bits 4 and 9 of it.
- `div_aclk_cpif_200` still goes through `assigned-clock-rates` on the cmu_mif clock, which
  mainline already models.
- This shortcut is not raceless in general. It is race-free here only because the clock
  driver has no clock on those offsets, and it must be removed once §4.3 lands.

### 4.5 PMU

- Register: `EXYNOS5433_LLI_PHY_CON = EXYNOS_PMUREG(0x0720)`
  (`K310/arch/arm/mach-exynos/include/mach/regs-pmu-exynos5433.h:36`).
- Writes in 3.10 (`exynos-mipi-lli.c`): `1` at each `SW_RESET_DONE` (`:296`), `0` at
  suspend (`:626`), `1` at resume (`:637`) and in the loopback test (`:744`) [proven].
- Mainline:
  - Offset 0x720 is defined only as `EXYNOS5_DPTX_PHY_CONTROL`, the 5250/5420 DP PHY name
    (`ML/include/linux/soc/samsung/exynos-regs-pmu.h:355`).
  - Nothing on 5433 uses it: the nearest 5433 define is `EXYNOS5433_USBHOST30_PHY_CONTROL
    0x0728` (`:644`), and our board has no DP.
  - The 5433 PMU has no `pmu_data` and no secure write filter
    (`ML/drivers/soc/samsung/exynos-pmu.c:256-257`) [proven].
- **How**: add `#define EXYNOS5433_LLI_PHY_CONTROL 0x0720` to `exynos-regs-pmu.h` (one line,
  same patch as §4.3), then `regmap_write(pmu, EXYNOS5433_LLI_PHY_CONTROL, 1)`. Stock wrote
  the whole word with 1, so `regmap_write` reproduces it; `update_bits` would keep unknown
  upper bits. A DT `reg` at 0x105c0720 is impossible: `exynos_pmu_probe` already requests the
  whole range (`exynos-pmu.c:338`), so a second request fails with `-EBUSY` [proven].

---

## 5. Interaction with today's kernel; CP state; safety

### 5.1 Is anything modem-related touched or claimed today?

| Resource | Today (`t715-bringup`) | Evidence |
|---|---|---|
| Modem GPIOs gpr3-1, gpr2-0, gpc0-5, gpg2-1, gpa2-3/5/6, gpa3-1, gpf1-1/2, gpf5-0 | **Not referenced** anywhere in the board DT or patches | grep of `BRD/exynos5433-gts28ltexx*.dts*` and `kernel/patches/t715-bringup/*.patch` [proven] |
| Same banks, other pins | gpa2-0/1/7 keys (`-m4.dtsi:32,40,59`); gpa2-2 BT host wake (`-bt.dtsi:35,94`); gpa3-6 MUIC IRQ (`.dts:786`); gpr3-4/5/6 PCIe, gpr3-7 BT wake (`-wifi.dtsi:118,206`; `-bt.dtsi:43,85`); gpc0-7 codec reset (`-audio.dtsi:79,144`); gpf1-0 PCIe wake (`-wifi.dtsi:192`) | No pin overlaps. gpa2/gpa3 share the muxed wakeup EINT parent (GIC SPI 16, `ML/…/exynos5433.dtsi:853-857`), which already serves BT and MUIC [proven] |
| SPI4 (0x14d00000) and gpv7 | Node `status = "disabled"` in the SoC dtsi (`:1535-1553`), not enabled by the board. **`CONFIG_SPI` is not set** in the daily build | `out/mainline/.config` [proven] |
| CMU_CPIF | Registered with the mainline subset. `sclk_mphy_pll` is `CLK_IGNORE_UNUSED`. Nothing gated (`clk_ignore_unused`). LLI gates and muxes unmodeled, so they keep reset or sboot values | §4.2 [proven] |
| `aclk_cpif_200` | `CLK_IGNORE_UNUSED`; rate as left by sboot or reset | §4.2 [proven] |
| PMU 0x720 | Never written by mainline | §4.5 [proven] |
| GIC SPI 184/185 | Not requested by any node | `ML/…/exynos5433.dtsi` grep [proven] |
| 0xde000000-0xde7fffff | Ordinary free highmem today (between our two ION no-map carveouts, `BRD/exynos5433-gts28ltexx.dts:214-222`) | [proven DT; inferred free] |
| The S2MPS13 CP 32 kHz output (`s2mps13_osc` index 1, `S2MPS11_CLK_CP`, `ML/include/dt-bindings/clock/samsung,s2mps11.h:14`) | Registered, no consumer; kept as sboot left it thanks to `clk_ignore_unused` | `BRD/exynos5433-gts28ltexx.dts` PMIC section [proven]. Whether the SS333 uses it is [unknown]; the stock kernel never enabled it explicitly |

### 5.2 State of the CP after our kernel boots

**[inferred, high confidence]: off, or held in reset, and idle.**
- Nothing in our kernel or initramfs drives the CP lines (§5.1), so they keep the
  power-on-reset or sboot configuration. On Exynos pin controllers that means GPIO input by
  default.
- Since 2026-10-29 the tablet keeps no Android and cold-boots straight into Linux
  (`docs/journal/HANDOVER.md`). Before that, every stock shutdown or reboot ran `modem_shutdown` →
  `ss333_off`, which leaves `CP_RESET = 0` (`modem_main.c:658-667`,
  `modem_ctrl_ss333.c:263-267`) [proven code].
- Note that stock "off" leaves `CP_ON` **high** with `CP_RESET` low (`:246-267`). Whether the
  CP PMIC then cuts power is [unknown]; on a cold boot the question disappears.
- The LLI cannot be up: its IRQs are not requested, and the PMU PHY control and remap were
  never programmed. The CP can therefore not reach AP memory through LLI [inferred].

**Read-only confirmation** (stage S0, run by whoever deploys on the tablet):
tests on the tablet per `docs/journal/HANDOVER.md`):
- `grep -hE "\((gpr3-1|gpr2-0|gpc0-5|gpg2-1|gpa2-[356]|gpa3-1|gpf1-[12]|gpf5-0|gpv7-[1-4])\)"
  /sys/kernel/debug/pinctrl/*/pins`. pinctrl-samsung prints CON/DAT/PUD/DRV per pin
  (`ML/drivers/pinctrl/samsung/pinctrl-samsung.c:287-303`; `CONFIG_DEBUG_FS=y`).
- The expected result is not established; it is S0's job.

### 5.3 Power and safety concerns today

- **Today: none** from the modem. The CP is idle, and unmodeled CPIF gates may draw a little
  static power [inferred].
- **After the port**, a powered CP adds tens to hundreds of mA, plus RF bursts. The tablet has
  no charger or VBUS driver (`docs/journal/HANDOVER.md`), so long CP tests drain the battery [inferred].
- The **AP memory exposure** that appears once LLI is up is covered in R-1 (§7).

---

## 6. Staged bring-up plan with checkpoints

Each stage is one small, separately testable step. The kernel log strings quoted are the 3.10
ones, kept on purpose by the port so they can be compared with the stock log in
`DUMP/dmesg.txt`. "Loader" means the independent `shannon-loader` (LOADER_SPEC, with the four
fixes from RN `cp_boot_firmware.md` Q2).

| Stage | Action | Expected evidence | Most likely failure causes |
|---|---|---|---|
| **S0 Baseline (no new code)** | Read-only on the device: pinctrl `pins` grep (§5.2); `clk_summary` for `fout_mphy_pll`, `div_aclk_cpif_200`, `aclk_cpif_200`; `busybox devmem` **reads** of CMU_CPIF 0x10fc0204/0800/0900/0a00/0b00/0b04 and PMU 0x105c0720 (`CONFIG_DEVMEM=y`; `CONFIG_STRICT_DEVMEM` absent from `out/mainline/.config`) | The CP lines are inputs or low. 0x720 = 0. The CPIF register values get recorded for §4.4. **Never** read 0x10f2xxxx-0x10f3xxxx or 0x10fdxxxx yet: an unclocked IP can hang the bus | — |
| **S1 Probe, allow_hw=0** | New BOOT image with the DT; `modprobe exynos5433-mipi-lli; modprobe sec_modem_v1` | dmesg: the reserved-memory line (§3.1); `lli: dout_aclk_cpif_200 = 100000000` (port prints the real `clk_get_rate`); `lli: Registered MIPI-LLI interface` (`exynos-mipi-lli.c:1203`); `mif: modem_probe: ss333: lli link created` and `spi_boot link created` (`modem_main.c:600`); `mif: create_io_device: umts_ipc0 created` ×13 (`:192`); `BOOT device = umts_boot0` (`:171`). Nodes: 9 misc (`/dev/umts_ipc0 … /dev/umts_ramdump0`, `/dev/multipdp`) + `rmnet0-3` (type 519 = RAWIP in `ip -d link`). Sysfs: `lli_control` = `MIPI-LLI 0`; `/sys/bus/platform/drivers/mif_sipc5/mif_pdata/cp_status/value` = `0`. `IOCTL_MODEM_ON` → `-EPERM`. CP lines unchanged versus S0 | Probe deferral loop (`mif_pdata` waits for LLI/SPI: missing `CONFIG_SPI`, missing pl330 is harmless); `memory-region` rejected (alignment check); the clock patch IDs mismatched; `-EBUSY` from a PMU `reg` (must be the syscon) |
| **S2 LLI controller alone, CP held in reset** | `allow_hw=1`; debugfs `ss333/lli_reset` with CP_ON = 0 and CP_RESET = 0 (stock probe state, driven low) | dmesg `lli: SW_RESET_DONE ++` (`:912`): this proves IRQ 184, clocks and soft reset. debugfs: `IAL_LL_INIT_ADDR_REMAP` (LLI+0x1110) and `BE` (+0x1114) = **0x0001BC97** (§2.6); PMU 0x720 = 1; `PA_SYSTEM_CLK_PERIOD` (+0x400) = 10; `DME_CSA_SYSTEM_STATUS` mounted bit clear. `/proc/interrupts` line for SPI 184 increments; SPI 185 stays at 0 | Bus hang or external abort on the first LLI register access (a gated `ENABLE_IP_CPIF*` bit or `aclk_cpif_200`; fix the clocks, compare S0's register dump). No `SW_RESET_DONE`: wrong IRQ index or type, or `INTR_ENABLE` not written. `remap calculation error` (`:306`): region misaligned |
| **S3 GPIO power-on** | Loader steps 1-6 only: `SET_TX_LINK(10)`, `IOCTL_MODEM_ON`, `IOCTL_MODEM_BOOT_ON`, `IOCTL_MODEM_DL_START`; no SPI yet | dmesg `mif: ss333_on: ss333: ss333_on: +++` / `---` with `print_mc_state` lines `MC state:OFFLINE on:1 reset:1 …` (`modem_ctrl_ss333.c:40-42,167,207`); `SW_RESET_DONE ++` again (from `ld->reset`, `:197-198`); `mif: mem_start_download: lli: magic == 0x424F4F54` (`link_device_bootdump.c:218`). debugfs levels: CP_ON = 1, CP_RESET = 1, PDA_ACTIVE = 1, AP2CP_STATUS = 1, AP2CP_WAKEUP = 0. `cp_status` stays 0 (the BootROM is waiting for SPI). PHONE_ACTIVE: record it, the expected level is [unknown] | Wrong polarity (ACTIVE_LOW flags copied from stock: CP_ON reads inverted); pinctrl glitch; `-EPERM` (`allow_hw`); timing is fixed by `msleep` (100/500/100/300 ms, `:187-205`) |
| **S4 SPI BOOT → cp_status high** | Loader steps 8-9: `SET_TX_LINK(3)`; one `write(umts_boot0, BOOT, 0x29fc)`; then poll `cp_status/value` (10 × 500 ms) | `write()` returns 0x29fc. The port logs `spi_boot: 10748 bytes, NNN ms` (≈0.9 s at 100 kHz, RN `cp_boot_firmware.md` Q2). `cp_status/value` = `1` within 5 s. The CP2AP_STATUS edge counter increments | `CONFIG_SPI` / `SPI_S3C64XX` missing; the spi4 pin override not applied (mainline gpv7-1/3/4 group drives no nCS); SPI clock far from 100 kHz (`clk_summary`); BOOT read from a wrong offset (TOC 0x200, size 0x29fc, CBD_RE §3); CP not out of reset (S3 levels); the 4-byte SIPC5 header not stripped (`link_device_spi.c:92-93`) |
| **S5 LLI mount** | Loader steps 10-11: `SET_TX_LINK(10)`; poll `lli_control` (10 × 500 ms) | dmesg as in the stock remount (`DUMP/dmesg.txt:95-103`): `lli: HIBERN8_EXIT_DONE: rx=3, tx=1` → `lli: Mount intr` → `lli: rx=5, tx=5, afc=…, status=5, pa_err=0` → `lli: Mount (ok:1 fail:0 roe:0 pa_err:0)`. `lli_control` = `MIPI-LLI 1`. `DME_CSA_SYSTEM_STATUS` bit 0 (`LLI_MOUNTED`) set | No `HIBERN8_EXIT_DONE`: M-PHY reference or symbol clocks (`SRC_SEL_CPIF1[4,8]`), LLI_PHY_CON, gear or series mismatch, missing `cmn_init` 5433 values. `ERR: Mount failed` (no TX credits, `:877-883`). `PA_REASON` storm: `aclk_cpif_200` ≠ 100 MHz (`SYSTEM_CLOCK_PERIOD`) or PHY tuning. Loop of `Error sent`: the rate limit must stop it |
| **S6 std_udl stages** | Loader step 12: 0x900D/0xA00D, TOC (stage 1), MAIN + CRC 0x920C (stage 2), NV (stage 3, from a **copy** of `nv_data.bin`), FIN 0x9F00/0xAF00 | Each 4-byte answer is read from `umts_boot0` after `poll()`. The SPI 185 counter grows by ≥1 per answer (CP doorbells; ARGOS's "IPC" IRQ = hwirq 217). No `NOSPC in RAW_TXQ` storms (`link_device_bootdump.c:36-40`), or only transient ones (20 × 50 ms retry). MAIN is ~17 000 frames of 2 KiB (0x21271a0 B, CBD_RE §3) | No answer within 30 s: the CP cannot see the region (remap or address window U-3; magic not `BOOT`, so `DL_START` must come first), no doorbell RX (SIG mask / TL status / IRQ 185 type), ordering bug (try `shmem_map=device`), frame padding (must stay 4). `0xa_0F` answer = CP STAGE_FAIL (e.g. MAIN CRC) |
| **S7 INIT_START → PIF_INIT_DONE → PHONE_START → ONLINE** | The loader opens `umts_ipc0` + `umts_rfs0` (`rild_ready`), then `IOCTL_MODEM_BOOT_OFF` (≤30 s), then `IOCTL_MODEM_BOOT_DONE` | dmesg `mif: cmd_init_start_handler: lli: INIT_START <- ss333 (ss333.state:BOOTING cp_boot_done:0)` → `lli: PIF_INIT_DONE -> ss333` → `mif: cmd_phone_start_handler: lli: CP_START <- ss333 …` → `lli: INIT_END -> ss333` (`link_ctrlmsg_command.c`). `BOOT_OFF` returns 0. `IOCTL_MODEM_STATUS` = 4 (STATE_ONLINE). AP2CP_WAKEUP and AP2CP_STATUS = 1 (locked-on). The `ss333_active` IRQ is enabled | `T-I-M-E-O-U-T` from `ss333_boot_off` (`:411-416`): PHONE_START lost (the AP doorbell silently dropped while unmounted: `exynos_lli_send_signal` returns `-EIO`, `:438-443`, and the caller ignores it); SBD descriptor layout; `rild_ready` false (FMT/RFS not open), so the CP keeps resending CP_START; `STATE_CRASH_EXIT` (phone_active rising) |
| **S8 First FMT and RFS traffic** | A test client reads `umts_ipc0` and `umts_rfs0` (`poll` + `read`) | `poll()` POLLIN. Frames start with a 7-byte `sipc_fmt_hdr` (`BUP` §2.3). RFS requests (NV read) arrive on `umts_rfs0`. With `dflags=0` nothing is dumped; enable FMT hex only to the private log directory | Stale or garbled data: memory type or barriers (§2.6). Nothing at all: SBD RX ring parse, IRQ 185, or the CP still in BOOTING |
| **S9 rmnet up** | The daemon activates a PDP context (FMT `GPRS` messages, RN `linux_stack_voice.md:89`), then `ip link set rmnet0 up`, address, route | `/sys/class/net/rmnet0/statistics/rx_packets` grows; ping works; with RAWIP, an IPv6 link-local address appears once the interface is up | cid → rmnet mapping (RN Gaps); MTU; RAWIP vs the stock PPP expectations in userspace; `NETDEV_TX_BUSY` loops (SBD UL ring full) |
| **S10 Crash, off, reboot paths** | `IOCTL_MODEM_FORCE_CRASH_EXIT`, then `umts_ramdump0`, `IOCTL_MODEM_DUMP_RESET`, `IOCTL_MODEM_OFF`; `systemctl reboot` | `STATE_CRASH_EXIT` via `ss333_active` or the ack timer (10 s); `ss333_off` waits for phone_active **high** (≤3 s, C-5) then `cp_reset -> 0`. `.shutdown` runs on reboot. **No AP panic** on `CP_UPLOAD` | `panic` left in by mistake (with `oops=panic` the tablet reboots); ack timer not converted (`timer_setup`) |

Bring-up hygiene:
- Raw logs go to `$T715_PRIVATE/`.
- Before committing a log excerpt, scrub IMEI, IMSI, MSISDN, ICCID, serials and MACs
  (`docs/journal/HANDOVER.md`).

---

## 7. Risks, unknowns and the rules the mission must follow

### 7.1 Risks

| ID | Risk | Mitigation |
|---|---|---|
| R-1 | **CP writes into the wrong AP memory.** The LL/BE remap decides where CP accesses land. A wrong base, or a region that is not reserved, means silent corruption of the running kernel (and, with `oops=panic`, a reboot loop) [inferred] | Static `no-map` reservation; refuse to bind on misalignment; check the remap readback at S2 before any CP power-on; never enable the CP if the remap write failed |
| R-2 | **Cache coherency and ordering.** A cacheable alias or missing barriers give stale or garbled rings (§2.4) [inferred] | `no-map` + WC + `dma_*mb`; debug `shmem_map=device` |
| R-3 | **IRQ storms**: (a) DME `PA_ERROR`/`RESET_ON_ERROR` loops; (b) level-flipped CP2AP GPIO IRQs while the CP is off and the lines float; (c) TL signal if status is not cleared [inferred] | Rate-limit soft resets; edge-both GPIO IRQs requested only after `ss333_on`; keep the W1C clears (`exynos-mipi-lli.c:483-486,1019`) |
| R-4 | **Bus hang on unclocked registers** (LLI, M-PHY, SYSREG) [inferred, a common Exynos failure mode] | Clocks on before IRQ request and before any access; `IRQF_NO_AUTOEN`; S0 register snapshot; S2 isolates the LLI before CP power. A hang ends in the AP watchdog (`tmr_atboot=1`): accepted as an accident, not as a procedure |
| R-5 | **PM and hibern8.** Stock unmounted the link every few hundred ms when idle (`DUMP/dmesg.txt`) under the FSM. Locked-on behaviour is untested on this CP (U-6). Suspend, if ever enabled, would gate LLI (`exynos_lli_suspend`) | Phase 1 holds a wakeup source while the CP is on; port the FSM in phase 2 |
| R-6 | **Timing.** The stock `msleep` sequence (≈1 s), 30 s `BOOT_OFF`, 100 kHz SPI, 30 s udl polls, the 1 ms × `credit_cnt` = 10 mount wait (`:44,864-875`) | Keep all values verbatim; log durations |
| R-7 | **Polarity / DT-flag trap**: copying the stock 3rd GPIO cells (0x1, 0xf) inverts the lines under gpiod [proven semantics] | All `GPIO_ACTIVE_HIGH` (§3.3) |
| R-8 | **Pin glitch** at pinctrl apply (mux before DAT) [proven order] | No output `pin-function` for CP_ON/CP_RESET (§3.4) |
| R-9 | **EFS/NV integrity.** The NV stage streams `nv_data.bin`; cbd *creates* it if missing, and the RFS daemon *writes* it on CP request (CBD_RE §5, RN Q3) | Loader and RFS work on a RAM copy; never write `/efs` (rule below) |
| R-10 | **Privacy**: FMT logs carry identifiers | `dflags=0` default (§1.3) |
| R-11 | **SPI subsystem disabled** (`# CONFIG_SPI is not set`), so S4 is impossible without the config fragment [proven] | §1.1 patch 6 |
| R-12 | **Battery/thermal** with no charger driver; CP RF heat is not covered by the AP TMU zones [inferred] | Short sessions; watch `capacity` |

### 7.2 Unknowns (need hardware)

| ID | Unknown |
|---|---|
| U-1 | Stock LLI shared-memory address. 0xde000000 is inferred from the memblock top-down rule and the ION hole. The stock boot log line `memblock_reserve: [..] for mipi-lli` (`mach-universal5433.c:64-66`) is not in our dumps (they start at 686 s). |
| U-2 | Reset and sboot values of `ENABLE_IP_CPIF0/1`, `SRC_SEL_CPIF1`, and the `fout_mphy_pll` rate (S0). |
| U-3 | Which AP addresses the CP can reach through the LLI window, beyond "the region stock used". |
| U-4 | Whether the GIC lines 184/185 are level or edge (level assumed). |
| U-5 | PHONE_ACTIVE level during BOOT/MAIN, and what `ss333_off`'s "wait for high" means for the CP. |
| U-6 | CP behaviour under locked-on PM: does it ever unmount on its own? |
| U-7 | Whether the SS333 needs the S2MPS13 CP 32 kHz clock, and whether stock `CP_RESET=0` with `CP_ON=1` removes CP power. |
| U-8 | Whether the BootROM tolerates SPI clocks other than ~100 kHz, and whether DMA vs PIO timing matters. |
| U-9 | Doorbell loss: `send_signal` returns `-EIO` when unmounted and the 3.10 callers ignore it. Whether the CP retransmits (it does for CP_START, `link_ctrlmsg_command.c` comment) is unknown for others. |

### 7.3 Rules the mission must follow

From `docs/journal/HANDOVER.md`, "Rules that stay", plus the modem-specific consequences.

- **Partitions.** Write only BOOT and RECOVERY (heimdall or `device/write-part.sh`).
  **Never write BOOTLOADER, EFS, RADIO or PARAM.** For the modem:
  - RADIO (`mmcblk0p13`) is opened read-only by the loader;
  - `/efs` is mounted read-only or not at all;
  - `nv_data.bin`, its `.md5` and every RFS write go to a copy outside EFS;
  - `m9kefs*` stays untouched.
- **Update order.** Update RECOVERY's rescue only once a new BOOT has booted.
- **Citations.** Never guess a register, GPIO, regulator or ioctl: every DT value cites its
  source (as in §3). The two inferred values, the region base and the GIC trigger type, are
  marked as such in the DT comments.
- **Identifiers.** No serial number, MAC address, Wi-Fi password, or (modem addition) IMEI,
  IMSI, MSISDN or ICCID in the repo, logs or messages. Raw logs go to
  `$T715_PRIVATE/`.
- **Modules.** A driver whose probe can hang is a module: both modem modules are `=m`,
  blocklisted until S7.
- **Reboots.** Leave Linux with `systemctl reboot`, never a watchdog reset; `.shutdown` powers
  the CP down.
- **Who touches the tablet.** Only the Omarchy session deploys and tests on the tablet. This
  design is handed over; it does not flash.
- **Commits.** Kernel commits stay local (`t715-modem` side series); nothing is pushed.
- **Stage discipline.**
  - `allow_hw=0` is the default.
  - No stage powers the CP before S2 has proved the remap readback.
  - No stage writes LLI registers before S0 has captured the CMU state.

---

## Appendix A. Key source index

| Topic | Location |
|---|---|
| Stock modem DT | `K310/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:12-215`; `modem-ss333-pdata.dtsi:14-187`; `exynos5433.dtsi:2128-2172`; `DUMP/live_fdt.dts:1747-1772, 2580-2603, 5503-5558, 6331-6338` |
| LLI core | `K310/drivers/misc/mipi-lli/mipi-lli.c` (API `:62-436`, sysfs `:251-313`, add_driver `:438-485`) |
| LLI controller | `exynos-mipi-lli.c` (remap `:68-90`, init `:271-280`, setting `:282-385`, mount `:396-426`, signal `:434-500`, IRQs `:834-1022`, probe `:1071-1208`) |
| M-PHY | `exynos-mipi-lli-mphy.c:26-152` |
| SS333 control | `K310/drivers/misc/modem_v1/modem_ctrl_ss333.c:45-587` |
| Probe / DT parse | `modem_main.c:259-656` |
| LLI link + PM branches | `link_device_lli.c:41-914`; FSM `link_device_pm.c:375-1092` |
| Memory link | `link_device_memory_main.c:34-1110`; `link_device_bootdump.c:22-285`; SBD `link_device_memory_sbd.c` |
| SPI boot link | `link_device_spi.c:54-256` |
| Stock reservation | `K310/arch/arm/mach-exynos/mach-universal5433.c:58-68`; `K310/mm/memblock.c:98-125` |
| Stock config | `K310/arch/arm/configs/lineage_gts28ltexx_defconfig:405-406, 453, 538, 559, 1322-1348, 3829` |
| Stock runtime log | `DUMP/dmesg.txt:9-16, 93-104` (FSM and mount sequence) |
| Public cbd v1 | `SP/src/cpboot/boot_shannon333.c:255-380`, `shannon333.h`, `util.c:730-833` |
| Mainline clocks | `ML/drivers/clk/samsung/clk-exynos5433.c:839-915, 1257, 1439-1441`; `ML/include/dt-bindings/clock/exynos5433.h:191-199` |
| Mainline PMU | `ML/drivers/soc/samsung/exynos-pmu.c:256, 297-329, 338`; `ML/include/linux/soc/samsung/exynos-regs-pmu.h:355, 644` |
| Mainline pinctrl | `ML/drivers/pinctrl/samsung/pinctrl-exynos-arm64.c:33-41, 65-75, 103-144`; `pinctrl-samsung.c:224-236, 287-303, 693-695`; `pinctrl-exynos.c:248-251`; `ML/arch/arm64/boot/dts/exynos/exynos5433-pinctrl.dtsi:727-732` |
| Mainline SPI | `ML/drivers/spi/spi-s3c64xx.c:378-406, 829-837, 1183, 1561-1571, 1658`; `ML/arch/arm64/boot/dts/exynos/exynos5433.dtsi:1535-1553` |
| ARM32 memory types and barriers | `ML/arch/arm/include/asm/pgtable.h:115-119`; `barrier.h:63-77`; `io.h:175-176, 301`; `ML/arch/arm/mm/mmu.c:252` |
| Reserved memory and memremap | `ML/drivers/of/of_reserved_mem.c:36-60, 769`; `ML/arch/arm/kernel/setup.c:866`; `ML/kernel/iomem.c:103-113` |
| IPv6 / ARPHRD | `ML/net/ipv6/addrconf.c:3496-3518` |
| Our board | `BRD/exynos5433-gts28ltexx.dts:114, 141-223, 803-811`; `out/mainline/.config` |
