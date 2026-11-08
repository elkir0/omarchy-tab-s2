# CPU frequency scaling — SM-T715 (Exynos 5433), mainline 6.12 arm32

Paper study, 2026-10-30. **No device was touched and nothing was built.** No
kernel file changed; this document is the only file added. Every step below
waits for the owner's approval.

Why: Firefox renders on the CPU (SWGL) and feels slow, and both clusters stay
at the bootloader's 1.2 GHz.

**Added after the study, same day.** Debian's Chromium 150, in its own root,
rendered on the GPU and beat Firefox on the same tests: 56 against 40 frames/s on
the scrolling page, 21 against 1.9 on a page with effects, 0-4 % of clip frames
dropped against 34-45 %, with 11 % CPU busy against 41 %. Its JavaScript was
slower, about 1.7 times on one loop. The owner then tried it on real YouTube:
far smoother than Firefox, by eye, with no measurement. The gain figures of
section 10 are for Firefox. With Chromium the CPU clock matters mostly for
JavaScript, and the GPU clock may matter more for pages [I], so the kernel work
below is no longer what makes browsing usable.

**P0 ran the same day, from the rescue, read-only: results in section 9.** The DRAM
is confirmed at 825 MHz. The A57 ABB and EMA are not as stock, which blocks
everything above 1.2 GHz until decision D7.

**Stage 1 ran for the A53s on 2026-11-03, on a test kernel: results in section
9.** Every level from 400 MHz to 1.2 GHz passed, as did the storm and the
throttle. Screen off, the gain is small: 60-90 mW of 1.48 W.

Evidence tags, used wherever it matters:

* **[M]** measured on this tablet under mainline (today's figures or a saved
  on-device log);
* **[Ms]** measured on this tablet under the stock Samsung kernel (the stock
  boot logs);
* **[S]** read in source;
* **[I]** my inference. Not proven.

Path abbreviations:

* `stock/` = `src/kernel_universal5433/` (a LineageOS tree; the boot logs come
  from Samsung's own 3.10.9 binary, `boot-log:391`, so voltages below are taken
  from the logs and the source only explains them)
* `eagle.c`, `kfc.c` = `stock/drivers/cpufreq/exynos5433-{eagle,kfc}-cpufreq.c`
* `mp.c` = `stock/drivers/cpufreq/exynos-mp-cpufreq.c`
* `asv.h` = `stock/arch/arm/mach-exynos/include/mach/asv-exynos5433.h`
* `cal.c` = `stock/arch/arm/mach-exynos/asv-exynos5433_cal.c`
* `bus.c` = `stock/drivers/devfreq/exynos5433_bus.c`
* `s2mps13.c` = `stock/drivers/regulator/s2mps13.c`
* `stock-dts` = `stock/arch/arm/boot/dts/exynos5433.dtsi`; `stock-thermal` =
  `stock/drivers/thermal/exynos_thermal.c`; `tmu.h`, `cpufreq.h`, `map.h` =
  `stock/arch/arm/mach-exynos/include/mach/`
* `boot-log` = a private stock boot log (stock boot
  of this tablet from t = 0)
* `live_fdt` = `dumps/live_fdt.dts` (the running stock tree)
* `ml/` = `src/linux-modem-lli/` (the running kernel, branch `t715-modem`,
  commit `629753b47`)
* `clk.c`, `clk-cpu.c`, `clk-pll.c` = `ml/drivers/clk/samsung/clk-{exynos5433,cpu,pll}.c`
* `dt.c`, `platdev.c` = `ml/drivers/cpufreq/cpufreq-dt{,-platdev}.c`
* `soc-dtsi`, `tmu-dtsi` = `ml/arch/arm64/boot/dts/exynos/exynos5433{,-tmu}.dtsi`
* `board` = `ml/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts`

---

## 0. Verdict

**Worth doing, but only part of it.**

| item | verdict | why |
|---|---|---|
| Both clusters scale at or below 1.2 GHz, with CPU cooling | **do it** | Adds the throttle this kernel lacks, adds no heat, lowers the idle rails. It also measures how much Firefox gains before any overclock risk is taken |
| A57 cap **1.5 GHz** | **do it if the prechecks pass** | +25 % clock, the highest cluster bus clock below 1.9 GHz, and stock's own boot level. Estimated Firefox gain +14 to +22 % (section 10) |
| A57 cap 1.7 GHz | only if section 9 shows it pays | About twice today's dynamic power for +42 % clock, and a slower cluster bus than 1.5 GHz |
| A57 1.9 GHz as a daily cap | **no** | 6.4 W on four cores against stock's 3.5 W sustained budget. Short bursts at best |
| A53 1.3 GHz | **no** | +8 % clock for +18 % power, on the cluster whose sensor is stock's emergency sensor |
| DRAM, CCI, INT clocks | **do not touch** | Already at or within 3 % of stock's top level (section 6) |

Three findings change what was assumed:

1. **The rails already match stock.** `vdd_eagle` 1.0625 V and `vdd_kfc`
   1.1625 V [M] are exactly this chip's 1.2 GHz voltages (`boot-log:712,733`)
   [Ms]. The stock kernel reads the same rails from sboot before it changes
   anything (`boot-log:825-826`) [Ms]. What does not match is mainline's OPP
   table, which is 25-50 mV lower at 1.2 GHz (section 3).
2. **`mem0_pll` at 543 MHz is not the DRAM rate.** It is one of three fixed
   sources. The DRAM runs at 825 MHz, stock's top level: P0 read it (section 9).
3. **Do not enable `CONFIG_CPUFREQ_DT` on the current board file.** The SoC
   dtsi already gives every CPU an OPP table, and the board has no
   `cpu-supply`. In that state cpufreq-dt scales the clock and never touches
   the voltage, so the governor could take the A57s to 1.9 GHz at 1.0625 V
   [S, not tested]. Built in, that is a boot loop (section 2.3).

## 1. What THERMAL.md left open

`docs/hardware/THERMAL.md` section 8.1 kept cpufreq out for the reasons below.
All have an answer now.

| objection | answer |
|---|---|
| "The chip's ASV group is unknown" | Known. Table version 8, group 1 on ATLAS, APOLLO, G3D, MIF, INT and CAM0, printed by sboot at every boot: 67 identical prints in the boot logs (`boot-log:138-146`) [Ms], and the kernel's own table for every level (`boot-log:699-789`) [Ms]. The table version and fused flag were also read on the tablet: `0x33010008` (`image/cache/ondevice/2026-10-29-gpufreq/precheck.txt:13`) [M] |
| "Mainline OPP voltages are below the slowest groups" | True and worse than stated: below this chip too. So they are not used; a board table replaces them (section 3) |
| "Mainline has no 5433 ASV support" | Not needed. This is one tablet. A board OPP table from its own logged column does the job. It is unit-specific (risk 9) |
| "Stock programs ABB per level, mainline does not" | On this chip ABB does not change with level: 8 on the A57 at every level up to 1.9 GHz, bypass on the A53 at every level (`boot-log:705-722,725-743`) [Ms]. So no per-level code is needed, but the two registers have never been read (section 2.5, check P3) |
| "An envelope is not a stock table" | No envelope is needed. Every voltage here is this chip's own |
| Section 8.5: review the `active` trips | Reviewed in section 5: they must be replaced |

Two risks in THERMAL.md section 9 also close, for the CPU sensors:

* **Risk 1, trim source.** This chip's OTP is blank (`boot-log:678-697`) [Ms],
  so `cal_tmu_otp_read()` fails (`stock/drivers/thermal/cal_tmu.c:240-241`) and
  stock falls back to TRIMINFO (`stock/drivers/thermal/exynos_thermal.c:2117-2119`)
  [S]. That is the register mainline reads.
* **Risk 3, VPTAT mux.** Stock's CONTROL words on the CPU sensors are
  `0x10009803` (`boot-log:1752,1761,1779`) [Ms]: reference 16, gain 8, no mux
  value. Nothing there for mainline to miss.

## 2. What is needed

### 2.1 Kernel configuration

None of these is set today (the `CONFIG_` check of 2026-10-30 [M], and the
defconfig [S]).

| symbol | value | note |
|---|---|---|
| `CPU_FREQ` | y | `CPU_FREQ_STAT` too: `trans_table` is the proof of what ran |
| `CPUFREQ_DT` | **m** | selects `CPUFREQ_DT_PLATDEV` and `PM_OPP` (`ml/drivers/cpufreq/Kconfig:208-212`). A module, for the same reason as panfrost (section 8) |
| `CPU_FREQ_GOV_USERSPACE`, `_PERFORMANCE`, `_SCHEDUTIL` | y | tests pin with userspace, daily use is schedutil |
| `CPU_FREQ_DEFAULT_GOV_USERSPACE` | y, test kernels only | the driver then changes nothing at load |
| `CPU_THERMAL`, `CPU_FREQ_THERMAL` | y | the second defaults to y under the first (`ml/drivers/thermal/Kconfig:177-190`). The cooling device registers from cpufreq core (`ml/drivers/cpufreq/cpufreq.c:1587`, flag at `dt.c:162`) |
| `DETECT_HUNG_TASK`, `SOFTLOCKUP_DETECTOR` | y, test kernels only | the 2026-10-29 lesson (`docs/journal/ONDEVICE-2026-10-29.md:359-369`) |

