# Milestone 5 — Wi-Fi (BCM4358 / PCIe / brcmfmac) and Bluetooth (BCM4358 / UART3 / hci_bcm)

SM-T715 (gts28ltexx), mainline 6.12 arm32. Deliverables:
`arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m5.dtsi` (+ `-m5.dts`
wrapper), one `Makefile` line, `arch/arm/configs/gts28ltexx_m5.config`
(this document). Sources used: `dumps/live_fdt.dts` (the device's
stock device tree, ground truth), the downstream universal5433 kernel
sources in `src/kernel_universal5433/`, mainline bindings and
drivers, and the vendor configuration preserved in
`dumps/`/`legacy/phosh/`. MAC addresses and calibration data are
**not** copied into the repo.

---

## 1. Hardware summary

| Radio | Bus | Host driver | Chip as seen by mainline |
|---|---|---|---|
| Wi-Fi | PCIe (Exynos5433 DW host, `pcie@15700000`) | `brcmfmac` (PCIe) | PCI `14e4:43ec`, chip ID `0x4358` |
| Bluetooth | UART3 (`serial@11460000` = ttySAC3) | `hci_bcm` via serdev | LMP subver reported by BCM4358A3 firmware |

### 1.1 Why mainline brcmfmac probes this chip with no driver change

The stock kernel's dmesg records the endpoint config-space ID:
`dumps/dmesg.txt:312` — `device_vendor_id reg : 43ec14e4`, i.e.
**14e4:43ec**. That ID is not in any "4358" PCI table, because
Broadcom never gave 4358 a dedicated PCI ID entry — mainline matches it
through an older chip's entry:

- `drivers/net/wireless/broadcom/brcm80211/brcmfmac/pcie.c:2688` —
  `BRCMF_PCIE_DEVICE(BRCM_PCIE_4356_DEVICE_ID, WCC)`, and
  `include/linux/bcma/bcma_driver_pci.h`-adjacent header
  `brcm_hw_ids.h:78` — `#define BRCM_PCIE_4356_DEVICE_ID 0x43ec`.

Firmware selection does **not** use the PCI ID: at probe,
`brcmf_chip_recognition()` reads the chip ID from the hardware
(`chip.c:989`, `ci->pub.chip = regdata & CID_ID_MASK`), and
`brcmf_fw_alloc_request(devinfo->ci->chip, ...)` (`pcie.c:2241-2243`)
maps it through `BRCMF_FW_ENTRY(BRCM_CC_4358_CHIP_ID, 0xFFFFFFFF, 4358)`
(`pcie.c:95`) → base name **`brcmfmac4358-pcie`**. With `BRCMFMAC=y`
the fwvid vendor ops (WCC, `pcie.c:2480`) are compiled in, so no extra
module request occurs.

### 1.2 Why the DT Wi-Fi child carries no interrupts

`brcmf_of_probe()` parses `interrupts` only for SDIO:
`drivers/net/wireless/broadcom/brcm80211/brcmfmac/of.c:129` —
`if (bus_type != BRCMF_BUSTYPE_SDIO) return;` before any IRQ parsing
for OOB wake. A `host-wake` interrupt on the PCIe child would be dead
configuration, so it is omitted. (The stock WLAN host-wake pin is still
muxed — see the pinctrl table.)

---

## 2. Device tree — value-by-value source table

Everything below lives in `exynos5433-gts28ltexx-m5.dtsi`.

### 2.1 PCIe host (`&pcie`, mainline node from `arch/arm64/boot/dts/exynos/exynos5433.dtsi:1965`)

| DT value | Value | Source |
|---|---|---|
| `status` | `"okay"` | stock node is enabled-by-presence; milestone goal |
| `pinctrl-0` | `<&pcie_bus &wlan_en_pins &pcie_wake_pins &wlan_host_wake_pins>` | stock `pinctrl-0 = <0xaa 0xab 0xac 0xad>` (live_fdt.dts:7071) = pcie_bus, cfg-wlanen, pcie_wake, wlan_host_wake (phandles resolved in live_fdt) |
| `vdd10-supply` | `<&pcie_vdd10>` | binding-required (`samsung,exynos-pcie.yaml` required list); no real rail named in live_fdt (see §2.4) |
| `vdd18-supply` | `<&wlan_reg_on>` | binding-required; wired to the WLAN_EN GPIO rail so enabling supplies actually powers the chip (see §2.4) |
| `assigned-clocks` | `cmu_fsys CLK_MOUT_SCLK_PCIE_100_USER`, `cmu_top CLK_MOUT_SCLK_PCIE_100` | TM2 idiom, `exynos5433-tm2-common.dtsi:994-1000`; clock constants from `include/dt-bindings/clock/exynos5433.h` (CLK_MOUT_SCLK_PCIE_100_USER=6 cmu_fsys, CLK_MOUT_SCLK_PCIE_100=56, CLK_SCLK_PCIE_100_FSYS=228 cmu_top) |
| `assigned-clock-parents` | `CLK_SCLK_PCIE_100_FSYS`, `CLK_MOUT_BUS_PLL_USER` | same TM2 lines |
| `assigned-clock-rates` | `<0> <100000000>` | same TM2 lines (100 MHz PCIe refclk) |
| `interrupt-map-mask` | `<0 0 0 0>` | binding-required; TM2 `exynos5433-tm2-common.dtsi:1001-1002` |
| `interrupt-map` | `<0 0 0 0 &gic GIC_SPI 245 IRQ_TYPE_LEVEL_HIGH>` | same TM2 lines; matches the controller IRQ (GIC SPI 245, live_fdt.dts:7076 `interrupts = <0x00 0xf5 0x00>`) |
| child `wifi@0,0` `reg` | `<0x10000 0x0 0x0 0x0 0x0>` | bus 1, dev 0, fn 0 — stock enumeration at `0000:01:00.0` (dmesg.txt:312 block); same idiom as Apple `arch/arm64/boot/dts/apple/t8103-jxxx.dtsi:74-80` |
| child `compatible` | `"pci14e4,43ec"` | PCI bus binding form: `pci-device.yaml` (applied through `pci-bus-common.yaml` patternProperties to every `@<devfn>` child) requires a `pci<vendor>,<device>` compatible; Apple uses the same (`pci14e4,4425`). `brcm,bcm4329-fmac` alone fails the schema and 0x43ec is not in the fmac enum. Driver matching is unaffected — on PCI, brcmfmac binds via its `pci_device_id` table (0x43ec entry), not DT |
| child `brcm,board-type` | `"gts28ltexx"` | optional per binding; makes brcmfmac try `brcmfmac4358-pcie.gts28ltexx.*` firmware/NVRAM names first (`of.c:83-85`, `firmware.c` `brcm_alt_fw_path`) |

