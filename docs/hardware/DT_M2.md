# Device-tree milestone 2 — SM-T715 (gts28ltexx)

PMIC (S2MPS13), internal eMMC and USB DWC3 (peripheral) for the mainline
6.12 arm32 kernel.  Every value below is traceable to the device's real
device tree (`dumps/live_fdt.dts`) or to a mainline binding / the
mainline TM2 board (same SoC, same PMIC).  Anything not traceable was
left out (list at the end).

Files: `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m2.dtsi` (+ the
`-m2.dts` wrapper and `Makefile` entry), config fragment
`arch/arm/configs/gts28ltexx_m2.config`.

## hsi2c bus + PMIC

| DT value (m2) | Source |
|---|---|
| `&hsi2c_0` enabled (i2c@14e40000) | live_fdt.dts:2305 `hsi2c@14E40000`, status okay; same reg `0x14e40000` as mainline `arch/arm64/boot/dts/exynos/exynos5433.dtsi:1595` |
| PMIC `pmic@66`, `compatible = "samsung,s2mps13-pmic"` | live_fdt.dts:2320–2323 (`s2mps13_pmic@66`, reg `<0x66>`) |
| `interrupt-parent = <&gpa0>`, `interrupts = <7 IRQ_TYPE_LEVEL_LOW>` | live_fdt.dts:2337–2338 (`interrupt-parent <0x4b>` = gpa0 bank (live_fdt.dts:181), `interrupts = <7 0 0>`, pin gpa0-7 — the `pmic-irq` group live_fdt.dts:126). The live tree's type cell carries no type; the downstream 3.10 driver hard-codes `IRQF_TRIGGER_LOW` (kernel_universal5433 `drivers/mfd/sec-irq.c:382`), and TM2 uses `IRQ_TYPE_LEVEL_LOW` (`exynos5433-tm2-common.dtsi:396`). |
| `s2mps13-clk` clocks sub-node, 3 outputs | mainline TM2 `exynos5433-tm2-common.dtsi:399-404` (binding-required shape, `mfd/samsung,s2mps11.yaml`) |
| PMIC regulators: 31 nodes, exact names/voltages/flags | live_fdt.dts:2345–2576 (see table below) |

Not copied from the live PMIC node (downstream-only properties, absent
from the mainline `mfd/samsung,s2mps11.yaml` binding — `additionalProperties:
false` would reject them): `g3d_en`, `check_jigon`, `wtsr_en`,
`smpl_timer_val`, `init_time,*`, `gpios`, `dvs_en`, `smpl_warn_vth`,
`wtsr_timer_val`, `smpl_warn_en`, `smpl_en`, the `pinctrl-0` phandle list
(pm-g3d-en / pm-dvs-en / pmic-irq / pm-wrsti / gpa3 groups don't exist as
such in mainline `exynos5433-pinctrl.dtsi`).

`samsung,s2mps11-wrstbi-ground` (TM2) was **not** added: the live tree
wires the WRSTBI pin via its own `pm-wrsti` group and the mainline
property's presence is not established for this board.

`wakeup-source` (TM2) **not** added: not present in the live tree.

`regulator-initial-mode` (live tree, many regulators) **omitted**: the
mainline S2MPS13 regulator driver registers no `of_map_mode`, so the
regulator core ignores the property with a warning
(`drivers/regulator/of_regulator.c:443` with `match->desc == NULL`).
`regulator-ramp-delay` was kept — it is a generic, honoured property.

## PMIC regulator mapping (real name → mainline node, µV)

31 regulators described in the live tree; node names match the mainline
driver's expected names 1:1 (`drivers/regulator/s2mps13.c` matches DT
children by node name `LDO#`/`BUCK#`).  19 further regulators (LDO1,
LDO4–10, LDO12–16, LDO24, LDO28, BUCK7–10) are **not** described in the
live tree: they stay absent, and the mainline regulator core then never
disables them (no constraints ⇒ no `REGULATOR_CHANGE_STATUS` in
`valid_ops_mask` ⇒ `regulator_late_cleanup()` skips them) — the same
behaviour as the stock kernel.