Modem modules stay out of test kernels (section 8.4).

### 2.2 CPU clock: the safe sequence exists

**It is implemented for this SoC.** `exynos5433_cpuclk_pre_rate_change()` and
`_post_rate_change()` (`clk-cpu.c:323-404`) are wired to `CPUCLK_LAYOUT_E5433`
(`clk-cpu.c:624-628`) and both clusters use them (`clk.c:3762-3766,4006-4010`)
[S]. So the CPU path does not have the problem the G3D PLL has (GPU.md section
10.2): the core leaves the PLL before it relocks.

| step | stock | mainline |
|---|---|---|
| leave the PLL | `mout_egl` to the bus PLL, wait for status 2 (`eagle.c:265-273`) | mux bit 0, wait for status 2 (`clk-cpu.c:369-371`) |
| set dividers | before the rate rises, after it falls (`eagle.c:331-362`) | while on the alternate parent, either way (`clk-cpu.c:374-378`) |
| PLL lock time | `pdiv × 150` (`eagle.c:279`) | `pdiv × 270`, longer (`clk-pll.c:208,280`) |
| wait for lock | `eagle.c:290-293` | `clk-pll.c`, message "Could not lock PLL" on timeout (`:111`) |
| back to the PLL | `eagle.c:296-304` | `clk-cpu.c:397-401` |
| below the 800 MHz alternate | safe voltage of 800 MHz (`mp.c:359-382`) plus 800 MHz dividers (`eagle.c:261`) | a divider on the alternate, so the core never exceeds min(old, new) (`clk-cpu.c:357-366`); no safe voltage needed |
| only the S divider changes | direct write, no alternate (`eagle.c:332-339`) | still goes through the alternate, then an S-only write (`clk-pll.c:266`) |

The divider values are identical to stock at every level. A57:
`clk.c:3987-4003` against `eagle.c:109-123`. A53: `clk.c:3748-3759` against
`kfc.c:84-93` [S]. The PLL P/M/S values match stock at every level but one
(`clk.c:744-774` against `eagle.c:109-124`):

* **700 MHz differs**: mainline P = 3 (`clk.c:763`), stock P = 6
  (`eagle.c:121`, `kfc.c:90`). GPU.md section 10.2 flagged this entry. **Leave
  700 MHz out of the table.** Nothing is lost.

One gap, and it needs a check:

* Stock forces the alternate parent's input at init:
  `clk_set_parent(mout_bus_pll_user, mout_bus_pll_div2)` (`eagle.c:491`,
  `kfc.c:373`) [S]. Mainline does not, and TM2 sets nothing for it either.
  If sboot left `mout_bus_pll_{apollo,atlas}_user` on oscclk (`clk.c:3645,3858`),
  the core would idle through each relock at 24 MHz: slow, not unsafe [I].
  Check P4 reads it. The fix, if needed, is one `assigned-clock-parents`.

The 800 MHz figure is sound. Mainline's fixed factors say 1:1 where stock says
1:2 (`clk.c:1186-1189`, `stock/drivers/clk/samsung/clk-exynos5433.c:1361-1362`),
so a mainline rate can read high but not low. The live 800 MHz [M] and stock's
own 800 MHz safe level (`eagle.c:508`) agree [I].

### 2.3 cpufreq-dt on arm32 with two clusters

Nothing in the source blocks it. It has never been built or run here, and
TM2's arm64 board file is the only other user of this path in the tree.

* **Device creation.** 5433 is not in `platdev.c`'s allowlist (`:45-49`), but
  any board whose cpu0 has `operating-points-v2` gets the device unless
  blocklisted (`platdev.c:231`). The blocklist has no Samsung entry. The board
  inherits that property (`soc-dtsi:94`).
* **Two policies.** Each table is `opp-shared` (`soc-dtsi:240,286`), so cpu0-3
  and cpu4-7 become one policy each (`dt.c:217`).
* **Supply.** `cpu-supply` on cpu0 and cpu4 is enough, as on TM2
  (`exynos5433-tm2-common.dtsi:318-324`): cpu1-3 and cpu5-7 are covered by the
  shared table. BUCK3 is the A53, BUCK2 the A57 (`board:426-442`; stock:
  `regulator_get(NULL, "vdd_eagle")`, `"vdd_kfc"`, `mp.c:1929,1935`).
* **The trap.** `find_supply_name()` returns NULL with no `cpu-supply`
  (`dt.c:69-87`), `dev_pm_opp_set_regulators()` is then skipped (`dt.c:206-214`),
  and the OPP core changes only the clock. Every OPP of `soc-dtsi` is live, up
  to 1.9 GHz, on a rail nothing moves. **The `cpu-supply`, the replacement
  tables and `CPUFREQ_DT` must arrive together.**
* **Clocks.** Every CPU node has its cluster clock since `9497112f2`
  (`board:293-324`).
* **Scheduler.** When policies appear, arch_topology renormalises capacities
  to each policy's `cpuinfo.max_freq` (`ml/drivers/base/arch_topology.c:449-456`).
  With A53 1.2 GHz and A57 1.5 GHz the A53 capacity falls from 586 to about
  469 [I, arithmetic]. Frequency invariance is wired on arm32
  (`ml/arch/arm/include/asm/topology.h:13-16`).
* **Delays.** arm32 rescales `loops_per_jiffy` on transitions
  (`ml/arch/arm/kernel/smp.c:793-832`), but `udelay` uses the MCT here
  (`ml/drivers/clocksource/exynos_mct.c:250-252`), so delays do not depend on
  the CPU clock.
* **Rail limit.** BUCK2 and BUCK3 accept 0.6-1.5 V (`board:428-429,437-438`),
  as stock (`live_fdt:2491-2515`). A typo in a table could reach 1.5 V. Test
  boards should set `regulator-max-microvolt` to the highest OPP of the stage.

### 2.4 Order of voltage and frequency

The OPP core does what stock does: up, voltage then clock
(`ml/drivers/opp/core.c:1238-1271`; `mp.c:482-505,543`); down, clock then
voltage (`core.c:1267-1284`; `mp.c:543,570-599`) [S].

The ramp is safe. BUCK_RAMP1 reads `0x55` (`precheck.txt:3`) [M], so the BUCK2
field (bits 7:6, `s2mps13.c:141-143`) and the BUCK3 field (bits 5:4,
`s2mps13.c:145-147`) are both 1 = 12 mV/µs, the board's
`regulator-ramp-delay` (`board:432,441`). Mainline cannot program that field
(GPU.md section 10.7 risk 5), but it is already right. The largest step in the
proposed table is about 190 mV, or 16 µs [I, arithmetic].

### 2.5 What stock does that mainline will not

| feature | stock | this chip | needed here |
|---|---|---|---|
| A57 ABB (PMU + 0x0780) | written at each step (`mp.c:490-495`, `cal.c:21-22,484-495`) | 8 at all levels ≤ 1.9 GHz, so `0x80000088` | one read (P3). If it is not that value, one write at boot, as `t715-g3d-abb` does for the GPU. That branch is not in this tree |
| A53 ABB (PMU + 0x0784) | same | bypass at all levels, so 0 | one read (P3) |
| A57 EMA (SYSREG_EGL + 0x330) | at each step (`eagle.c:187-190`, `cal.c:505-516`) | fuses `0x33010008`: both EMA fields 3 (`cal.c:133-134`), so 3 at any voltage | one read (P3). The sources do not say what sboot leaves, or what EMA does |
| Cold offset | +37.5 mV under `TMU_COLD` (`mp.c:1038-1053`, `cpufreq.h:161,169`), ≤ 19 °C (`tmu.h:22`) | | see section 3.3 |
| MIF floor per CPU level | `bus_table` (`eagle.c:160-185`, `kfc.c:124-144`, `mp.c:531-555`) | | no: DRAM stays at the top |
| SMPL warning | throttles on a battery sag (`eagle.c:544-557`; `live_fdt:2339-2342`) | enabled | none in mainline: risk 6 |
| Reboot level | raises the rail first (`mp.c:1550-1586`) | | `opp-suspend` on the 1.2 GHz OPP: `device_shutdown()` calls `cpufreq_suspend()` (`ml/drivers/base/core.c:4924`), which sets that OPP (`cpufreq.c:1924-1943`, `dt.c:119,173`) |
| Hotplug, IPA | `live_fdt:1790-1813`, `stock-dts:2016-2017` | | no: passive trips instead (section 5) |

## 3. Voltages

### 3.1 The rails today

