# SM-T715 (Galaxy Tab S2 9.7, GTS2) hardware map — stock 3.10 DT → mainline 6.12

Source of truth: `dumps/live_fdt.dts` (decompiled stock DTB, Samsung 3.10
`kernel_universal5433`, board `exynos5433-GTS2`), parsed with
[`hwmap_extract.py`](hwmap_extract.py) (211 enabled `compatible` nodes).
Mainline references: `src/linux-6.12` (driver `file:line` = the line of
the grep-verifiable `compatible` string; dtsi `label@addr:line` =
`arch/arm64/boot/dts/exynos/exynos5433.dtsi` unless noted `tm2-common`/`tm2`).
Downstream driver paths are relative to `src/kernel_universal5433/`.
Line numbers for `live_fdt.dts` quotes are given as `l.NNNN`.

Effort legend:

* **dt-only** — mainline driver exists; write the board-DT node.
* **dt+small-driver-change** — driver exists but needs a compatible/variant tweak.
* **new-driver** — no mainline driver; one must be written (or ported from stock).
* **skip** — Android/vendor shim, no hardware path in mainline worth porting.

Parser caveats (affects counts): `hwmap_extract.py` tests each node's *own*
`status` only, so children of a disabled parent still appear — e.g. the 5
`spd-*` children of `pd-fsys@105c40e0`, which is itself `status="disabled"`
(l.4136), are counted. `/chosen` is ignored by design. `reg` shows only the
first cell pair.

## Summary

| Category | Nodes |
|---|---|
| Enabled nodes with `compatible` | **211** |
| Mainline driver with the **same** compatible | **46** |
| Equivalent mainline driver under a **different** compatible | **89** |
| No mainline driver | **76** |

---

## 1. CPU, timers, interrupts (18 nodes — 6 same / 9 diff / 3 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/cpus/cpu@0`, `/cpus/cpu@1`, `/cpus/cpu@2`, `/cpus/cpu@3` | `arm,cortex-a7` | arch/arm/kernel/perf_event_cpu.c (cpu nodes unused by driver) | (cpu nodes) | `arm/cpus.yaml` | dtsi `cpus` uses `arm,cortex-a53` | dt-only | Stock names little cluster "kfc"/a7; the real cores are Cortex-A53 — use mainline naming |
| `/cpus/cpu@4`, `/cpus/cpu@5`, `/cpus/cpu@6`, `/cpus/cpu@7` | `arm,cortex-a15` | idem | idem | `arm/cpus.yaml` | dtsi `cpus` uses `arm,cortex-a57` | dt-only | Big cluster "eagle"/a15 → Cortex-A57; mainline boots via PSCI |
| `/arm-pmu` | `arm,cortex-a15-pmu`, `arm,cortex-a7-pmu` | arch/arm/kernel/perf_event_cpu.c:182 | `arm_pmuv3.c:1379/1381` (`arm,cortex-a57-pmu`, `arm,cortex-a53-pmu`) | `arm/pmu.yaml` | `arm-a57-pmu:35`, `arm-a53-pmu:26` | dt-only | Two pmu nodes, one per cluster, a53/a57 compatibles |
| `/interrupt-controller@11001000` | `arm,cortex-a15-gic` | drivers/irqchip/irq-gic.c | `irq-gic.c:1516` (same compatible) | `interrupt-controller/arm,gic.yaml:30,44` | `gic@11001000:938` | dt-only | — |
| `/mct@101C0000` | `samsung,exynos4210-mct` | drivers/clocksource/exynos_mct.c | `exynos_mct.c:700` (same) | `timer/samsung,exynos4210-mct.yaml` | `timer@101c0000:805` (`exynos5433-mct`,`exynos4210-mct`) | dt-only | reg l.921 |
| `/pwm@14dd0000` | `samsung,s3c6400-pwm` | drivers/clocksource/samsung_pwm_timer.c | `pwm-samsung.c:500` (same) | `pwm/pwm-samsung.yaml` | `pwm@14dd0000:1580` | dt-only | reg l.97 |
| `/watchdog@10020000` | `samsung,s3c2410-wdt` | drivers/watchdog/s3c2410_wdt.c | `s3c2410_wdt.c:310` (same); 5433 variant `:328` `samsung,exynos5433-wdt` | `watchdog/samsung-wdt.yaml` | — (no node in dtsi) | dt-only | reg l.1680; prefer `samsung,exynos5433-wdt` like the driver's 5433 data |
| `/rtc@10590000` | `samsung,s3c6410-rtc` | drivers/rtc/rtc-s3c.c | `rtc-s3c.c:588` (same) | `rtc/s3c-rtc.yaml` | — (no node in dtsi) | dt-only | reg l.6987 |
| `/chipid@10000000` | `samsung,exynos4210-chipid` | arch/arm/mach-exynos/common.c | `exynos-chipid.c:186` (same) | `hwinfo/samsung,exynos-chipid.yaml` | `chipid@10000000:363` | dt-only | reg l.1826 |
| `/coresight` | `exynos,coresight` | arch/arm/mach-exynos/exynos-coresight.c | none | — | — | skip | Debug/trace plumbing; reg covers 0x16000000+0xc00000 |
| `/firmware@0207B000` | `samsung,secure-firmware` | arch/arm/mach-exynos/firmware.c | none (exynos secure-firmware support removed from arm64) | — | — | skip | Replace by PSCI/ATF on mainline |
| `/persistent_clock@10590000` | `samsung,exynos_persistent_clock` | drivers/rtc/exynos_persistent_clock.c | none | — | — | skip | Mainline gets time from RTC driver |