| Mainline node (label) | Real regulator-name | min µV | max µV | Flags |
|---|---|---|---|---|
| LDO2 (`ldo2_reg`) | vqmmc | 1800000 | 3300000 | boot-on |
| LDO3 (`ldo3_reg`) | VDD1_E_1.8V_AP | 1800000 | 1800000 | always-on |
| LDO6 (`ldo6_reg`) | VDD10_MIPI2L_1.0V_AP † | 1000000 | 1000000 | — |
| LDO10 (`ldo10_reg`) | VDD33_USB30_3.0V_AP † | 3000000 | 3000000 | — |
| LDO11 (`ldo11_reg`) | vdd_int_m | 600000 | 1500000 | always-on, boot-on, ramp 12000 |
| LDO17 (`ldo17_reg`) | vmmc | 2800000 | 2800000 | — |
| LDO18 (`ldo18_reg`) | V_CODEC_1.8V_AP | 1800000 | 1800000 | always-on |
| LDO19 (`ldo19_reg`) | GRIP_1.8V | 1800000 | 1800000 | always-on, boot-on |
| LDO20 (`ldo20_reg`) | VCC_2.8V_AP | 2800000 | 2800000 | always-on, boot-on |
| LDO21 (`ldo21_reg`) | VT_CAM_1.8V | 1800000 | 1800000 | — |
| LDO22 (`ldo22_reg`) | CAM_IO_1.8V_AP | 1800000 | 1800000 | — |
| LDO23 (`ldo23_reg`) | CAM_SEN_CORE_1.2V_AP | 1300000 | 1300000 | — |
| LDO25 (`ldo25_reg`) | VCI_3.0V | 3000000 | 3000000 | boot-on |
| LDO26 (`ldo26_reg`) | CAM_AF_2.8V_AP | 2800000 | 2800000 | — |
| LDO27 (`ldo27_reg`) | VT_CAM_2.8V | 2800000 | 2800000 | — |
| LDO29 (`ldo29_reg`) | CAM_SEN_A2.8V_AP | 2800000 | 2800000 | — |
| LDO30 (`ldo30_reg`) | tsp_avdd | 3300000 | 3300000 | — |
| LDO31 (`ldo31_reg`) | tsp_io | 1850000 | 1850000 | — |
| LDO32 (`ldo32_reg`) | vtouch_1.8v | 1800000 | 1800000 | boot-on |
| LDO33 (`ldo33_reg`) | vtouch_3.3v | 3300000 | 3300000 | — |
| LDO34 (`ldo34_reg`) | VCC_1.8V_MHL | 1800000 | 1800000 | — |
| LDO35 (`ldo35_reg`) | VCC_3.0V_MOTOR_AP | 3000000 | 3000000 | — |
| LDO36 (`ldo36_reg`) | VSIL_1.2A | 1250000 | 1250000 | — |
| LDO37 (`ldo37_reg`) | VDDR_1.6V | 1600000 | 1600000 | boot-on |
| LDO38 (`ldo38_reg`) | VCC_3.3V_MHL | 3300000 | 3300000 | — |
| LDO39 (`ldo39_reg`) | VDD3_1.8V | 1800000 | 1800000 | boot-on |
| LDO40 (`ldo40_reg`) | VLED_2.8V | 2800000 | 2800000 | — |
| BUCK1 (`buck1_reg`) | vdd_mif | 600000 | 1500000 | always-on, boot-on, ramp 12000 |
| BUCK2 (`buck2_reg`) | vdd_eagle | 600000 | 1500000 | always-on, boot-on, ramp 12000 |
| BUCK3 (`buck3_reg`) | vdd_kfc | 600000 | 1500000 | always-on, boot-on, ramp 12000 |
| BUCK4 (`buck4_reg`) | vdd_int | 600000 | 1500000 | always-on, boot-on, ramp 12000 |
| BUCK5 (`buck5_reg`) | vdd_disp_cam0 | 600000 | 1500000 | always-on, boot-on, ramp 12000 |
| BUCK6 (`buck6_reg`) | vdd_g3d | 600000 | 1500000 | always-on, boot-on, ramp 12000 |