| rail | live [M] | stock at hand-over [Ms] | this chip's table [Ms] | meaning |
|---|---|---|---|---|
| vdd_eagle | 1.0625 V | 1062 mV (`boot-log:825`) | 1.2 GHz: 1 062 500 (`:712`) | A57 at 1.2 GHz |
| vdd_kfc | 1.1625 V | 1162 mV (`:826`) | 1.2 GHz: 1 162 500 (`:733`) | A53 at 1.2 GHz |
| vdd_mif | 1.0125 V | 1012 mV (`:824`) | 825 MHz: 1 012 500 (`:755`) | **the top DRAM level** |
| vdd_int | 0.975 V | 975 mV (`:827`) | 400 MHz: 975 000 (`:746`) | the top INT level |
| vdd_g3d | 0.9375 V | 937 mV (`:829`) | 420 MHz: 937 500 (`:773`) | GPU at 266 MHz, known (GPU.md) |

So **there is no mismatch**. sboot programs this chip's ASV values itself [I]:
`pmic_asv_init` prints the groups first (`boot-log:137-146`), and mainline
inherits the result. The numbers that do differ are mainline's OPPs and stock's
fallback table (`eagle.c:132-157`, `kfc.c:101-121`), which stock uses only when
ASV has no answer (`eagle.c:377-381`). Mainline's table is nearly that fallback.

### 3.2 This chip against mainline

Stock column: `boot-log:699-743`, group 1, confirmed in every stock boot log
that prints it (14 and 16 identical copies of the rows checked) [Ms]. Mainline
column: `soc-dtsi:238-348` [S]. All values in µV.

| MHz | A57 this chip | A57 mainline | diff | A53 this chip | A53 mainline | diff |
|---|---|---|---|---|---|---|
| 1900 | 1 300 000 | 1 262 500 | −37 500 | | | |
| 1800 | 1 262 500 | 1 212 500 | −50 000 | | | |
| 1700 | 1 225 000 | 1 175 000 | −50 000 | | | |
| 1600 | 1 175 000 | 1 137 500 | −37 500 | | | |
| 1500 | 1 137 500 | 1 125 000 | −12 500 | | | |
| 1400 | 1 112 500 | 1 087 500 | −25 000 | | | |
| 1300 | 1 087 500 | 1 062 500 | −25 000 | 1 212 500 | 1 150 000 | −62 500 |
| 1200 | 1 062 500 | 1 037 500 | −25 000 | 1 162 500 | 1 112 500 | −50 000 |
| 1100 | 1 037 500 | 1 012 500 | −25 000 | 1 125 000 | 1 112 500 | −12 500 |
| 1000 | 1 012 500 | 975 000 | −37 500 | 1 087 500 | 1 075 000 | −12 500 |
| 900 | 1 012 500 | 937 500 | −75 000 | 1 025 000 | 1 050 000 | +25 000 |
| 800 | 987 500 | 912 500 | −75 000 | 1 000 000 | 1 000 000 | 0 |
| 700 | 962 500 | 912 500 | −50 000 | 962 500 | 975 000 | +12 500 |
| 600 | | | | 937 500 | 950 000 | +12 500 |
| 500 | | | | 912 500 | 925 000 | +12 500 |
| 400 | | | | 875 000 | 900 000 | +25 000 |

Loading mainline's table would take the A57s to 1.0375 V and the A53s to
1.1125 V **at today's frequency**, and it is under stock by up to 75 mV. Group
1 is near the slow end of 16 groups, which is why [I].

Notes:

* The logged A57 values at 700, 800 and 900 MHz are 25 mV above the v3 table
  (`asv.h:713-715`). That is `CONFIG_EXYNOS5433_ASV_NEON_WORKAROUND` (`cal.c:346-352`,
  on in `stock/arch/arm/configs/lineage_gts28ltexx_defconfig:431`). The log is the
  authority, and the point stands: NEON is the sensitive path at those levels.
* Stock's floors are 700 MHz on the A57 (`eagle.c:420`, `boot-log:1892`) and
  400 MHz on the A53 (`kfc.c:311`, `boot-log:1842`).
* All values sit on the BUCK2/BUCK3 grid: 6.25 mV steps from 500 mV at selector
  0x10 (`ml/drivers/regulator/s2mps11.c:607-608`). Mainline reads the same
  voltages sboot left, so the base is right, as for BUCK6 [M].

### 3.3 Margin

Stock's table has no margin to spare at a given temperature; stock adds 37.5 mV
when cold. Mainline has no cold signal, and it may differ from stock in ABB and
EMA until those are read. A voltage that is too low means silent corruption, so
for the qualification:

| range | proposed | reason |
|---|---|---|
| ≤ 1.2 GHz | this chip's stock value | The 1.2 GHz pair has run daily since 2026-10-28 [M]. A higher rail there would add heat for nothing |
| > 1.2 GHz | stock value **+ 37 500 µV** | A voltage stock itself writes on this chip when cold (`mp.c:149-163`), below its 1.35 V limit (`cpufreq.h:169`). Same reasoning as the GPU table (GPU.md section 10.3). Cost: about 7 % dynamic power |

Once a level has soaked, the owner may drop to the plain stock value (decision
D3). **No undervolting and no search for the minimum voltage.** A cold start
(hottest sensor at or below 19 °C) has never been measured; the sensors idle at 43-45
°C (THERMAL.md), so it is not expected in normal use.

### 3.4 Reading the fuses, read-only

Already known: `0x1000400C` and `0x10004004` were read on the tablet
(`precheck.txt:13-14`) [M]. That read used a Python `mmap` of `/dev/mem`, opened
`O_RDONLY` with `PROT_READ` (`image/tests/ondevice/gpufreq.sh:55-57`), which
cannot write. The same reader covers P1 below. Addresses: CHIPID2 =
`0x10004000` (`map.h:76`), PMU = `0x105C0000` (`map.h:79`). Field layout: `cal.c:30-36,103-115,133-136,518-524`.

## 4. Levels and caps

Stock's maximum on this chip is **A57 1.9 GHz, A53 1.3 GHz** (`boot-log:1841,1891`)
[Ms]: table version 8 takes the default branch (`eagle.c:406-411`), it is not a
limited sample (no "ATL max frequency limited" in any log, `cal.c:518-524`), and
the A53 is fixed in code (`kfc.c:310`).

A57, stock voltages unless noted. ACLK is the clock of the cluster's bridge to
the CCI (`aclk_asyncaces_atlas_cci`, parent `div_aclk_atlas`, `clk.c:3936-3937`;
dividers `clk.c:3987-3997`) [S]. The mW column is stock's own estimate for this
chip, printed at boot: dynamic only, one core loaded (`boot-log:2686-2693`,
`mp.c:643-711`) [Ms].

| GHz | clock | V | ACLK MHz | V²f vs 1.2 | V²f with +37.5 mV | mW/core | 3 cores W | 4 cores W |
|---|---|---|---|---|---|---|---|---|
| 1.2 | | 1.0625 | **300** (÷4) | 1.00 | 1.00 | 672 | 2.0 | 2.7 |
| 1.3 | +8 % | 1.0875 | 325 (÷4) | 1.13 | 1.21 | 756 | 2.3 | 3.0 |
| 1.4 | +17 % | 1.1125 | 350 (÷4) | 1.28 | 1.37 | 860 | 2.6 | 3.4 |
| **1.5** | **+25 %** | 1.1375 | **375 (÷4)** | **1.43** | **1.53** | 955 | 2.9 | 3.8 |
| 1.6 | +33 % | 1.175 | 320 (÷5) | 1.63 | 1.74 | 1093 | 3.3 | 4.4 |
| 1.7 | +42 % | 1.225 | 340 (÷5) | 1.88 | 2.00 | 1262 | 3.8 | 5.0 |
| 1.8 | +50 % | 1.2625 | 360 (÷5) | 2.12 | 2.25 | 1425 | 4.3 | 5.7 |
| 1.9 | +58 % | 1.300 | 380 (÷5) | 2.37 | 2.51 | 1602 | 4.8 | 6.4 |

Why 1.5 GHz is the natural stop:

* **The ACLK divider changes between 1.5 and 1.6 GHz.** At 1.6 GHz the core
  gains 7 % over 1.5 GHz and the bridge to memory loses 15 %. 1.7 GHz is still
  9 % below 1.5 GHz on that bridge. Memory-bound work, and SWGL is partly that,
  may gain little or nothing past 1.5 GHz [I]. The port width is not in the
  sources, so the size of the effect is not known. **Skip 1.6 GHz as a cap.**
* **It fits the budget.** Firefox at 250-350 % CPU [M], if 300 % of that sits
  on the A57s, is about 2.9 W at 1.5 GHz, under stock's sustained 3.5 W (`tdp`,
  `boot-log:2399`) [Ms]. At 1.7 GHz it is 3.8 W, over it [I].
* **Stock uses it.** It is the A57 boot level (`eagle.c:513`) and the 90 °C
  throttle level (`stock-dts:2065-2069`).

Staged proposal:

| stage | A57 max | A53 max | condition |
|---|---|---|---|
| 1 | 1.2 GHz | 1.2 GHz | P0 passed |
| 2a | 1.4 GHz | 1.2 GHz | stage 1 passed; margin in the table |
| 2b | 1.5 GHz | 1.2 GHz | 2a passed |
| 3 | 1.7 GHz | 1.2 GHz | only if the stage 2 measurements show the gain is worth twice the power |
| 4 | 1.9 GHz | 1.2 GHz | not recommended as a cap; at most a short-burst experiment |