## 2. Clocks & power domains (34 nodes — 0 same / 12 diff / 22 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/clock-controller@0x11900000` | `samsung,exynos5433-clock` | drivers/clk/samsung/clk-exynos5433.c | `clk-exynos5433.c:835` (CLK_OF_DECLARE `cmu-*` nodes, different compatibles) | `clock/samsung,exynos5433-clock.yaml` | 19 nodes: `cmu_top@10030000:369`, `cmu_cpif@10fc0000:384`, `cmu_peric@14c80000:404`, `cmu_peris@10040000:410`, `cmu_fsys@156e0000:416`, `cmu_g2d@12460000:443`, `cmu_disp@13b90000:457`, `cmu_aud@114c0000:483`, `cmu_bus0@13600000:492`, `cmu_bus1@14800000:501`, `cmu_g3d@14aa0000:519`, `cmu_gscl@13cf0000:529`, `cmu_mscl:~555`, `cmu_mfc@15280000:575`, `cmu_hevc:~585`, `cmu_isp:~595`, `cmu_cam0@120d0000:609`, `cmu_cam1@145d0000:622`, `cmu_imem@11060000:647` | dt-only | Stock has one CMU node at 0x11900000 (CPIF); mainline splits per-subsystem CMUs |
| `/fixed-rate-clocks/oscclk` | `samsung,exynos5433-oscclk` | drivers/clk/samsung/clk-exynos5433.c | none — model as `fixed-clock` | `clock/fixed-clock.yaml` | `xxti: clock:44` (output name "oscclk") | dt-only | `clock-frequency = <0x16e3600>` 24 MHz (l.1346) |
| `/pwm-clock-controller@14DD0000` | `samsung,exynos-pwm-clock` | drivers/clk/samsung/clk-exynos-pwm.c | none | — | `pwm@14dd0000:1580` is the raw PWM | skip | Vendor PWM-derived clocks (used for modem/spi_boot); drop |
| `/pd-cam0@105c4020` | `samsung,exynos-pd` | arch/arm/mach-exynos/pm_domains-exynos5433.c | `exynos-pm-domains.c:89` `samsung,exynos5433-pd` | `power/pd-samsung.yaml` | `pd_cam0@105c4020:678` | dt-only | 11 pd-* nodes, all `dt-only` with the 5433-pd compatible |
| `/pd-cam1@105c40a0` | `samsung,exynos-pd` | idem | idem | idem | `pd_cam1@105c40a0:707` | dt-only | — |
| `/pd-disp@105c4080` | `samsung,exynos-pd` | idem | idem | idem | `pd_disp@105c4080:700` | dt-only | — |
| `/pd-g2d@105c4120` | `samsung,exynos-pd` | idem | idem | idem | `pd_g2d@105c4120:721` | dt-only | — |
| `/pd-g3d@105c4060` | `samsung,exynos-pd` | idem | idem | idem | `pd_g3d@105c4060:693` | dt-only | — |
| `/pd-gscl@105c4000` | `samsung,exynos-pd` | idem | idem | idem | `pd_gscl@105c4000:671` | dt-only | — |
| `/pd-hevc@105c41c0` | `samsung,exynos-pd` | idem | idem | idem | `pd_hevc@105c41c0:743` | dt-only | — |
| `/pd-isp@105c4140` | `samsung,exynos-pd` | idem | idem | idem | `pd_isp@105c4140:728` | dt-only | — |
| `/pd-maudio@105c40c0` | `samsung,exynos-pd` | idem | idem | idem | — (no node; audio-subsystem covers it) | dt-only | Mainline powers audio via `audio-subsystem@11400000:1901` |
| `/pd-mfc@105c4180` | `samsung,exynos-pd` | idem | idem | idem | `pd_mfc@105c4180:736` | dt-only | — |
| `/pd-mscl@105c4040` | `samsung,exynos-pd` | idem | idem | idem | `pd_mscl@105c4040:686` | dt-only | — |
| `/pd-disp@105c4080/spd-decon-tv@105c4080`, `/pd-disp@105c4080/spd-decon@105c4080`, `/pd-disp@105c4080/spd-hdmi-phy@105c4080`, `/pd-disp@105c4080/spd-hdmi@105c4080`, `/pd-disp@105c4080/spd-mdnie@105c4080`, `/pd-disp@105c4080/spd-mic@105c4080`, `/pd-disp@105c4080/spd-mipi-dphy-m4s4@105c4080`, `/pd-disp@105c4080/spd-mipi-dsi@105c4080`, `/pd-disp@105c4080/spd-pll-disp@105c4080` (9 nodes) | `samsung,exynos-spd` | none — DTS-only bookkeeping (no driver; `arch/arm/boot/dts/exynos5433.dtsi:1139`) | none | — | — | skip | Sub-power-domain descriptors; mainline models this via `power-domains` phandles on devices |
| `/pd-fsys@105c40e0/spd-dwmmc0@105c40e0`, `/pd-fsys@105c40e0/spd-dwmmc1@105c40e0`, `/pd-fsys@105c40e0/spd-dwmmc2@105c40e0`, `/pd-fsys@105c40e0/spd-usbdrd30@105c40e0`, `/pd-fsys@105c40e0/spd-usbhost20@105c40e0` (5 nodes) | `samsung,exynos-spd` | none — DTS-only | none | — | — | skip | Parent pd-fsys is disabled (l.4136); fsys devices need no PD on mainline |
| `/pd-gscl@105c4000/spd-gscl0@105c4000`, `/pd-gscl@105c4000/spd-gscl1@105c4000`, `/pd-gscl@105c4000/spd-gscl2@105c4000` (3 nodes) | `samsung,exynos-spd` | none — DTS-only | none | — | — | skip | idem |
| `/pd-mscl@105c4040/spd-jpeg@105c4040`, `/pd-mscl@105c4040/spd-mscl0@105c4040`, `/pd-mscl@105c4040/spd-mscl1@105c4040` (3 nodes) | `samsung,exynos-spd` | none — DTS-only | none | — | — | skip | idem |

## 3. Pinctrl / GPIO (11 nodes — 11 same / 0 diff / 0 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/pinctrl@10580000` | `samsung,exynos5433-pinctrl` | drivers/pinctrl/pinctrl-samsung.c | `pinctrl-samsung.c:1482` (same) | `pinctrl/samsung,pinctrl.yaml` | `pinctrl_alive@10580000:849` | dt-only | Alive bank; also GPA0-2 wake keys |
| `/pinctrl@10580000/wakeup-interrupt-controller` | `samsung,exynos4210-wakeup-eint` | drivers/pinctrl/pinctrl-exynos.c | `pinctrl-exynos.c:579` (same) | `pinctrl/samsung,pinctrl-wakeup-interrupt.yaml` | child of `pinctrl_alive:849` | dt-only | Parent of all wake IRQs (keys, TS, PMIC…) |
| `/pinctrl@10FE0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_cpif@10fe0000:867` | dt-only | — |
| `/pinctrl@11090000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_imem@11090000:891` | dt-only | — |
| `/pinctrl@114B0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_aud@114b0000:860` | dt-only | — |
| `/pinctrl@14CA0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_ese@14ca0000:873` | dt-only | — |
| `/pinctrl@14CB0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_finger@14cb0000:879` | dt-only | — |
| `/pinctrl@14CC0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_peric@14cc0000:903` | dt-only | — |
| `/pinctrl@14CD0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_nfc@14cd0000:897` | dt-only | — |
| `/pinctrl@14CE0000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_touch@14ce0000:909` | dt-only | — |
| `/pinctrl@15690000` | `samsung,exynos5433-pinctrl` | idem | idem | idem | `pinctrl_fsys@15690000:885` | dt-only | — |

