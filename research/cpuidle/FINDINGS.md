# Deep CPU idle states on the SM-T715 (Exynos 5433) under 32-bit mainline

Source study, 2026-11-03. Trees read:
`stock/` = `src/kernel_universal5433/` (Samsung 3.10.9),
`ml/` = `src/linux-camera-af/` (our 6.12, ARMv7/LPAE),
plus `docs/hardware/SMP_BRINGUP.md`. Tags: **[S]** read in source
(with `path:line` relative to the tree root), **[I]** inference. No device was touched.

## Summary

1. Stock's idle driver is `stock/arch/arm/mach-exynos/cpuidle-exynos5433.c` (built for
   this board by Makefile rule, `stock/arch/arm/mach-exynos/Makefile:28-31`): C1 WFI,
   C2/C2.1 per-core power-down, C2-1 cluster power-down, C3 system-level
   AFTR/LPA/STOP — all entered through the secure monitor with
   `SMC_CMD_SAVE`/`SMC_CMD_SHUTDOWN` (IDs −6/−7), never through bare PMU writes alone.
2. Those SMC IDs exist verbatim in our mainline tree
   (`ml/arch/arm/mach-exynos/smc.h:17-18,42-46`), but mainline's `do_idle` firmware op
   never issues them on a 5433 — it falls back to `SMC_CMD_CPU0AFTR` (−5)
   (`ml/arch/arm/mach-exynos/firmware.c:34-56`), which stock's 5433 monitor protocol
   does not use.
3. Stock runs on the MCT only (no architected timer,
   `stock/arch/arm/configs/lineage_gts28ltexx_defconfig:536`); the MCT is a peripheral
   in the always-on PERIS block, so stock's idle states never set
   `CPUIDLE_FLAG_TIMER_STOP` and never use tick broadcast for C2. Our mainline uses the
   same MCT (`ml/arch/arm64/boot/dts/exynos/exynos5433.dtsi:805-823`) with the arch
   timer node disabled (`ml/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts:238-240`).
4. No mainline 32-bit cpuidle driver can drive this SoC as-is: `cpuidle-exynos.c` is
   registered only for 4210/4212/4412/3250/5250 (`ml/arch/arm/mach-exynos/exynos.c:229-237`),
   `cpuidle-big_little.c` needs MCPM + two machine compatibles (`ml/drivers/cpuidle/cpuidle-big_little.c:160-182`),
   and `cpuidle-psci.c` needs PSCI. The 5433-specific work is a new driver carrying
   stock's SMC finishers plus the 5433 PMU register programming.
5. The cheapest real step needs no new driver: porting the vendor hot-unplug handshake
   (boot flag + `exynos5433_cpu_down` + `SMC_CMD_SHUTDOWN`) so CPU hotplug of the four
   A57s actually powers the cores off. Mainline's `exynos_cpu_die` writes only the core
   Aff0 index (wrong for A53s) and no SMC, and `exynos_cpu_can_disable` returns false
   for the 5433, so hotplug is currently refused outright
   (`ml/arch/arm/mach-exynos/platsmp.c:826-859`).

---

## 1. Stock's idle states

### 1.1 Driver and state table

Built for this board: `ifeq ($(CONFIG_SOC_EXYNOS5433),y)` adds
`cpuidle-exynos5433.o` under `CONFIG_CPU_IDLE`
(`stock/arch/arm/mach-exynos/Makefile:28-31`), and the T715 defconfig has
`CONFIG_CPU_IDLE=y`, `CONFIG_EXYNOS_CPUIDLE_C2=y`,
`CONFIG_EXYNOS_CLUSTER_POWER_DOWN=y` (`stock/arch/arm/configs/lineage_gts28ltexx_defconfig:660-666`).
That matches the "using governor ladder/menu" boot lines: both governors are on
(`:662-663`).

State table `exynos5_cpuidle_set[]` (`stock/arch/arm/mach-exynos/cpuidle-exynos5433.c:432-479`),
all states flagged only `CPUIDLE_FLAG_TIME_VALID` (no `TIMER_STOP` anywhere in the file;
the flag exists at `stock/include/linux/cpuidle.h:60` but is unused here):

| Idx | Name | desc | enter | exit_latency (µs) | target_residency (µs) | What goes down |
|---|---|---|---|---|---|---|
| 0 | C1 | "ARM clock gating(WFI)" | `exynos_enter_idle` | 1 | 500 | nothing — plain `cpu_do_idle()` (`:1107-1118`) |
| 1 | C2 | "Little power down" | `exynos_enter_c2` | 20 | 750 | one A53 core |
| 2 | C2.1 | "big power down" | `exynos_enter_c2` | 30 | 2000 | one A57 core (index 1 maps big cores back to WFI for cpu4-7, `:1039-1041`) |
| 3 | C2-1 | "Cluster power down" | `exynos_enter_c2` | 300 | 3000 (`CLUSTER_OFF_TARGET_RESIDENCY`, `:121`) | whole cluster incl. L2/CCI (`L2_CCI_OFF`) |
| 4 | C3 | "System power down" | `exynos_enter_lowpower` | 300 | 5000 | AFTR or LPA/STOP — only when all other CPUs are offline (`:916-917`) |

### 1.2 How C2 (per-core and cluster) is entered — `exynos_enter_c2` (`:1031-1104`)

1. Writes the resume address `s3c_cpu_resume` and magic `0xFCBA0D10` to sysram-ns
   `+0x24`/`+0x20` (`REG_DIRECTGO_ADDR/FLAG`, `:52-55`, writes at `:1058-1059`). **[S]**