† LDO6/LDO10 are **not** in the live tree.  They were added from TM2
(`exynos5433-tm2-common.dtsi:453–460`, `492–499`) because the
`samsung,exynos-dwc3` binding makes `vdd10-supply`/`vdd33-supply`
required and the mainline `dwc3-exynos.c` glue enables both regulators at
probe; without the nodes the DWC3 driver would fail with
`regulator_enable` on a dummy, or worse silently probe with a stub.  The
real hardware rails exist (USB works under the stock kernel); the live
tree simply never describes them (the 3.10 driver did not require it).

## eMMC (`&mshc_0`, dwmmc0@15540000)

| DT value (m2) | Source |
|---|---|
| `cap-mmc-highspeed` | live_fdt.dts:4103 `supports-highspeed` |
| `mmc-hs200-1_8v` | live_fdt.dts:4104 `supports-hs200-1-8v-mode` |
| `non-removable` | live_fdt.dts:4101 `broken-cd` (eMMC is soldered; TM2 idiom `exynos5433-tm2-common.dtsi:954`) |
| `card-detect-delay = <200>` | live_fdt.dts:4058 `<0xc8>` |
| `samsung,dw-mshc-ciu-div = <3>` | live_fdt.dts:4089 `<0x03>` |
| `samsung,dw-mshc-sdr-timing = <0 2>` | live_fdt.dts:4085 `<3 0 2 0>` (see decoding below) |
| `samsung,dw-mshc-ddr-timing = <2 3>` | live_fdt.dts:4086 `<3 0 3 2>` |
| `fifo-depth = <0x80>` | live_fdt.dts:4084 |
| `bus-width = <8>` | live_fdt.dts:4099 slot@0 |
| `vmmc-supply = <&ldo17_reg>` | live_fdt.dts:2360 regulator-name "vmmc" (2.8 V); MMC core looks supplies up by name (`drivers/mmc/core/regulator.c`) |
| `vqmmc-supply = <&ldo2_reg>` | live_fdt.dts:2380 regulator-name "vqmmc" (1.8–3.3 V) |
| pinctrl `sd0_clk/cmd/rdqs/bus1/bus4/bus8` | live_fdt.dts:4056 pinctrl-0 `<0x13..0x18>` = sd0-clk/cmd/rdqs/bus-width1/4/8 (live_fdt.dts:1100–1145 area); mainline groups at `exynos5433-pinctrl.dtsi:256–305` carry the same pins |
| alias `mmc0 = &mshc_0` | live_fdt.dts:5216 `mshc0 = "/dwmmc0@15540000"` (downstream alias name mapped to the mainline `mmcN` convention, as TM2 does at `exynos5433-tm2-common.dtsi:24`) |

### Timing-tuple decoding (downstream 4-cell → mainline 2-cell)

The downstream 3.10 driver parses 4 cells
(`dw_mmc-exynos.c:846–896` in kernel_universal5433) through
`SDMMC_CLKSEL_TIMING(div, f_drv, drv, sample)`
(`arch/arm/mach-exynos/include/mach/exynos-dwmci.h:87`), i.e. the tuple
order is `<ciu-div, fine-drive, drive, sample>`.  The mainline driver
parses 2 cells through `SDMMC_CLKSEL_TIMING(sample, drv, div)`
(`dw_mmc-exynos.c:405–416`, `dw_mmc-exynos.h:27`), i.e. `<sample, drive>`
with div taken from `samsung,dw-mshc-ciu-div`.  Decoding the live tree:

| Property | Live 4-cell | Mainline 2-cell |
|---|---|---|
| sdr | `<3 0 2 0>` | `<0 2>` |
| ddr | `<3 0 3 2>` | `<2 3>` |
| sdr-hs | `<3 0 2 1>` | no mainline equivalent (MMC/SD HS falls into the `default: sdr_timing` branch of `dw_mci_exynos_set_ios`, `dw_mmc-exynos.c:364`) |
| hs200 | `<3 0 3 0>` | no mainline equivalent (HS200 also uses `sdr_timing` + runtime tuning) |

The downstream `use-fine-tuning` / `bypass-for-allpass` /
`use-enable-shift` / ddr200 properties are handled by driver code that
does not exist in mainline and are dropped (HS200 tuning on mainline
uses the generic DW-MMC tuning machinery instead).