## 4. I2C / HSI2C / SPI / UART (22 nodes — 14 same / 8 diff / 0 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/hsi2c@14D90000` | `samsung,exynos5-hsi2c` | drivers/i2c/busses/i2c-exynos5.c | `i2c-exynos5.c:245` (same compatible) | `i2c/i2c-exynos5.yaml` | `hsi2c_8@14d90000:1707` | dt-only | Bus of SM5703 PMIC/MFD |
| `/hsi2c@14DA0000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_9@14da0000:1721` | dt-only | Bus of tc300 touchkey |
| `/hsi2c@14DE0000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_10@14de0000:1735` | dt-only | Bus of lsm6ds3 + yas537 |
| `/hsi2c@14DF0000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_11@14df0000:1749` | dt-only | Bus of sii8240 MHL |
| `/hsi2c@14E40000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_0@14e40000:1595` | dt-only | PMIC bus; stock `clock-freq 0x2625a0` l.2318 |
| `/hsi2c@14E70000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_3@14e70000:1637` | dt-only | Codec wm1814 bus |
| `/hsi2c@14EC0000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_4@14ec0000:1651` | dt-only | Camera EEPROM bus |
| `/hsi2c@14ED0000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_5@14ed0000:1665` | dt-only | Touchscreen bus |
| `/hsi2c@14EF0000` | `samsung,exynos5-hsi2c` | idem | idem | idem | `hsi2c_7@14ef0000:1693` | dt-only | Fuel gauge bus |
| `/i2c@25` | `i2c-gpio` | drivers/i2c/busses/i2c-gpio.c | `i2c-gpio.c:465` (same) | `i2c/i2c-gpio.yaml` | — | dt-only | Bit-bang bus of muic; gpios `<0x56 0x05> <0x56 0x04>` l.3065 |
| `/i2c@28` | `i2c-gpio` | idem | idem | idem | — | dt-only | sx9310 bus; gpios `<0x19 0x04> <0x19 0x05>` l.7007 |
| `/i2c@29` | `i2c-gpio` | idem | idem | idem | — | dt-only | sx9310_wifi bus; gpios `<0xc2 0x01> <0xc2 0x02>` l.5323 |
| `/i2c@30` | `i2c-gpio` | idem | idem | idem | — | dt-only | cm36652 bus; gpios `<0xd1 0x01> <0xd1 0x02>` l.75 |
| `/i2c@35` | `i2c-gpio` | idem | idem | idem | — | dt-only | Camera vision bus; gpios `<0xbd 0x04> <0xbd 0x05>` l.3333 |
| `/spi@14d00000` | `samsung,exynos543x-spi` | drivers/spi/spi-s3c64xx.c | `spi-s3c64xx.c:1658` `samsung,exynos5433-spi` | `spi/samsung,spi.yaml` | `spi_4@14d00000:1535` | dt-only | — |
| `/spi@14d20000` | `samsung,exynos543x-spi` | idem | idem | idem | `spi_0@14d20000:1455` | dt-only | — |
| `/spi@14d30000` | `samsung,exynos543x-spi` | idem | idem | idem | `spi_1@14d30000:1475` | dt-only | — |
| `/spi@14d40000` | `samsung,exynos543x-spi` | idem | idem | idem | `spi_2@14d40000:1495` | dt-only | — |
| `/serial@11460000` | `samsung,exynos5430-uart` | drivers/tty/serial/samsung.c | `samsung_tty.c:2631` `samsung,exynos5433-uart` | `serial/samsung_uart.yaml` | `serial_3@11460000:1942` | dt-only | Bluetooth UART (l.3989) |
| `/serial@14C10000` | `samsung,exynos5430-uart` | idem | idem | idem | `serial_0@14c10000:1419` | dt-only | Candidate console UART |
| `/serial@14C20000` | `samsung,exynos5430-uart` | idem | idem | idem | `serial_1@14c20000:1431` | dt-only | tm2 `stdout-path = &serial_1` (tm2-common:48) |
| `/serial@14C30000` | `samsung,exynos5430-uart` | idem | idem | idem | `serial_2@14c30000:1443` | dt-only | — |

## 5. PMIC & regulators (1 node — 1 same / 0 diff / 0 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/hsi2c@14E40000/s2mps13_pmic@66` | `samsung,s2mps13-pmic` | drivers/mfd/sec-core.c:82 | `sec-core.c:90` (same); clocks `clk-s2mps11.c:225`; RTC `rtc-s5m.c:103` | `mfd/samsung,s2mps11.yaml` + `regulator/samsung,s2mps13.yaml` | tm2-common `s2mps13-pmic:394` (osc `s2mps13_osc:401`) | dt-only | addr 0x66 l.2322; IRQ gpa0-7 `<0x07 0x00 0x00>` l.2331; full rail list in "Board DT values" |

## 6. Storage (2 nodes — 0 same / 2 diff / 0 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/dwmmc0@15540000` (eMMC) | `samsung,exynos5433-dw-mshc` | drivers/mmc/host/dw_mmc-exynos.c | `dw_mmc-exynos.c:72` `samsung,exynos7-dw-mshc-smu` (no 5433 entry) | `mmc/samsung,exynos-dw-mshc.yaml` | `mshc_0@15540000:1841` (`exynos5433-dw-mshc-smu`,`exynos7-dw-mshc-smu`) | dt-only | bus-width 0x08 l.4103, hs200-1.8v l.4097; reuse dtsi compatible pair |
| `/dwmmc2@15560000` (SD) | `samsung,exynos5433-dw-mshc` | idem | idem | idem | `mshc_2@15560000:1869` | dt-only | bus-width 0x04 l.1296, cd gpa2-4 l.1274, vmmc-en l.1284 |

## 7. USB (13 nodes — 2 same / 4 diff / 7 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/usb@15400000` (DRD30) | `samsung,exynos5-dwusb3` | drivers/usb/dwc3/dwc3-exynos.c:62 | `dwc3-exynos.c:183` `exynos5433-dwusb3` | `usb/samsung,exynos-dwc3.yaml` | `usbdrd30@15400000:1763` | dt-only | dr_mode "otg" l.2799, maximum-speed "high-speed" l.2800 |
| `/usb@15400000/dwc3` | `synopsys,dwc3` | drivers/usb/dwc3/core.c | `dwc3/core.c:2685` (same) | `usb/snps,dwc3.yaml` | `usbdrd_dwc3: usb@0:1775` | dt-only | — |
| `/usb@15a00000` (host30) | `samsung,exynos5-dwusb3` | idem | `dwc3-exynos.c:183` | `usb/samsung,exynos-dwc3.yaml` | `usbhost30@15a00000:1816` | dt-only | — |
| `/usb@15a00000/dwc3` | `synopsys,dwc3` | drivers/usb/dwc3/core.c | `dwc3/core.c:2685` (same) | `usb/snps,dwc3.yaml` | `usbhost_dwc3: usb@0:1828` | dt-only | — |
| `/usbphy@15500000` | `samsung,exynos5430-usb3phy` | drivers/usb/phy/phy-samsung-usb3.c | `phy-exynos5-usbdrd.c:1667` `samsung,exynos5433-usbdrd-phy` | `phy/samsung,usb3-drd-phy.yaml` | `usbdrd30_phy@15500000:1788` | dt-only | usbphy-sys `<0x105c0704 0x04>` l.3057 |
| `/usbphy@15580000` | `samsung,exynos5430-usb3phy` | idem | idem | idem | `usbhost30_phy@15580000:1802` | dt-only | — |
| `/usb@15510000` | `samsung,exynos5-ehci` | drivers/usb/host/ehci-s5p.c | none (only `exynos4210-ehci` `ehci-exynos.c:283`; no 5433 USB2 host path) | — | — | skip | No 5433 USB2 PHY support in mainline |
| `/usb@15520000` | `samsung,exynos5-ohci` | drivers/usb/host/ohci-exynos.c | none (idem, `ohci-exynos.c:257` exynos4210 only) | — | — | skip | idem |
| `/usb2phy@15530000` | `samsung,exynos5-usb2phy` | drivers/usb/phy/phy-samsung-usb2.c | none (`drivers/phy/samsung/phy-exynos-usb2.c` does not exist in 6.12) | — | — | skip | USB2 PHY for 5433 unsupported |
| `/usbphy@0`, `/usbphy@1` | `samsung,exynos5-usb2phy-dummy` | drivers/usb/phy/phy-samsung-usb2-dummy.c | none | — | — | skip | Placeholder nodes |
| `/usb-switch` | `samsung,exynos-usb-switch` | drivers/usb/misc/exynos-usb-switch.c | none | — | — | skip | OTG role switch; mainline does this in dwc3/muic |
| `/usb_notifier` | `samsung,usb-notifier` | drivers/usb/notify/usb_notifier.c | none | — | — | skip | Android vendor notification shim |