2. `set_boot_flag(cpuid, C2_STATE)` — sysram-ns `+0x28` word for this core gets bit 3
   (`stock/arch/arm/mach-exynos/pmu-exynos5433.c:50-69`, bit value
   `stock/arch/arm/mach-exynos/include/mach/pmu.h:74`). **[S]**
3. `cpu_pm_enter()`, then for the cluster state (index 3)
   `exynos_cluster_power_down(true, ...)` (`:1067-1070`), which under `c2_state_lock`
   marks this CPU in `cpu_c2_state` and, if every core of the *big* cluster
   (`cpuid & 0x4`) is in C2 with next timer events ≥ 3 ms away (`check_matched_state`,
   `:972-993`), sets `L2_CCI_OFF` (`:995-1006`); if additionally *all* CPUs system-wide
   are in C2, `exynos_check_lpc()` passes and the display is in `POWER_HIBER_DOWN`
   (`ref_power_status`), it also sets `CMU_OFF` ("lpc" early-wakeup tag) (`:1007-1016`). **[S]**
4. `exynos5433_cpu_down(cpuid)` — clears `EXYNOS_CORE_PWR_EN` (0xf, local power) in the
   core's `ARM_CORE_CONFIGURATION` register, indexed `core + 4*cluster`
   (`stock/arch/arm/mach-exynos/pmu-exynos5433.c:130-144`; the register macro block
   `stock/arch/arm/mach-exynos/include/mach/regs-pmu.h:306-339`, stride 0x80). **[S]**
5. `cpu_suspend(flags, c2_finisher)` — the finisher (`:530-560`) issues
   `exynos_smc(SMC_CMD_SAVE, OP_TYPE_CORE, SMC_POWERSTATE_IDLE, 0)`, and if
   `L2_CCI_OFF` first sets `exynos_cpu_sequencer_ctrl(true)`
   (EAGLE_CPUSEQ_OPTION 0x2488 bit 0, `stock/arch/arm/mach-exynos/pmu-exynos5433.c:282-292`),
   then `exynos_smc(SMC_CMD_SHUTDOWN, kind, SMC_POWERSTATE_IDLE, param)` with
   `kind = OP_TYPE_CLUSTER` and `param = 1` for `CMU_OFF`. **[S]** The monitor powers
   the core (or cluster) down at the WFI inside the SMC; on the way back the driver
   does `local_flush_tlb_all()` because "Secure monitor disables the SMP bit and takes
   the CPU out of the coherency domain" (`:553-557`). **[S]**
6. Wake-up: an interrupt; cluster exit re-disables the CPU sequencer (`:1084-1091`),
   `exynos5433_cpu_up` restores `EXYNOS_CORE_PWR_EN` only on early wakeup (`ret != 0`)
   (`:1074-1076`) — on a normal wake the core is already powered and resumes at the
   `cpu_suspend` resume vector, not at the boot ROM.

Conditions that demote C2 to C1 (`exynos_enter_c2` head, `:1039-1051`): the
`enable_mask` bit for C2 cleared (`CONFIG_SEC_PM` module param `enable_mask`,
`:65-111`), and on BCM4358 Wi-Fi an active scan (`wl_check_wifi_scanning`). **[S]**

### 1.3 C3 / AFTR — system-level states, last man only

`exynos_enter_lowpower` (`:908-950`) only continues past WFI when `num_online_cpus() == 1`
(`:916-917`). `exynos_check_enter_mode()` (`:352-430`) then picks a target:
`EXYNOS_CHECK_C2` (0xABAC0000), `EXYNOS_CHECK_DIDLE` (0xBAD00000 → AFTR),
`EXYNOS_CHECK_LPA` (0xABAD0000), `EXYNOS_CHECK_DSTOP` (0xABAE0000) —
constants at `:55-58` and `stock/arch/arm/mach-exynos/include/mach/regs-pmu.h:124-126`. **[S]**

**AFTR** (`exynos_enter_core0_aftr`, `:583-636`): sets `EXYNOS5433_WAKEUP_MASK`/
`MASK1`/`MASK2` = 0x40001000/0xFFFF0000/0xFFFF0000 — the comment at `:488` says
"Ext-GIC nIRQ/nFIQ is the only wakeup source in AFTR" — then
`exynos_sys_powerdown_conf(SYS_AFTR)` writes the whole 5433 PMU "SYS_PWR_REG" table
for AFTR (see §1.5), `exynos_central_sequencer_ctrl(true)` clears the CENTRAL_SEQ
power-down bits, DIRECTGO registers, `cpu_pm_enter()`, and
`cpu_suspend(0, idle_finisher)` where the finisher is
`SMC_CMD_SAVE(OP_TYPE_CORE)` + `SMC_CMD_SHUTDOWN(OP_TYPE_CLUSTER)` (`:519-525`). **[S]**

**LPA / STOP** (`exynos_enter_core0_lpa`, `:736-906`): same skeleton plus
`exynos_lpa_enter()` (an LPA notifier chain over pinctrl/I2C/thermal/MMC listeners,
`stock/arch/arm/mach-exynos/exynos-pm.c:59-91`), a UART TX FIFO drain loop (`:774-776`),
a large clock-register save/restore (`exynos5_lpa_clk_save`, `:638-724`), forcing
MPHY_PLL on and gating FSYS/BUS2 clocks (`:804-825`), and on exit re-releasing pad
retention for 16 pad groups (`:834-849`) and `mipi_lli_intr_enable()` because
"LLI_INTR_ENABLE is not retention register" (`:881-885`). **[S]**

