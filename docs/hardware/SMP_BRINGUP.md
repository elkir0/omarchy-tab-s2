# SMP bring-up on Exynos5433 (SM-T715): stock Android kernel vs mainline arm32

Scope: how the stock Samsung `universal5433` 3.10 kernel (AArch32 on an ARMv8 SoC)
brings up, hot-unplugs and powers down the 7 secondary CPUs, what mainline
Linux 6.12 `arch/arm/mach-exynos` does instead, the resulting gap, and a
minimal (not applied) patch proposal for mainline.

Citation convention: paths are relative to the repository root (`src/` holds the kernel and Android trees)
so `src/kernel_universal5433/...:line` refers to the stock kernel and
`src/linux-6.12/...:line` to mainline. Live device tree evidence is
`dumps/live_fdt.dts` (its `/chosen` node is out of scope). Every register
offset, bit value, SMC ID and physical address below carries a citation;
anything without one is explicitly marked **unknown**.

**Update 2026-10-28:** a patch derived from this analysis is now applied
(build-tested only); see §8 "Implemented (2026-10-28)", which also lists
the corrections to §2-§7 below.

State today: the mainline test kernel boots with `nosmp` in its bootargs
(`src/linux-6.12/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts:35`),
the PSCI node is deleted and every `enable-method` property is deleted
(`exynos5433-gts28ltexx.dts:77-88`), so only CPU0 ever runs.

---

## 1. Platform map (as evidenced)

### 1.1 Clusters and MPIDRs

| Cluster | Samsung name | Cores | MPIDR Aff1 | DT `reg` values |
|---|---|---|---|---|
| 0 | EAGLE (Cortex-A57) | 4 | 0x0 | 0x0–0x3 |
| 1 | KFC (Cortex-A53) | 4 | 0x1 | 0x100–0x103 |

Stock DT: `src/kernel_universal5433/arch/arm/boot/dts/exynos5433.dtsi:56-100`
(`cpu@0` reg 0x100 … `cpu@3` reg 0x103, `cpu@4` reg 0x0 … `cpu@7` reg 0x3;
the `compatible` strings "a7"/"a15" are wrong but the `reg`s are what Linux
uses as `cpu_logical_map`). Live FDT agrees on the regs:
`dumps/live_fdt.dts:4462-4513` (`cpu@0` reg 0x100 at :4496-4497, `cpu@4`
reg 0x0 at :4472-4473). Mainline arm64 dtsi agrees and fixes the CPU names:
`src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi:87-206`
(cpu0–3 are `arm,cortex-a53` reg 0x100–0x103, cpu4–7 A57 reg 0x0–0x3).

So in Linux logical numbering (both trees): **cpu0–3 = A53, cpu4–7 = A57**.

`MPIDR_AFFINITY_LEVEL(mpidr, level)` extracts 8 bits per affinity level:
`src/linux-6.12/arch/arm/include/asm/cputype.h:58-63`; the stock tree
has the same macro plus `MPIDR_HWID_BITMASK 0xFFFFFF`
(`src/kernel_universal5433/arch/arm/include/asm/cputype.h:33`).

### 1.2 PMU

Physical base **0x105C0000** — stock maps it for 5433 via
`EXYNOS5430_PA_PMU` (`src/kernel_universal5433/arch/arm/mach-exynos/include/mach/map.h:87`,
iodesc at `arch/arm/mach-exynos/common.c:675-678`, SZ_64K); mainline's
5433 dtsi node is `system-controller@105c0000`, reg `<0x105c0000 0x5008>`
(`src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi:915-917`).

Per-core register block (flat PMU index *n*, physical = 0x105C0000 + …):

| Register | Offset | Stock citation |
|---|---|---|
| CORE*n* CONFIGURATION (rw) | 0x2000 + 0x80·*n* | `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/regs-pmu.h:306,332-333` |
| CORE*n* STATUS (ro) | +0x4 | `regs-pmu.h:307,334-335` |
| CORE*n* OPTION | +0x8 | `regs-pmu.h:308,336-337` |
| CORE*n* RESET | +0xC | `regs-pmu.h:309,338-339` |
| per-core DURATION0..3 | +0x10,+0x14,+0x18,+0x1C | `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/regs-pmu-exynos5433.h:123-125` |

The flat index is **core + 4·cluster**: `exynos5433_cpu_up` computes
`EXYNOS_ARM_CORE_CONFIGURATION(core + (4 * cluster))`
(`src/kernel_universal5433/arch/arm/mach-exynos/pmu-exynos5433.c:97`),
same in `exynos5433_cpu_state` (:154). The 0x80 stride and the KFC block at
0x2200 are confirmed by the explicit per-core defines
(`regs-pmu.h:306-330`: EAGLE CORE0 = 0x2000, KFC CORE0 = 0x2200, KFC CORE3 =
0x2380). Example physical addresses:

* A53 core0 (MPIDR 0x100): CONFIGURATION 0x105C2200, STATUS 0x105C2204
* A57 core0 (MPIDR 0x000): CONFIGURATION 0x105C2000, STATUS 0x105C2004
* A57 core3 (MPIDR 0x003): CONFIGURATION 0x105C2180

Cluster (L2/COMMON) block:

| Register | Offset (5433) | Stock citation |
|---|---|---|
| ARM_COMMON (cluster) *c* CONFIGURATION | 0x2500 + 0x80·*c* | `regs-pmu.h:341-344` |
| L2 *c* CONFIGURATION | 0x2600 + **0x20**·*c* | `regs-pmu.h:350-353` (`soc_is_exynos5430() || soc_is_exynos5433()` picks the 0x20 stride) |
| L2 *c* STATUS / OPTION | +0x4 / +0x8 | `regs-pmu.h:355-358` |

Note the 5433 L2 stride is 0x20; mainline's generic header hard-codes 0x80
(`src/linux-6.12/include/linux/soc/samsung/exynos-regs-pmu.h:150-152`)
— one of the gaps (§4).

Key bit values:

| Value | Meaning | Citation |
|---|---|---|
| 0xF | `EXYNOS_CORE_PWR_EN` — 5433 core power-enable pattern written to CONFIGURATION | `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/regs-pmu.h:367`; used at `pmu-exynos5433.c:125-127` |
| 0xF | expected STATUS pattern (`state == EXYNOS_CORE_PWR_EN`) | `pmu-exynos5433.c:154-157` |
| 0x3 | `S5P_CORE_LOCAL_PWR_EN` — mainline's enable value | `src/linux-6.12/include/linux/soc/samsung/exynos-regs-pmu.h:181` |
| 0x7 | `EXYNOS_L2_PWR_EN` | `regs-pmu.h:369` |
| (0x7<<8)\|0x7 | L2 up pattern `(EXYNOS_L2_PWR_EN << 8) \| EXYNOS_L2_PWR_EN` | `pmu-exynos5433.c:230` |
| 1<<28 | `EXYNOS5433_USE_SMPEN` (per-core OPTION) | `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/regs-pmu-exynos5433.h:205` |
| UP_SCHEDULER 0x0120, bits 0/1 = ENABLE_EAGLE_CPU / ENABLE_KFC_CPU | "UP scheduler" enables | `regs-pmu.h:28-31` |

### 1.3 iRAM ("sysram") and the secure-monitor handshake

| Region | Physical | Size | Citations |
|---|---|---|---|
| secure sysram | 0x02020000 | 0x1000 | `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/map.h:38` (`EXYNOS5_PA_SYSRAM`); iodesc `common.c:680-683`; virtual `S5P_VA_SYSRAM` = `arch/arm/plat-samsung/include/plat/map-s5p.h:30` |
| non-secure sysram-ns | 0x0207B000 | 0x1000 | `map.h:44` (`EXYNOS5433_PA_SYSRAM_NS`); iodesc `common.c:685-688`; virtual `S5P_VA_SYSRAM_NS` = `map-s5p.h:31` |

Offsets inside sysram-ns (all `S5P_VA_SYSRAM_NS + …`, physical 0x0207B000 + …):

| Offset | Use | Citation |
|---|---|---|
| +0x08 / +0x0C | REG_INFORM0/1 — suspend resume addr / sleep magic | `src/kernel_universal5433/arch/arm/mach-exynos/pm-exynos5433.c:43-44`; written at :215,:217 |
| +0x1C | **secondary boot address** (target PC for released cores) | `src/kernel_universal5433/arch/arm/mach-exynos/firmware.c:38` |
| +0x20 / +0x24 | DIRECTGO flag (0xFCBA0D10) / DIRECTGO addr — C2 idle handshake | `src/kernel_universal5433/arch/arm/mach-exynos/cpuidle-exynos5433.c:52-55`; used at :603-604 |
| +0x28 | REG_CPU_STATE_ADDR — per-core boot flags, index 4·(core + 4·cluster) | `src/kernel_universal5433/arch/arm/mach-exynos/pmu-exynos5433.c:28,58` |