**Both clusters scale, only the A57s rise.** The A53s stay at 1.2 GHz at most:
1.3 GHz needs 50 mV more for 8 % more clock, and the threads that limit Firefox
belong on the A57s (check S0.3). The A53s still gain from the lower levels,
because their rail is the highest on the chip (1.1625 V against 0.875 V at 400
MHz).

Tables for the board, **in the device tree**, so that no OPP above the approved
cap exists at all. A udev rule or a service would act too late, and the kernel
is shared with the rescue (GPU.md section 10.11).

| cluster | OPPs (MHz) at stage 2b | suspend OPP |
|---|---|---|
| A57 | 800, 900, 1000, 1100, 1200, 1300, 1400, 1500 | 1200 |
| A53 | 400, 500, 600, 800, 900, 1000, 1100, 1200 | 1200 |

700 MHz is left out on both (section 2.2). Both tables replace
`operating-points-v2` on all eight CPU nodes.

## 5. Thermal

**CPU cooling goes in at stage 1, before anything exceeds 1.2 GHz.** Today the
only protection is the 115 °C trip (THERMAL.md section 4).

### 5.1 Stock's throttling

Table (`stock-dts:2054-2085`, `live_fdt:4297-4334`) [S]:

| sensor max | A57 cap | A53 cap |
|---|---|---|
| 80, 85 °C | 1.7 GHz | 1.3 GHz |
| 90 °C | 1.5 GHz | 1.3 GHz |
| 95 °C | 0.9 GHz | 1.0 GHz |
| 100, 110 °C | 0.8 GHz | 0.4 GHz |

On top of it [S]:

* **IPA** (`CONFIG_CPU_THERMAL_IPA`): control temperature **81 °C**, TDP 3.5 W
  (`live_fdt:1790-1813`, `boot-log:2396-2417`). This is what acts in practice.
  At the caps proposed here, the 80-90 °C rows above cap nothing, so 81 °C is
  the first number that matters.
* **The A53 sensor is the emergency sensor.** Above 80 °C stock treats the
  maximum as 98 °C, above 85 °C as 112 °C (`stock-thermal:991-1000`), which
  selects the 95 °C and 110 °C rows. So a 1.5 GHz cap stock would keep is cut to
  0.9 GHz the moment the A53 sensor passes 80 °C.
* A57 hotplug at 100/95 °C (`stock-dts:2016-2017`).

### 5.2 Mainline's inherited maps must go

`tmu-dtsi` is not usable as it stands [S]:

* It has seven `active` trips from 65 °C (`:17-51`), and states numbered for 15
  OPPs from 1.9 GHz (`:54-97`). With an 8-OPP table capped at 1.5 GHz, 65 °C
  would already take 200 MHz off, 15 °C earlier than stock's first step.
* **`atlas1` has no cooling-maps at all** (`:100-142`), though it is the second
  A57 sensor. Only `atlas0` (`:54`) and `apollo` (`:228`) have them.
* Each zone cools only its own cluster, while stock cools both from the hottest
  sensor.

The board should delete those maps and add these, with stock's 2 °C hysteresis
(`live_fdt:4246`). Zones already poll at 100 ms passive, 500 ms idle
(`exynos5433-gts28ltexx-thermal.dtsi`).

| zone | trip | A57 | A53 | stock source |
|---|---|---|---|---|
| atlas0, atlas1 | 81 °C passive | step down to 1.2 GHz | | IPA control temperature |
| atlas0, atlas1 | 95 °C passive | ≤ 0.9 GHz | ≤ 1.0 GHz | row 95 °C |
| atlas0, atlas1 | 100 °C passive | 0.8 GHz | 0.4 GHz | row 100 °C |
| apollo | 81 °C passive | ≤ 0.9 GHz | ≤ 1.0 GHz | `stock-thermal:992-996` |
| apollo | 86 °C (existing hot) | 0.8 GHz | 0.4 GHz | `stock-thermal:997-1000` |
| all | 115 °C critical | unchanged | | THERMAL.md |

`step_wise` walks the 81 °C range one state per poll, a rough stand-in for IPA.
The states depend on the OPP count, so the maps change at each stage (GPU.md
section 10.7, risk 9). `power_allocator` could replace it later; stock's
coefficients do not map onto mainline's units, so not now.

### 5.3 Can the sensors be trusted?

| check | status |
|---|---|
| Same calibration source as stock | **yes** for this chip (section 1), 2-point (THERMAL.md, first boot) [M] |
| Same conversion | yes: both 25/85 °C two-point (`stock/drivers/thermal/cal_tmu.c:210-212`, `ml/drivers/thermal/samsung/exynos_tmu.c:206-214`) [S] |
| Sensors move with load | yes: 43-45 °C idle, 48-51 °C after a browser load [M] |
| Absolute agreement with stock | **not established.** Mainline idles at 43-45 °C, stock at 32-37 °C (THERMAL.md section 5). That gap has a physical explanation (all rails at the top, no cpuidle, no DVFS) [I], but it is not proof |
| Hardware trip at 115 °C on this board | **never tested** (THERMAL.md, first boot) |
| G3D and ISP sensors | disabled, nonsense readings. A second candidate for G3D beside GPU.md's power-domain hypothesis: stock's G3D word is `0x17609803` (`boot-log:1770`), with a mux value mainline never sets [I] |

A cheap cross-check needs no new kernel. **sboot prints all five sensors at
every boot** (`[TMU] 47, 47, 49, 47, 47`, `boot-log:210`) and whether a trip
was seen ("Not Detected TRIP", `:212`) [Ms]. Read the zones, `systemctl reboot`,
then compare with sboot's line. That compares mainline's conversion with an
independent one (S0.4). The sensor order in that line is not in the sources.

### 5.4 The first limit is probably not the die

The die has room: 50 °C against 81 °C. **The inside of the tablet does not.**

* The gauge reads 46-51 °C after a browser load, and 44-48 °C at idle with a
  case that does not feel warm [M] (`docs/hardware/MODEM.md:171-173`). That is
  the gauge's own sensor. The battery thermistor sits behind the Exynos ADC,
  which is not enabled (`MODEM.md:170-171`).
* The CP refuses to start at 55.0 °C, and its prepare service waits below 54.0
  °C (`MODEM.md:167-175`). So a warm reboot may hold the modem back.
* Stock's battery limits were 55 °C, recovery 50 °C, with thermal source 2
  (`boot-log:2480-2482`) [Ms], the ADC thermistor
  (`stock/include/linux/battery/sec_charging_common.h:240-244`) [S], so not
  directly comparable with the gauge.

That leaves a few degrees of margin at the gauge, not tens, and no kernel
mechanism acts on it. The gauge's zone has no trips.

**Proposal:** a small service, in place before any cap above 1.2 GHz is
daily: gauge ≥ 52 °C sets `scaling_max_freq` to 1.2 GHz on policy4, released at
49 °C. These numbers are mine: 3 °C under the modem's prepare gate. It is a
comfort limit, not a safety net, so it may live in userspace (decision D6).

### 5.5 The modem

CP heat is not measured. MODEM.md section 6.8 shows no CPU, memory or GPU cost
from the modem, but it has no temperature column. Stock's thermal path has no
equivalent here for the CP. So the combined case, Firefox on LTE at a raised
cap, is tested last (stage 5), on a kernel that has already soaked.

## 6. Is the CPU clock really the limit?

**Yes, as far as the sources go.** Memory and bus clocks are not the bottleneck
relative to stock: they sit at or near stock's top level, and they stay there.

### 6.1 DRAM

`mem0_pll` at 543 MHz does not mean 543 MHz DRAM. Stock's MIF level is chosen by
`DREX_FREQ_CTRL0` (`bus.c:2244-2295`, written at `:2966-2969`; register name
`clk.c:1053`), which selects a **divider and one of three sources**. The PLLs
never change [S]. Which bit picks which source is my reading [I]; the arithmetic
fits every level, including the 633-based 206 and 165 (the comments at
`bus.c:2603-2604` say 211 and 158, which is 633 ÷ 3 and ÷ 4):

| source | levels (MHz) |
|---|---|
| `mem1_pll` 1650, ÷2 | **825**, 413 |
| `mfc_pll` path | 633 (called 667 in the OPP list), 206, 165 |
| `mem0_pll` 543 | 543, 275, 138, 103, 78 |

So seeing `fout_mem0_pll` = 543 and `fout_mem1_pll` = 1650 [M] is what every
level looks like. Evidence for 825 MHz at hand-over:

| evidence | tag |
|---|---|
| `vdd_mif` = 1.0125 V, the 825 MHz voltage; 667 MHz would be 0.9375 V, 543 MHz 0.875 V (`boot-log:755-757`) | [M] + [Ms] |
| Stock reads the DLL state as on before any MIF change (`boot-log:2422`, `bus.c:4187-4188`), and "only MIF_LV0 use DLL tacing mode" (`bus.c:3622`) | [Ms] + [S] |
| Stock's devfreq starts from 825 000 (`stock/drivers/devfreq/exynos5_bus_mif.c:32`) | [S] |
| Mainline has no MIF driver and writes none of this | [S] |