## 8. Display (15 nodes — 0 same / 8 diff / 7 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/decon_fb` | `samsung,exynos5-disp_driver` | drivers/video/decon_display/decon_display_driver.c | `exynos5433_drm_decon.c:750` `samsung,exynos5433-decon` | `display/samsung/samsung,exynos5433-decon.yaml` | `decon@13800000:949` | dt-only | Panel details l.992-1061 (see "Board DT values") |
| `/decon_tv@13880000` | `samsung,exynos5-decon_tv_driver` | drivers/video/exynos/decon_tv_display/decon_tv_drv.c | `exynos5433_drm_decon.c:754` `samsung,exynos5433-decon-tv` | same binding | `decon_tv@13880000:992` | dt-only | — |
| `/hdmi@13970000` | `samsung,exynos5-hdmi_driver` | drivers/video/exynos/decon_tv_display/hdmi_drv.c | `exynos_hdmi.c:1840` `samsung,exynos5433-hdmi` | `display/samsung/samsung,exynos-hdmi.yaml` | `hdmi@13970000:1087` | dt-only | hdmiphy `@13af0000:1113` |
| `/cec@101B0000` | `samsung,exynos5-cec_driver` | drivers/video/exynos/decon_tv_display/hdmi_cec.c | `s5p_cec.c:289` `samsung,s5p-cec` | `media/cec/samsung,s5p-cec.yaml` | — (no 5433 node upstream) | dt-only | reg l.2138; driver+binding exist, node must be written |
| `/scaler@15000000` | `samsung,exynos5-scaler` | drivers/media/platform/exynos/scaler/scaler-core.c | `exynos_drm_scaler.c:713` `samsung,exynos5433-scaler` | `gpu/samsung-scaler.yaml` | `scaler_0@15000000:1237` | dt-only | — |
| `/scaler@15010000` | `samsung,exynos5-scaler` | idem | idem | idem | `scaler_1@15010000:1249` | dt-only | — |
| `/sysreg_disp@0x13B81004` | `samsung,exynos5-sysreg_disp` | drivers/video/exynos/decon_display_ext/decon_dt_exynos5430.c | syscon — `samsung,exynos5433-disp-sysreg` (no dedicated driver; used by decon/hdmi) | `soc/samsung/samsung,exynos-sysreg.yaml` | `syscon_disp@13b80000:1117` | dt-only | Fold into the single 0x13b80000 syscon |
| `/sysreg_localout@0x13B80000` | `samsung,exynos5-sysreg_localout` | idem | idem | idem | same `syscon_disp@13b80000:1117` | dt-only | Same block as syscon_disp upstream |
| `/decon_fb1` | `samsung,exynos5-disp1_driver` | drivers/video/decon_display/decon_display_driver.c | none (single DECON upstream; `decon_tv` covers 0x13880000) | — | — | skip | Second framebuffer instance, unused upstream |
| `/hdmi` | `samsung,pacific-hdmi` | sound/soc/samsung/pacific_hdmi.c | none | — | — | skip | HDMI audio pdata shim; DAI handled by tm2-style machine driver |
| `/hsi2c@14DF0000/sii8240cbus@64`, `/hsi2c@14DF0000/sii8240disc@4D`, `/hsi2c@14DF0000/sii8240hdmi@49`, `/hsi2c@14DF0000/sii8240tmds@39`, `/hsi2c@14DF0000/sii8240tpi@59` (5 nodes) | `sii8240,{cbus,disc,hdmi,tmds,tpi}` | drivers/video/mhl/sii8240/sii8240.c | none (no MHL bridge in mainline) | — | — | skip | MHL transmitter; only useful for MHL-out, not for the panel |

## 9. GPU (2 nodes — 0 same / 1 diff / 1 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/mali` | `arm,mali` | drivers/gpu/arm/t7xx (kbase midgard) | `panfrost_drv.c:812` `arm,mali-t760` | `gpu/arm,mali-midgard.yaml` | `gpu@14ac0000:1186` | dt-only | T760; regulator BUCK6 vdd_g3d l.2399-2405 |
| `/fimg2d@12400000` | `samsung,s5p-fimg2d` | drivers/media/platform/exynos/fimg2d/g2d-core.c | none (`exynos_drm_g2d.c:1602-1603` supports 5250/4212 only) | — | — | skip | 2D blitter; no 5433 G2D upstream |

## 10. Audio (10 nodes — 2 same / 3 diff / 5 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/lpass@11400000` | `samsung,exynos5433-lpass` | sound/soc/samsung/lpass.c | `exynos-lpass.c:180` (same) | `mfd/samsung,exynos5433-lpass.yaml` | `audio-subsystem@11400000:1901` | dt-only | — |
| `/hsi2c@14E70000/wm1814@1a` | `wlf,wm1814` | drivers/mfd/arizona-core.c | `arizona-i2c.c:105` (same) | `mfd/wlf,arizona.yaml` | — (tm2 uses wm5110) | dt-only | Codec supported by `arizona.c` core; node from l.1975-2022 |
| `/i2s@11440000` | `samsung,i2s-v5` | sound/soc/samsung/i2s.c | `i2s.c:1729` `samsung,exynos7-i2s` (no `i2s-v5`) | `sound/samsung-i2s.yaml` | `i2s0@11440000:1921` (`exynos5433-i2s`,`exynos7-i2s`) | dt-only | — |
| `/i2s@14D60000` | `samsung,i2s-v5` | idem | `i2s.c:1732` `samsung,exynos7-i2s1` | idem | `i2s1@14d60000:1565` | dt-only | — |
| `/sound` | `samsung,pacific-arizona` | sound/soc/samsung/pacific_arizona.c | none — closest `samsung,tm2-audio` `tm2_wm5110.c:660`, `samsung,midas-audio` `midas_wm1811.c:758` | `sound/samsung,tm2.yaml` (shape reference) | tm2-common `sound:121` | new-driver | Machine driver must be written; codec DAI + i2s0/i2s1 wiring per l.5344-5352 |
| `/audio_pdata` | `samsung,audio-pdata` | sound/soc/samsung/pacific_arizona.c | none | — | — | skip | Platform-data blob folded into machine driver |
| `/dummy-codec` | `samsung,dummy-codec` | sound/soc/codecs/dummy_codec.c | none (`snd-soc-dummy` has no of_match) | — | — | skip | Use `snd-soc-dummy` DAI without a DT node |
| `/dummy-i2s` | `snd-soc-dummy` | sound/soc/soc-core.c | none (no of_match) | — | — | skip | idem |
| `/eax` | `samsung,exynos-amixer` | sound/soc/samsung/eax-dai.c | none | — | — | skip | Vendor effect mixer |
| `/seiren` | `samsung,exynos5430-seiren` | sound/soc/samsung/seiren/seiren.c | none | — | — | skip | Audio offload DSP (uses lpass); large port, skip |

## 11. Wi-Fi / BT / connectivity (4 nodes — 1 same / 1 diff / 2 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/pcie@15700000` | `samsung,exynos5433-pcie`, `snps,dw-pcie` | drivers/pci/host/pci-exynos.c | `pci-exynos.c:380` (same 5433 compatible) | `pci/samsung,exynos-pcie.yaml` | `pcie@15700000:1965` | dt-only | num-lanes 1 l.7077; assumed Wi-Fi host (see uncertainties) |
| `/bluetooth` | `broadcom,bcm4358` | drivers/bluetooth/bcm4358.c (vendor) | `hci_bcm.c:1605` `brcm,bcm43438-bt` | `net/bluetooth/brcm,bluetooth.yaml` | — | dt-only | On `serial@11460000` (l.3989); gpios l.4202 |
| `/wlan` | `samsung,brcm-wlan` | drivers/net/wireless/bcmdhd4358/dhd_custom_exynos.c | none — use brcmfmac (`brcmfmac/pcie.c:59` ships `brcmfmac4358-pcie` firmware name) | — | — | dt+small-driver-change | No DT node needed upstream beyond pcie; firmware `brcm/brcmfmac4358-pcie.bin`; interface uncertain |
| `/gps` | `samsung,exynos54xx-bcm4752` | drivers/gps/sec_gps_bcm4752.c | none (mainline GNSS has `bcm4751` binding `gnss/bcm4751.yaml`, different chip wiring) | `gnss/bcm4751.yaml` (reference) | — | new-driver | Uncertain: UART wiring needed; reg l.1245 |