What distinguishes the modes is the PMU table column (`SYS_AFTR`, `SYS_STOP`,
`SYS_DSTOP`, `SYS_DSTOP_PSR`, `SYS_LPD`, `SYS_LPA`, `SYS_ALPA`, `SYS_SLEEP` —
enum `stock/arch/arm/mach-exynos/include/mach/pmu.h:29-40`): **[I]** from
`exynos5433_pmu_config[]` (`stock/arch/arm/mach-exynos/pmu_cal_sys_exynos5433.c:45-118`,
column order in the comment at `:46`): AFTR and STOP gate the top-level and MIF logic
(top-level `TOP_PWR_SYS_PWR_REG` 0x3 at `:74`, OSCCLK_GATE at `:79`, pad retention and
isolation `:85-101`) — STOP additionally powers down both CPU clusters' NONCPU and L2 domains
(`ATLAS/KFC_NONCPU_SYS_PWR_REG` = 0xF at `:54-55`,
`ATLAS/APOLLO_L2_SYS_PWR_REG` = 0x7 at `:59-60`)
while AFTR leaves them at 0 (retained); DSTOP/LPA/ALPA keep MIF in reset-run
(`CLKRUN_CMU_MIF` = 1) with the memory interface alive; and the shared "check" tables
gate entry on power domains and clocks: `exynos5_power_domain[]` (GSCL/CAM0/CAM1/MFC/
HEVC/G3D/DISP must read 0, `:153-161`), `exynos5_dstop_power_domain[]` (AUD blocks
LPA/STOP, `:163-165`), `exynos5_none_domain[]` (ISP on → only C2, `:167-169`), and
`exynos5_clock_gating[]` (PERIC0/PERIC2 gate bits, `:183-186`). **[S]**

### 1.4 What blocks each state (stock's own conditions)

`exynos_check_lpc()` (`:288-349`) and `exynos_check_enter_mode()` (`:352-430`), both **[S]**:

- a JIG UART cable attached (`is_jig_attached`, `:275-286`) — fed by the MUIC notifier, below;
- MIF devfreq level at its floor (`MIF_LIMIT`, `:127,293-296`) — i.e. the bus is already idle;
- any of the power domains above still powered, or the PERIC clock gates open;
- an in-flight `dw_mmc` request (`dw_mci_exynos_request_status`);
- **the modem's MIPI-LLI link up** (`mipi_lli_get_link_status()` nonzero, `:308-311`
  and `:379-382`);
- USB PHY active (`samsung_usbphy_check_op`);
- Wi-Fi (PCIe) active (`check_wifi_op`), and Wi-Fi scanning blocks even C2 (`:1048-1051`);
- BT active (`check_bt_op`);
- GPS (non-BCM4773) in use (`check_gps_op`);
- DECON-TV overlay active (`check_decon_tv_op`);
- PWM in use (`pwm_check_enable_cnt`);
- audio above the "LPC" power state (`exynos_check_aud_pwr() > AUD_PWR_LPC` — the
  function grades LPASS DRAM use, `stock/sound/soc/samsung/lpass.c:204-222`);
- for `CMU_OFF` (the C2 "lpc" extension): all eight CPUs in C2 with ≥3 ms residency
  *and* the display in `POWER_HIBER_DOWN` (`:1007-1016`, `ref_power_status` from
  `stock/drivers/video/exynos/decon_display/decon_display_driver.c:41-42`).

A per-CPU timer deadline nearer than the cluster target residency also vetoes the
cluster state (`check_matched_state`, `:989-991`). Suspend and reboot force polling
idle (`cpu_idle_poll_ctrl(true)`, `:1120-1163`). And the cpufreq driver disables cluster
power-down around big-cluster frequency changes (`disable_c3_idle`,
`stock/drivers/cpufreq/exynos-mp-cpufreq.c:845-854`). **[S]**

### 1.5 The MUIC notifier

`exynos_cpuidle_muic_notifier` (`:1234-1258`) watches only the four
`ATTACHED_DEV_JIG_UART_OFF*` device types; on ATTACH it sets `muic_is_attached = true`,
on DETACH false. That flag is read by `is_jig_attached()` and, through
`exynos_check_lpc()`, keeps the *system* states (AFTR/LPA/STOP) off while a service JIG
(UART) cable is plugged — the log line `exynos_cpuidle_muic_notifier - action=1,
attached_dev=1` (`:1255`) is exactly the ATTACH (action 1) of `ATTACHED_DEV_USB_MUIC`
(value 1, `stock/include/linux/muic/muic.h:110-111`) hitting the default case, i.e. it
only reports. Registered as `MUIC_NOTIFY_DEV_CPUIDLE` (`:1260-1265`). **[S]** A plain
USB cable therefore disables nothing by itself in this driver **[I]** — the USB *PHY*
blocker above comes from the USB stack, not the MUIC. (USB attach also pulls the device
out of the deep suspend-to-RAM path elsewhere, which is out of scope here.)

### 1.6 Idle clock-down option (off on this board)

`CONFIG_EXYNOS_IDLE_CLOCK_DOWN` would toggle the cluster L2QACTIVE handshake bit
(`EXYNOS5430_USE_L2QACTIVE`, KFC/EGL `PWR_CTRL` at CMU 0x11901020/0x11801020) around
AFTR/LPA (`exynos_idle_clock_down`, `:563-581`; register defines
`stock/arch/arm/mach-exynos/include/mach/regs-clock-exynos5433.h:635-638`), but the
T715 defconfig has it off (`stock/arch/arm/configs/lineage_gts28ltexx_defconfig:668`). **[S]**