Boot-flag bits (`src/kernel_universal5433/arch/arm/mach-exynos/include/mach/pmu.h:71-78`):
RESET = 1<<0, SECONDARY_RESET = 1<<1, **HOTPLUG = 1<<2**, C2_STATE = 1<<3,
CORE_SWITCH = 1<<4, mask 0x1F.

The live FDT contains exactly one node for this region — the secure-firmware
node at the same physical address as sysram-ns:
`dumps/live_fdt.dts:1583-1586` (`firmware@0207B000`, reg
`<0x207b000 0x1000>`, compatible `"samsung,secure-firmware"`); the stock
`exynos5433.dtsi` carries the identical node
(`src/kernel_universal5433/arch/arm/boot/dts/exynos5433.dtsi:205-208`).
i.e. on 5433 the "sysram-ns" window *is* the secure-firmware window.

### 1.4 Secure firmware SMC convention

Samsung monitor SMC function IDs
(`src/kernel_universal5433/arch/arm/mach-exynos/include/mach/smc.h:14-21,40`):

| ID | Command |
|---|---|
| −3 | SMC_CMD_SLEEP |
| −4 | SMC_CMD_CPU1BOOT |
| −5 | SMC_CMD_CPU0AFTR |
| −6 | SMC_CMD_SAVE |
| −7 | SMC_CMD_SHUTDOWN |
| −101 | SMC_CMD_REG (with `SMC_REG_ID_SFR_W/R` encoding, `smc.h:64-65`) |

`OP_TYPE_CORE` 0x0 / `OP_TYPE_CLUSTER` 0x1 (`smc.h:68-69`),
`SMC_POWERSTATE_SLEEP` 0x0 / `SMC_POWERSTATE_IDLE` 0x1 (`smc.h:72-73`).
The trampoline is `dsb; smc #0`
(`src/kernel_universal5433/arch/arm/mach-exynos/exynos-smc.S:19-24`).
Mainline keeps the same IDs
(`src/linux-6.12/arch/arm/mach-exynos/smc.h:14-18,42-43,46`).

### 1.5 Stock PMU init that arms the sequencer

`exynos5433_pmu_init()` (`src/kernel_universal5433/arch/arm/mach-exynos/pmu-exynos5433.c:457-545`)
is called from `exynos_init_time()` when `soc_is_exynos5433()`
(`src/kernel_universal5433/arch/arm/mach-exynos/common.c:1199-1200`).
Relevant to SMP:

* OSC_DURATION (0x2D3C) = 0x3A98 (:466; define `regs-pmu-exynos5433.h:147`)
* CENTRAL_SEQ_OPTION |= STANDBYWFI-all | PROLOGNED_LOGIC_RESET (:469-470)
* `exynos_core_option()` (:475; :338-357): per-core OPTION |= SC_COUNTER |
  SC_FEEDBACK | `EXYNOS5433_USE_SMPEN` (1<<28, `regs-pmu-exynos5433.h:205`);
  per-core DURATION regs |= `DUR_WAIT_RESET` (0xF<<20) and
  `DUR_SCALL_VALUE` (0x1<<4) (:350-356; defines `regs-pmu-exynos5433.h:126-128`)
* L2_OPTION(0/1) &= ~`EXYNOS5433_USE_AUTOMATIC_L2FLUSHREQ` (:480-486);
  L2 options for retention/standby (:492-498)
* `EXYNOS5_UP_SCHEDULER` (0x0120) |= ENABLE_EAGLE_CPU | ENABLE_KFC_CPU (:501-503)
* ops wiring: `exynos_cpu.power_up = exynos5433_cpu_up`, `power_state =
  exynos5433_cpu_state`, `power_down = exynos5433_cpu_down`,
  `cluster_down = exynos5433_l2_down`, `cluster_state`,
  `is_last_core` (:533-538)

This runs before any secondary is booted; mainline has no equivalent (§3.4).

---

## 2. Stock bring-up sequence (universal5433)

### 2.1 Boot-time preparation

Machine descriptor wires `.smp = smp_ops(exynos_smp_ops)`
(`src/kernel_universal5433/arch/arm/mach-exynos/mach-universal5433.c:75`, block :73-84).
`exynos_smp_ops` (`src/kernel_universal5433/arch/arm/mach-exynos/platsmp.c:322-330`):
`.smp_init_cpus` = `exynos_smp_init_cpus` (:323) — non-Cortex-A9 SoCs just
return and let `arm_dt_init_cpu_maps()` set the possible map from DT
(`platsmp.c:248-271`, early return at :253-260). `.smp_prepare_cpus` =
`exynos_smp_prepare_cpus` (:324):

1. `exynos_firmware_init()` (:277) — finds the `"samsung,secure-firmware"`
   node (`platsmp.c`→`firmware.c:56-57`), iomaps its reg 0x0207B000 into
   `ns_base` (`firmware.c:67`), and `register_firmware_ops(&exynos_firmware_ops)`
   (`firmware.c:76`; ops table `firmware.c:44-48`).
2. Pre-writes the secondary boot address for cpus 1..max_cpus−1 (:288-297):
   `boot_addr = virt_to_phys(exynos4_secondary_startup)` (:293), then
   `call_firmware_op(set_cpu_boot_addr, …)` with fallback
   `__raw_writel(boot_addr, cpu_boot_reg(phys_cpu))` (:295-296).
3. 5430-only NONCPU block (:299-317) — skipped on 5433.
4. `BUG_ON(exynos_cpu.power_up == NULL)` (:319) — asserts the PMU ops were
   installed by `exynos5433_pmu_init()`.

### 2.2 `cpu_boot_reg()` — where each core's boot address would live (fallback path)

`src/kernel_universal5433/arch/arm/mach-exynos/platsmp.c:48-63`:

```c
core    = MPIDR_AFFINITY_LEVEL(phys_cpu, 0);   /* :53 */
cluster = MPIDR_AFFINITY_LEVEL(phys_cpu, 1);   /* :54 */
boot_reg = cpu_boot_reg_base();                /* :56  = S5P_VA_SYSRAM (0x02020000), :41-46 */
boot_reg += cluster ? 0 : 0x10;                /* :57 */
if (soc_is_exynos4412() || soc_is_exynos5430() || soc_is_exynos5433())
        boot_reg += 4 * core;                  /* :59-60 */
```

So the non-secure fallback registers are:

* **A57 core n (cluster 0)**: 0x02020010 + 4·n
* **A53 core n (cluster 1)**: 0x02020000 + 4·n

### 2.3 Bringing up a secondary Cortex-A53 (KFC) core — step by step

Call chain: `exynos_boot_secondary()` (`platsmp.c:172-241`) →
`exynos_power_up_cpu()` (:102-170) → `exynos_cpu.power_up` =
`exynos5433_cpu_up()` (`pmu-exynos5433.c:88-128`).

Example: logical cpu1, `cpu_logical_map(1)` = MPIDR 0x100.

1. `phys_cpu = cpu_logical_map(cpu)` = 0x100 (`platsmp.c:175`);
   `spin_lock(&boot_lock)` (:182).
2. `write_pen_release(phys_cpu)` — pen gets the **full MPIDR value** 0x100
   (`platsmp.c:192`).
3. `exynos_power_up_cpu(1)` (:194):
   a. Skip if already on: `exynos_cpu.power_state(1)` → `exynos5433_cpu_state`
      (`pmu-exynos5433.c:146-158`): reads
      `EXYNOS_ARM_CORE_STATUS(0 + 4·1)` = PMU 0x105C2204, returns true iff
      `(val & 0xF) == 0xF` (:154-157).
   b. `exynos_cpu.power_up(1)` → `exynos5433_cpu_up` (`pmu-exynos5433.c:88-128`):
      - `phys_cpu = cpu_logical_map(1)` (:90), `core` = Aff0 = 0, `cluster` =
        Aff1 = 1 (:94-96).
      - `addr = EXYNOS_ARM_CORE_CONFIGURATION(core + 4·cluster)` (:97) =
        PMU 0x105C2200 (macro `regs-pmu.h:332-333`, base :306).
      - If `CONFIG_EXYNOS5433_CORE_FEEDBACK_CHECK_DISABLE`
        (set in the shipping defconfig,
        `src/kernel_universal5433/arch/arm/configs/lineage_gts28ltexx_defconfig:430`):
        `OPTION (0x105C2208) &= ~0x2` (:100-102), then DURATION0..3
        (0x105C2210/14/18/1C) each `&= ~(0xff<<4); |= (0x11<<4)` (:104-122;
        register defs `regs-pmu-exynos5433.h:123-125`).
      - `tmp |= EXYNOS_CORE_PWR_EN (0xF); __raw_writel(tmp, addr)` (:125-127;
        0xF define `regs-pmu.h:367`). **This is the actual power-on write.**
   c. Poll `power_state` up to 10 ms, 1 ms steps (`platsmp.c:115-127`), else
      −ETIMEDOUT.
   d. The 5422/5430 SWRESET workaround is compiled out for 5433:
      `#if !defined(CONFIG_SOC_EXYNOS5433)` (`platsmp.c:129-167`).