## 12. Sensors & input (13 nodes — 3 same / 4 diff / 6 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/adc@14D10000` | `samsung,exynos-adc-v2` | drivers/iio/adc/exynos_adc.c | `exynos_adc.c:513` (same) | `iio/adc/samsung,exynos-adc.yaml` | `adc@14d10000:1555` (`exynos5433-adc`,`exynos7-adc`) | dt-only | reg l.4452 |
| `/gpio_keys` | `gpio-keys` | drivers/input/keyboard/gpio_keys.c | `gpio_keys.c:836` (same) | `input/gpio-keys.yaml` | tm2-common `gpio-keys:56` | dt-only | 4 keys, GPIOs+codes l.7021-7058 |
| `/hsi2c@14DE0000/lsm6ds3@6b` | `st,lsm6ds3` | drivers/iio/imu/st_lsm6ds3_i2c.c | `st_lsm6dsx_i2c.c:46` (same) | `iio/imu/st,lsm6dsx.yaml` | — | dt-only | addr 0x6b |
| `/hsi2c@14ED0000/touchscreen@20` | `synaptics,rmi4` | drivers/input/touchscreen/synaptics_dsx/synaptics_i2c_rmi.c | `rmi_i2c.c:180` `syna,rmi4-i2c` | `input/syna,rmi4.yaml` | — | dt-only | addr 0x20; IRQ gpa1-1 `<0x42 0x01 0x00>` l.1674; rails LDO30/31 |
| `/hsi2c@14DE0000/yas537@2e` | `yas_magnetometer` | drivers/iio/magnetometer/yas537/yas_mag_kernel.c | `yamaha-yas530.c:1596` `yamaha,yas537` | `iio/magnetometer/yamaha,yas530.yaml` | — | dt-only | addr 0x2e |
| `/i2c@28/sx9310-i2c@28` | `sx9310-i2c` | drivers/sensors/sx9310.c | `sx9310.c:996` `semtech,sx9310` | `iio/proximity/semtech,sx9310.yaml` | — | dt-only | IRQ `<0x4c …>` per stock node |
| `/i2c@29/sx9310_wifi-i2c@28` | `sx9310-wifi-i2c` | drivers/sensors/sx9310.c | idem `semtech,sx9310` | idem | — | dt-only | Second SAR sensor; IRQ `<0x4c 0x04>` l.5330 |
| `/hall` | `hall` | drivers/input/hall.c | none (mainline models lid/hall as `gpio-keys`) | `input/gpio-keys.yaml` | — | dt-only | gpa0-1 (l.5367-5372); SW_LID via gpio-keys |
| `/haptic` | `isa1000a-vibrator` | drivers/motor/isa1000a_vibrator.c | `pwm-vibrator`, with the rest duty of `kernel/patches/t715-parity/` | — | — | done | LDO35, enable gpc0-1, timer 0 on gpd2-4, 33238 ns, rest at half the period, full drive at 24872 ns (l.4749-4761) |
| `/hsi2c@14DA0000/touchkey@20` | `coreriver,tc300-keypad` | drivers/input/keyboard/tc300k.c | `tc300k.ko` (`kernel/patches/t715-parity/`), reduced from stock, no firmware path | — | — | done | addr 0x20, IRQ **gpa3-2** l.1897 (phandle 0x4c is the gpa3 bank), LDO32 chip, LDO33 LEDs. The chip answers: firmware 0x05 |
| `/i2c@30/cm36652@60` | `cm36652` | drivers/iio/light/cm36652.c | none — mainline has `capella,cm36651` `cm36651.c:723` only | `iio/light/capella,cm36651.yaml` (nearest) | — | new-driver | cm36651 driver may port with small changes; addr 0x60 |
| `/input_booster` | `input_booster` | drivers/input/misc/input_booster.c | none | — | skip | Android CPU/IRQ boost on touch |
| `/spi@14d40000/vfsspi-spi@0` | `vfsspi,vfs7xxx` | drivers/fingerprint/vfs7xxx.c | none | — | skip | Fingerprint sensor; no mainline driver |

## 13. Charger & fuel gauge (4 nodes — 0 same / 0 diff / 4 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/battery` | `samsung,sec-battery` | drivers/battery/sec_battery.c | none | `power/samsung,samsung,battery.yaml` — does not exist | — | new-driver | Full sec-battery stack; large |
| `/hsi2c@14D90000/sm5703-mfd@49` | `siliconmitus,sm5703mfd` | drivers/mfd/sm5703_core.c | none (no SM5703 MFD/charger/muic upstream) | — | — | new-driver | Charger + MUIC + LED MFD; addr 0x49 |
| `/hsi2c@14EF0000/sm5703-fuelgauge@71` | `samsung,sm5703-fuelgauge` | drivers/battery/sm5703_fuelgauge.c | none | — | — | new-driver | addr 0x71 |
| `/i2c@25/muic-universal@25` | `muic-universal` | drivers/muic/universal/muic_dt.c | none (only maxim 77705 muic extcon upstream) | — | — | new-driver | Needed for USB OTG role/ID |

## 14. Modem & LLI (3 nodes — 0 same / 0 diff / 3 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/mif_pdata` | `sec_modem,modem_pdata` | drivers/misc/modem_v1/modem_main.c | none | — | skip | CP shim (Exynos-modem); no mainline stack |
| `/mipi-lli@10F24000` | `samsung,exynos-mipi-lli` | drivers/misc/mipi-lli/ | none | — | skip | CP link; l.5506-5509 |
| `/mipi-lli@10F24000/mphy` | `samsung,exynos-mipi-lli-mphy` | drivers/misc/mipi-lli/exynos-mipi-lli-mphy.c | none | — | skip | idem |

## 15. Thermal (2 nodes — 1 same / 0 diff / 1 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/tmu@10060000` | `samsung,exynos5433-tmu` | drivers/thermal/exynos_thermal.c | `exynos_tmu.c:831` (same) | `thermal/samsung,exynos-thermal.yaml` | `tmu_atlas0@10060000:750` (+ `tmu_atlas1:761`, `tmu_g3d:772`, `tmu_apollo:783`, `tmu_isp:794` in `exynos5433-tmu.dtsi`) | dt-only | Stock has 1 node, 5 regions l.4237-4238; mainline has 5 nodes |
| `/sec_thermistor` | `samsung,sec-ap-thermistor` | drivers/hwmon/sec_thermistor.c | none | — | skip | AP thermistor ADC consumer; fold into tmu/NTC tables |