---

## 2. The secure monitor calls

SMC trampoline is `dsb; smc #0` in both trees
(`stock/arch/arm/mach-exynos/exynos-smc.S:19-24`, `ml/arch/arm/mach-exynos/exynos-smc.S:15-20`). **[S]**

### 2.1 Around idle / CPU power-down (stock, 5433)

IDs from `stock/arch/arm/mach-exynos/include/mach/smc.h:14-21` (and the ARM32-signed
arguments at `:67-73`); call sites in `cpuidle-exynos5433.c` **[S]**:

| Call | Where | Meaning (inferred from args) |
|---|---|---|
| `exynos_smc(SMC_CMD_SAVE, OP_TYPE_CORE, SMC_POWERSTATE_IDLE, 0)` (−6, 0, 1) | `:521`, `:536` | checkpoint the *core*'s secure state before idle power-down |
| `exynos_smc(SMC_CMD_SHUTDOWN, OP_TYPE_CORE, SMC_POWERSTATE_IDLE, 0)` (−7, 0, 1) | `c2_finisher` `:551` | power this core off at WFI (per-core C2) |
| `exynos_smc(SMC_CMD_SHUTDOWN, OP_TYPE_CLUSTER, SMC_POWERSTATE_IDLE, 0/1)` (−7, 1, 1, param) | `c2_finisher` `:551`, `idle_finisher` `:522` | power the cluster down (param 1 = with CMU off / LPC); `idle_finisher` always uses CLUSTER for AFTR/LPA/STOP |
| `exynos_smc(SMC_CMD_SHUTDOWN, OP_TYPE_CLUSTER & type, SMC_POWERSTATE_IDLE, 0)` | hotplug `stock/arch/arm/mach-exynos/hotplug.c:114-119` | hot-unplug: `type` is 1 (cluster) only when this was the cluster's last online core, else 0 (core) — see §5 |
| `exynos_smc(SMC_CMD_SLEEP, 0, 0, 0)` (−3) | suspend, via `do_idle` op, `stock/arch/arm/mach-exynos/firmware.c:24-29`, `pm-exynos5433.c:172-173` | whole-system sleep (suspend-to-RAM) |

Boot-time support: `SMC_CMD_CPU1BOOT` (−4) exists in the firmware ops but the stock
5433 secondary-release loop deliberately skips `cpu_boot` and uses `dsb_sev()` only
(`stock/arch/arm/mach-exynos/platsmp.c:218-226`), as our port also does
(`ml/arch/arm/mach-exynos/platsmp.c:670-681`). **[S]** `SMC_CMD_REG` (−101) with the
`SMC_REG_ID_SFR_W` encoding is used by mainline for secure sysram writes on 5420-class
SoCs (`ml/arch/arm/mach-exynos/suspend.c:348-350,490-492`); stock has the same IDs
(`smc.h:38-64`) plus Samsung-private ones (FMP, DTRNG, secmem) that idle never needs. **[S]**

### 2.2 Mainline's coverage