4. Release loop (`platsmp.c:206-232`, retried for up to 1 s):
   - `boot_addr = virt_to_phys(exynos4_secondary_startup)` (:212).
   - `call_firmware_op(set_cpu_boot_addr, 0x100, boot_addr)` (:218) →
     `exynos_set_cpu_boot_addr()` writes `boot_addr` to **one** register,
     `ns_base + 0x1C` = 0x0207B01C
     (`src/kernel_universal5433/arch/arm/mach-exynos/firmware.c:36-42`)
     — no per-CPU offset under secure firmware. (The per-CPU offsets of §2.2
     only apply to the insecure fallback at :219.)
   - **Wakeup**: for 5433 the kernel executes `dsb_sev()` and nothing else
     (`platsmp.c:221-222`: `if (soc_is_exynos5433() || soc_is_exynos5430()
     || soc_is_exynos5422()) { dsb_sev(); }`). `dsb_sev()` = `dsb` + `sev`
     (`src/kernel_universal5433/arch/arm/include/asm/spinlock.h:45-51`).
     The other branches — `call_firmware_op(cpu_boot)` (SMC_CMD_CPU1BOOT, −4,
     `firmware.c:30-34`) and `arch_send_wakeup_ipi_mask()` (:225) — are **not
     taken on 5433**.
   - Poll `pen_release == -1` (:228-231).
5. Secondary core path: the secure monitor releases the core at the address
   found in 0x0207B01C; the core runs `exynos4_secondary_startup`
   (`src/kernel_universal5433/arch/arm/mach-exynos/headsmp.S:25-41`):
   - read MPIDR (`mrc p15,0,r0,c0,c0,5`, :26) and `and r0, r0, #0xFFFFFF`
     (:27; `MPIDR_HWID_BITMASK` :16 — **Aff1 kept**, A53 core n has key 0x10n);
   - poll `pen_release` until it equals that value (:32-34);
   - `b secondary_startup` (:40) → kernel C entry.
   The monitor code itself that copies 0x0207B01C into the core's reset
   vector is inside sboot and is **unknown** (not in this tree).
6. Primary side completes: `exynos_secondary_init()` (`platsmp.c:85-100`)
   runs on the new core: `write_pen_release(-1)` (:91) releases the primary's
   poll, and `clear_boot_flag(cpu, HOTPLUG)` (:93) clears bits 0x1F at
   sysram-ns 0x0207B028 + 4·(core + 4·cluster) — for cpu1: 0x0207B038
   (`pmu-exynos5433.c:58,71-86`; HOTPLUG = 1<<2, `pmu.h:73`). Then
   boot_lock unlock, `return pen_release != -1 ? -ENOSYS : 0` (:240).

No SMC call is issued anywhere in the 5433 boot path; no IPI is sent; the
only writes are PMU CONFIGURATION/DURATION regs and sysram-ns 0x0207B01C.

### 2.4 Bringing up a Cortex-A57 (EAGLE) core — differences

Identical chain; only the arithmetic changes for, say, logical cpu4
(MPIDR 0x000, core 0 cluster 0):

* `exynos5433_cpu_up`: `addr = EXYNOS_ARM_CORE_CONFIGURATION(0 + 4·0)` =
  PMU 0x105C2000 (`pmu-exynos5433.c:97`).
* pen value 0x000; holding-pen key 0x000 (`headsmp.S:26-34`).
* boot-flag slot index 0 → sysram-ns 0x0207B028 (`pmu-exynos5433.c:58`).
* fallback boot register 0x02020010 + 4·core (`platsmp.c:57,59-60`).

The **cluster** itself is not explicitly powered in this path: there is no
`cluster_up` op at all (ops struct `src/kernel_universal5433/arch/arm/mach-exynos/include/mach/common.h:104-111`
has `cluster_down`/`cluster_state`/`is_last_core` only, wiring at
`pmu-exynos5433.c:533-538`). `exynos5433_l2_up()`
(`pmu-exynos5433.c:228-240`, writes `(0x7<<8)|0x7` to L2 CONFIGURATION
0x105C2600 + 0x20·cluster, busy-waits on L2 STATUS) exists but has **no
in-tree caller on 5433** (only 5430's PMU code calls an l2_up; grep across
the stock tree finds no 5433 call site). The implicit assumption is that the
PMU sequencer armed by `exynos5433_pmu_init()` (UP_SCHEDULER enable,
:501-503) brings the cluster/L2 up when the first core is powered — the
mechanism is **unknown** (see §7).

### 2.5 Hot-unplug / CPU-idle differences

* **cpu_die**: `exynos_smp_ops.cpu_die` = `exynos_cpu_die` (`platsmp.c:328`;
  implementation `src/kernel_universal5433/arch/arm/mach-exynos/hotplug.c:160-190`).
  Before entering low power, `exynos_power_down_cpu()`
  (`hotplug.c:99-120`): `set_boot_flag(cpu, HOTPLUG)` (:104 — sysram-ns
  boot-flag slot gets 1<<2), `exynos_cpu.power_down(cpu)` (:105) →
  `exynos5433_cpu_down` clears `EXYNOS_CORE_PWR_EN` in the core's
  CONFIGURATION (`pmu-exynos5433.c:130-144`), then under
  `CONFIG_ARM_TRUSTZONE` (set in defconfig, `lineage_gts28ltexx_defconfig:452`)
  issues `exynos_smc(SMC_CMD_SHUTDOWN, OP_TYPE_CLUSTER & type,
  SMC_POWERSTATE_IDLE, 0)` (`hotplug.c:114-119`; IDs `smc.h:21,68-69,73`).
  Replug re-uses exactly the §2.3 sequence (the HOTPLUG flag tells the
  monitor-side stub this is a hotplug, cleared again in
  `exynos_secondary_init`, `platsmp.c:93`).
* **C2 cluster idle** (cpuidle): same registers, extra handshake —
  DIRECTGO flag 0xFCBA0D10 / addr at sysram-ns 0x0207B020/24
  (`cpuidle-exynos5433.c:52-55`, writes at :603-604 and :1058-1059),
  `set_boot_flag(cpu, C2_STATE)` (:1061), `exynos5433_cpu_down/up`
  (:1072,:1076), and finishers that issue `SMC_CMD_SAVE`/`SMC_CMD_SHUTDOWN`
  with `OP_TYPE_CORE`/`OP_TYPE_CLUSTER`, `SMC_POWERSTATE_IDLE`
  (:519-560). These SMCs are idle-only; the hotplug/boot path never issues
  them (except the SHUTDOWN above).

---

## 3. Mainline 6.12 arm32 equivalent

### 3.1 What runs today (with `nosmp`)