## 16. Camera & media (13 nodes — 0 same / 5 diff / 8 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/gsc@13C00000` | `samsung,exynos5-gsc` | drivers/media/platform/exynos/gsc_1.3/gsc-core.c | `gsc-core.c:1093` `samsung,exynos5433-gsc` (stock string exists at `:1097` but binds the deprecated `gsc_v_100` variant, warns "deprecated" `:1122`) | `media/samsung,exynos5250-gsc.yaml` | `gsc_0@13c00000:1141` | dt-only | Use the 5433 compatible |
| `/gsc@0x13C10000` | `samsung,exynos5-gsc` | idem | idem | idem | `gsc_1@13c10000:1156` | dt-only | — |
| `/gsc@0x13C20000` | `samsung,exynos5-gsc` | idem | idem | idem | `gsc_2@13c20000:1171` | dt-only | — |
| `/mfc0@152E0000` | `samsung,mfc-v6` | drivers/media/platform/s5p-mfc/s5p_mfc.c | `s5p_mfc.c:1709` `samsung,exynos5433-mfc` (`mfc-v6` exists at `:1697` but is the wrong IP revision for 5433) | `media/samsung,s5p-mfc.yaml` | `mfc@152e0000:1274` | dt-only | — |
| `/jpeg0@15020000` | `samsung,exynos-jpeg` | drivers/media/platform/exynos/jpeg/jpeg-core.c | `jpeg-core.c:3142` `samsung,exynos5433-jpeg` | `media/samsung,s5pv210-jpeg.yaml` | `jpeg@15020000:1261` | dt-only | — |
| `/fimc_is@14000000` | `samsung,exynos5-fimc-is` | drivers/media/platform/exynos/fimc-is/ | none (no Exynos5433 FIMC-IS in mainline; exynos4-is does not cover it) | — | — | skip | ISP is a Cortex-R5 with vendor firmware |
| `/fimc_is_sensor@12100000`, `/fimc_is_sensor@12110000` (2 nodes) | `samsung,exynos5-fimc-is-sensor` | idem | none | — | — | skip | — |
| `/i2c@35/fimc-is-vision@35` | `samsung,exynos5-fimc-is-sensor-6b2` | drivers/media/platform/exynos/fimc-is/sensor/module/fimc-is-device-6b2.c | none | — | skip | Sensor (6b2); would need a V4L2 subdev — separate project |
| `/hsi2c@14EC0000/fimc_is_eeprom_i2c@58` | `samsung,rear-eeprom-i2c` | drivers/media/platform/exynos/fimc-is/vendor/fimc-is-device-eeprom.c | none | — | skip | Camera calibration EEPROM |
| `/hevc@14FE0000` | `samsung,hevc` | drivers/media/platform/exynos/hevc/hevc.c | none (s5p-mfc covers decoders; separate HEVC IP unsupported) | — | skip | Vendor HEVC decoder |
| `/mdev_capture`, `/mdev_output` (2 nodes) | `samsung,exynos5-mdev` | drivers/media/platform/exynos/mdev/exynos-mdev.c | none | — | skip | /dev/media plumbing shim |

## 17. DMA / IOMMU (36 nodes — 5 same / 31 diff / 0 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/amba` | `arm,amba-bus` | drivers/amba/bus.c | `of/platform.c:32` (same) | `arm/primecell.yaml` | (implicit) | dt-only | — |
| `/amba/pdma0@15610000` | `arm,pl330`, `arm,primecell` | drivers/dma/pl330.c | `pl330.c:3250` AMBA id `0x00041330` (same IP) | `dma/arm,pl330.yaml:21,33` | `pdma0@15610000:1883` | dt-only | — |
| `/amba/pdma1@15600000` | `arm,pl330`, `arm,primecell` | idem | idem | idem | `pdma1@15600000:1892` | dt-only | — |
| `/amba/adma@11420000` | `arm,pl330`, `arm,primecell` | idem | idem | idem | `adma@11420000:1911` | dt-only | Audio DMA (i2s0 uses it) |
| `/amba/mdma1@12500000` | `arm,pl330`, `arm,primecell` | idem | idem | idem | — (no node upstream) | dt-only | Write the node from stock reg |
| `/sysmmu@0x13A00000`, `/sysmmu@0x13A10000`, `/sysmmu@0x13A20000`, `/sysmmu@0x13A30000` (disp/tv, 4 nodes) | `samsung,exynos5430-sysmmu` | drivers/iommu/exynos-iommu.c | `exynos-iommu.c:869` `samsung,exynos-sysmmu` | `iommu/samsung,sysmmu.yaml` | `sysmmu_decon0x@13a00000:1287`, `sysmmu_decon1x@13a10000`, `sysmmu_tv0x@13a20000`, `sysmmu_tv1x@13a30000` | dt-only | All 4 present upstream |
| `/sysmmu@0x13C80000`, `/sysmmu@0x13C90000`, `/sysmmu@0x13CA0000` (gscl, 3 nodes) | idem | idem | idem | idem | `sysmmu_gscl0@13c80000`, `sysmmu_gscl1@13c90000`, `sysmmu_gscl2@13ca0000` | dt-only | All present |
| `/sysmmu@0x15040000`, `/sysmmu@0x15050000`, `/sysmmu@0x15060000` (scaler/jpeg, 3 nodes) | idem | idem | idem | idem | `sysmmu_scaler_0@15040000`, `sysmmu_scaler_1@15050000`, `sysmmu_jpeg@15060000` | dt-only | All present |
| `/sysmmu@0x15200000`, `/sysmmu@0x15210000` (mfc, 2 nodes) | idem | idem | idem | idem | `sysmmu_mfc_0@15200000`, `sysmmu_mfc_1@15210000` | dt-only | All present |
| `/sysmmu@0x114E0000` (aud, 1 node) | idem | idem | idem | idem | — (absent upstream) | dt-only | Write from stock reg; attach to audio-subsystem |
| `/sysmmu@0x12150000`, `/sysmmu@0x12160000`, `/sysmmu@0x12170000`, `/sysmmu@0x12180000`, `/sysmmu@0x121A0000` (cam0, 5 nodes) | idem | idem | idem | idem | — | dt-only | Camera cluster; only useful with FIMC-IS |
| `/sysmmu@0x12450000` (g2d, 1 node) | idem | idem | idem | idem | — | dt-only | G2D unsupported anyway |
| `/sysmmu@0x142B0000`, `/sysmmu@0x142C0000`, `/sysmmu@0x142D0000`, `/sysmmu@0x14320000`, `/sysmmu@0x14330000`, `/sysmmu@0x14340000`, `/sysmmu@0x143A0000`, `/sysmmu@0x143B0000`, `/sysmmu@0x143C0000`, `/sysmmu@0x143D0000` (isp, 10 nodes) | idem | idem | idem | idem | — | dt-only | ISP cluster; only useful with FIMC-IS |
| `/sysmmu@0x14F00000`, `/sysmmu@0x14F10000` (mscl, 2 nodes) | idem | idem | idem | idem | — | dt-only | Uncertain: no upstream nodes; registers from stock DT |

## 18. Others (8 nodes — 0 same / 1 diff / 7 none)