`ml/arch/arm/mach-exynos/smc.h:14-18` defines `SMC_CMD_SLEEP/CPU1BOOT/CPU0AFTR/SAVE/SHUTDOWN`
and `:42-46` the `OP_TYPE_*`/`SMC_POWERSTATE_IDLE` constants — identical IDs. **[S]**
`exynos_do_idle` (`ml/arch/arm/mach-exynos/firmware.c:34-56`) issues the
SAVE+SHUTDOWN(CLUSTER) pair **only for `soc_is_exynos3250()`**; every other SoC gets
`SMC_CMD_CPU0AFTR` — a protocol stock's 5433 monitor never exercises for idle (grep of
`cpuidle-exynos5433.c` shows only SAVE/SHUTDOWN; `CPU0AFTR` appears in no 5433 idle
path **[S]**). `firmware_ops` registered: `do_idle`, `set_cpu_boot_addr`,
`get_cpu_boot_addr`, `cpu_boot`, `suspend`, `resume` (`:150-157`). `cpu_boot` is a no-op
returning 0 on non-Exynos4 SoCs ("On Exynos5 devices the call is ignored by trustzone
firmware", `:58-68`). **[S]** So the SMC *vocabulary* is present in mainline; the 5433
*idle phrasing* (SAVE/SHUTDOWN with CORE/CLUSTER/param) is not wired to anything.

---

## 3. Timers

Stock has **no ARM architected timer**: `# CONFIG_HAVE_ARM_ARCH_TIMER is not set`
(`stock/arch/arm/configs/lineage_gts28ltexx_defconfig:536`), the dtsi has no
`armv7-timer` node (only `mct@101C0000`, `stock/arch/arm/boot/dts/exynos5433.dtsi:226`),
and the MCT is initialised from `exynos_init_time` (`stock/arch/arm/mach-exynos/common.c:1192-1193`). **[S]**

Each CPU gets a *local* MCT comparator (`EXYNOS4_MCT_L_BASE(cpu)`, per-CPU bank at
0x300 + 0x100*cpu, `stock/drivers/clocksource/exynos_mct.c:44-45,431`), an SPI routed
per-CPU, registered as per-cpu clockevent without `CLOCK_EVT_FEAT_C3STOP`
(`:438-447`). **[S]** Consequences, all **[I]** from those facts:

- Stock's C2/cluster-off idle relies on the **MCT local timer surviving core and
  cluster power-down** — it lives in the PERIS block (mainline gates it as
  `CLK_PCLK_MCT` in cmu_peris, `ml/arch/arm64/boot/dts/exynos/exynos5433.dtsi:822`),
  outside the CPU clusters, and no state sets `CPUIDLE_FLAG_TIMER_STOP` nor arranges
  tick broadcast. **[I]** Whether the local comparator *and its SPI* truly keep firing
  with a whole cluster off is exactly what stock's design assumes and what stock's
  `RESET_CPUCLKSTOP_SYS_PWR_REG` column (set in every idle mode except SLEEP,
  `pmu_cal_sys_exynos5433.c:64`) appears to guarantee (CPU-clock stop without MCT
  reset). **[I]**
- The arch timer is irrelevant to stock; there is no `arm,no-tick-in-suspend` handling
  anywhere in the stock cpuidle path (grep found none). **[S]** (absence)
- `arm,armv8-timer` exists only in the *arm64* dtsi
  (`ml/arch/arm64/boot/dts/exynos/exynos5433.dtsi:1988-1998`), which our arm32 board
  disables (`&timer { status = "disabled"; }`,
  `ml/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts:238-240`) — the 32-bit EL1
  virtual timer is unreliable under this bootloader. **[S]**

Mainline today: the MCT node is `samsung,exynos5433-mct` + `exynos4210-mct`
(`ml/arch/arm64/boot/dts/exynos/exynos5433.dtsi:805-807`), the driver matches
`exynos4210-mct` and runs in SPI mode (`ml/drivers/clocksource/exynos_mct.c:700`),
its per-CPU events carry `CLOCK_EVT_FEAT_PERCPU` and *no* C3STOP (`:471-473`), and
per-CPU banks are mapped through the `samsung,local-timers` DT array (`:642-683`,
binding `ml/Documentation/devicetree/bindings/timer/samsung,exynos4210-mct.yaml:56-60`). **[S]**

What a mainline deep-idle port needs, **[I]**: since the MCT is a core-independent
peripheral, states that stop only the core can keep `local-timer-stop` *absent* from
the DT idle-state node (no broadcast needed) — same as stock. If any state is found to
lose the local comparator (e.g. cluster off kills the L-timer bank), the state must set
`local-timer-stop`, the driver `CPUIDLE_FLAG_TIMER_STOP`
(`ml/drivers/cpuidle/dt_idle_states.c:80-82`), and `CONFIG_GENERIC_CLOCKEVENTS_BROADCAST`
with a broadcast device (the MCT *global* comparator, already registered as
`mct_comp_device` pinned to cpu0, `ml/drivers/clocksource/exynos_mct.c:347-352`) must
be enabled. Which case holds cannot be settled from source alone — see "Not established".

---

## 4. Mainline's options for a 32-bit Exynos 5433

Read: `ml/drivers/cpuidle/{cpuidle-exynos.c,cpuidle-big_little.c,cpuidle-psci.c,dt_idle_states.c}`,
`ml/arch/arm/mach-exynos/{pm.c,suspend.c,mcpm-exynos.c,firmware.c,platsmp.c,exynos.c}`.

### 4.1 Candidates, as shipped

- **`cpuidle-arm.c` (generic ARM)** — parses `arm,idle-state` nodes and calls
  `arm_cpuidle_suspend`, which dispatches on the CPU's `enable-method` into
  `CPUIDLE_METHOD_OF_DECLARE` ops (`ml/drivers/cpuidle/cpuidle-arm.c:65-69,105-107`;
  `ml/arch/arm/kernel/cpuidle.c:46-57`). Only TI registers a method
  (`ml/arch/arm/mach-omap2/pm33xx-core.c:441-442`); with `enable-method` deleted from
  our DT there is nothing to call. **[S]** Not usable without adding a new method ops —
  which is actually a legitimate extension point (see ranking).
- **`cpuidle-psci.c`** — pure PSCI (`arm,psci-suspend-param` per state,
  `ml/drivers/cpuidle/cpuidle-psci.c:208-219`); requires `ARM_PSCI_FW`. The bootloader
  gives a 32-bit kernel no PSCI and our DT deletes the node
  (`ml/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts:261`). **[S]** Dead end.
- **`cpuidle-big_little.c`** — DT states + MCPM (`mcpm_cpu_suspend`,
  `ml/drivers/cpuidle/cpuidle-big_little.c:125-136`), but gated to exactly two machine
  compatibles (`:160-163`), needs `mcpm_is_available()` (`:184`), and identifies
  clusters by CPU *part number* `CORTEX_A7`/`CORTEX_A15` (`:189-193`) — we have
  A53/A57. **[S]** The MCPM backend `mcpm-exynos.c` likewise matches only
  `samsung,exynos5420/5800` (`ml/arch/arm/mach-exynos/mcpm-exynos.c:211-215`) and its
  power-up path is 5420-specific (KFC reset through `EXYNOS_SWRESET`, `:96-119`). **[S]**
  `SOC_EXYNOS5433` does not `select EXYNOS_MCPM` (only 5420 does,
  `ml/arch/arm/mach-exynos/Kconfig:110`). **[S]** Far road.
- **`cpuidle-exynos.c` (ARM_EXYNOS_CPUIDLE)** — platform device `exynos_cpuidle`
  registered only for 4210/4212/4412-midas/3250/5250 (`ml/arch/arm/mach-exynos/exynos.c:229-237`);
  its non-coupled driver enters `exynos_enter_aftr` from `pm.c`, which programmes the
  *legacy* PMU table `exynos_sys_powerdown_conf(SYS_AFTR)` —
  `ml/arch/arm/mach-exynos/pm.c:138-142` — implemented in
  `ml/drivers/soc/samsung/exynos-pmu.c:172-195` from per-SoC `pmu_config` tables…
  and the 5433 entry in the match table carries **no data at all**
  (`ml/drivers/soc/samsung/exynos-pmu.c:255-256`), so `powerdown_conf` and `pmu_config`
  are both NULL and the call is a silent no-op on this SoC. **[S]** The coupled variant
  is 2-CPU Exynos3250-specific (`ml/arch/arm/mach-exynos/pm.c:186-338`). **[S]** Wrong
  shape for 8 CPUs, but the closest skeleton.

### 4.2 What is actually missing for a 5433 driver, ranked least → most work

All items **[I]** from the gaps above plus §1-3 evidence:

1. **New tiny driver + firmware-op wiring (C2 per-core only).** Register a 2-state
   driver (WFI + core power-down) per CPU; on entry: DIRECTGO registers, `C2_STATE`
   boot flag (`ml/arch/arm/mach-exynos/firmware.c:238-261` already has
   `exynos_set/clear_boot_flag` on the right sysram window +0x28, but indexed
   `4 * logical_cpu` whereas stock indexes `4 * (core + 4*cluster)` — same fix needed),
   PMU core down with the `core + 4*cluster` index
   (`ml/arch/arm/mach-exynos/platsmp.c:88-92` has `exynos5433_pmu_core`), then
   `cpu_suspend` →
   `SMC_CMD_SAVE(CORE)` + `SMC_CMD_SHUTDOWN(CORE)`. Missing pieces: nothing structural
   — only the driver file, a `CPUIDLE_METHOD_OF_DECLARE` or platform registration, DT
   `arm,idle-state` nodes (none exist today in the 5433 dtsi — grep over
   `ml/arch/arm64/boot/dts/exynos/` finds `idle-states` only in gs101), and
   `CONFIG_CPU_IDLE`/`GENERIC_CLOCKEVENTS_BROADCAST` in the defconfig (currently
   absent, `ml/arch/arm/configs/gts28ltexx_defconfig:285-295` has no CPU_IDLE). **Risk:
   medium** — the SMC protocol is exactly stock's, but a wrong monitor handshake can
   hang a core unrecoverably (no JTAG), and resume-address/flag placement must match
   the monitor's expectations byte for byte. Test with one A53 first, `maxcpus=1`.
2. **C2 + cluster power-down (C2-1).** Everything above plus stock's
   `cpu_c2_state`/`check_matched_state` coordination, `exynos_cpu_sequencer_ctrl`
   (EAGLE_CPUSEQ_OPTION 0x2488 bit 0 — offset known from stock
   `regs-pmu-exynos5433.h:138`, *not* in `ml/include/linux/soc/samsung/exynos-regs-pmu.h`),
   `SHUTDOWN(CLUSTER)`, and the L2/CCI implications (monitor-side per the stock
   comment at `stock/.../cpuidle-exynos5433.c:553-556`). **Risk: high** — takes a whole
   cluster including its L2 out; any coherency mistake corrupts memory, and the four
   cores must rendezvous like stock's spinlock/mask scheme does.
3. **AFTR/LPA/STOP (C3).** Needs the full 5433 `SYS_PWR_REG` table ported (stock's
   `pmu_cal_sys_exynos5433.c` has no mainline counterpart; the mainline PMU header's
   WAKEUP_MASK offsets are 5250-era — 0x0604/0x0608/0x0614 — while 5433 uses
   0x060C/0x0610/0x0614/0x0618, `stock/.../regs-pmu-exynos5433.h:23-31`), all the
   blocker hooks (USB, MMC, LLI, display), the clock save/restore, and the LPA
   notifier chain. **Risk: very high** — system-level states gate on a dozen
   conditions; missing one means memory corruption or a device that never wakes.
   Least value per watt vs. (1)+(2) plus hotplug.

---

## 5. Cheaper intermediate steps

### 5.1 Hotplug as cluster power-down (stock)

Stock's `cpu_die` → `exynos_cpu_die` (`stock/arch/arm/mach-exynos/hotplug.c:160-190`) →
`platform_do_lowpower` → **`exynos_power_down_cpu` (`:99-120`)** which: sets the
`HOTPLUG` boot flag (bit 2), calls `exynos_cpu.power_down(cpu)` =
`exynos5433_cpu_down` (clears `EXYNOS_CORE_PWR_EN`, PMU write), and — under
`CONFIG_ARM_TRUSTZONE` (on, defconfig `:452`) — issues
`exynos_smc(SMC_CMD_SHUTDOWN, OP_TYPE_CLUSTER & type, SMC_POWERSTATE_IDLE, 0)`, where
`type` = 1 iff no other core of this core's cluster is still online
(`:102-104`). **[S]** So yes: stock's hot-unplug genuinely powers the core off through
the PMU register *and* tells the monitor (SMC) it may take the cluster down when it is
the last one; WFI inside the loop (`:122-153`) is the sleep instruction when TrustZone
is compiled out, not the fallback here. The `HOTPLUG` flag is what the monitor-side
stub/`exynos_secondary_init` reads on the way back (`clear_boot_flag(cpu, HOTPLUG)`,
`stock/arch/arm/mach-exynos/platsmp.c:93`). **[S]**

Stock then *uses* this at runtime: `CONFIG_EXYNOS5_DYNAMIC_CPU_HOTPLUG=y`
(`stock/arch/arm/configs/lineage_gts28ltexx_defconfig:382,429`) with
`drivers/cpufreq/dm_cpu_hotplug.c` — `CMD_BIG_OUT` does `cpu_down()` for
i = 7..NR_CA7(4) (`:578-583`, `NR_CA7 = 4`,
`stock/arch/arm/mach-exynos/include/mach/cpufreq.h:170`), and the display driver asks
for it through `force_dynamic_hotplug` on hibernation entry
(`stock/drivers/video/exynos/decon_display/decon_pm_core.c:468-479`,
`dm_cpu_hotplug.c:744-766`). **[S]** Suspend also drains CPUs to
`nr_sleep_prepare_cpus` = 1 (`CMD_SLEEP_PREPARE`, `:563-573`). **[S]**

### 5.2 Hotplug in our mainline tree

Implemented but deliberately switched off for the 5433:

- `smp_operations.cpu_die = exynos_cpu_die` (`ml/arch/arm/mach-exynos/platsmp.c:862-870`)
  does `v7_exit_coherency_flush(louis)` then `platform_do_lowpower`, which calls
  `exynos_cpu_power_down(core_id)` + `wfi()` (`:111-139`) — a plain PMU write indexed by
  **Aff0 only** (`:113-114`), i.e. wrong core for the A53s (their PMU index is
  `core + 4*cluster`), no `HOTPLUG` boot flag, and **no SMC_CMD_SHUTDOWN**. **[S]**
- `exynos_cpu_can_disable` returns `false` for `samsung,exynos5433` with the comment
  that the vendor handshake (boot flag, SMC_CMD_SHUTDOWN: stock hotplug.c:99-119) is
  "not ported, so no CPU may be taken offline" (`:846-859`). **[S]**
- CPU0 is excludable only on non-5433 (`:857-858`); `CONFIG_HOTPLUG_CPU` is not in our
  defconfig at all (grep over `ml/arch/arm/configs/gts28ltexx_defconfig`). **[S]**

So the cheapest screen-off win on mainline is exactly what the code comment promises:
port stock's `exynos_power_down_cpu` into `exynos_cpu_die` (fix the PMU index with
`exynos5433_pmu_core()`, add the `HOTPLUG` flag set/clear, add the SMC), enable
`CONFIG_HOTPLUG_CPU`, allow `cpu_can_disable` (including cpu4-7), then drive
`cpu_down(4..7)` from userspace (or a small screen-off hook) — no cpuidle driver
needed. **[I]** Stock's own `CMD_BIG_OUT` shows the A57 cluster can be parked this way
while the display is off, and `exynos5433_boot_secondary` already knows how to bring a
core back from power-off (the whole §2.3 bring-up path of
`docs/hardware/SMP_BRINGUP.md`). Risk: **medium-low** — the
replug path is proven on this hardware by our SMP bring-up; the new part is only the
down-handshake. One caveat from stock: replug re-runs the holding-pen release, and the
pen is shared by Aff0 twins across clusters — `exynos5433_check_pen_twin` already
guards that (`ml/arch/arm/mach-exynos/platsmp.c:555-570`). **[S/I]**