**Read on 2026-10-30 [M]:** `DREX_FREQ_CTRL0` = `0x00100100`, stock's 825 MHz
pattern (section 9). This kernel's clk_summary has no `clk2x_phy` line, so the
register is the evidence.

825 MHz is the memory clock, so 1650 MT/s: the MR2 values for levels 825, 633
and 543 (`stock/drivers/devfreq/dram_timing_parameter.h:30,43-45`) decode to
RL14, RL10 and RL9, the right latencies for those clocks, not half of them [I,
the command encoding and the JEDEC table are from memory]. Two channels (DREX0, DREX1,
`bus.c:4116-4117`) of 32 bits (`bus.c:2943`) give a 13.2 GB/s peak [I]. The
3.9 GB/s `dd` figure says little: its method is not recorded in the repository
(`MODEM.md` section 6.8), and it depends on block size and cache.

Stock's requests for reference: A57 1.2 GHz wants ≥ 543, 1.4-1.7 GHz ≥ 667, 1.8
GHz and up 825 (`eagle.c:160-185`); A53 at 1.2 GHz ≥ 667 (`kfc.c:133`). At 825
MHz all are met at every proposed level.

### 6.2 CCI and INT

| clock | live | stock | position |
|---|---|---|---|
| `aclk_cci` | 400 MHz [M] | child of `aclk_mif_400` (`clk.c:1461`, stock `clk-exynos5433.c:2349`): 413 MHz at MIF LV0, 275 at LV1-2, down to 138 (`bus.c:2315-2326`) | 3 % under the top |
| INT | rail at the 400 MHz voltage [M] | top level 400 MHz (`boot-log:746`) | top |
| A57 to CCI bridge | **300 MHz** (1200 ÷ 4) [I] | scales with the core | **the one that rises with cpufreq** |

400 MHz is reachable only from the bus PLL (800 ÷ 2), not from `mem1` (825 ÷ 2 =
413), so sboot left the CCI on the bus PLL, where stock's first MIF change moves
it (`bus.c:2298`) [I]. The 3 % is not worth a clock change on a live fabric.

The narrowest clock on the A57's way to memory today is its own bridge. That is
one more reason a modest raise helps, and a reason to stop at 1.5 GHz.

### 6.3 Touching them

**Not sane.** A MIF change takes DREX timing sets, a PHY DLL sequence, mode
register writes, a hardware pause and voltage steps (`bus.c:2966-3021,3613-3690`).
The modem's LLI link takes its clock from this block (`boot-log:1249`), and the
CP uses DRAM through it (`MODEM.md`).
A mistake loses the RAM the running kernel is in. There is nothing to gain above
the top level. The one reason to do it is idle power, which is a separate,
larger project (section 7).

### 6.4 The evidence that the CPU limits Firefox

* WebRender moved to the CPU took the video from 7-9 to 57-62 panel frames/s,
  at about 2.6 of 8 cores (`docs/journal/ONDEVICE-2026-10-29.md:187-198`) [M].
* The heavy threads are the main thread and "Renderer"
  (`docs/journal/ONDEVICE-2026-10-28.md:138-140`) [M].
* Scrolling: 38-54 frames/s; clips drop 31-45 % (`MODEM.md` section 6.8) [M].

250-350 % on an 8-core machine means the cores are not all busy. The limit is
the speed of one or two threads, which only clock speed helps [I].

Other levers exist and are cheaper. On 2026-10-28 a lower content resolution was
already noted. A 1.25 scale removes 36 % of the pixels, which beats any CPU
level proposed here [I, arithmetic]. It is outside this study, but it should be
tried first.

## 7. Power and battery

Stock's model is dynamic power only (`ps = 0`, `mp.c:704-708`): V²f with a
per-core coefficient of 48 on the A57 and 9 on the A53 (`mp.c:51-52`), so the
table in section 4 and the V²f ratios are the same model.

| case | CPU power vs today | basis |
|---|---|---|
| Firefox on 3 A57s, 1.5 GHz | +0.9 W (2.0 to 2.9 W), +1.1 W with margin | section 4 [I] |
| Firefox on 3 A57s, 1.7 GHz | +1.8 W | section 4 [I] |
| Firefox on 3 A57s, 1.9 GHz | +2.8 W | section 4 [I] |
| Four A53s at 1.2 GHz | 0.6 W (150 mW/core, `boot-log:2676`) | [Ms] |
| Idle and light load | **lower**, by an unknown amount | [I] |

Leakage is not modelled, and it rises with temperature and voltage, so the real
cost of the top levels is worse than this.

A task that finishes faster and sleeps gives some of this back, but a scrolling
browser does not finish: at a fixed frame rate it uses what it is given. Expect
energy per minute of browsing to rise roughly with the table [I].

Stage 1 should help idle: today both CPU rails are at their 1.2 GHz voltages all
the time, with no cpuidle driver and no DVFS (no `CPU_IDLE` in the defconfig). A
big part of the mainline-stock idle gap, and the gauge's 44-48 °C at rest, stays
out of reach, though: `vdd_mif` 1.0125 V and DRAM at the top level are permanent
on this kernel, where stock falls to 78 MHz at 0.8125 V (`boot-log:764`) [Ms].

Battery life in hours cannot be derived. The sources I read do not give the
capacity, and there is no power figure for this kernel. `CURRENT_NOW` works
(`docs/hardware/BATTERY.md:214`), so section 9 measures it.

## 8. Risks and recovery

### 8.1 What a bad transition looks like

| failure | sign |
|---|---|
| clock stuck | `re-parenting mux timed-out`, `timeout in divider stablization` (`clk-cpu.c:136,156`), `Could not lock PLL` (`clk-pll.c:111`) |
| PMIC write failed | `Failed to set regulator voltages` (`opp/core.c:1260`), hsi2c timeouts: the transition stops, no change of state |
| OPP not in the clock table | `-EINVAL` before anything moves (`clk-cpu.c:334-338`) |
| voltage too low | the worst one: no message. Wrong hashes, SIGILL or SIGSEGV in user tasks, Firefox crashes, then an oops or a hang |
| voltage too low on one cluster | possibly one dead cluster with the other alive (below) |
| too hot | cooling state rises; if cooling failed, a power cut at 115 °C |
| battery sag | a sudden reset under load at low charge, no log (risk 6) |

### 8.2 How the tablet comes back

Facts [M/S]: panic reboots through a software reset within 5 s (`panic=5
oops=panic`, `gts28ltexx_defconfig:64`; `docs/journal/PROGRESS.md:373`). The
watchdog fires after 30 s, but a **kernel thread** pings it
(`docs/hardware/WATCHDOG.md` section 5). A software reset keeps INFORM3 normal, so
sboot boots BOOT. A watchdog reset clears INFORM3, and sboot boots RECOVERY
(`docs/DEPLOY.md:82`, `docs/journal/PROGRESS.md:241`). The initramfs guard then
turns that into a software reset (`boot/initramfs/init:1272-1295`), unless the
image has `t715.wdtguard=0`, as the rescue does (`docs/DEPLOY.md:810-817`).

### 8.3 The route for test kernels

**Test kernel in RECOVERY, daily kernel left in BOOT.** Written with
`device/write-part.sh RECOVERY`, entered with `t715-reboot-to recovery`, which
ends in `systemctl reboot`. Knobs:

```
t715.usbfn=ecm t715.failwait=300 t715.rootimg=media/0/linux/rootfs-omarchy.img
t715.persist=0 t715.modblacklist=cpufreq_dt t715.returnafter=5400
```

and **not** `t715.wdtguard=0`. Every way out lands on the daily kernel with
nothing to do from the Mac:

| event | path | back on the daily kernel? |
|---|---|---|
| oops, panic | software reset | yes, unattended |
| full hang | watchdog, RECOVERY again, module not loaded, guard, software reset | yes, unattended, about a minute |
| `returnafter` expires | SysRq `b`, software reset (`init:1119-1152`) | yes, unattended |
| `systemctl reboot` | software reset | yes |
| userspace stall, kernel alive | **no watchdog**: this is the 2026-10-29 freeze, 2.5 hours (`ONDEVICE-2026-10-29.md:355-358`) | `returnafter`, if its shell still runs |
| one cluster dead, the other alive | **no watchdog**: the ping thread runs on the live cluster [I] | RCU stall panic, below. `returnafter`'s shell may be stuck on the dead cluster |
| trip at 115 °C | power cut; stays off | **no**, the owner's power key |

Why each part matters:

* **`cpufreq_dt` is a module, blacklisted.** The driver loads by hand, after the
  guard has run. Built in, a bad table hangs before the guard, and that is the
  panfrost boot loop again (`PROGRESS.md:319`, `docs/DEPLOY.md:1035-1040`).