* `exynos_map_pmu()` runs from `exynos_init_irq()`
  (`src/linux-6.12/arch/arm/mach-exynos/exynos.c:157-166`) but
  `exynos_dt_pmu_match` knows only `"samsung,exynos5260-pmu"` and
  `"samsung,exynos5410-pmu"` (`exynos.c:141-145`) → **`pmu_base_addr` stays
  NULL** on 5433. (`drivers/soc/samsung/exynos-pmu.c:256` *does* know
  `"samsung,exynos5433-pmu"` — that's the syscon driver, a different consumer.)
* `exynos_smp_prepare_cpus()` runs with `max_cpus == 0`
  (`src/linux-6.12/arch/arm/mach-exynos/platsmp.c:406-414`):
  `exynos_sysram_init()` (:408) finds no `"samsung,exynos4210-sysram"` /
  `"samsung,exynos4210-sysram-ns"` nodes (`exynos.c:48-71` — none exist in
  the arm64 5433 dtsi nor in the live FDT) → `sysram_base_addr` /
  `sysram_ns_base_addr` stay NULL; the delayed-reset write is Exynos4-gated
  (`exynos.c:120-134`) and the SCU enable is A9-only, so no PMU access
  happens.
* `exynos_firmware_init()` runs from `.init_early`
  (`exynos.c:257`) → `exynos_secure_firmware_available()`
  (`src/linux-6.12/arch/arm/mach-exynos/firmware.c:196-214`) finds no
  `"samsung,secure-firmware"` node → ops never registered.
* Nothing ever touches `pmu_raw_*` (`src/linux-6.12/arch/arm/mach-exynos/common.h:163-171`,
  raw `pmu_base_addr + offset`), so boot succeeds on CPU0 only.

### 3.2 What `exynos_boot_secondary()` would do

`src/linux-6.12/arch/arm/mach-exynos/platsmp.c:317-404`, step by step:

1. `mpidr = cpu_logical_map(cpu)`, `core_id = MPIDR_AFFINITY_LEVEL(mpidr, 0)`
   (:320-321) — **Aff0 only, cluster dropped**.
2. `exynos_write_pen_release(core_id)` (:338) — pen gets Aff0, not full MPIDR.
3. `exynos_cpu_power_state(core_id)` (:340 → :129-133): `pmu_raw_readl(EXYNOS_ARM_CORE_STATUS(core_id))`
   = `pmu_base_addr + 0x2004 + 0x80·core_id` (`common.h:168-171`;
   `exynos-regs-pmu.h:134-138`). With `pmu_base_addr == NULL` this is a
   **data abort at virtual 0x2004** — today's first failure if `nosmp` were
   dropped.
4. If it got this far: `exynos_cpu_power_up(core_id)` (:341 → :114-123)
   writes `S5P_CORE_LOCAL_PWR_EN` = **0x3**
   (`exynos-regs-pmu.h:181`) to CONFIGURATION — wrong pattern (stock writes
   0xF, §1.2) and wrong register for any cluster≠0 core (Aff0 index used
   flat).
5. Wait until `power_state == S5P_CORE_LOCAL_PWR_EN` (:345-346), 10 ms.
6. `exynos_core_restart()` (:360) — Exynos3250-only, returns immediately
   (:211-234).
7. `boot_addr = __pa_symbol(exynos4_secondary_startup)` (:374);
   `exynos_set_boot_addr()` (:376 → :267-290): firmware op first (:275).
   - Ops unregistered (no firmware node): `call_firmware_op` returns
     −ENOSYS → fallback `cpu_boot_reg(core_id)` (:279 → :192-204) →
     `cpu_boot_reg_base()` returns `sysram_base_addr` = NULL →
     `IOMEM_ERR_PTR(-ENODEV)` (:197-198) → boot fails −ENODEV.
   - If only the firmware node were added: op = mainline
     `exynos_set_cpu_boot_addr()` (`firmware.c:82-101`) writes
     `sysram_ns_base_addr + 0x1c` (:89) but returns **−ENODEV when
     `sysram_ns_base_addr` is NULL** (:86-87) — and unlike stock, mainline's
     firmware op uses the *global* sysram-ns mapping, not a private one —
     so a sysram-ns DT node is mandatory even with the firmware node present.
   - `cpu_boot_reg()` has **no 5433 case** (:199-202: only 4412 +4·cpu and
     5420/5800 +4) — even with both nodes mapped, the insecure fallback
     would program the wrong register for every 5433 core.
8. `call_firmware_op(cpu_boot, core_id)` (:380) — mainline
   `exynos_cpu_boot()` returns 0 without any SMC for non-Exynos4
   (`firmware.c:58-80`, "On Exynos5 devices the call is ignored by trustzone
   firmware") — consistent with stock 5433 behaviour (§2.3 step 4).
9. **Wakeup**: `if (soc_is_exynos3250()) dsb_sev(); else
   arch_send_wakeup_ipi_mask(...)` (:382-385) — mainline sends an **IPI**,
   stock 5433 uses `dsb_sev()`.
10. Secondary entry: same symbol, different mask —
    `src/linux-6.12/arch/arm/mach-exynos/headsmp.S:18-35`:
    `and r0, r0, #15` (:21) keeps only Aff0, so an A57 core n and an A53
    core n compare equal against the pen; with pen = Aff0 (:338) A53 vs A57
    are indistinguishable and two clusters race for one pen value. Stock
    uses the full 0xFFFFFF mask and full-MPIDR pen values (§2.3).
11. `exynos_secondary_init()` (:252-265) clears the pen; there is no
    boot-flag handling in the cold-boot path (stock also sets no flags on
    cold boot, so no gap here).

### 3.3 DT dependencies of the mainline path

| Symbol | Set by | Needs |
|---|---|---|
| `pmu_base_addr` | `exynos_map_pmu()` `exynos.c:147-155` ← `exynos_dt_pmu_match` :141-145 ← `exynos_init_irq` :157-166 | a DT node compatible `samsung,exynos5260-pmu` or `samsung,exynos5410-pmu` — **the 5433 node's compatible (`samsung,exynos5433-pmu`, `exynos5433.dtsi:916`) does not match** |
| `sysram_base_addr` / `sysram_ns_base_addr` | `exynos_sysram_init()` `exynos.c:48-71` | nodes compatible `"samsung,exynos4210-sysram"` / `"samsung,exynos4210-sysram-ns"` (`exynos.c:52,64`) — absent from the 5433 dtsi and from the live FDT |
| firmware ops registered | `exynos_firmware_init()` `exynos.c:257` → `firmware.c:216-236`, gated by `exynos_secure_firmware_available()` :196-214 | node compatible `"samsung,secure-firmware"` — **present in the live FDT** (`dumps/live_fdt.dts:1583-1586`) but absent from the mainline 5433 dtsi |

Note also: `exynos_set_boot_flag/clear_boot_flag` exist in mainline
(`firmware.c:241-261`, REG_CPU_STATE_ADDR = sysram-ns + 0x28) but index
`4·cpu` flat (:247-250 area) — that's the Exynos3250 layout; the 5433 layout
is `4·(core + 4·cluster)` (stock `pmu-exynos5433.c:58`). Not used in the
mainline cold-boot path, relevant only later for hotplug.

### 3.4 Precisely what happens if `enable-method` were kept / `nosmp` removed

Two scenarios:

**(a) As the board dts actually is (PSCI deleted, enable-method deleted).**
`arm_dt_init_cpu_maps()` still walks all 8 cpu nodes and
`set_cpu_possible(i, true)` for each — the enable-method only selects
smp_ops, and its absence falls back to whatever the machine descriptor set
(`src/linux-6.12/arch/arm/kernel/devtree.c:35-49` returns 0 when the
property is missing; :140-148 fallback; :160-164 sets the possible map
regardless). So `exynos_smp_ops` stays active
(`exynos.c:252-263`, `.smp` :255) and 7 secondaries are booted at init:
first PMU access at `platsmp.c:340` → NULL-pointer data abort (§3.2 step 3),
panic (`panic=5 oops=panic` in bootargs, `exynos5433-gts28ltexx.dts:35`).
Even with the PMU match fixed, the chain then fails at the boot-address
step (−ENODEV, §3.2 step 7), and if that were fixed, the IPI wakeup + #15
pen mask would mis-release cores (§3.2 steps 9-10). This is why `nosmp` +
deletions are currently load-bearing.

**(b) Hypothetical: keep the dtsi defaults (`enable-method = "psci"`,
psci node present) and drop `nosmp`.** `set_smp_ops_by_method()` matches
"psci" in `__cpu_method_of_table` (`devtree.c:35-49`) and replaces the
mach ops with the ARM PSCI smp ops; the first `cpu_on` is an `smc #0` with
ID 0xc4000003 (psci node, `src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi:350-355`).
The device's signed bootloader provides no PSCI conduit to a 32-bit kernel
(board dts comment, `exynos5433-gts28ltexx.dts:71-76`), so the behaviour of
that SMC is **unknown** — at best an unsupported-call return, at worst a
hang in secure state. This is why the psci node is deleted rather than used.

---

## 4. Gap analysis

| # | Stock step | Mainline equivalent | Missing piece | Evidence |
|---|---|---|---|---|
| 1 | PMU ioremapped for 5433 (0x105C0000) and PMU ops installed pre-SMP | `exynos_dt_pmu_match` lacks 5433 → `pmu_base_addr` NULL; no 5433 PMU init at all | add `"samsung,exynos5433-pmu"` to the match table (and accept: no 5433 sequencer init exists) | stock `common.c:675-678`, `pmu-exynos5433.c:457-545,533-538`; mainline `exynos.c:141-145,147-166`, `common.h:163-171` |
| 2 | Flat PMU index `core + 4·cluster` | `core_id` = Aff0 only, used as flat PMU index | MPIDR→flat-index conversion for 5433 | stock `pmu-exynos5433.c:97,154`; mainline `platsmp.c:320-321,340-341` |
| 3 | Power-enable value 0xF (`EXYNOS_CORE_PWR_EN`), status check vs 0xF | writes `S5P_CORE_LOCAL_PWR_EN` (0x3); status masked 0x3 | 0xF write for 5433 (mainline's 0x3-masked status compare still passes when 0xF is written) | stock `regs-pmu.h:367`, `pmu-exynos5433.c:125-127,154-157`; mainline `exynos-regs-pmu.h:181`, `platsmp.c:114-123,345-346` |
| 4 | Optional FEEDBACK/DURATION tuning per core (`CONFIG_EXYNOS5433_CORE_FEEDBACK_CHECK_DISABLE`) | absent | unknown whether required (defconfig ships it enabled) | stock `pmu-exynos5433.c:99-123`, `regs-pmu-exynos5433.h:123-128`, defconfig :430 |
| 5 | Boot address: firmware op → single reg sysram-ns+0x1C; fallback per-CPU regs 0x02020000/0x02020010 + 4·core (cluster 0 adds 0x10) | firmware op (needs global `sysram_ns_base_addr`); fallback `cpu_boot_reg` has no 5433 case (no cluster +0x10, no +4·core) | sysram-ns DT node + 5433 offsets in `cpu_boot_reg` | stock `firmware.c:36-42`, `platsmp.c:48-63`; mainline `firmware.c:82-101`, `platsmp.c:185-204`, `exynos.c:48-71` |
| 6 | `samsung,secure-firmware` node present; ops registered from `.init_early`/prepare | node absent from mainline 5433 dtsi → ops unregistered | add node (value available from live FDT) | stock dtsi :205-208, `firmware.c:50-77`; live FDT :1583-1586; mainline `firmware.c:196-236`, `exynos.c:257` |
| 7 | Wakeup = `dsb_sev()` (no SMC, no IPI) on 5433 | `dsb_sev()` only for 3250; IPI otherwise | 5433 in the SEV branch | stock `platsmp.c:221-226`; mainline `platsmp.c:382-385` |
| 8 | Holding pen keyed by full MPIDR (mask 0xFFFFFF), pen = full MPIDR | mask `#15`, pen = Aff0 | widen mask + pen value for 5433 | stock `headsmp.S:16,26-27`, `platsmp.c:192`; mainline `headsmp.S:21`, `platsmp.c:338` |
| 9 | `soc_is_exynos5433()` available (SOC ID 0xE5433000, mask 0xFFFFF000) | no `EXYNOS5433_SOC_ID` / `soc_is_exynos5433()` (local Kconfig exists) | add SOC ID + inline | stock `arch/arm/plat-samsung/include/plat/cpu.h:55,57,79`; mainline `common.h:14-26,36-95`; local `Kconfig:120-131` |
| 10 | Boot flags (HOTPLUG/C2) at sysram-ns+0x28, index 4·(core+4·cluster) | helper exists but indexes 4·cpu (3250 layout); unused in cold boot | only matters for hotplug/C2 later | stock `pmu-exynos5433.c:28,50-86`, `pmu.h:71-78`; mainline `firmware.c:238,241-261` |
| 11 | Cluster/L2 power via PMU sequencer (UP_SCHEDULER); `l2_up` defined but uncalled for 5433 | no cluster power-up in boot path; L2 stride 0x80 in header (5433 is 0x20) | nothing to do for a first A53 bring-up; unresolved for A57 (§7) | stock `pmu-exynos5433.c:228-240,501-503`, `regs-pmu.h:350-353`; mainline `exynos-regs-pmu.h:150-152` |
| 12 | `cpu_die` = boot flags + PMU power-down + SMC_CMD_SHUTDOWN | plain WFI loop, no flags, no SMC | hotplug gap — keep secondaries online for now | stock `hotplug.c:99-119,160-190`; mainline `platsmp.c:422-441` |
| 13 | No `SMC_CMD_CPU1BOOT` on 5433 boot path | `exynos_cpu_boot` no-ops for non-Exynos4 | **no gap** — behaviour already matches | stock `platsmp.c:221-226`; mainline `firmware.c:58-80` |

---

## 5. Proposed minimal mainline patch (shown here only — NOT applied)

Design rules: everything C-side is gated on `soc_is_exynos5433()` (or the
machine-compatible check); DT values only from `dumps/live_fdt.dts` or
the mainline dtsi; anything unsourcable is an open question (§7), not a
guess. No attempt is made to hotplug, idle, or power-manage clusters.

### 5.1 Device tree (board file `exynos5433-gts28ltexx.dts`)

```dts
/*
 * Secure-monitor handshake SRAM.
 *
 * The firmware node below is the ONLY 5433 evidence in the live FDT for
 * this address window (dumps/live_fdt.dts:1583-1586). Mainline's
 * exynos_set_cpu_boot_addr() writes boot addresses through the GLOBAL
 * sysram-ns mapping (firmware.c:89), not through the firmware node, so a
 * "samsung,exynos4210-sysram-ns" node is required even with firmware ops
 * registered (exynos.c:64-70).
 *
 * [OPEN QUESTION OQ-2] the physical base 0x0207B000 for sysram-ns is not
 * stated by any mainline 5433 dts or by the live FDT as a sysram node; it
 * is used here because it is exactly the address of the live FDT's
 * firmware node (0x207b000), which the stock kernel maps as S5P_VA_SYSRAM_NS
 * for the same offsets (+0x1C boot addr etc.). Size 0x1000 = live FDT
 * firmware node size (live_fdt.dts:1584).
 */
	smp-sram@207b000 {
		compatible = "samsung,exynos4210-sysram-ns";
		reg = <0x0207b000 0x1000>;
	};

	firmware@207b000 {
		/* verbatim from the live FDT: dumps/live_fdt.dts:1583-1586
		   (also stock exynos5433.dtsi:205-208) */
		compatible = "samsung,secure-firmware";
		reg = <0x0207b000 0x1000>;
	};
```

No PMU node is added: the board already inherits
`pmu_system_controller: system-controller@105c0000` (compatible
`samsung,exynos5433-pmu`, reg `<0x105c0000 0x5008>`) from
`src/linux-6.12/arch/arm64/boot/dts/exynos/exynos5433.dtsi:915-936`;
only the C match table (§5.2, hunk B) needs to learn that compatible.
(The secure sysram at 0x02020000 is deliberately **not** added — mainline's
5433 path never touches `sysram_base_addr`; see §7 OQ-2.)

### 5.2 C changes

**Hunk A — `src/linux-6.12/arch/arm/mach-exynos/common.h`** (SOC id;
value from stock `arch/arm/plat-samsung/include/plat/cpu.h:55` with mask
`EXYNOS5_SOC_MASK` 0xFFFFF000, `common.h:26`):

```c
@@
 #define EXYNOS5420_SOC_ID	0xE5420000
 #define EXYNOS5800_SOC_ID	0xE5422000
+#define EXYNOS5433_SOC_ID	0xE5433000
 #define EXYNOS5_SOC_MASK	0xFFFFF000
@@
 IS_SAMSUNG_CPU(exynos5420, EXYNOS5420_SOC_ID, EXYNOS5_SOC_MASK)
 IS_SAMSUNG_CPU(exynos5800, EXYNOS5800_SOC_ID, EXYNOS5_SOC_MASK)
+IS_SAMSUNG_CPU(exynos5433, EXYNOS5433_SOC_ID, EXYNOS5_SOC_MASK)
@@
 #if defined(CONFIG_SOC_EXYNOS5800)
 # define soc_is_exynos5800()	is_samsung_exynos5800()
 #else
 # define soc_is_exynos5800()	0
 #endif
+
+#if defined(CONFIG_SOC_EXYNOS5433)
+# define soc_is_exynos5433()	is_samsung_exynos5433()
+#else
+# define soc_is_exynos5433()	0
+#endif
```

(`CONFIG_SOC_EXYNOS5433` already exists in the local tree:
`src/linux-6.12/arch/arm/mach-exynos/Kconfig:120-131`.)

**Hunk B — `src/linux-6.12/arch/arm/mach-exynos/exynos.c`** (PMU
mapping; compatible string from the in-tree 5433 dtsi,
`arch/arm64/boot/dts/exynos/exynos5433.dtsi:916`):

```c
@@ static const struct of_device_id exynos_dt_pmu_match[] = {
 	{ .compatible = "samsung,exynos5260-pmu" },
 	{ .compatible = "samsung,exynos5410-pmu" },
+	/*
+	 * The 5433 PMU node is a syscon (exynos5433.dtsi:915-917); mapping
+	 * it here only gives platsmp.c its raw register window. The base
+	 * address 0x105C0000 matches the stock kernel's EXYNOS5430_PA_PMU
+	 * iodesc (stock common.c:675-678).
+	 */
+	{ .compatible = "samsung,exynos5433-pmu" },
 	{ /*sentinel*/ },
 };
```

**Hunk C — `src/linux-6.12/arch/arm/mach-exynos/platsmp.c`**
(flat PMU index, power pattern, boot reg offsets, SEV wakeup, pen value;
each 5433 constant cited to the stock tree):

```c
@@
+/*
+ * Exynos5433: two clusters (EAGLE/A57 = MPIDR Aff1 0, KFC/A53 = Aff1 1),
+ * PMU core registers are indexed flat as core + 4 * cluster with an 0x80
+ * stride (stock pmu-exynos5433.c:97,154), and the core power-enable
+ * pattern is 0xF, not S5P_CORE_LOCAL_PWR_EN (0x3) (stock
+ * regs-pmu.h:367, pmu-exynos5433.c:125-127).
+ */
+static unsigned int exynos5433_pmu_index(u32 mpidr)
+{
+	return MPIDR_AFFINITY_LEVEL(mpidr, 0) +
+	       4 * MPIDR_AFFINITY_LEVEL(mpidr, 1);
+}
+
+static u32 exynos5433_core_pwr_en(void)
+{
+	return 0xF;	/* stock EXYNOS_CORE_PWR_EN, regs-pmu.h:367 */
+}
+
 static inline void __iomem *cpu_boot_reg(int cpu)
 {
@@
 	if (soc_is_exynos4412())
 		boot_reg += 4*cpu;
 	else if (soc_is_exynos5420() || soc_is_exynos5800())
 		boot_reg += 4;
+	else if (soc_is_exynos5433()) {
+		/* stock platsmp.c:57,59-60: cluster 0 adds 0x10, then +4*core */
+		unsigned int mpidr = cpu_logical_map(cpu);	/* caller passes logical; see call site */
+		boot_reg += MPIDR_AFFINITY_LEVEL(mpidr, 1) ? 0 : 0x10;
+		boot_reg += 4 * MPIDR_AFFINITY_LEVEL(mpidr, 0);
+	}
 	return boot_reg;
 }
```

(In `cpu_boot_reg()` the `cpu` argument is the logical cpu on the fallback
path — mainline's 4412 branch already treats it that way
(`platsmp.c:199-200`); stock passes `phys_cpu` here, stock `platsmp.c:219`.
The call sites below pass the logical cpu, matching mainline's existing
convention. This path is dead once firmware ops are registered — it exists
only to keep the fallback from being silently wrong.)

```c
@@ static int exynos_boot_secondary(unsigned int cpu, struct task_struct *idle)
 	u32 mpidr = cpu_logical_map(cpu);
 	u32 core_id = MPIDR_AFFINITY_LEVEL(mpidr, 0);
+	u32 pmu_idx = core_id;
@@
 	spin_lock(&boot_lock);
+	if (soc_is_exynos5433()) {
+		pmu_idx = exynos5433_pmu_index(mpidr);	/* core + 4*cluster */
+		exynos_write_pen_release(mpidr);	/* full MPIDR: stock platsmp.c:192 */
+	} else {
+		exynos_write_pen_release(core_id);
+	}
 
-	exynos_write_pen_release(core_id);
-
-	if (!exynos_cpu_power_state(core_id)) {
-		exynos_cpu_power_up(core_id);
+	if (!exynos_cpu_power_state(pmu_idx)) {
+		if (soc_is_exynos5433())
+			pmu_raw_writel(exynos5433_core_pwr_en(),
+				EXYNOS_ARM_CORE_CONFIGURATION(pmu_idx));
+		else
+			exynos_cpu_power_up(pmu_idx);
 		timeout = 10;
 
 		/* wait max 10 ms until cpu1 is on */
-		while (exynos_cpu_power_state(core_id)
+		while (exynos_cpu_power_state(pmu_idx)
 		       != S5P_CORE_LOCAL_PWR_EN) {
@@
-		if (soc_is_exynos3250())
+		if (soc_is_exynos3250() || soc_is_exynos5433())
 			dsb_sev();
 		else
 			arch_send_wakeup_ipi_mask(cpumask_of(cpu));
```

Notes on hunk C:

* `exynos_cpu_power_state(pmu_idx)` reads
  `EXYNOS_ARM_CORE_STATUS(pmu_idx)` (`platsmp.c:129-133`), i.e. PMU
  0x105C2004 + 0x80·pmu_idx — exactly the stock register
  (`pmu-exynos5433.c:154`). The status compare against
  `S5P_CORE_LOCAL_PWR_EN` (0x3, `platsmp.c:346`) still terminates when 0xF
  was written, because the read is masked with 0x3 (`platsmp.c:131-132`).
* The direct `pmu_raw_writel(0xF, CONFIGURATION)` replaces
  `exynos_cpu_power_up()` only for 5433 to avoid touching the shared
  helper used by hotplug paths of other SoCs.
* The stock per-core FEEDBACK/DURATION block
  (`pmu-exynos5433.c:99-123`) is deliberately **not** ported (see OQ-5).

**Hunk D — `src/linux-6.12/arch/arm/mach-exynos/headsmp.S`**
(holding-pen mask; value from stock
`src/kernel_universal5433/arch/arm/mach-exynos/headsmp.S:16,27`):

```asm
 ENTRY(exynos4_secondary_startup)
 ARM_BE8(setend	be)
 	mrc	p15, 0, r0, c0, c0, 5
-	and	r0, r0, #15
+	and	r0, r0, #0xffffff	@ keep Aff1: matches pen values
```

Safe for other Exynos SoCs: single-cluster machines have MPIDR ≤ 0x3, so a
0xFFFFFF-masked key equals the old #15 key; the stock kernel shipped this
mask for every SoC (stock `headsmp.S:16,27`), and the only pen writer that
produces values above 0x3 is the new 5433 branch of hunk C. (`MPIDR_HWID_BITMASK`
0xFFFFFF is the stock constant, stock `headsmp.S:16` /
`arch/arm/include/asm/cputype.h:33`.)

### 5.3 Deliberately left out

* Hotplug/C2 (`cpu_die`, boot flags, SMC_CMD_SHUTDOWN/SAVE) — §4 rows 10/12.
* Cluster/L2 power-up (`exynos5433_l2_up` port; L2 stride fix in
  `exynos-regs-pmu.h`) — not needed for a first core on the boot cluster;
  required before bringing up an A57 (§7 OQ-3).
* `suspend.c`/`exynos5433_pmu_init()` equivalents (the stock pre-SMP
  sequencer setup, §1.5) — deferred; minimal diff keeps only what the boot
  path needs.
* cpufreq, PSCI, MCPM — out of scope.

---

## 6. Risks and cheapest-first diagnostics

Failure modes of a first SMP test, in the order a broken piece would bite:

1. **NULL `pmu_base_addr` data abort** at the first
   `exynos_cpu_power_state()` (`platsmp.c:340` → `common.h:168-171`).
   Symptom: oops at virtual address ≈ 0x2004 during `smp_init`, panic via
   `panic=5` (`exynos5433-gts28ltexx.dts:35`). Fix = hunk B; if you see
   this, the DT/compatible plumbing is wrong.
2. **Wrong core powered** — if the flat-index conversion is wrong, the
   kernel writes CONFIGURATION of a *running* core (PMU 0x105C2000 vs
   0x105C2200 differ only in the 4·cluster term): powering down/re-upping
   CPU0 underneath itself hangs the board with no console output. This is
   the scariest silent failure; double-check `pmu_idx` against MPIDR before
   first boot (one A53 target = MPIDR 0x101 → pmu_idx 5 → 0x105C2280).
3. **Power pattern too weak** — writing 0x3 (unpatched path) instead of
   0xF: PMU may not assert core reset release; symptom is the 10 ms
   `power_state` timeout → "cpu1 power enable failed" (`platsmp.c:354`),
   −ETIMEDOUT. Non-fatal.
4. **Boot address not consumed** — −ENODEV from `exynos_set_boot_addr`
   (`platsmp.c:377-378`) means sysram-ns/firmware nodes missing or
   mismatched compatibles (§5.1). Non-fatal (boot_secondary just fails).
5. **Core wakes but never leaves the pen** — SEV didn't reach it (parking
   detail of the sboot stub, OQ-6) or pen key mismatch (hunk D vs hunk C
   values). Symptom: 1 s timeout loop, `ret = -ETIMEDOUT`
   (`platsmp.c:393-394`), board stays alive. Diagnostic: dump
   0x0207B01C..0x1F before/after (devmem2-equivalent) to confirm the
   address was written.
6. **Cluster-level power events on A57** — bringing up an A57 when the
   EAGLE cluster is off may need PMU-sequencer state that mainline never
   initializes (§1.5, OQ-3). Possible hang or L2 fault. This is why A57 is
   phase 2.
7. **Later footguns**: `exynos_cpu_die` path on 5433 (IPI-less WFI +
   Aff0-only pen compare, `platsmp.c:422-441`, pen compare at :61) will not
   survive an offline/online cycle until ported — do **not** offline
   secondaries in the first sessions; and the `pm_state` sysram compare in
   the 5420 resume path is irrelevant here.

Cheapest diagnostic order (matches "one A53 secondary first, A57 later"):

1. Boot patched kernel with `nosmp` **removed** but secondaries capped:
   `maxcpus=1` — verifies the PMU map (hunk B) without running the boot
   path (no abort = mapping good).
2. `maxcpus=2`: only logical cpu1 (an A53, same KFC cluster as the boot
   CPU — MPIDR 0x100/0x101 per §1.1) comes up. No cluster power-up
   involved; exercises hunks A/C/D + DT in one step. Watch for
   `Brought up 2 CPUs` vs the §6.1-6.5 symptoms; `ramoops` is already
   reserved (`exynos5433-gts28ltexx.dts:60-67`) so a panic is readable
   post-mortem.
3. `maxcpus=4` (all A53), then full boot (A57 last). Stop at the first
   divergence; A57 failures implicate OQ-3 (cluster/L2), not the core path.
4. Only after all 8 come up: attempt one `echo 0 > …/cpu7/online` cycle to
   size the hotplug gap — expect failure (§4 row 12); do not ship hotplug
   until row 10/12 gaps are ported.

---

## 7. Open questions

* **OQ-1 — SOC id:** stock gates 5433 code on `soc_is_exynos5433()` with
  `EXYNOS5433_SOC_ID 0xE5433000` / mask 0xFFFFF000
  (`src/kernel_universal5433/arch/arm/plat-samsung/include/plat/cpu.h:55,57,79`),
  read from the chipid block. Unverified on live hardware: if the chipid
  register didn't return a 0xE5433xxx value, hunk A's `soc_is_exynos5433()`
  would silently disable the whole patch. Fallback if it misbehaves: gate on
  `of_machine_is_compatible("samsung,exynos5433")` (pattern already used by
  the local mods, `src/linux-6.12/arch/arm/mach-exynos/exynos.c:202`,
  `suspend.c:687`; compatible in `dt_compat`, `exynos.c:239`).
* **OQ-2 — sysram addresses:** the secure sysram (0x02020000) and
  sysram-ns (0x0207B000) physical bases appear only in stock source
  (`map.h:38,44`, iodesc `common.c:680-688`) — neither the live FDT nor any
  mainline 5433 dts declares these regions (the live FDT's only node in
  that window is the firmware node, `dumps/live_fdt.dts:1583-1586`). The
  patch derives sysram-ns = firmware-node address (same window, stock maps
  both names to it); the secure sysram is simply not declared. Confirm
  against sboot docs/strings before adding more.
* **OQ-3 — cluster/L2 power for A57:** stock never calls `exynos5433_l2_up`
  on 5433 (no in-tree caller; `pmu-exynos5433.c:228-240`), implying the PMU
  sequencer (UP_SCHEDULER, :501-503) or sboot handles cluster power. The
  exact trigger conditions are unknown; until understood, A57 bring-up may
  need an explicit L2/COMMON write or may work as-is.
* **OQ-4 — CPU1BOOT truly unused on 5433?** Stock skips it for 5433
  (`platsmp.c:221-226`) and mainline skips it for all Exynos5
  (`firmware.c:58-80`) — consistent, but neither is proof about the
  monitor; if SEV alone doesn't wake cores, an SMC_CMD_CPU1BOOT (−4,
  `smc.h:18`) variant is the next experiment.
* **OQ-5 — are the 0xF power pattern and the FEEDBACK/DURATION block
  mandatory?** The shipping defconfig enables
  `CONFIG_EXYNOS5433_CORE_FEEDBACK_CHECK_DISABLE`
  (`lineage_gts28ltexx_defconfig:430`) so the block always ran on the stock
  device; its register semantics (`(0x11 << 4)` fields,
  `pmu-exynos5433.c:99-123`) are undocumented in-tree. First test without
  it (as proposed); if power-up times out, port it.
* **OQ-6 — what do released cores execute before the kernel?** The stub
  that reads 0x0207B01C and jumps (and whether it sits in WFE until SEV) is
  in sboot/secure RAM and is **unknown**. The stock dsb_sev-only path
  (§2.3) is the evidence that WFE+SEV is the mechanism.
* **OQ-7 — CCI-400 coherency:** stock 5433 SMP code performs no explicit
  CCI port enable (grep of `arch/arm/mach-exynos/` finds none); 5420's MCPM
  handles CCI separately (`src/linux-6.12/arch/arm/mach-exynos/mcpm-exynos.c:213`
  matches 5420 only). Whether the monitor leaves the CCI ports enabled is
  unknown — relevant if A57 (cluster 0) bring-up faults on cache ops.
* **OQ-8 — boot CPU identity:** both DT generations list logical cpu0 as
  reg 0x100 (A53) (`exynos5433.dtsi:87-91`, stock dtsi :60-62,
  live FDT :4496-4497), but which physical core sboot actually releases
  the kernel on is unverified; if the kernel happens to run on an A57, the
  "A53 first" plan inverts (check `dmesg | grep -i 'CPU0: Cortex'` first).

---

## 8. Implemented (2026-10-28)

Build-tested only; not yet run on the device. "stock" = files of
`src/kernel_universal5433/arch/arm/mach-exynos/`; mainline paths are
relative to `src/linux-6.12/`.

### 8.1 What was implemented

| File | Change |
|---|---|
| `arch/arm/mach-exynos/common.h` | `EXYNOS5433_SOC_ID` 0xE5433000 / mask 0xFFFFF000 and `soc_is_exynos5433()` (stock `plat-samsung/include/plat/cpu.h:55,57,79,169-173`; same ID in mainline `drivers/soc/samsung/exynos-chipid.c:55`) |
| `arch/arm/mach-exynos/exynos.c` | `"samsung,exynos5433-pmu"` added to `exynos_dt_pmu_match` → `pmu_base_addr` mapped in `init_irq` (mapping only; the INFORM2/3 code is untouched) |
| `arch/arm/mach-exynos/platsmp.c` | Exynos5433 path, selected when the DT root is `samsung,exynos5433`; other SoCs run the unchanged code |
| `arch/arm/mach-exynos/firmware.c` | **no change needed** (see 8.2) |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-smp.dts` | boot1 + root `firmware@207b000` (`samsung,secure-firmware`, verbatim `dumps/live_fdt.dts:1583-1586`) + `&soc/smp-sram@207b000` (`samsung,exynos4210-sysram-ns`, same page: stock `map.h:44`) + `/chosen/bootargs` without `nosmp` |
| `arch/arm/configs/gts28ltexx_smp.config` | boot1 fragment without `nosmp`; nothing else (SMP=y, NR_CPUS=8 in the defconfig; HOTPLUG_CPU already selected by PM_SLEEP_SMP) |

Sequence (all in `platsmp.c`, each constant cited in the code):

* **prepare** (`exynos_smp_prepare_cpus()` → `exynos5433_smp_prepare_cpus()`;
  not called at all with `nosmp`, `arch/arm/kernel/smp.c` `smp_prepare_cpus()`
  needs `max_cpus > 0`):
  1. check chip ID (`soc_is_exynos5433()`) and `pmu_base_addr`;
  2. read-only dump of the 8 core blocks, cluster NONCPU/L2/CPUSEQ,
     UP_SCHEDULER, monitor boot address and the 8 boot-flag words
     (CPU part of stock `show_exynos_pmu()`, `pmu-exynos5433.c:412-439`);
  3. write the entry point `__pa(exynos4_secondary_startup)` once through
     the firmware op = sysram-ns + 0x1c (stock `platsmp.c:288-297`,
     `firmware.c:36-42`); failure (no firmware or no sysram-ns node) →
     SMP refused, kernel continues uniprocessor;
  4. CPU part of stock `exynos5433_pmu_init()` in stock order:
     NONCPU (cluster) OPTION 0x2408/0x2428 `&= ~SC_COUNTER, |= SC_FEEDBACK`
     (`exynos_use_feedback()` on `exynos_list_feed[0..1]`, `:252-266,31-32`);
     per-core OPTION `|= SC_COUNTER|SC_FEEDBACK|USE_SMPEN` and DURATION0
     `|= 0xF<<20`, SCALL = 1 (`exynos_core_option()`, `:338-357`); UP_SCHEDULER
     0x0120 `|= BIT(0)|BIT(1)` (`:500-503`).
* **boot_secondary**, per logical CPU (`exynos5433_boot_secondary()`), PMU
  index = Aff0 + 4·Aff1 (stock `pmu-exynos5433.c:97`):
  1. refuse if an earlier core failed, if the MPIDR is outside
     Aff0 ≤ 3 / Aff1 ≤ 1 / Aff2 = 0, or if the other-cluster core with the
     same Aff0 is powered but not online (pen collision guard, 8.2);
  2. rewrite the entry point (it must be valid before power-up, as in stock);
  3. pen := Aff0; if STATUS & 0xF ≠ 0xF: OPTION `&= ~0x2`, DURATION0-3
     bits [11:4] := 0x11, `wmb()`, CONFIGURATION `|= 0xF` (stock
     `exynos5433_cpu_up()` incl. the FEEDBACK_CHECK_DISABLE block,
     `:88-128`); poll STATUS & 0xF == 0xF, 10 × 1 ms (stock `platsmp.c:114-127`);
  4. release loop, ≤ 1 s: rewrite entry point, `dsb_sev()`, wait for pen
     == −1, `udelay(10)` (stock `platsmp.c:206-232`). No SMC
     (`SMC_CMD_CPU1BOOT` is not used on 5433, stock `:221-226`), no IPI;
  5. on any failure: pen := −1, no further core is started, the core's PMU
     registers are printed.
* **secondary_init** (on the new core): pen := −1, then clear the HOTPLUG
  boot flag (bit 2) at sysram-ns + 0x28 + 4·index (stock `platsmp.c:93` →
  `pmu-exynos5433.c:71-86`, reusing mainline `exynos_clear_boot_flag()`
  with the PMU index as slot number).
* **hot-unplug disabled** on 5433: `.cpu_can_disable` returns false (the
  mainline `exynos_cpu_die()` would power down PMU core Aff0, i.e. a core of
  the other cluster; the stock handshake, `hotplug.c:99-119`, is not
  ported). `/sys/devices/system/cpu/cpuN/online` is therefore absent.
  Other SoCs keep the arm32 default (`cpu != 0`).

Behaviour without the new DT nodes or with `nosmp`: with the boot1 DTB the
patched kernel prints the "cannot set the boot address … (-38)" error and
runs uniprocessor; with `nosmp` nothing of the above runs (only the PMU is
ioremapped, and with the smp DTB "Running under secure firmware." appears).

### 8.2 Corrections to §2-§7

1. **FEEDBACK_CHECK_DISABLE block (OQ-5) is not optional**: it is compiled
   into the shipped kernel. `dumps/stock/Image.stock` contains
   `exynos5433_cpu_up` at offset 0x1e330-0x1e3b8 (core index
   `(Aff0 + 4·Aff1) << 7` on base 0xFE182000 = S5P_VA_PMU + 0x2000, then
   `OPTION &= ~2`, four `bic #0xff0 / orr #0x110` on +0x10..+0x1c,
   `CONF |= 0xf`), `exynos5433_cpu_state` at 0x1e3fc (`(STATUS & 0xf) == 0xf`)
   and `exynos_set_cpu_boot_addr` at 0x1e2bc (`str r1, [ns_base, #0x1c]`).
   It is now ported, together with its preconditions from
   `exynos5433_pmu_init()` that §5 had left out (core OPTION/DURATION,
   cluster NONCPU option, UP_SCHEDULER).