---

## 6. Interactions to fear

All **[S]** in stock unless tagged:

- **Modem MIPI-LLI link.** `mipi_lli_get_link_status()` gates AFTR (`:379-382`) *and*
  the LPC variant of C2 (`:308-311`); the link driver re-enables
  `LLI_INTR_ENABLE` after every LPA exit because that register loses its value
  (`:881-885`). The wake path is the `CP2AP_WAKEUP` GPIO (gpa3-1 on this board,
  `stock/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:35,89`) whose handler toggles
  the CP wake handshake and holds a wake lock
  (`stock/drivers/misc/modem_v1/link_device_lli.c:425-462`). Any mainline state that
  powers down the AP side of the LLI must leave that GPIO able to interrupt (it is a
  GPA "always-alive" bank pin, and stock keeps EINT wake masks configured in
  `exynos5433_pmu_init`, `stock/arch/arm/mach-exynos/pmu-exynos5433.c:489`). **[I]**
  for the GPIO-bank remark.
- **GIC wake path.** Stock's own AFTR comment: "Ext-GIC nIRQ/nFIQ is the only wakeup
  source in AFTR" (`:488-510`) — the wakeup mask value 0x40001000 leaves exactly the
  GIC lines unmasked. Mainline's GIC driver has no `irq_set_wake` and no suspend
  integration (grep of `ml/drivers/irqchip/irq-gic.c` finds only `gic_dist_save` for
  Suspend-to-RAM, `:550,721`); a 5433 idle port must programme
  `EXYNOS5433_WAKEUP_MASK{,1,2}` (0x0610/0x0614/0x0618) exactly as stock or wakeups
  are silently masked. **[I]**