| Stock path | Stock compatible | Stock driver (3.10) | Mainline driver (6.12) | Mainline binding | Mainline node | Effort | Notes |
|---|---|---|---|---|---|---|---|
| `/slimsss@11140000` | `samsung,exynos5-slimsss` | drivers/crypto/ace.c | `s5p-sss.c:414` `exynos5433-slim-sss` | `crypto/samsung-slimsss.yaml:21` | `slim_sss@11140000:662` | dt-only | SHA/AES crypto |
| `/sss@11100000` | `samsung,exynos5-sss` | drivers/crypto/ace.c | none (`s5p-sss.c` supports only s5pv210-secss/exynos4210-secss/slim-sss) | — | — | skip | Different SSS block, unsupported |
| `/argos` | `samsung,argos` | drivers/staging/samsung/sec_argos.c | none | — | skip | Android scheduler-bandwidth shim |
| `/ion` | `samsung,exynos5430-ion` | drivers/gpu/ion/exynos/exynos_ion.c | none (ION removed; use DMA-BUF heaps) | — | skip | — |
| `/ipa_pdata` | `samsung,exynos-ipa` | drivers/thermal/ipa.c | none (mainline IPA is internal to thermal) | — | skip | Power-model data; upstream IPA computes its own |
| `/otp_ctrl@0x101E0010` | `samsung,exynos5-otp_ctrl` | none found (no dedicated driver in stock tree either) | none | — | uncertain | Keep disabled until purpose is clear |
| `/secgpio_dvs` | `samsung,exynos5433-secgpio-dvs` | drivers/pinctrl/secgpio_dvs.c | none | — | skip | Factory GPIO verification |
| `/spi@14d00000/spidev@0` | `spi_boot_link` | drivers/misc/modem_v1/link_device_spi.c | none | — | skip | CP boot SPI link; drop with modem |

---

## Board DT values you will need (quoted from `dumps/live_fdt.dts`)

### eMMC (dwmmc0@15540000)

| Property | Value | Line |
|---|---|---|
| reg | `0x15540000 0x2000` | l.4053 |
| broken-cd | present | l.4069 |
| sdr-timing | `<0x03 0x00 0x02 0x00>` | l.4077 |
| fifo-depth | `0x80` | l.4079 |
| hs200-timing | `<0x03 0x00 0x03 0x00>` | l.4081 |
| ciu-div | `0x3` | l.4091 |
| hs200-1-8v | present | l.4097 |
| ddr-timing | present | l.4098 |
| **bus-width** | `0x08` | l.4103 |

Rails: vmmc = LDO17 `vmmc` 2.8 V (l.2354-2357); vqmmc = LDO2 `vqmmc` 1.8-3.3 V (l.2380-2385).

### SD card (dwmmc2@15560000)

| Property | Value | Line |
|---|---|---|
| reg | `0x15560000 0x2000` | l.1256 |
| sdr104 | (property present) | l.1266 |
| cd-gpio | `<0x26 0x04 0x0f>` → gpa2-4 | l.1274 |
| sdr-timing | present | l.1276 |
| fifo-depth | `0x40` | l.1278 |
| vmmc-en-gpio | `<0x27 0x07 0x01>` | l.1284 |
| ciu-div | present | l.1286 |
| **bus-width** | `0x04` | l.1296 |

### PMIC (S2MPS13)

* I2C bus `hsi2c@14E40000`, reg `0x14e40000 0x1000` l.2307; `clock-freq = <0x2625a0>` (2.5 MHz) l.2318.
* `s2mps13_pmic@66`, reg 0x66, compatible `samsung,s2mps13-pmic` l.2322-2323.
* Interrupt: `<0x07 0x00 0x00>` = gpa0-7, parent gpa0 (l.2331, interrupt-parent l.2337).

Regulator set (name → constraints → line): LDO3 `VDD1_E_1.8V_AP` l.2347-2351 · LDO17 `vmmc` 2.8 V l.2354-2357 · LDO2 `vqmmc` 1.8-3.3 V l.2380-2385 · LDO18 `V_CODEC_1.8V_AP` (all 8 wm1814 supplies = `0x5c`) l.2389-2395 · BUCK6 `vdd_g3d` 0.6-1.5 V l.2399-2405 · BUCK1 `vdd_mif` l.2415 · LDO33 `vtouch_3.3v` l.2449-2452 · LDO35 `VCC_3.0V_MOTOR_AP` (haptic) l.2461-2464 · LDO32 `vtouch_1.8v` l.2467-2471 · BUCK4 `vdd_int` l.2474 · LDO25 `VCI_3.0V` (panel) l.2484-2488 · BUCK3 `vdd_kfc` l.2491 · LDO40 `VLED` (backlight) l.2507-2510 · BUCK2 `vdd_eagle` l.2513 · LDO37 `VDDR_1.6V` (panel) l.2539-2543 · LDO30 `tsp_avdd` 3.3 V l.2546-2549 · LDO39 `VDD3_1.8V` (panel IO) l.2552-2556 · LDO31 `tsp_io` 1.85 V l.2565-2568.

### USB

* `usb@15400000` reg `0x15400000 0x10000` l.2787-2788; child `dwc3` l.2796-2797;
  **`dr_mode = "otg"` l.2799; `maximum-speed = "high-speed"` l.2800.**
* USB3 PHY `usbphy@15500000` l.3049; `usbphy-sys = <0x105c0704 0x04>` l.3057.
* OTG role needs the SM5703 MUIC (none upstream — see uncertainties).

### Display / panel

* `decon_fb` reg 3 regions l.992; `lcd_info` blob l.996 (replace with standard bindings).
* MIPI-DSI: burst mode l.1041, **4 lanes** l.1042.
* Panel node l.1045-1061 (`s6e3ha2_qxga`, no `compatible` in stock — the panel carries
  `lcd_info` instead): `dsi-hs-clk 0x400` l.1046 · MIC enable l.1053 ·
  **resolution `<0x600 0x800>` = 1536×2048** l.1054 · v-porch l.1055 ·
  `esc-clk 0x10` l.1056 · physical size l.1057 · refresh 0x3c = 60 Hz l.1058 ·
  `errfg-gpio` l.1059 · h-porch l.1060.
* Panel rails: LDO25 `VCI_3.0V` (l.2484-2488), LDO39 `VDD3_1.8V` (l.2552-2556), LDO37 `VDDR_1.6V` (l.2539-2543); backlight via LDO40 `VLED` (l.2507-2510).
* CEC reg l.2138. Mainline panel driver `s6e3ha2` expects `samsung,s6e3ha2`
  (panel-samsung-s6e3ha2.c of_match :774; binding `samsung,amoled-mipi-dsi.yaml:20`);
  tm2 board node `panel@0` (tm2.dts:56).

### Input

* `gpio_keys` l.7021-7058: VOL-UP gpa2-0, code `0x73` l.7028-7032 · HOME gpa0-3, code `0xac` l.7036-7041 · VOL-DOWN gpa2-1, code `0x72` l.7045-7049 · POWER gpa2-7, code `0x74` l.7053-7058.
* Touchscreen `synaptics,rmi4` @0x20 on hsi2c@14ED0000 l.1663-1674; IRQ gpa1-1 `<0x42 0x01 0x00>` l.1674; rails LDO30 3.3 V + LDO31 1.85 V.
* Touchkey `coreriver,tc300-keypad` @0x20 l.1884-1905; IRQ gpa3-2 l.1897; rails LDO33 3.3 V + LDO32 1.8 V.
* Hall sensor gpa0-1 l.5367-5372 (→ gpio-keys `SW_LID`).
* Haptic: LDO35 enable + `pwm_id 0` l.4749-4761 (PWM@14dd0000).

### Connectivity

* WLAN `samsung,brcm-wlan` l.4733-4739 (bcmdhd; mainline = brcmfmac4358, see uncertainties).
* Bluetooth `broadcom,bcm4358` l.4198-4204, on `serial@11460000` l.3989-3990; enable/regulator GPIOs l.4202.
* PCIe `pcie@15700000` l.7065-7077, `num-lanes = <1>` l.7077.
* GPS l.1245.