2. **Power state check**: §5.2 relied on mainline's `& 0x3` compare; the
   port uses the stock `(STATUS & 0xF) == 0xF` (`pmu-exynos5433.c:154-157`).
3. **`clear_boot_flag()` clears only the given bit** (`tmp &= ~mode`,
   `pmu-exynos5433.c:83-85`), not the 0x1F mask (§2.3 step 6 was wrong;
   only `set_boot_flag()` clears `BOOT_MODE_MASK`).
4. **Enable-method / PSCI (§3.4 b)**: arm32 has no `"psci"` CPU method (no
   `CPU_METHOD_OF_DECLARE` for it); PSCI SMP ops come only from
   `psci_smp_available()` in `arch/arm/kernel/setup.c:1178-1182`, which
   needs `CONFIG_ARM_PSCI` (not set) and a psci node. Exynos has no CPU
   method either: its ops come from the machine descriptor. So the
   `enable-method` properties are irrelevant on arm32 and stay deleted;
   only the psci node deletion matters.
5. **No 5433 case in `cpu_boot_reg()`** (§5.2 hunk C): that fallback
   writes the *secure* sysram (0x02020000 + …), which the vendor kernel
   never used on 5433 (the firmware node always exists there). The port
   refuses SMP instead of falling back.
6. **Holding pen (§5.2 hunk D)**: `headsmp.S` was out of scope and is
   unchanged (`and r0, r0, #15`), so the pen holds Aff0. A collision
   needs two powered, not-yet-online cores with the same Aff0 at the
   same time; cores are started one at a time from power-off, and the
   twin guard plus "stop after the first failure" plus "pen := −1 on
   failure" cover the remaining cases (a pre-powered or late core).