## USB (`&usbdrd30`, `&usbdrd30_phy`, `&usbdrd_dwc3`)

| DT value (m2) | Source |
|---|---|
| `&usbdrd30` status okay | live_fdt.dts:2784–2790 `usb@15400000`, status okay, same reg `0x15400000` as mainline `exynos5433.dtsi:1763` |
| `vdd33-supply = <&ldo10_reg>`, `vdd10-supply = <&ldo6_reg>` | required by the `samsung,exynos-dwc3` binding (`usb/samsung,exynos-dwc3.yaml` required list); values from TM2 `exynos5433-tm2-common.dtsi:1355–1359` (see regulator table †) |
| `dr_mode = "peripheral"` | task requirement (no MUIC/extcon driver in scope); the real tree says `otg` (live_fdt.dts:2800) but OTG role switching needs the SM5703 MUIC, out of scope |
| `maximum-speed = "high-speed"` | live_fdt.dts:2801 |
| `&usbdrd30_phy` status okay | live_fdt.dts:3045 `usbphy@15500000` (compatible `samsung,exynos5430-usb3phy`, same reg as mainline `samsung,exynos5433-usbdrd-phy`); the binding (`phy/samsung,usb3-drd-phy.yaml`) requires no supplies for this compatible |
| IRQ 231 (`GIC_SPI 231`) | live_fdt.dts:2802 `<0x00 0xe7 0x00>` = 231, matches mainline `exynos5433.dtsi:1781` |
| clocks | provided by the mainline dtsi node; live tree's 2-clock encoding is a downstream clock binding, not copied |

The `vbus-supply` that TM2 sets on the PHY (a max77843 `safeout1_reg`)
was **not** copied: this device's MUIC is an SM5703 (out of scope) and
`vbus-supply` is optional in the binding.

## Config fragment (`gts28ltexx_m2.config`)

All symbols verified present and satisfiable `=y` on arm/6.12:

- `I2C_EXYNOS5` — tristate, depends on `OF` + `ARCH_EXYNOS` (satisfied)
- `MFD_SEC_CORE`, `REGULATOR_S2MPS11`, `COMMON_CLK_S2MPS11` — tristate, S2MPS13 covered by all three drivers
- `MMC`, `MMC_BLOCK`, `MMC_DW`, `MMC_DW_PLTFM`, `MMC_DW_EXYNOS` — tristate chain, `MMC_DW_EXYNOS` selects `MMC_DW_PLTFM`
- `USB`, `USB_GADGET`, `USB_DWC3`, `USB_DWC3_GADGET`, `USB_DWC3_EXYNOS`, `PHY_EXYNOS5_USBDRD` — tristate/bool chain; `USB_DWC3_GADGET` (bool) is the choice over `USB_DWC3_DUAL_ROLE`/`USB_DWC3_HOST`, consistent with `dr_mode = "peripheral"`; `PHY_EXYNOS5_USBDRD` depends on `USB_DWC3_EXYNOS` (satisfied)
- `USB_LIBCOMPOSITE`, `USB_CONFIGFS`, `USB_CONFIGFS_RNDIS`, `USB_CONFIGFS_ECM` — gadget framework
- `EXT4_FS`

No symbol had to be dropped.  `CONFIG_I2C` is set `=y` (it is not in the
defconfig; `I2C_EXYNOS5=y` would otherwise still select it, but the
explicit line keeps the fragment self-describing).

## What was left out, and why

1. **PMIC downstream-only properties** (wtsr/smpl/g3d/dvs/init_time/gpios)
   — not in the mainline binding, rejected by dtbs_check.
2. **`regulator-initial-mode`** — mainline S2MPS13 driver has no
   `of_map_mode`; the core ignores the property with a pr_warn.
3. **`samsung,s2mps11-wrstbi-ground`, `wakeup-source`** — TM2-only
   properties not evidenced by the live tree.
4. **19 undescribed regulators** — not in the live tree; adding them
   would be inventing values.