### Core block addresses (quoted)

MCT reg l.921 · chipid l.1826 · GIC l.4770 · CMU l.1818 · watchdog l.1680 ·
RTC l.6987 · PWM l.97 · ADC l.4452 · arm-pmu l.4764 · TMU 5 thermal regions
l.4237-4238 · oscclk `clock-frequency <0x16e3600>` (24 MHz) l.1344-1347 ·
pd-fsys disabled l.4136 · mipi-lli l.5506-5509 · audio `sound` node
l.5344-5352 (`samsung,pacific-arizona`, audio-cpu phandle `0xbe`, audio-codec `0xbf`) ·
wm1814@1a l.1975-2022 (`reset` gpc0-7 l.2004, `ldoena` gpf0-0 l.1975).

---

## Recommended milestone order

1. **Boot to serial console + eMMC rootfs** — pinctrl ×10 + wakeup-eint;
   `xxti` fixed-clock 24 MHz (l.1346) + the 19 CMU nodes from mainline dtsi;
   GIC `@11001000`; MCT `@101C0000` (l.921); UART console (start `serial@14C20000`,
   tm2 precedent tm2-common:48); dwmmc0 eMMC (bus-width 8, hs200-1.8v, l.4053-4103)
   + S2MPS13 PMIC @66 on hsi2c@14E40000 (l.2307-2337) + regulator set above;
   watchdog `@10020000` (`samsung,exynos5433-wdt`); RTC `@10590000`;
   slim-sss `@11140000`; ADC `@14D10000`.
2. **Storage + USB** — dwmmc2 SD card (cd gpa2-4 l.1274, vmmc-en l.1284, bus-width 4);
   USB DRD `usb@15400000` + dwc3 + `usbphy@15500000` (dr_mode otg l.2799,
   high-speed l.2800, usbphy-sys l.3057). USB role needs MUIC — start fixed-peripheral/host.
3. **Display** — decon@13800000 → dsi@13900000 (4 lanes l.1042, burst l.1041) →
   mic@13930000 → panel (1536×2048 l.1054, porches l.1055/1060, rails
   LDO25/LDO39/LDO37, backlight LDO40); `syscon_disp@13b80000`; `pd-disp`;
   decon_tv/hdmi/cec last (they are independent of the panel path).
4. **Input & sensors** — gpio-keys (4 keys, exact GPIOs/codes l.7028-7058);
   hall as gpio-keys SW_LID (gpa0-1 l.5367); rmi4 touchscreen (IRQ gpa1-1 l.1674,
   rails LDO30/31); lsm6ds3@6b; yas537@2e; sx9310 ×2; then touchkey and cm36652
   (both need new/port drivers).
5. **Connectivity, GPU, audio** — pcie@15700000 (1 lane) + brcmfmac4358 firmware;
   BT hci_bcm on serial@11460000 (gpios l.4202); panfrost `gpu@14ac0000`
   (T760, BUCK6 vdd_g3d l.2399-2405); audio machine driver last (i2s0/i2s1,
   lpass@11400000, wm1814@1a, LDO18 for all codec supplies) — model it on
   `samsung,tm2-audio`/`samsung,midas-audio`.

---

## Uncertainties

* **Wi-Fi interface** — stock uses bcmdhd (`samsung,brcm-wlan` l.4733). Mainline
  brcmfmac ships `brcmfmac4358-pcie` (brcmfmac/pcie.c:59); whether this board's
  4358 hangs off `pcie@15700000` or SDIO is unverified from the DT alone. The
  pcie node is present and enabled in the stock DT, which supports PCIe, but
  mark **uncertain** until probed on hardware.
* **Panel compatible** — stock panel is `s6e3ha2_qxga` 1536×2048 (l.1045-1061);
  mainline `samsung,s6e3ha2` was written for the 1600×2560 TM2 panel. The GTS2
  panel likely needs a new compatible + small driver change (init sequence
  from the vendor `lcd_info`, l.996).
* **USB2 host** — `usb@15510000` (EHCI), `usb@15520000` (OHCI) and
  `usb2phy@15530000` have no mainline path for 5433 (no USB2 PHY driver); the
  exynos4210-era drivers exist but nothing binds them without a PHY. Marked skip.
* **dwmmc variant** — 6.12 `dw_mmc-exynos.c` has no `samsung,exynos5433-dw-mshc-smu`;
  the dtsi uses it only as a fallback paired with `samsung,exynos7-dw-mshc-smu`.
  SMU-side behavior differences are untested on this board.
* **gsc / mfc compatibles** — the stock strings `samsung,exynos5-gsc` and
  `samsung,mfc-v6` *do* appear in mainline drivers but bind deprecated/wrong
  variant data; always write `samsung,exynos5433-gsc` / `samsung,exynos5433-mfc`.
* **I2S** — `samsung,i2s-v5` is not in the mainline driver; use the
  `exynos5433-i2s` + `exynos7-i2s` pair exactly as the dtsi does.
* **CEC** — driver + binding exist, but no 5433 CEC node exists upstream; the
  node is dt-only and the integration untested.
* **SYSMMU coverage** — only 12 of the 31 stock SYSMMU nodes exist in the
  mainline dtsi (disp/tv/gscl/scaler/jpeg/mfc). The other 19 (aud, cam0, g2d,
  isp, mscl) must be written from stock registers; their `power-domain`/`clock`
  wiring is unverified — **uncertain**.
* **otp_ctrl** — no dedicated driver found in either tree; purpose unknown (l.98).
* **pd-fsys** — disabled in stock (l.4136) yet its 5 spd children are counted by
  the extractor; fsys devices (mmc/usb) run without a PD node upstream.
* **CPU naming** — stock claims a7/a15; the 5433 is really A53+A57. Mainline
  cpu nodes must use `arm,cortex-a53`/`arm,cortex-a57` + PSCI, so no stock
  cpu property can be copied verbatim.
* **pmu interrupts** — stock single `arm-pmu` node vs mainline two per-cluster
  nodes; interrupt affinity per cluster needs the GIC SPI list from the stock
  node (l.4764) split in two — verify on boot.
* **MUIC / charging** — SM5703 MFD, charger, fuel gauge and `muic-universal`
  have no upstream drivers; USB OTG role and battery/charging stay broken until
  new drivers are written. Only a Maxim MUIC exists upstream as a reference.
* **Audio machine driver** — `samsung,pacific-arizona` has no upstream
  equivalent; the wm1814 codec itself is supported by the arizona core, but the
  machine driver (DAI link, routing, mic-bias) is new work modeled on
  tm2_wm5110.c / midas_wm1811.c.
* **Touchkey / light sensor** — `coreriver,tc300-keypad` (l.1884) and `cm36652`
  (l.79) have no upstream drivers; `cypress,tm2-touchkey` and `capella,cm36651`
  are *different hardware* and cannot be reused as-is.
* **vmmc-en-gpio phandle** — `<0x27 0x07 0x01>` (l.1284) resolves only inside
  the decompiled tree (phandle 0x27 bank not re-derived here); cross-check the
  bank name against the pinctrl dump before writing the board DT.
* **GPS** — stock BCM4752 driver is a vendor char device; the mainline
  `gnss/bcm4751.yaml` binding is for a different wiring; treat as new-driver.