`&pcie_phy` (`pcie-phy@15680000`): `status = "okay"` — the host's `phys
= <&pcie_phy>` requires it (exynos5433.dtsi:1981).

### 2.2 Bluetooth UART (`&serial_3`)

Mainline `serial_3` = `serial@11460000` (exynos5433.dtsi) — matches the
stock `serial@11460000` node (live_fdt.dts:3988-4001) by register
address. `ro.bluetooth.tty=ttySAC3` (`dumps/getprop.txt:240`)
confirms userspace used UART3. `alias serial3 = &serial_3` added at
root (same as TM2 `exynos5433-tm2-common.dtsi:39`).

| DT value | Value | Source |
|---|---|---|
| `status` | `"okay"` | milestone goal |
| child `compatible` | `"brcm,bcm43540-bt"` | closest hci_bcm match: no `bcm4358` in `of_match` (`hci_bcm.c:1597-1612`); `brcm,bcm43540-bt` → `bcm4354_device_data` with `.no_early_set_baudrate = true` — matches the stock fixed-baud attach (vendor stack opens ttySAC3 at 921600, then loads the .hcd) |
| child `shutdown-gpios` | `<&gpd4 0 GPIO_ACTIVE_HIGH>` | stock BT node gpio 0 (live_fdt.dts:4198-4203); pin `cfg-en` gpd4-0 (6196-6201) |
| child `device-wakeup-gpios` | `<&gpr3 7 GPIO_ACTIVE_HIGH>` | stock gpio 1 / `cfg-btwake` gpr3-7 (3496-3501) |
| child `interrupt-parent`/`interrupts` | `<&gpa2 2 IRQ_TYPE_EDGE_RISING>` | stock gpio 2 / `cfg-hostwake` gpa2-2 (438-444); rising edge = downstream `IRQF_TRIGGER_RISING` (kernel_universal5433 `bcm4358.c`); `interrupt-names "host-wakeup"` is what `hci_bcm` requests (`hci_bcm.c:1245`, `of_irq_get_byname(node, "host-wakeup")`) |
| child `clocks` | `<&s2mps13_osc S2MPS11_CLK_BT>` | 32.768 kHz BT clock, PMIC clk output 2 (`s2mps13_bt`); `S2MPS11_CLK_BT = 2` (`include/dt-bindings/clock/samsung,s2mps11.h:15`); osc node from m2.dtsi:37-42. TM2 wires the same (`exynos5433-tm2-common.dtsi:1268-1269`). The stock BT node carries no `clocks`; this is the one borrowed-from-TM2 value (see §5) |
| child `clock-names` | `"extclk"` | deprecated alias of `txco`; resolves through `bcm_get_txco` fallback (`hci_bcm.c:1067-1082`) |
| child `max-speed` | `<3000000>` | TM2's speed on the same UART (`exynos5433-tm2-common.dtsi`); the baud clock comes from the audio PLL through `&cmu_aud` (§7.8), 460800 from 2026-10-28 to 2026-11-08, 921600 never worked on the bootloader's oscclk (§7.4); consumed by hci_bcm as `oper_speed` |
| `&cmu_aud` assigned-clocks | `mout_aud_pll_user` → `fout_aud_pll`, `sclk_aud_uart` the PLL undivided, the other dividers /8 | `exynos5433-gts28ltexx-bt.dtsi` (`t715-bluetooth`), TM2's `&cmu_aud` (`exynos5433-tm2-common.dtsi`); the bootloader leaves the mux on oscclk — §7.8 |
| child `pinctrl-0` | `<&bt_host_wake_pins &bt_wake_pins &bt_en_pins>` | stock `cfg-hostwake` (438-444), `cfg-btwake` (3496-3501), `cfg-en` (6196-6201) |
| `brcm,requires-autobaud-mode` | **not set** | stock flow never autobauds: fixed 921600 open + patchram |

### 2.3 Board pin groups (inside their controller nodes)

Group node names carry the `-pins` suffix required by the samsung
pinctrl schema (`^[a-z0-9-]+-pins$`).

| Group | Pins | Function/Pull/Drv | Source (live_fdt.dts) | Controller |
|---|---|---|---|---|
| `wlan_en_pins` | gpj2-0 | OUTPUT, PULL_NONE, `EXYNOS5433_PIN_DRV_FAST_SR4` | `cfg-wlanen` 5626-5632 (func 0x1, drv 0x3, con-pdn 0x3) | `&pinctrl_ese` (bank at exynos5433-pinctrl.dtsi:174) |
| `pcie_wake_pins` | gpf1-0 | INPUT, PULL_NONE | `pcie_wake` 402-407 (func 0x0, pud 0x0) | `&pinctrl_alive` (gpf1 at :82) |
| `wlan_host_wake_pins` | gpf3-1 | EINT (0xf), PULL_DOWN | `wlan_host_wake` 666-672 (func 0xf, pud 0x1) | `&pinctrl_alive` (gpf3 at :98) |
| `bt_host_wake_pins` | gpa2-2 | INPUT, PULL_NONE | `cfg-hostwake` 438-444 (func 0x0, pud 0x0) | `&pinctrl_alive` (gpa2 at :66) |
| `bt_wake_pins` | gpr3-7 | OUTPUT, PULL_NONE | `cfg-btwake` 3496-3501 (func 0x1, pud 0x0) | `&pinctrl_fsys` (gpr3 at :248) |
| `bt_en_pins` | gpd4-0 | OUTPUT, PULL_DOWN | `cfg-en` 6196-6201 (func 0x1, **pud 0x1** = pull-down) | `&pinctrl_peric` (gpd4 at :504) |

`pcie_bus` is already defined in mainline
(`exynos5433-pinctrl.dtsi:340`, gpr3-4/5/6 func 3 pull-up — same pins as
the stock `pcie_bus` group, live_fdt.dts:3849-3855). The stock
`samsung,pin-con-pdn`/`pin-pud-pdn` cells are intentionally not
transcribed, consistent with every mainline exynos5433 board.

### 2.4 Regulators (the power-sequencing decision)

The stock kernel sequenced these radios from vendor glue: bcmdhd
`dhd_custom_exynos.c` drives `wlan_pwr_on` high, sleeps
`WIFI_TURNON_DELAY` (=200 ms, `dhd_custom_exynos.c:64`), then lets the
PCIe host train; `bcm4358.c` drives BT_REG_ON before opening the UART.
Mainline has no such hooks, so the dtsi uses the two mechanisms the
kernel actually provides:

1. **`wlan_reg_on`** — `regulator-fixed` bound to the WLAN_EN GPIO
   (gpj2-0), consumed as the PCIe controller's **`vdd18-supply`**.
   Mainline `pci-exynos.c` bulk-gets and enables `vdd18`/`vdd10`
   *before* `exynos_add_pcie_port()` starts link training
   (`drivers/pci/controller/dwc/pci-exynos.c:307-314`), so this is the
   one mainline hook that powers the chip before perst. 1.8 V is the
   binding's vdd18 level; the live tree does not name the rail behind
   the pin. `regulator-always-on` + `regulator-boot-on` keep it up
   (boot-on alone would be dropped by `regulator_late_cleanup`,
   `drivers/regulator/core.c:6381-6420`, which only skips
   `always_on` rails). `startup-delay-us = <200000>` restates the
   downstream 200 ms settle delay in the mainline-supported property
   (`drivers/regulator/fixed.c:198`).

2. **`pcie_vdd10`** — dummy `regulator-fixed` (1.0 V, no GPIO,
   always-on) for the binding-required 1.0 V PCIe rail. The live PMIC
   description has **no LDO6/LDO7** (the TM2 PCIe rails; only
   LDO2,3,11,17-23,25-27,29-40 exist, live_fdt.dts:2345-3080), so the
   real rails cannot be transcribed — the dummy restates the
   bootloader's leave-on state instead of borrowing TM2's rails (same
   policy as the `usbdrd30` comment in `exynos5433-gts28ltexx-m2.dtsi`).

3. **BT_EN** — *no* regulator. The line is driven by exactly one
   writer: `hci_bcm`'s `shutdown-gpios` (gpd4-0). Modelling BT_REG_ON
   additionally as a `regulator-fixed` consumed by hci_bcm
   (`vbat`/`vddio`) would give the regulator core / hci_bcm shutdown
   path a second writer that can cut power to shared silicon; the
   stock flow keeps the chip powered while Wi-Fi is up. No
   `vbat`/`vddio` supplies are given to hci_bcm (binding-optional; no
   rail named in the live tree).

What is deliberately **not** in the DT:

- **perst GPIO**: the stock pcie node carries a `gpios` list including
  the perst line (live_fdt.dts:7072; downstream drives it from
  `exynos_pcie_*` code). Mainline `pci-exynos.c` has **no perst-GPIO
  support** (`pcie-designware.c` acquires `pe_rst` only for
  bt1/rcar-gen4 hosts), so nothing in the DT can express it; reset is
  driven by the controller registers (`exynos_pcie_assert/deassert_core_reset`).
- **Wi-Fi OOB interrupt**: pointless for PCIe (§1.2).
- **`brcm,requires-autobaud-mode`**: stock flow never autobauds (§2.2).

---

## 3. Firmware files

### 3.1 Wi-Fi (brcmfmac, PCIe)

Request order at probe (`brcm_alt_fw_path`, firmware.c:617-634 —
board-specific name first, then plain; NVRAM is
`BRCMF_FW_REQF_OPTIONAL`, pcie.c:2248-2249):

| Order | Mainline name requested | Install from stock |
|---|---|---|
| 1 | `brcm/brcmfmac4358-pcie.gts28ltexx.bin` | copy of `bcmdhd_sta.bin_4358_a1` (`dumps/etc_wifi/` — name only) |
| 2 | `brcm/brcmfmac4358-pcie.bin` | same |
| 3 | `brcm/brcmfmac4358-pcie.gts28ltexx.txt` (NVRAM, optional) | copy of `nvram_net.txt_4358_a1` (`dumps/etc_wifi/` — name only; **contains MAC + calibration: never commit, install at runtime only**) |
| 4 | `brcm/brcmfmac4358-pcie.txt` (NVRAM, optional) | same |

Notes:

- `brcm,board-type = "gts28ltexx"` on the child sets the alt-path
  suffix (`of.c:83-85`); without it the driver would derive
  `samsung-gts28ltexx` from the root compatible (`of.c:98-107`) —
  either works; the shorter spelling is explicit.
- **No `.clm_blob` is requested for this chip**: 4358 is registered
  with `BRCMF_FW_DEF` (pcie.c:67), not `BRCMF_FW_CLM_DEF`.
- **Corrected by the device test (§7):** the chip is rev 3 (A3), for
  which stock bcmdhd appends no suffix and loads the plain
  `bcmdhd_sta.bin` (build string `4358a3-roml/pcie-…`, version
  7.112.53.12) and `nvram_net.txt`, as its boot log shows. The `_4358_a1`
  files are for rev 1 chips. The rootfs symlinks
  (`brcmfmac4358-pcie.bin` → `bcmdhd_sta.bin`, `.txt` → `nvram_net.txt`)
  are right. The board-specific name brcmfmac actually tries first is
  `brcmfmac4358-pcie.samsung,gts28ltexx.bin`: the `wifi@0,0` DT child is
  not attached to the PCI device, so the root compatible is used.
- NVRAM/board rev caveats: the `_a1` suffix is the stock load; if the
  chip is a different rev the NVRAM mismatch shows up as a failed
  firmware download — a device-boot test would tell, which is out of
  scope here.

### 3.2 Bluetooth (btbcm via hci_bcm)

`btbcm_setup_patchram()` reads the controller's LMP subver, maps it to
`hw_name` through `bcm_uart_subver_table` (`btbcm.c:495-517`), derives
`board_name` from the **root** compatible's first string with
`'/'`→`'-'` (`btbcm.c:541-560`: `samsung,gts28ltexx` →
`samsung-gts28ltexx`; btbcm does not read the wifi child's
`brcm,board-type`), then tries (`btbcm.c:645-668`):

| Order | Name requested (UART, empty USB postfix) |
|---|---|
| 1 | `brcm/BCM4354.samsung-gts28ltexx.hcd` |
| 2 | `brcm/BCM4354.hcd` |
| 3 | `brcm/BCM.samsung-gts28ltexx.hcd` |
| 4 | `brcm/BCM.hcd` |

`hw_name` derivation caveat (flagged honestly): `bcm_uart_subver_table`
has **no BCM4358 entry**; BCM4358A3 hardware is known to report LMP
subver `0x610c` ("003.001.012"), which the table maps to **"BCM4354"**
(`btbcm.c:504`) — so the expected match is `brcm/BCM4354.hcd`. If the
chip reports a subver absent from the table, `hw_name` stays NULL and
the search degenerates to entries 3-4 (`brcm/BCM*.hcd`). **Practical
target: install the stock firmware as
`/usr/lib/firmware/brcm/BCM4354.hcd`** (or additionally as `BCM.hcd`
as a table-proof fallback). Source file: vendor
`bcm4358A3_V0086.0144.hcd` (`dumps/vendor_firmware/`); the m4-rootfs
layout already stages it as `/usr/lib/firmware/brcm/BCM4358A3.hcd`
(`boot/README.md:63,137`) — that name will **not** be found
by mainline btbcm and must be renamed (the rename belongs to the
rootfs milestone, not this one). The `.hcd` itself contains the MAC
default and calibration — keep it out of the repo, install at runtime.

---

## 4. Kernel config (`gts28ltexx_m5.config`)

Full copy of `gts28ltexx_m2.config` (I2C/PMIC/MMC/USB/EXT4 chain,
all `=y`) plus:

| Symbol | Why |
|---|---|
| `PCI_EXYNOS=y` | PCIe host (defconfig has `=m`; built-in so Wi-Fi probes without modules) |
| `PHY_EXYNOS_PCIE=y` | PCIe PHY (bool, `drivers/phy/samsung/Kconfig:24`) |
| `CFG80211=y` | cfg80211 (defconfig `=m`; flip required for `BRCMFMAC=y`) |
| `BRCMFMAC=y` + `BRCMFMAC_PCIE=y` | brcmfmac built-in; `=y` also avoids the `brcmfmac-wcc` fwvid module request for the 0x43ec/WCC match; firmware loading works fine from built-in (request waits for the rootfs) — **no need for `=m`** |
| `BT=y`, `BT_HCIUART=y`, `BT_HCIUART_BCM=y` | hci_uart + Broadcom protocol (`BT_HCIUART_BCM` selects `BT_BCM` and `BT_HCIUART_H4`) |
| `SERIAL_DEV_BUS=y`, `SERIAL_DEV_CTRL_TTYPORT=y` | serdev; TTYPORT depends on `SERIAL_DEV_BUS != m`, hence `=y` |
| `SERIAL_SAMSUNG=y` | ttySAC3 (not in defconfig, no Kconfig default) |
| `RFKILL=y` | radio kill-switch plumbing |

## 5. Left out / uncertain

1. **BT 32 kHz clock source is borrowed from TM2** (the only
   non-transcribed DT value): the stock BT node has no `clocks`
   property, so the 32 kHz feed is unrecorded in the live tree; TM2
   wires `s2mps13_osc` CLK_BT to the same chip family
   (exynos5433-tm2-common.dtsi:1268-1269). If the board actually ties
   LPO to a different source, hci_bcm falls back gracefully — the
   clock is optional in `bcm_get_txco` (NULL → no clock toggling).
2. **BT firmware name depends on the reported LMP subver** (`BCM4354`
   if `0x610c`, otherwise `BCM` fallback) — needs one device boot to
   confirm; flagged in §3.2.
3. **No perst GPIO, no vdd rails, no OOB IRQ**: hardware lines that
   mainline cannot express or does not consume (§2.4). If link training
   fails on real hardware, the candidate root causes are (a) the chip
   needing WLAN_EN asserted before host `config` accesses — already
   covered by vdd18-supply ordering — or (b) perst polarity/timing
   that would need a small `pci-exynos.c` change (driver change, out
   of scope per the milestone constraints).
4. **0x43ec probes as a "4356" PCI entry** (§1.1). Cosmetic: fwvid
   ops and firmware naming are chip-ID-driven. A tidy-up would add
   `BRCM_PCIE_DEVICE(0x43ec, WCC)` labelled 4358 to pcie.c — driver
   change, out of scope.
5. **Wi-Fi NVRAM rev**: settled by the device test, see §3.1 and §7.
6. **Not in scope** (unchanged from the brief): firmware installation,
   NetworkManager/BlueZ configuration, boot-image packing, flashing.

## 6. Build

- `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_m5.config`
  → `out/mainline-m5/` (zImage + `exynos5433-gts28ltexx-m5.dtb`).
- dt-schema check (dtschema 2026.9, `make CHECK_DTBS=y
  samsung/exynos5433-gts28ltexx-m5.dtb` in the container): **no findings
  on any milestone-5 node.** The six findings of the first iteration
  (five pin groups not matching `^[a-z0-9-]+-pins$`, and the
  `pcie@0,0`/`brcm,bcm4329-fmac` child rejected by the PCI bus binding)
  were fixed by renaming the groups to `-pins` and rewriting the child
  as `wifi@0,0` / `compatible = "pci14e4,43ec"`.
- Remaining findings are pre-existing, shared with the m1/m2 boards and
  outside this milestone's files: the root compatible
  `samsung,gts28ltexx` is not in `samsung-boards.yaml` (board not
  upstream); the SoC `fixed-clock` nodes lack `clock-frequency`
  (exynos5433.dtsi); the m2 `usb@15400000` node lacks required
  `vdd33-supply`/`vdd10-supply`; the other worker's `sec-log` node has
  an undocumented compatible.

---

## 7. Device test (2026-10-28)

The M5 DTB was booted with the default kernel. Every radio driver was a
module, loaded by hand over SSH. A 45-minute automatic return to Android
was set (`t715.returnafter=2700`).

### 7.1 Kernel configuration that came out of it

In `gts28ltexx_defconfig`; the `gts28ltexx_m5.config` fragment is now
empty:
- `REGULATOR_FIXED_VOLTAGE=y` (WLAN_EN rail), `PHY_EXYNOS_PCIE=y`;
- as modules: `PCI_EXYNOS`, `CFG80211`, `BRCMFMAC`, `BT`, `BT_HCIUART`
  (+ `BT_HCIUART_BCM`), `SERIAL_SAMSUNG`, `RFKILL`, `MFD_EXYNOS_LPASS`;
- `SERIAL_DEV_BUS=y`, `SERIAL_DEV_CTRL_TTYPORT=y`;
- `MODULE_UNLOAD=y` and `DEBUG_FS=y` for bring-up.

**Never read `/sys/kernel/debug/pinctrl/*/pins` on this board.**
`samsung_pinconf_rw` touches banks in powered-off domains (the AUD
`gpz` banks): external abort, `oops=panic`, then a software reset back to
Android (seen on 2026-10-28). Reading `debugfs/gpio` and the clocks'
`clk_rate` / `clk_parent` files is safe.

### 7.2 Wi-Fi: PCIe works, the dongle firmware stalls the chip

What works:
- PCIe Gen1 x1 link, endpoint `14e4:43ec` enumerated, BARs assigned.
  The endpoint is Gen1-only (`LnkCap` 2.5 GT/s).
- **Chip ID:** chipcommon reads `0xAA2A` = **BCM43562 rev 3**, unknown
  to mainline. Stock bcmdhd folds it into the 4358/43569 class
  (`si_chipid_fixup`, `bcmdhd4358a3/siutils.c:436-446`). Kernel patch:
  `BRCM_CC_43562_CHIP_ID` in `brcm_hw_ids.h`, in the 0x180000 RAM-base
  group of `chip.c`, and a `pcie.c` firmware entry to `brcmfmac4358-pcie`.
- Download: RAM 0xc0000 at 0x180000 (same as stock: "dongle ram size …
  786432 at 0x180000"), firmware copied in 28 ms with correct readback,
  NVRAM at 0x23f1d8, config space intact before the start.

What fails:
- Releasing the CR4 (`brcmf_pcie_exit_download_state`) blocks for
  **10.4 s**.
- After that, every access to the chip returns `0xffffffff`, while the
  root port stays in L0 (LTSSM 0x11, DLLLA set, no link-down event).
- The chip's internal bus (backplane) freezes as soon as the firmware
  starts; the PCIe link itself does not drop.
- Only a power cycle (reboot) gives the next attempt a clean chip.

Ruled out on the device, one cause at a time:

| Hypothesis | Test | Result |
|---|---|---|
| Probe-time watchdog reset (`brcmf_pcie_reset_device`) | skipped | same stall |
| Firmware/NVRAM variant | stock log: same `bcmdhd_sta.bin` 7.112.53.12 A3 + `nvram_net.txt`, ready in 83 ms | same files |
| Gen2 switch | Target Link Speed = Gen1 at both ends | same stall |
| PERST# floating (gpr3-5 in function 3) | gpr3-5 held as GPIO output high like stock (`pci-exynos.c:837-841`), verified in GPR3 CON/DAT | same stall (change kept in `-m5.dtsi`) |
| 32 kHz LPO missing | S2MPS13 RTCCTRL = 0x17 (AP, CP, BT outputs on), read just before the test | ruled out |
| Probe too early after link-up (stock waits 200 ms) | brcmfmac loaded 3 s after link-up | same stall |
| D11 left in reset with FGC; chip GPIO pulls (bcmdhd zeroes `gpiopullup/down`) | test parameter: D11 untouched + pulls at 0 | same stall |
| L1SS/ASPM/LTR as configured by stock (`dw_pcie_config_l1ss`) | same values via `setpci` | chip unreachable as soon as it idles: the RC is not in hardware L1-exit mode (stock `pci-exynos.c:563-565`); not the cause of the stall, but a gap for power saving |

Still open:
- Mainline `pci-exynos.c` uses Exynos5440 register names.
  - On the 5433, 0x1c is `PCIE_BUS_NUM` and 0x20/0x24 are LTR registers.
  - Mainline sets bit 0 of 0x1c and writes 1 to 0x20/0x24; stock never
    writes them.
- Stock also drives a PERST# low/high sequence with 80 ms before LTSSM,
  and pulses the gpr3-6 pull.
- Next step: align the host side with stock register by register, using
  the instrumentation kept in
  `out/m5-debug/brcmfmac-43562-and-t715-debug.patch`.
- Each attempt needs a reboot for a fresh chip.

### 7.3 Bluetooth: the UART exists, the chip does not answer

- UART3 lives inside the LPASS block (`audio-subsystem@11400000`). Its
  device only exists once `exynos-lpass` (`MFD_EXYNOS_LPASS`) is loaded.
  After that: `ttySAC3 at MMIO 0x11460000`, serdev, `hci_uart_bcm`,
  `hci0`.
- **LPASS runtime PM:** mainline `exynos-lpass` takes no runtime
  reference.
  - It suspends right after probe, and its suspend zeroes
    `SFR_LPASS_INTR_CPU_MASK`, which masks UART3's interrupt (0 interrupts
    seen).
  - Stock keeps LPASS on while the UART exists (`lpass_get_sync`,
    `drivers/tty/serial/samsung.c:2090-2092`).
  - Forcing `power/control = on` brings the interrupt back.
  - This needs a driver fix: a runtime reference while UART3 is in use.
- With LPASS on, `HCI_Reset` at 115200 still times out (`0x0c03 tx
  timeout`). The UART sends one interrupt and then waits: the chip never
  asserts CTS.
- Everything below was checked and matches stock:
  - pins: `gpz1-0..3` (TX/RX/CTS/RTS, function 2, no pull);
  - GPIOs: BT_EN gpd4-0 (`bcm4358.c` gpio 0, phandle `gpd4`) high,
    BT_WAKE gpr3-7 high;
  - clock: `sclk_aud_uart` 24 MHz;
  - 32 kHz output on;
  - the same result on a fresh chip with the Wi-Fi side never touched.
- Firmware names installed for btbcm (RAM overlay only): `BCM4354.hcd`
  and `BCM.hcd` → `BCM4358A3.hcd`.

### 7.4 Bluetooth works (2026-10-28, evening)

Three fixes, then `hci0` comes up with the patched firmware and a 20 s
scan finds nearby devices:

1. **LPASS runtime PM** (`drivers/mfd/exynos-lpass.c`).
   - The probe now takes a runtime PM reference when an enabled
     `samsung,exynos5433-uart` child exists, and drops it in the remove
     action.
   - Measured with `/dev/mem` and LPASS active:
     - `CORE_SW_RESET` = 0xf1f (UART out of reset);
     - `INTR_CPU_MASK` = 0x53;
     - CTS (gpz1-2) goes low as soon as BT_EN (gpd4-0) rises.
   - So the earlier failure was only the masked interrupt. The forced-on
     retry had come after a first failed setup.
2. **460800 baud instead of 921600** (`-m5.dtsi`, `max-speed`) —
   superseded by §7.8, which moves the clock to the audio PLL and runs
   3 Mbaud.
   - UART3 runs from `sclk_aud_uart` = 24 MHz (oscclk). At 921600 the
     Samsung driver programs `UBRDIV = 0` / `UFRACVAL = 10`.
   - The patched controller accepts the `0xfc18` baud change at 115200,
     then never answers at 921600.
   - 460800 (`UBRDIV = 2`) works.
3. **L2CAP getsockopt** (`net/socket.c`).
   - The 6.12.114 tree converted L2CAP to `->getsockopt_iter`
     (`sockopt_t`, `include/linux/net.h`) but `do_sock_getsockopt` only
     calls `->getsockopt`. Every L2CAP getsockopt returned `-EOPNOTSUPP`,
     and bluetoothd refused every adapter ("Failed to create GATT
     database").
   - Fix: `do_sock_getsockopt_iter()` wraps the caller's buffer
     (user or kernel) in `iov_iter`s and writes `optlen` back.

Firmware and address:
- btbcm finds no `hw_name` for this chip (LMP subver not in its table).
  It tries `brcm/BCM.samsung,gts28ltexx.hcd`, then `brcm/BCM.hcd`, and
  loads `bcm4358A3_V0086.0144.hcd`. The patched controller reports
  "BCM4358A3 Samsung Tab-S2 UART 37.4MHz BT 4.2-0086", build 0144.
  The rootfs should install the patch as `BCM.samsung,gts28ltexx.hcd`.
- Without the patch, the ROM firmware (001.004.015) is too old for
  BlueZ: `Opcode 0x202f failed`.
- The controller carries the default Broadcom address (`43:58:A3:…`),
  so hci_bcm leaves it unconfigured until an address is set.
  - The real address is in EFS, which Linux must not write.
  - The test used a locally administered address:
    `btmgmt public-addr 02:…`.
  - A stable per-device source has to be chosen (see docs/journal/PROGRESS.md).
- `brcm-bluetooth.service` (btattach) is obsolete with serdev, since
  `/dev/ttySAC3` is never created; it is skipped by its condition.
- Added to the defconfig as modules: `BT_RFCOMM` (+TTY), `BT_BNEP`
  (+filters), `BT_HIDP`. bluetoothd needs them for its serial, OBEX and
  PAN profiles.

### 7.5 Bluetooth in the normal image (2026-10-28, night)

- **Device tree:** the BT part of `-m5.dtsi` moved to
  `exynos5433-gts28ltexx-bt.dtsi`, which the board file includes
  (section 13). The `-m5` DTB now only adds Wi-Fi/PCIe, which stays out of
  the default board until the firmware-start stall is solved.
- **Modules:** `build-initramfs.sh --modules` packs the whole
  `lib/modules/RELEASE` tree. `/init` copies it into the root's tmpfs layer
  (`install_modules`). udev then loads `exynos_lpass`, `samsung_tty`,
  `hci_uart`, `btbcm`, `bluetooth`, `bnep` and `rfkill` by itself. Checked
  on the tablet; host tests 35/35 (two new checks in the fake init).
- **Rootfs:**
  - patch link `brcm/BCM.samsung,gts28ltexx.hcd` → `BCM4358A3.hcd`;
  - `brcm-bluetooth.service` (btattach) removed;
  - verify-rootfs: 41 checks.
- **Address:** the kernel accepts the chip's Broadcom default address
  (`43:58:A3:…`), so the controller is not "unconfigured". The earlier
  "No default controller" came from the L2CAP getsockopt bug of §7.4.
  - That default is shared by such chips, so `t715-bt-addr@hciN.service`,
    pulled in by `/etc/udev/rules.d/90-t715-bt-addr.rules`, replaces it.
  - The new address is derived on the tablet from the eMMC CID: SHA-256
    with a fixed label, locally administered bit set, stable from boot to
    boot.
  - The script powers the controller off (mgmt refuses
    `set_public_address` while powered, `net/bluetooth/mgmt.c`), sets the
    address, and the kernel re-runs the setup with `set_bdaddr`; bluetoothd
    powers the adapter on again. This sequence lost the adapter on some
    boots, through the kernel's auto-off window, until 2026-11-08: see
    §7.8.
  - EFS is never read or written; neither the CID nor the address is
    logged.
- Result on the tablet with no manual step:
  - patch build 0144 loaded;
  - generated address applied (locally administered, no longer the
    Broadcom default);
  - adapter `gts28lte` powered (`ssp br/edr le secure-conn`);

### 7.6 Wi-Fi, second session (2026-10-28, evening)

Setup:
- clean kernel `7ba58ac33a74` with the M5 DTB;
- initramfs with the module tree and `t715.modblacklist=pci_exynos,brcmfmac`
  (a new knob), so that udev does not start the chip before the test is
  ready;
- one reboot per attempt, for a chip fresh from power-up.

Results:

| Test | Result |
|---|---|
| E1: manufacturing firmware `bcmdhd_mfg.bin` + `nvram_mfg.txt` (stock loads it first at boot) | same stall: the STA firmware's features are not the cause |
| E3a: PERST# as a GPIO (`perst-gpios`, gpr3-5): asserted at probe, released after the PHY starts, then 100 ms before training, as stock does | same stall (the support is kept: `pci-exynos.c` + `-m5.dtsi`) |
| E3b: ELBI 0x1c-0x28 left alone, as stock does (0x1c read back as 0x00100101: bit 0 already set) | same stall |
| No host access at all for 200-300 ms after releasing the CR4 | the first read returns `0xffffffff` within 12 ms: the chip has already stopped answering, without any host access |
| LTSSM (ELBI 0x74) sampled during that window | stays at 0x11 (L0): no L1 entry, no link drop |
| brcmfmac's pre-6.1 D11 handling (reset, then release with PHYCLOCKEN) | same stall |
| Root-port AER after the failure | only completion timeouts (`CmpltTO`); nothing anomalous upstream (no UR, no abort, no malformed TLP) |
| Bluetooth after the Wi-Fi stall (same chip) | still working (a scan works) |

What this establishes:
- The chip's power, PMU, crystal and LPO are fine, since Bluetooth keeps
  running.
- Within 200 ms of its firmware starting, the Wi-Fi side stops serving
  PCIe requests while the link stays in L0. The host does nothing at that
  moment, the same STA and MFG firmwares work under Android, and the host
  sequence (bcmdhd `ai_core_reset`, `download_state`, `write_vars`) matches
  brcmfmac's.
- The difference therefore lies in something the firmware reads at
  startup and that differs here: the PCIe configuration space as mainline
  leaves it (L1SS/LTR/ASPM capabilities and their controls, which stock
  programs before the download), or a property of the brcmfmac path not
  identified yet.

Next leads:
- a firmware built for brcmfmac (linux-firmware `brcmfmac4358-pcie.bin`,
  if it matches the A3 ROM);
- reproducing stock's L1SS/LTR configuration while keeping MMIO
  reachable;
- comparing with the LineageOS kernel (`kernel/samsung/gts2`).

The instrumentation of both sessions is kept in `out/m5-debug/`
(not in the tree).

### 7.7 Wi-Fi works: linux-firmware instead of the Samsung firmware (2026-10-28, night)

- Two research passes (precedents, alternative drivers) found no public
  case of a 4356/4358-class PCIe chip on an Exynos SoC under mainline.
- They gave three leads:
  - the linux-firmware build;
  - stock's L1SS/LTR configuration;
  - the Rockchip bcmdhd 101.10 (built for 6.12 as a fallback in
    `src/wifi-alt/build-rkwifi-pcie/`, never loaded).
- **linux-firmware `brcm/brcmfmac4358-pcie.bin`** (634 361 bytes, SHA-256
  `f04d8fdc…37c`, build `4358a3-roml/pcie-…`, version 7.112.300.14
  r707445, July 2017) is built for the same A3 ROM.
  - With the device's `nvram_net.txt`, brcmfmac brings the chip up at once:
    `Firmware: BCM43562/3 wl0: Jul 5 2017 version 7.112.300.14`.
  - `wlan0` is created and NetworkManager sees the radio (AP mode
    supported).
  - A scan lists 2.4 and 5 GHz networks.
  - Bluetooth keeps working at the same time.
  - AP mode needs `ieee80211w=0`: without it a phone read the password as
    rejected (2026-10-31, `21-t715-wifi-no-pmf.conf`). The phone's PSK-SHA256
    handshake itself completes on this firmware.
- So the stall of §7.2 to 7.6 belongs to Samsung's 7.112.53.12 build
  (and to its manufacturing build), which only runs with the bcmdhd host.
  The PCIe platform and the brcmfmac host sequence are fine.
- Remaining warnings: no `.clm_blob` and no `.txcap_blob` for this chip
  ("device may have limited channels"). The 7.112 firmware carries its
  own CLM data.
- **MAC address:**
  - The NVRAM's `macaddr` is the same on every SM-T715 (Android injects
    the real address from EFS through bcmdhd).
  - `t715-wifi-addr`, run by udev while the interface is still down, sets
    a stable locally administered address derived from the eMMC CID (its
    own label, nothing logged, EFS untouched).
  - NetworkManager keeps it for connections (`wifi.cloned-mac-address=
    preserve`) and may still randomise it for scans.
- **Integration:**
  - `-m5.dtsi` became `exynos5433-gts28ltexx-wifi.dtsi`, included by the
    board file (section 14);
  - `-m5.dts` and `gts28ltexx_m5.config` are removed;
  - `pci-exynos` sequences PERST# through `perst-gpios`;
  - `build-rootfs.sh` downloads and pins the firmware, and the Dockerfile
    installs it as `brcm/brcmfmac4358-pcie.bin`;
  - verify-rootfs: 43 checks.
- **Limit of the RAM-overlay root:** saved Wi-Fi connections (passwords)
  are lost at every reboot until the root filesystem is persistent.

### 7.8 Bluetooth at 3 Mbaud, UHID and the address race (2026-11-08)

Kernel `#10`: the daily `#9` tree (the 1.0.1 release tree plus
`t715-sdcard`) plus the `t715-bluetooth` series, built with
`--fragment gts28ltexx_cpufreq.config` and `KBUILD_BUILD_VERSION=10`,
tested on the tablet from RECOVERY, then the daily kernel: in BOOT since
19:27. Not in a release yet.

**3 Mbaud.** The BCM4358's UART (UART3, `ttySAC3`, inside the audio
subsystem LPASS) ran at 460800 baud (§7.4) because its clock
`sclk_aud_uart` came from oscclk: the bootloader leaves CMU_AUD's
`mout_aud_pll_user` on the 24 MHz oscillator. 460800 baud carries
46 kB/s; A2DP's high-quality SBC takes about 41 kB/s before its framing,
and SBC-XQ more than the link has. 921600 was never an option there
(UBRDIV = 0, §7.4).

The series moves `mout_aud_pll_user` to the audio PLL (`fout_aud_pll`,
196608009 Hz), as TM2 does (`exynos5433-tm2-common.dtsi`), gives
`sclk_aud_uart` the PLL undivided, and sets `max-speed = <3000000>`,
TM2's speed on the same UART. The Samsung UART driver rounds the divider
down: read back on the tablet, UBRDIV = 3 and UFRACVAL = 1, that is
196608009 / 65 = 3.025 Mbaud, 0.8 % fast.

The other CMU_AUD dividers go to /8, so `div_aclk_aud` (the audio bus),
the CA5 and `sclk_aud_i2s/pcm/slimbus` run at 24.6 MHz (24576002 Hz read
back) instead of 24 MHz. Audio does not depend on these rates: the WM1814
codec is the I2S bit and frame clock provider, from its own MCLK (the
PMU's CLKOUT, the 24 MHz XXTI), and I2S0 runs on its bus clock
(`gts28_wm1814.c`: CBP_CFP, `SAMSUNG_I2S_OPCLK_PCLK`). Checked on the
tablet:

- 2 s of playback took 2.46 s, against 2.42 s before; microphone capture
  works; the same two existing codec warnings ("Mixer dropped sample",
  "ASRC underclocked").
- `/proc/tty/driver/s3c2410_serial` shows no framing, parity or overrun
  counter on line 3.
- A 20 s scan finds 16 devices.

The patch RAM (firmware 0144) still loads at 115200 baud before the
switch, about 5.7 s at boot: the compatible `brcm,bcm43540-bt` sets
`no_early_set_baudrate`. At rest UMCON = 0 is expected: hci_bcm
runtime-suspends the port 5 s after the last traffic (it has the host-wake
interrupt) and stops the flow (CRTSCTS off, RTS low) while suspended.

**UHID.** BlueZ 5.87 creates the input device of every Bluetooth keyboard
or mouse through `/dev/uhid`: LE ones always (HID over GATT), classic ones
too since `UserspaceHID=true` is the default in `/etc/bluetooth/input.conf`.
Without `CONFIG_UHID` — every kernel up to the 1.0.1 release and the daily
`#9` — no Bluetooth keyboard or mouse can connect. The series builds it
in; `/dev/uhid` exists at boot (`crw------- root`, and bluetoothd runs as
root).

**The address race.** On some boots bluetoothd had no adapter ("No default
controller") although `hci0` existed and the patch RAM had loaded: once in
a 5-reboot loop on 2026-11-08, and once before on a test root. In that
boot the journal shows bluetoothd's "Battery Provider Manager destroyed"
right after the address change, and no "created" after it. The cause, in
the kernel:

- Right after a controller's setup the kernel keeps it up for two seconds
  with `HCI_AUTO_OFF` (the auto-off window). mgmt reports it unpowered, so
  `btmgmt power off` does nothing.
- `set_public_address` (`net/bluetooth/mgmt.c`) accepts the change,
  because the controller counts as unpowered. It removes the index and
  queues a power-on.
- `hci_power_on` (`net/bluetooth/hci_core.c`) then sees the controller
  still up with `HCI_AUTO_OFF` and takes its shortcut: it never writes the
  new address and never sends "Index Added". `HCI_CONFIG` stays set, so
  mgmt answers "Invalid Index" until the next boot.

The script hit the window whenever it ran before bluetoothd had powered
the adapter on. The fix (`t715-bt-addr`): power on first, which ends the
window, then power off for real, then set the address. `btmgmt` exits 0
even when a command fails, so the script reads the address back: an
accepted change takes the controller out of the list until the kernel has
written the address, a refused one leaves the old address and the script
tries again, at most 10 times. Proofs:

- bluetoothd is D-Bus-activated, so it was masked for the test with
  `systemctl mask --runtime bluetooth.service` (a plain stop is undone
  within 0.2 s).
- An address change opens a fresh window. The fixed script run inside it
  set the address 5 times out of 5. The old sequence (power off,
  public-addr) inside the same window lost the controller: `hci0` still in
  sysfs, absent from mgmt.
- Then 8 consecutive reboots of the daily system on kernel `#10` with the
  fixed script (18:01 to 18:13): the adapter came up powered with its
  generated address every time, and the journal shows "generated address
  set" each boot.
- `image/tests/test_t715_bt_addr.sh` models the window off the device
  (9 groups, including a copy of the script without the power-on line,
  which the model shows losing the controller).

**Operating facts.**

- The Bluetooth tile and airplane mode switch Bluetooth with rfkill
  (`omarchy-bluetooth-power`). systemd-rfkill saves the soft block in
  `/var/lib/systemd/rfkill/` and restores it at boot: Bluetooth switched
  off stays off after a reboot, by design. `rfkill unblock bluetooth` or
  the tile turns it back on. (On 2026-11-08 the tablet's daily system had
  it blocked this way since an earlier session.)
- Never unbind `hci_uart_bcm`
  (`/sys/bus/serial/drivers/hci_uart_bcm/unbind`) or remove the
  `hci_uart` module while Wi-Fi is up. On 2026-11-08 an unbind and
  rebind brought Bluetooth back (address set, adapter powered), but
  within 4 s Wi-Fi's firmware stopped answering
  (`brcmf_msgbuf_query_dcmd: Timeout on response`) until a reboot. The
  likely cause: the BCM4358's Bluetooth and Wi-Fi share the chip's
  32.768 kHz low-power clock, which comes from the PMIC's `s2mps13_bt`
  output — only the Bluetooth node claims it, so the unbind switches it
  off. BT_EN going low is the other candidate; this was not separated.
  rfkill, the tile and airplane mode only close the HCI device, the chip
  stays powered, so normal use never does this.

**Devices tested (2026-11-08).** Each device was paired from the quick
settings' Bluetooth panel (which pairs, trusts and connects), about 18:30
to 19:00, on the daily system booted from RECOVERY.

- A keyboard (Bluetooth LE, HID over GATT, through `/dev/uhid`): pairs,
  trusts, types and reconnects after sleeping. A classic keyboard
  (BR/EDR HID) paired too. bluetoothd logs "Write output report failed:
  Attribute value length is invalid" — the keyboard refuses the LED
  output report; harmless. Omarchy's keyboard shortcuts did not answer;
  its 226 default bindings are loaded. Not investigated yet.
- A mouse, a Logitech MX Master 3S (Bluetooth LE, through `/dev/uhid`):
  pairs, trusts, clicks, scrolls and reconnects after sleeping. Its first
  pairing crashed the touch shell once: quickshell 0.3.2 died with
  SIGSEGV 11 s after the mouse's input device appeared, while handling
  BlueZ property updates for it; the core dump's only frame is
  `pthread_mutex_lock` on a thread other than the main one, with no
  symbols. systemd-coredump then held the tablet about 40 s with a black
  screen (two 24 MB cores, the crash handler's fork dumps too: 420 MB and
  23 s of CPU each), after which `omarchy-shell` relaunched the shell.
  Not seen again: the mouse reconnected later without a crash.
- A speaker, a BeoPlay A1 (A2DP sink, codec SBC): pairs, trusts, plays
  cleanly, and the volume keys move it; AVRCP adds an input device for
  its buttons. While it played the UART carried 46,074 B/s to the chip:
  all the old 460800 baud could carry, 15 % of the 3 Mbaud link. No UART
  error. At connection, bluetoothd's "a2dp-source profile connect failed:
  Device or resource busy" is both sides connecting at once; the stream
  came up.
- When an input device pairs, bluetoothd logs "Set device flags return
  status: Invalid Parameters" and the kernel `hci0: Bad flag given (0x1)
  vs supported (0x0)`: BlueZ asks for remote wakeup, which hci_bcm does
  not offer; the image has no system suspend. Harmless.