* **BOOT is not used for tests.** BOOT would need the rescue to catch a hang,
  and the texts disagree on what sboot does: `docs/DEPLOY.md:82` says it boots
  RECOVERY, the initramfs comment says "the partition it booted last"
  (`init:1272-1274`). Every observed case had RECOVERY as both, so nothing
  decides between them. In RECOVERY, either reading gives the same result. In
  BOOT, the second reading is a loop.
* **`t715.persist=0`.** A CPU that computes wrong must not have USERDATA
  mounted read-write. The persistent root is the only copy of the daily system.
  In image mode the root is an overlay on a read-only image.
* **The rescue is gone during the campaign.** RECOVERY holds the test image, so
  the daily kernel has no rescue behind it. Put the rescue back with
  `write-part.sh` at the end of each stage. This is the one real cost of the route.

Test kernels add, set by the test script at load:
`sysctl kernel.panic_on_rcu_stall=1 kernel.softlockup_panic=1
kernel.hung_task_panic=1`, and console loglevel 7, since the bootloader's
`loglevel=4` hid everything on 2026-10-29. The stall panic is what turns the
dead-cluster case into a clean reset.

### 8.4 Rules that hold

* Leave Linux with `systemctl reboot`, never the watchdog. A watchdog reset in
  the table above is a failure path, not a method.
* Never touch the RTC.
* Never write RADIO, CDMA-RADIO, EFS, m9kefs1-3, BOOTLOADER, PARAM or BOTA.
* BOOT and RECOVERY only through `device/write-part.sh`.
* **CP off before rebooting into any test** (`MODEM.md:438`). Test kernels
  carry no modem modules, so the units skip themselves
  (`modem/systemd/shannon-modem-prepare.service:10`). This is more than tidiness:
  the CP must never be cut between `cp_status` = 1 and the first 0xA00D or 10 s,
  because its boot programs eFuses (`MODEM.md:432-433`). **An unstable CPU must
  never be running during a CP boot.** A test kernel in RECOVERY returns to the
  daily kernel, where the CP boots normally.

### 8.5 Risk list

1. **Undervolt from the mainline table**: closed by replacing it (section 3).
2. **The config trap** (section 2.3): closed by shipping all three together.
3. **ABB or EMA not as stock**: P3 answers it. If A57 ABB reads `0x8000008d`, as
   the GPU's did, the A57s are running with reverse bias, and nothing rises
   above 1.2 GHz until a kernel write fixes it (same design as `t715-g3d-abb`).
4. **Silent corruption**: only hash checks see it (section 9). Never run a stage
   on the persistent root until it has passed in image mode.
5. **Transitions under load, on arm32**: never run on this hardware. Stage 1's
   storm is the test.
6. **Battery sag.** Stock enables an SMPL warning that slows the A57 in hardware
   on a sag (`eagle.c:544-557`, `boot-log:1893`), and writes a threshold to the
   PMIC (`s2mps13.c:877`, `live_fdt:2339-2342`). Mainline does neither, and the
   PMIC's current value is unknown (P5). So a burst at low charge could reset
   the tablet. Tests run at ≥ 50 % on USB power. The daily cap is 1.2 GHz below
   20 % (my number, part of the D6 service).
7. **Heat in the case**: section 5.4.
8. **Scheduler ramp.** Fixed 1.2 GHz never has to ramp. schedutil may start a
   frame at a low level, so some interactions could feel worse at the same
   average speed [I]. Measured in stage 1. If so, a higher `scaling_min_freq` on
   policy4 while the screen is on.
9. **Unit-specific table.** These voltages are this chip's. Another SM-T715 may
   be another group. The image must not go to another unit unchanged. The test
   script's precheck compares the fuses and refuses.
10. **GPU combination.** Stock caps the A57s at 1.3 GHz when the GPU is at 600
    MHz or more (GPU.md section 10.4). No issue at 266 MHz. It must be revisited
    if GPU devfreq lands.

## 9. Test protocol

Modelled on `image/tests/ondevice/gpufreq.sh`. The script would be
`image/tests/ondevice/cpufreq.sh`, subcommands `precheck`, `load`, `step
POLICY F MIN`, `storm POLICY F1 F2 MIN`, `throttle`, `slope`, `cap`. It is not
written yet. Lessons from the GPU run are built in: baseline first, on the
daily kernel; a load known to run clean; no glmark2; a 1 s stream of
`/proc/pressure/*`, `free`, zones, gauge and `CURRENT_NOW` over SSH to the Mac,
so the last sample before a freeze is kept; pstore read before anything reboots.

The tablet is shared, so each stage needs a slot agreed with the other session.

### P0: read-only prechecks, on the current kernel

Nothing here writes. Use the `rd` reader of GPU.md section 10.12 and the regmap
`reg()` of `gpufreq.sh`. **Run P0 from the rescue, not the persistent root**: a
first read of a block can bus-fault into a panic, as `pinctrl/*/pins` did
(`PROGRESS.md:373`). Only CMU_MIF, PMU, CHIPID and, last, one CMU_ATLAS and one
SYSREG_EGL register are read, never a block that can be powered off.

| id | read | expected | if not |
|---|---|---|---|
| P1 | `0x10004000` EGL/KFC groups (`cal.c:31-32`); `0x10004010` bit 20 (`cal.c:110-115`); `0x1000403C` bit 21 (`cal.c:518-524`) | group nibbles 1, bit 20 = 0, bit 21 = 0 | **stop**: the table is wrong for this chip |
| P2 | `0x105B1000` DREX_FREQ_CTRL0, `0x105B0204`, `0x105B0604`; clk_summary lines `clk2x_phy`, `aclk_cci` | bit 20 = 1, bits 16, 12 = 0, bits 31:28 = 0 (`bus.c:2244-2246`): 825 MHz | report. Section 6 changes, the plan does not |
| P3 | `0x105C0780` (A57 ABB), `0x105C0784` (A53), `0x11810330` (EMA, `map.h:78`, `cal.c:511`) | `0x80000088`; 0; both EMA fields 3 | **stop above 1.2 GHz** until understood |
| P4 | clk_summary: `mout_bus_pll_atlas_user`, `mout_bus_pll_apollo_user`, `div_aclk_atlas` | 800, 800, 300 MHz | one `assigned-clock-parents` |
| P5 | regmap `0x1C`, `0x1E` (B2OUT, B3OUT), `0x0E` (CTRL2), one line each; `0x11800608` | `0x6a`, `0x7a`; record CTRL2 and the SMPL register | stop if the rail bytes differ |

Never `cat` the regmap file: it clears the PMIC's interrupt registers
(`gpufreq.sh:32-33`). `0x11800608` and `0x11810330` sit in the A57 cluster's
block, which is on while cpu4-7 are online [I].

#### Results of P0, 2026-10-30

Script: `image/tests/ondevice/cpufreq.sh precheck`, from the rescue (kernel
`00021`), CP off, no fault. The state read is sboot's: neither kernel programs these
registers. Innocuity identical before and after.

| id | read [M] | expected | result |
|---|---|---|---|
| P1 | fuse words read on the tablet | group nibbles 1, 0, 0 | **as expected** |
| P2 | `0x105B1000` = `0x00100100`: bit 20 = 1, bits 16, 12 and 31:28 = 0; `0x105B0204` = `0x01001000`, `0x105B0604` = `0x00031100`; `aclk_cci` 400 MHz | 825 MHz pattern (`bus.c:2245`) | **825 MHz confirmed** |
| P3 | A53 ABB `0x105C0784` = 0 | 0 | as expected |
| P3 | A57 ABB `0x105C0780` = **`0x00000000`** | `0x80000088` | **differs**: bypass, written by stock as 0 (`cal.c:489-490`), not the reverse bias feared in section 8.5 |
| P3 | EMA `0x11810330` = `0x00210210`: **both fields 2** | 3 | **differs** |
| P4 | atlas and apollo bus user 800 MHz, `div_aclk_atlas` 300 MHz, `div_aclk_apollo` 400 MHz | 800, 800, 300 | as expected |
| P5 | B2OUT `6a`, B3OUT `7a`, CTRL2 `08`, `0x11800608` = `0x0000000c` | `6a`, `7a`, record | as expected |

What it means:

* **Memory and rails are settled.** The memory clock is not a lever, and the fuses
  and rails match the tables of section 3.
* **Nothing above 1.2 GHz** until D7. Stock has never run this chip's upper levels in
  this state. The sources do not say what bypass or EMA 2 do electrically compared
  with level 8 and EMA 3, so this cannot be argued away on paper. `cal.c:511` uses 2
  when the fuse holds 0, which suggests a chip default and nothing more [I].
* **Stage 1 needs the same question** [I]: this state is proven at 1.2 GHz only, and
  stage 1 lowers the rail under it. Setting stock's values first, or a floor at
  1.2 GHz until they are set, is the cautious order.

Also seen: 64 °C on the hottest zone at the rescue's start, a minute after Chromium
had been running on the tablet, 57-58 °C a minute later, gauge 45 °C. One sample, with
no cooling device today.

### S0: baseline at fixed 1.2 GHz, current kernel