7. **Boot CPU (OQ-8)**: stock `/proc/cpuinfo` lists processors 0-3 as
   part 0xd03 (A53) and 4-7 as 0xd07 (A57) (`dumps/cpuinfo.txt`),
   matching the DT order; the new log line prints the mainline boot MPIDR.
8. **Sboot command line**: the stock kernel starts all 8 cores
   (`dumps/dmesg.txt:382-391`), so sboot's own bootargs do not cap the
   CPU count.
9. `exynos.c` line numbers in §3 are pre-INFORM-patch; the match table is
   now at `exynos.c:141-153`.

### 8.3 First SMP boot: what to look for

Flash `zImage` + `exynos5433-gts28ltexx-smp.dtb` from
`out/mainline-smp/`. Expected on success, in order:

```
Samsung CPU ID: 0xe5433xxx
Running under secure firmware.
EXYNOS5433: SMP: chip ID 0xe5433xxx, boot CPU MPIDR 0x100
EXYNOS5433: before SMP setup: PMU core 0..7 (MPIDR …): CONF … STATUS … OPTION … DUR0-3 …
EXYNOS5433: before SMP setup: EAGLE/KFC NONCPU … L2 … CPUSEQ …
EXYNOS5433: before SMP setup: UP_SCHEDULER 0x…
EXYNOS5433: before SMP setup: monitor boot addr 0x…, boot flags …
EXYNOS5433: SMP: entry point 0x2…… at secure-firmware window + 0x1c, PMU core options set
smp: Bringing up secondary CPUs ...
EXYNOS5433: CPU1: MPIDR 0x101, PMU core 5 powered (STATUS 0x… -> 0x…f, N ms)
CPU1: thread -1, cpu 1, socket 1, mpidr 80000101
  … CPU2, CPU3 (PMU cores 6, 7) …
EXYNOS5433: CPU4: MPIDR 0x000, PMU core 0 powered (…)
CPU4: thread -1, cpu 0, socket 0, mpidr 80000000
CPU4: Spectre BHB: enabling loop workaround for all CPUs
  … CPU5-7 (PMU cores 1-3) …
smp: Brought up 1 node, 8 CPUs
SMP: Total of 8 processors activated (… BogoMIPS).
CPU: All CPU(s) started in SVC mode.   (or "… in HYP mode")
```