5. **eMMC downstream tuning knobs** (`use-fine-tuning`,
   `bypass-for-allpass`, `use-enable-shift`, `ignore-phase`, ddr200
   timing/delay-line properties, `ciu_clkin`, `num-ref-clks`, `qos_int_level`,
   `clk_val/clk_pin/clk_str_num/clk_addr`, `desc-size`, `enable-*` flags)
   — downstream driver features absent from mainline.
6. **HS200/sdr-hs timings** — no mainline binding equivalent (HS200 uses
   `sdr-timing` + generic tuning).
7. **eMMC `supports-ddr200-*`, `supports-poweroff-notification`,
   `enable-cclk-on-suspend`, `fixed_volt`, `extra_tuning`, `only_once_tune`**
   — downstream-only, dropped.
8. **`sd0_qrdy` pinctrl group** — TM2 includes it, but the live tree's
   eMMC pinctrl-0 does not reference a qrdy group for this slot; left
   out to stay faithful to the real wiring.
9. **USB `vbus-supply` on the PHY** — TM2's value is a max77843 rail
   this device doesn't have (SM5703 MUIC out of scope); optional in the
   binding.
10. **`adj-sof-accuracy`** (live dwc3) — not in the mainline `snps,dwc3`
    binding.
11. **`is_gpio`** (live usb@15400000) — downstream-only.
12. **HS400** — the live tree does not enable `supports-hs400-*`; only
    highspeed + HS200 are declared, so no `mmc-hs400-1_8v` /
    `samsung,dw-mshc-hs400-timing` / `samsung,read-strobe-delay`.

## Validation level

Build-tested only (no device interaction, per task constraints):

- `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_m2.config`
  produces `out/mainline-m2/zImage` (2.9 MiB) and
  `exynos5433-gts28ltexx-m2.dtb`; the required Kconfig symbols are all
  `=y` in `out/mainline-m2/.config`.  The ARM64 non-regression
  phase (defconfig + exynos clk/pinctrl + `exynos5433-tm2.dtb`) also
  passes.
- **dtschema dtbs_check ran** (`make ARCH=arm O=/build CHECK_DTBS=y
  samsung/exynos5433-gts28ltexx-m2.dtb` with dtschema 2026.9, installed
  in the container via `apt-get install python3-pip` +
  `pip3 install --break-system-packages dtschema`; `python3 -m venv`
  fails in the image — no ensurepip).  Exit 0.  All findings pre-exist
  in the milestone-1 board file or the SoC dtsi and also affect upstream
  boards; the m2 nodes (PMIC, regulators, eMMC, USB) produced **zero**
  findings:
  - `/soc@0/pcie@15700000` interrupt-provider warning — inherited from
    `exynos5433.dtsi:1965` (present on TM2 too);
  - root `compatible = ["samsung,gts28ltexx", "samsung,exynos5433"]` not
    in `arm/samsung/samsung-boards.yaml` — the board needs its own
    binding entry (milestone-1 scope, not this task);
  - `oscclk` fixed-clock missing `clock-frequency` — inherited from
    `exynos5433.dtsi:46`.
- Default-build non-regression: `bash -n`, script review, and a full
  throw-away default build in volume `t715-kbuild-out-check` output to
  `/tmp/t715-defcheck` (zImage + DTBs OK, then volume removed).  Per the
  concurrency rule, the default `t715-kbuild-out` volume was never
  touched by this task.  The first throw-away run exposed an unbound
  `FRAGMENT_NAME` variable in the script's default path (`set -u`);
  fixed by initialising it — the fragment path was unaffected.

## Supervisor review changes (2026-10-28)

- **LDO6 / LDO10 removed**, together with `vdd33-supply` / `vdd10-supply` on `&usbdrd30`. Their voltages came from the TM2 board, not from this device: the live tree does not say which rails feed the USB block. Without the properties, `dwc3-exynos` gets dummy regulators and the rails stay as the bootloader left them, as with the stock kernel.
- **`&framebuffer` now lists `vci-supply` (LDO25), `vddr-supply` (LDO37) and `vdd3-supply` (LDO39).** These panel rails are `regulator-boot-on` without `regulator-always-on`, so with no consumer the regulator core would switch them off when it cleans up unused regulators about 30 s after boot. `simple-framebuffer` / `simpledrm` enable every `*-supply` listed on the node.