1. `sha256`, `ffmpeg` decode and Firefox scrolling, 5 runs each, Wi-Fi off, in
   the rescue (the 38-54 frames/s spread of MODEM.md section 6.8 is Wi-Fi noise).
2. Reference hashes: a 256 MiB tmpfs file through `sha256sum`; a clip through
   `ffmpeg -f md5` (NEON). These become the expected values.
3. Where Firefox's threads run: `ps -L -o tid,psr,pcpu,comm` during scrolling.
   If "Renderer" sits on the A53s, the plan's gain is lower than estimated.
4. Sensor check of section 5.3.
5. All 8 cores at 100 % for 10 minutes: hottest zone and gauge curve. Stop at 85
   °C. This is the slope any later level is compared against.

### Stages

| stage | kernel | what | pass |
|---|---|---|---|
| **1a** load | test, OPPs ≤ 1.2 GHz | `modprobe cpufreq_dt` | policy0 and policy4; `cpuinfo_max_freq` 1200000; rails unchanged at 1 062 500 / 1 162 500; cooling devices present and bound (zone `cdev` links); no warning |
| **1b** steps | | one policy at a time, each level 5 minutes under hash and `ffmpeg` load, pinned with `taskset` to that cluster | voltage and clock equal the OPP; `sha256` MB/s proportional to clock; every hash right |
| **1c** storm | | flip 20 times a second between lowest and highest level, 10 minutes, under load, each policy, then both | `trans_table` count; every hash right; no message |
| **1d** throttle | | `emul_temp` on atlas0, atlas1, apollo at 82, 87, 96 °C. Never ≥ 110 °C | cooling state and `cur_freq` match section 5.2; release |
| **1e** slope | | Firefox at A57 1.2 and 1.0 GHz, 5 runs each | gives c, section 10 |
| **1f** soak | | schedutil, 2 hours of normal use | idle current below S0; no feel regression; no message |
| **2a, 2b** | test, new table | as 1b at 1.3, 1.4, then 1.5 GHz, 15 minutes each; storm 0.8 to the top; `throttle`; Firefox and 8-core runs as S0 | same, and zone under 81 °C in the Firefox run; gain near the estimate |
| **3** | optional | the same at 1.7 GHz, only if the gain measured at 1.5 GHz predicts it | gain per watt beats 1.5 GHz |
| **5** | daily candidate | CP online on LTE, Firefox, 30 minutes, at the chosen cap | gauge below 54 °C |
| **daily** | | BOOT by `write-part.sh` after a 2-hour soak on the persistent root; rescue restored to RECOVERY | three clean reboots |

Stage 4 (1.9 GHz) is not planned. Stage 1c is the one that matters most. It is the only test of relocking under
load. The GPU's equivalent never ran clean.

The 115 °C trip test of THERMAL.md section 7 powers the board off and needs the
owner at the tablet. Do it once, before stage 2a (decision D4).

### Abort

At once, then `systemctl reboot`:

* any wrong hash or md5: **no retry on that kernel**;
* `Internal error`, `Oops`, `undefined instruction`, `Unhandled fault`, `Bad
  mode`, `rcu.*stall`, `soft lockup`, `hung_task`, `WARNING: CPU`, or the clock
  and PMIC messages of section 8.1;
* SIGILL or SIGSEGV in a test binary;
* voltage or clock not equal to the OPP;
* any zone ≥ 85 °C (project rule, GPU.md section 4), or a trip active during a
  pinned step: that step no longer tests its level;
* gauge ≥ 54 °C; battery below 50 %.

If the tablet stops answering: wait. `returnafter` and the watchdog act first.
Read `/sys/fs/pstore/` and sboot's `[TMU]` line on the way back before anything
else; the next reboot replaces them.

The levels that pass become the table. **Any abort at a level removes that level
and all above it**; none is retried with more voltage.

### Results of stage 1 (A53), 2026-11-03

Kernel: branch `t715-cpufreq` on the camera kernel (with `ed71dc803`),
`exynos5433-gts28ltexx-cpufreq.dtsi`: A53 400 MHz to 1.2 GHz at this chip's
voltages, no 700 MHz; A57 a single level, 1.2 GHz at 1 062 500 uV, BUCK2 held
there; BUCK3 875 000 to 1 162 500 uV. Test RECOVERY `55977c30378c`, image mode,
no modem modules, CP off, `cpufreq_dt` loaded by hand. Script
`image/tests/ondevice/cpufreq.sh`. Innocuity identical before, between the two
test boots and after. Rescue back in RECOVERY (`fe94a7c3f0fc`).

On the Mac's USB, 450 mA in, the battery at 58-59 % throughout. **The steps ran
3 minutes, not 5**: a slow charge had stopped at 58 %, and the owner chose
to run at that level rather than wait; 5 minutes a level would have risked the
50 % floor.

**1a load: pass**, 20 checks, on the second test boot. The first boot's two
failures were the script's (below); the kernel log after the load held no bad
message, read by hand.

**1b steps: pass at every level** [M]. Four workers pinned on cpu0-3 (sha256
from memory, AES-CTR hashed with NEON and with integer code, an H.264 decode),
3 minutes a level. The rail read the OPP's voltage at every poll.

| level MHz | rail uV | sha256 MB/s | speed / clock vs 1.2 GHz | battery mA under load | hottest zone °C | runs, all right |
|---|---|---|---|---|---|---|
| 1200 | 1 162 500 | 343 | 1.000 / 1.000 | -220 | 60 | 166 |
| 1100 | 1 125 000 | 320 | 0.933 / 0.917 | -174 | 59 | 160 |
| 1000 | 1 087 500 | 295 | 0.860 / 0.833 | -145 | 58 | 144 |
| 900 | 1 025 000 | 268 | 0.781 / 0.750 | -88 | 57 | 136 |
| 800 | 1 000 000 | 241 | 0.703 / 0.667 | -51 | 55 | 124 |
| 600 | 937 500 | 184 | 0.536 / 0.500 | -17 | 54 | 96 |
| 500 | 912 500 | 154 | 0.449 / 0.417 | 0 | 52 | 80 |
| 400 | 875 000 | 123 | 0.359 / 0.333 | +31 | 51 | 64 |

Speed falls a little slower than the clock at every level: the memory clock
does not move [I]. Under full A53 load, 400 MHz draws about 250 mA, about
1.0 W, less than 1.2 GHz.

**1c storm: pass**, on the second boot. 400 MHz and 1.2 GHz flipped every 50 ms
for 10 minutes under the same load: 9 412 transitions (12 000 without the holds
for reads), 361 runs right, no kernel message, zones at most 56 °C. The 105
reads, each on a held level, all matched: 50 at 1.2 GHz and 1 162 500, 55 at
400 MHz and 875 000.

The first storm, on the first boot, aborted at its first poll: clock 400 MHz with
the rail at 1 162 500. The script read the clock and the rail one after the
other while the level changed every 50 ms. 400 MHz under 1.2 GHz's voltage is
the safe half of a transition, since the OPP core raises the voltage before the
clock and lowers the clock before the voltage. A status line of the same poll
paired 1.2 GHz with 875 000, the same race in the other order. The four runs
done by then were right. The abort did its job: reboot, daily kernel, CP online
9.9 s after its boot. The Abort rule above is meant for a wrong settled state,
not a read across a transition, so the storm ran again on a fresh boot, with
the reads held on a level and no change to any voltage.

**1d throttle: pass** [M]. `emul_temp` on each zone, one at a time, 3 s each:
apollo 82 and 87 °C, atlas0 and atlas1 96 and 101 °C. The first trip gave
state 1 (1.1 GHz), the second state 2 (1.0 GHz); each release went back to state 0
and 1.2 GHz. **step_wise steps once per trip at a steady temperature**, and walks
only while the temperature rises. Apollo raised 1 °C a second: 87 °C 1.0 GHz, 88
0.9, 89 0.8, 90 0.6, 91 0.5, 92 0.4 GHz, held there to 94; falling, it gave a
state back at each step (92 0.5 GHz ... 85 0.9 GHz), and the release restored
1.2 GHz. So a real heat-up reaches 0.4 GHz only while the die keeps heating
[I: emulated, not real heat].

**1f idle, screen off: a small gain** [M]. The current is what the 450 mA
input leaves for the battery, positive when charging, so a higher figure means
a lower draw. A status line every 10 s.

| policy0 | minutes | battery mA | mW | hottest zone °C |
|---|---|---|---|---|
| fixed 1.2 GHz | 3 | +170.6 | +680.7 | 53 |
| fixed 400 MHz | 3 | +193.0 | +772.2 | 47 |
| schedutil | 5 | +184.4 | +738.9 | 46 |

400 MHz saves about 22 mA (90 mW) against 1.2 GHz, schedutil about 14 mA
(60 mW): 4-6 % of the 1.48 W idle draw (BATTERY.md section 9). schedutil spent
95 % of the window at 400 MHz, with 3 551 transitions in 5 minutes. The windows
ran one after the other while the chip cooled from the storm, so 1.2 GHz's
window was the warmest, and its leakage the highest. These gaps are an upper
bound [I]. The 1.48 W idle is not mostly the A53s.