- **Display (DECON).** Cluster+CMU-off ("lpc" C2) requires `POWER_HIBER_DOWN`
  (`:1007-1010`); the DISP power domain must be off for AFTR/LPA (`exynos5_power_domain`
  includes `EXYNOS5433_DISP_STATUS`, `:160`). Our DECON is a mainline
  `samsung,exynos5433-decon` driver with `pd_disp` genpd (`ml/arch/arm64/boot/dts/exynos/exynos5433.dtsi:480,700-705`)
  — the "hibernation" state stock checks has no direct mainline equivalent; we'd have
  to derive "display off" from the DECON runtime-PM state instead. **[I]**
- **DMA masters.** `dw_mci_exynos_request_status()` gates AFTR/LPA (`:303-306,374-377`)
  — an in-flight eMMC DMA while the MIF/FSYS clocks are gated is the failure stock
  defends against; likewise the FIMG2D/G2D/CAM domains in `exynos5_lpc_power_domain`
  (`:171-176`) and the audio (ADMA/fDMA/Seiren DRAM use) grading in
  `exynos_check_aud_pwr` (`stock/sound/soc/samsung/lpass.c:204-222`). For C2-only
  states these matter less (they gate system-level states), but cluster-off with an
  active PL330 (`CONFIG_PL330_DMA=m` on our board,
  `ml/arch/arm/configs/gts28ltexx_defconfig:316`) writing to now-noncoherent memory
  would be a corruption bug. **[I]**