Record the "before SMP setup" dump in any case: it is the bootloader's PMU
and monitor state, needed for every follow-up decision.

Failure signatures (kernel stays up unless stated):

| Log | Meaning / next step |
|---|---|
| `SMP: chip ID is not an Exynos5433 …` | chip ID read wrong (check the `Samsung CPU ID` line) |
| `SMP: PMU not mapped …` | DT without `samsung,exynos5433-pmu` |
| `cannot set the boot address … (-38)` / `(-19)` | wrong DTB: firmware node (−ENOSYS) or sysram-ns node (−ENODEV) missing |
| `CPUn: core power already enabled` | the bootloader left that core on; it is still released, compare with the dump |
| `CPUn: not started: core MPIDR 0x… has the same holding-pen value …` | a twin core was left powered (see dump); that core is skipped |
| `CPUn: core power-up timed out` + `failed: PMU core …` | PMU did not report 0xF within 10 ms. If n ≥ 4 only: A57 cluster power (NONCPU/L2 state in the dump, OQ-3) |
| `CPUn: did not leave the holding pen within 1 s` | core powered but never reached `secondary_init`: monitor did not release it to our entry point (OQ-6; check boot flags / boot addr in dump) or it died between the monitor and the kernel (MMU on, coherency) |
| `CPUn: failed to boot: -110 / -16 / -5` | generic line after one of the above (−5: refused after an earlier failure) |
| `CPUn: failed to come online` | core left the pen but did not finish `secondary_start_kernel()` within 1 s (GIC/MCT local timer on that core) |
| hang or watchdog reset after `PMU core N powered` | core released but broke the system (coherency, cluster power). The ramoops console (`/sys/fs/pstore` on the next boot) holds the last lines; if N ≥ 4, fall back to the A53 cluster |
| `CPU: WARNING: CPU(s) started in wrong/inconsistent modes` | monitor enters secondaries in another mode than CPU0; informative |

### 8.4 Fallback

* A57 problems: add `maxcpus=4` to `CONFIG_CMDLINE` in
  `gts28ltexx_smp.config` and rebuild: CPUs 1-3 (A53, same cluster as the
  boot CPU) only. `maxcpus=2` starts one A53; `maxcpus=1` runs only the
  prepare step (dump + PMU option writes), no core is powered.
* Any problem: the same kernel with `nosmp` (or with the boot1 DTB,
  which makes the patch refuse SMP) boots uniprocessor as before.
* Next experiments if the A57 cluster fails: port the remaining cluster
  settings of `exynos5433_pmu_init()` (L2 OPTION, `:480-498`); for a core
  that never leaves the pen: the full-MPIDR pen of stock `headsmp.S:16,27`.

### 8.5 Left out

Hot-unplug and C2/cpuidle (boot-flag handshake, `SMC_CMD_SHUTDOWN`), the
rest of `exynos5433_pmu_init()` (system sleep, power domains, LPI mask),
cluster power-down, CCI handling (none in stock either), the secure
sysram 0x02020000.

---

*End of document. §1-§7 are the original analysis; §8 describes the
applied patch.*