**Script faults found on the device**, all fixed in `cpufreq.sh`:

1. The A57 policy lists its one level with a trailing space. The list is now
   normalized before the compare.
2. The kernel ring is already full at boot, and the session's services keep
   writing to it, one of them every 5 s. So a line count stops growing, and a
   fixed marker line leaves the ring within minutes. Messages are now bounded by
   kernel timestamps, read to the microsecond and advanced after each clean
   check. An injected line is seen once, and a gap in the ring is reported.
3. The storm's read race, above.
4. `Oops` matched `ramoops` and `oops=panic` in the boot lines. It now needs a
   word start and a following space, colon or dash.

**Not done in stage 1**: 1e (the slope needs A57 levels, which wait for D7), and
1f's 2-hour soak in normal use. Any daily kernel with these tables also needs the
modem modules, so its first run with the CP online is stage 5's.

### 1f and 5: the daily candidate's soak, 2026-11-03, and BOOT

Candidate: the same tree with `gts28ltexx_cpufreq.config` (the modem fragment's
lines, schedutil by default, `cpufreq-dt` a module that udev loads after the
initramfs guard, CPU cooling, the lockup and hung-task detectors), DTB
identical to stage 1's (`e1492b132fda`), the daily knobs (persistent root, quiet
boot, modem modules blacklisted for autoload). In RECOVERY (`48c18e0c5b22`) for
the soak, without `t715.returnafter`: that knob reboots through SysRq b, with
no sync and the CP still on, which a persistent root with the modem online
cannot take.

**Soak: 2 h 06, persistent root, CP online, on the Mac's USB, pass** [M]. 229
samples every 30 s, all read-only. The A53 rail at or above the level's
voltage on every read, the A57s held at 1.2 GHz and 1 062 500 uV, no kernel
fault, no modem crash or reset line, the CP booted once (9.94 s), no failed
unit. policy0 spent 80 % of the time at 400 MHz (6 069 s of 7 562), 3 % at
1.2 GHz, with 188 562 transitions. Screen off, the battery gained +44 mA on
average at the end, at 450 mA in.

- The tablet was used by hand for its first minutes, then left locked, so
  `image/tests/ondevice/usage-sim.sh` ran its headless cycles only (a
  real-time video decode, then idle; 12 cycles, none in the session). The
  interface's feel at these levels is still untested beyond those minutes.
- Two kernel lines matched the abort list: `Unhandled fault: alignment
  exception`, a user-space SIGBUS of Nautilus's previewer (gjs, an LDREXD at
  an address not 8-byte aligned). The same crash is in the 11-02 journal under
  the daily kernel without cpufreq: not this kernel's.
- **Heat**: the simulator's first headless cycle decoded on all eight cores at
  once, as fast as they could. In 90 s atlas1 reached 99 C. The A53 maps
  answered (state 4, 0.9 GHz), but the A57s have one level and nothing to
  give, as in today's daily kernel, where nothing throttles at all; only the
  115 C trip stands behind them. The load was stopped by hand and the zones
  were back at 54-57 C within minutes. This is past the 85 C project rule. It
  was counted, and the soak was not stopped, because the load was synthetic
  and the A57s behaved exactly as under the daily kernel. **D7's lower A57
  levels are what gives them something to throttle to.**

**BOOT since 2026-11-03**: `out/boot-cpufreq-daily/boot.img`
(`69b4e6c8bc8b`, one header byte away from the soaked image), the rescue back
in RECOVERY (`058d0481b509`). Four clean reboots, 39 s each: persistent root,
`cpufreq-dt` loaded, schedutil, CP online in 9.92-9.94 s, no kernel line on
the abort list, no failed unit. Innocuity identical before and after. To go
back: `out/boot-camaf/boot.img` (`6f47a0356be0`) with `device/write-part.sh BOOT`.

## 10. Expected gain for Firefox

Basis: the limiting thread's frame time has a part `c` that follows the CPU clock
and a part that does not; speed-up = 1 / ((1 − c) + c / r), with r = f / 1.2 GHz.
`c` was **not measured**. 0.6 to 0.9 is my assumption: below 1 because some time
goes to DRAM and the compositor, above 0.5 because the bridge clock rises with
the core up to 1.5 GHz. `sha256` is c = 1 and is not the workload.

| A57 | speed-up | scroll, from 38 frames/s | VP9 1080p drops, from 42 % | power vs today |
|---|---|---|---|---|
| 1.4 GHz | +9 to +15 % | 42-44 | 33-37 % | ×1.28 |
| **1.5 GHz** | **+14 to +22 %** | **43-46** | **29-34 %** | **×1.43** |
| 1.7 GHz | +21 to +36 % | 46-52 | 21-30 % | ×1.88 |
| 1.9 GHz | +28 to +50 % | 49-57 | 13-26 % | ×2.37 |

These are estimates, not measurements. Above 1.5 GHz the bridge clock drop means
the formula flatters those rows [I]. The 1.7 and 1.9 GHz figures also hold only
until thermal limits act. Runs near 54 frames/s are already close to the panel
rate, so they gain less.

In plain terms: **1.5 GHz should be noticeable on a stuttering scroll. It will
not fix video:** dropping 42 % needs about 1.7 times the throughput, and no level
gives that. It will not fix what is not CPU either, such as first-run network
traffic (MODEM.md section 6.8).

Stage 1e replaces the assumption with a number at no thermal risk. 1.0 and 1.2
GHz share the same ACLK divider as 1.5 GHz, so
c = 5 × (T(1.0) / T(1.2) − 1). **If c comes out under 0.4 (about +9 % at 1.5 GHz; my
threshold), stop there.** Stage 1 alone is still worth keeping, for throttling and idle.

## 11. Decisions for the owner

| # | decision | recommendation |
|---|---|---|
| D1 | Allow P0 and S0 on the tablet, in the rescue | yes |
| D2 | Replace the rescue in RECOVERY with test kernels during the campaign (no rescue behind the daily kernel meanwhile) | yes, restoring it after each stage |
| D3 | Margin above 1.2 GHz: stock + 37.5 mV, or plain stock | + 37.5 mV to qualify; revisit after soak |
| D4 | The 115 °C trip test, which needs you at the tablet | yes, once, before stage 2a |
| D5 | Target cap: stop at stage 1, 1.5 GHz, or attempt 1.7 GHz | 1.5 GHz, decided on the measured `c` |
| D6 | The userspace gauge and low-battery cap (52/49 °C, 20 %) | yes, before any cap above 1.2 GHz is daily; implemented as `t715-power-profile guard` (2026-11-07) |
| D7 | P3 found A57 ABB in bypass and EMA 2, not stock's level 8 and EMA 3: accept a small kernel write that sets stock's values | needed for anything above 1.2 GHz, and advised before stage 1 |
| D8 | Be within reach during stages 2 and up (power key) | yes: a 115 °C cut or a freeze needs a hand |

Worth trying before all of this, because it costs nothing: a lower content
resolution in Firefox (section 6.4).

**The owner's answers, 2026-11-03, after stage 1:**

| question | answer |
|---|---|
| The A53 tables in the daily kernel | **yes**: a daily candidate with the modem modules, then 1f's 2-hour soak in normal use and a run with the CP online, before BOOT |
| A57 above 1.2 GHz | **D7 only, no level above 1.2 GHz**: stock's ABB and EMA values so that the A57s can scale *down* at idle; D3, D4, D5 and D8 are not needed while the cap stays at 1.2 GHz |
| GPU devfreq (GPU.md section 10) | **after the CPU work**: the ABB kernel's T0-T5, then the 420 MHz cap with the panels as load, the owner present |
| Deep CPU idle states (cpuidle) | **study it**, on paper first: the largest unexplored lever on the 1.48 W idle draw [I] |

## 12. Not established

* **What the A57 ABB bypass and EMA 2 do** against stock's level 8 and EMA 3. P0 read
  the state; the sources do not say what the levels or the field physically do.
* **The alternate parent's mux** (P4), and the bus PLL's real state; `aclk_cci`
  on the bus PLL is deduced.
* **What sboot does after a watchdog reset from BOOT.** The project's texts
  differ, and no case is on record. The route in section 8.3 does not depend on it.
* **Whether this path works on arm32 and on this board.** cpufreq-dt, the OPP
  core and the 5433 CPU clock code have never run here. TM2's board file is
  evidence of intent only; nothing in this repository records it running.
* **The gain.** `c` is assumed; the cluster bridge's width is not in the sources.
* **Temperature at any raised level, and the thermal resistance of the case.** No
  sustained 8-core figure at 1.2 GHz is on record.
* **Absolute sensor accuracy**, and whether the hardware trip acts.
* **CP heat** and its effect at a raised cap.
* **Battery capacity, real power, leakage.** Stock's model has no leakage term.
* **PMIC peak current limits** for BUCK2. The sources I read give no number.
* **Behaviour below 19 °C.**
* **The sensor order in sboot's `[TMU]` line.**