- **Explicit stock disables.** Wi-Fi scanning blocks even C2 (`:1048-1051`, BCM4358);
  cpufreq big-cluster transitions temporarily disable cluster power-down
  (`stock/drivers/cpufreq/exynos-mp-cpufreq.c:845-854`); suspend/reboot force poll
  idle (`:1120-1163`); the `enable_mask` module param can turn each state class off at
  runtime (`:65-111`). Port the *shape* of at least the cpufreq exclusion: if our
  A57 cluster is off, a cpufreq transition targeting it must not be able to run. **[I]**
- **Pad retention.** LPA/STOP reset pad retention; stock re-releases 16 pad groups on
  exit (`:834-849`). Not relevant to C2, but it disqualifies any naive "LPA without
  the notifier chain" shortcut. **[S]**

---

## What to do with it (supervisor, 2026-11-03)

Twelve of the references above were opened and checked: the state table,
the hot-unplug SMC, `exynos_cpu_can_disable`, `exynos_do_idle`, the stock
defconfig lines (no arch timer; `CPU_IDLE`, C2, cluster power-down and
dynamic hotplug on), the 5433 PMU match entry with no data, `CMD_BIG_OUT`
and the Wi-Fi scan veto. All say what the study says.

The order, by risk against what it can save:

1. **The A57 cluster offline while the screen is off.** Stock's own
   behaviour: `CMD_BIG_OUT` takes cpu4-7 down on display hibernation
   (section 5.1). Mainline needs the down handshake only: `HOTPLUG` boot
   flag, the PMU core with the `core + 4*cluster` index, and
   `SMC_CMD_SHUTDOWN` (cluster when it is the cluster's last core). Then
   `CONFIG_HOTPLUG_CPU`, `exynos_cpu_can_disable` true for cpu4-7, and a
   screen-off hook. Bring-up already works from power-off, so the new code is
   short. The risk is a monitor that does not take the call: a core, or the
   board, that never comes back. Test it like CPU frequency stage 1: a test
   kernel in RECOVERY, CP off, image mode, `returnafter`, then hundreds of
   offline and online cycles, idle and under load, with hash checks.
   What it saves is not established; four A57 cores at 1 062 500 uV in WFI are
   leakage that D7 only lowers, and this removes [I].
2. **Per-core power-down (C2)**, a new cpuidle driver with stock's
   SAVE/SHUTDOWN(CORE) finisher. Medium risk, and every idle core gains,
   including the A53s while the screen is on.
3. **Cluster power-down in idle (C2-1)**: high risk (L2 and CCI, a four-core
   rendezvous). Only if 1 and 2 leave a gap worth it.
4. **AFTR/LPA/STOP**: not worth it here. A dozen vetoes, the modem link among
   them, which keeps the tablet out of them most of the time anyway.

D7 stays useful whatever comes of this: it is what gives the A57s a level to
throttle to under load (the soak of 2026-11-03 took atlas1 to 99 C with all
eight cores busy, and only the 115 C trip stands behind it today).

## Not established

What these sources cannot answer; each needs the device:

- Whether the shipped monitor actually implements SAVE/SHUTDOWN exactly as the 3.10
  driver calls them (the -6/-7 IDs are *named* in stock headers, but the monitor's
  behaviour on unknown or mis-ordered calls, and whether `param=1` (CMU off) is
  accepted, is only observable by trying — stock is the only witness).
- Whether the MCT local comparator and its SPI keep working with a full cluster
  powered down (§3). Stock's design says yes, but stock never documents the test.
- Whether the 5433 WAKEUP_MASK bit layout matches stock's constants on this board's
  monitor/fuse revision (0x40001000's exact bit meaning is stock-only knowledge).
- Actual power numbers: no source says what C2/cluster-off/AFTR each save on the
  1.48 W screen-off baseline; stock's `cpuidle_profiler` code exists but no data is
  readable here.
- Whether the bootloader tolerates CPUs coming back from hot-unplug through the
  holding pen under our mainline pen discipline (SMP_BRINGUP.md §8 documents cold
  bring-up; the hot-replug variant is reasoned about, not observed).
- Which of the stock blockers still apply to mainline drivers (our Wi-Fi is
  brcmfmac PCIe, not the stock PCIe driver; our display stack is DRM DECON, not the
  stock fbdev one) — the *register* checks are portable, the driver hooks are not.
- Whether `SMC_CMD_CPU0AFTR` (mainline's non-3250 `do_idle`) is accepted by this
  monitor as a substitute (nothing in either tree suggests it is; §2.2).
