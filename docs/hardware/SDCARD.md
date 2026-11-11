# microSD card (dwmmc2@15560000) — SM-T715 (Exynos 5433), mainline 6.12 arm32

The microSD slot, enabled by the series `kernel/patches/t715-sdcard/`
(2 patches, section 6). Measured on the reference tablet on 2026-11-08,
with a 16 GB SDHC card from 2018; in the 1.0.2 release and later.

Path abbreviations:

* `board` = `src/linux-6.12/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts`
* `live_fdt` = `dumps/live_fdt.dts` (the running stock tree)
* `stock/` = `src/kernel_universal5433/` (Samsung's 3.10 tree)

---

## 1. The slot

The slot sits on `mshc_2` (`dwmmc2@15560000`), the SoC's second dw_mmc
controller, with a 4-bit bus. The stock tree describes it at
`live_fdt.dts:1250-1300` (`HARDWARE_MAP.md`, "SD card (dwmmc2@15560000)"),
and the stock dmesg shows only `15560000.dwmmc2` printing "vmmc on, vqmmc
on" and "vmmc off, vqmmc on": the stock driver powers the card off when
none answers, and keeps the I/O rail on.

**Card detect: gpa2-4, active low, debounced 200 ms.** The board pulls
the line up. The pad's reset state has a pull-down on it — GPA2PUD read
back `0x1540`, pin 4 = pull-down — which the stock tree removes
(`dwmmc2_cd_ext_irq`); the node removes it too.

**gpf0-7**, the stock tree's `vmmc-en-gpio`, is an input with a pull-up
as the bootloader leaves it (GPF0CON nibble 7 = 0, GPF0PUD bits 15:14 =
11). The stock driver drives it low once at probe and never again
(`dw_mci_exynos_set_etc_gpio`, "vmmc_en is low"); the node holds it low
through pinctrl.

**Rails.** The card's VDD is LDO17, 2.8 V; its I/O is LDO2, 3.3 V,
1.8 V for UHS. The stock tree names them "vmmc" and "vqmmc"; section 3
is why they are `VDD_SD_2.8V` and `VDDQ_SD` here.

**Pads**, as the stock tree sets them: drive FAST_SR3, no pull. The SoC
dtsi's defaults are FAST_SR4 and pull-ups on the data lines.

**Clock.** The CIU clock is the bootloader's `sclk_mmc2` at 400 MHz,
100 MHz after ciu-div 3 — the stock's own ceiling: its `ciu_clkin` table
stops at 400 MHz.

## 2. The device tree node

The node follows the TM2 board's (`exynos5433-tm2-common.dtsi`), which
runs this slot of the same SoC in mainline with the same card detect pin:

```dts
&mshc_2 {
	status = "okay";
	cap-sd-highspeed;
	sd-uhs-sdr12;
	sd-uhs-sdr25;
	sd-uhs-sdr50;
	sd-uhs-sdr104;
	disable-wp;
	cd-gpios = <&gpa2 4 GPIO_ACTIVE_LOW>;
	card-detect-delay = <200>;
	samsung,dw-mshc-ciu-div = <3>;
	samsung,dw-mshc-sdr-timing = <1 2>;
	samsung,dw-mshc-ddr-timing = <2 3>;
	fifo-depth = <0x40>;
	bus-width = <4>;
	vmmc-supply = <&ldo17_reg>;
	vqmmc-supply = <&ldo2_reg>;
	pinctrl-names = "default";
	pinctrl-0 = <&sd2_clk &sd2_cmd &sd2_bus1 &sd2_bus4 &sd2_cd_pin
		     &sd2_vmmc_en_pin>;
};
```

The timings `<1 2>` and `<2 3>` are the stock's `<3 0 2 1>` and
`<3 0 3 2>` in mainline's two-cell `<sample drive>` form (`DT_M2.md`).
The two pin groups of section 1 complete `pinctrl-0`: `sd2_cd_pin`
(gpa2-4, EINT, no pull) and `sd2_vmmc_en_pin` (gpf0-7, output, no pull,
value 0); the bus pads carry section 1's FAST_SR3 and no pull.

The alias `mmc1 = &mshc_2` makes the card `mmcblk1`; the eMMC stays
`mmcblk0`.

## 3. Every write failed: the regulators' names

The first kernel that enabled the slot read the card fine at 50 MHz, and
failed every write:

```
I/O error, dev mmcblk1, sector 1 op 0x1:(WRITE)
Buffer I/O error on dev mmcblk1p1, logical block 0, lost sync page write
FAT-fs (mmcblk1p1): unable to read boot sector to mark fs as dirty
```

`/sys/kernel/debug/mmc1/ios` said "timing spec: 2 (sd high-speed)" with
"signal voltage: 1 (1.80 V)". The regulator summary listed
`15540000.mmc-vqmmc` — the eMMC's host — holding LDO2 at 1800-1950 mV,
and `15540000.mmc-vmmc` on LDO17, and the kernel log repeated "vqmmc:
Restricting voltage, 2800000-1950000uV".

**The cause.** LDO17 and LDO2 were named "vmmc" and "vqmmc", as in the
stock tree. When a device has no such supply in its node,
`regulator_dev_lookup()` falls back to a regulator of that name, so the
eMMC's host — which has none in the tree, on the model of the TM2 board —
took both, and held LDO2 at 1.8 V for its HS200. The card, its I/O at
1.8 V in a 3.3 V mode, read but did not write.

Renamed `VDD_SD_2.8V` and `VDDQ_SD`, the two rails belong to the SD host
only. The eMMC then runs HS200 at 200 MHz, 1.8 V, with no vmmc and no
vqmmc — first checked by booting the image read-only from RECOVERY, so
that nothing was written to the eMMC, then on the daily root.

## 4. Modes and speeds

The test card: a 16 GB SDHC card from 2018, 14.5 GiB.

| mode | bus | read | write |
|---|---|---|---|
| high speed | 50 MHz | 18.2 MB/s raw | 8.2 MB/s raw |
| UHS-I SDR104 | 100 MHz | 40.2 MB/s raw, 34.2 MB/s from files | 9.0 MB/s to files (the card's limit) |

In high speed, 256 MiB of random data written and read back identical.
In SDR104, 256 MiB written through exFAT and read back identical, the
file written in high speed read back intact, and no error in the kernel
log. SDR104 runs its bus at 100 MHz, the 400 MHz CIU clock's ceiling
(section 1).

## 5. The 800 MHz attempt

Raising `sclk_mmc2` to 800 MHz, for a 200 MHz bus, made every card
initialisation fail with -110 at every identification rate. The CIU
clock stays at 400 MHz, and the bus at 100 MHz.

## 6. The kernel series

`kernel/patches/t715-sdcard/` (2 patches), on top of `t715-turbo` in the
1.0.1 release order (`... camera-mc power-gpu turbo sdcard`;
[kernel/README.md](../../kernel/README.md)), built with `--fragment
gts28ltexx_cpufreq.config`:

| patch | what |
|---|---|
| the device tree | the node of section 2, its pins and pads, the two regulators renamed (section 3), the `mmc1` alias |
| the file systems | vfat (UTF-8 names by default), exFAT and the code pages 437, iso8859-1 and utf8, built in: cards come FAT32 up to 32 GB, exFAT above |

In the 1.0.2 release and later; tested on 2026-11-08 from RECOVERY, on the
daily root and on a test root.

**In BOOT on 2026-11-08**, as the daily kernel `#9`, until `#10` replaced
it the same day: the 1.0.1
release tree plus this series, the cpufreq fragment, `KBUILD_BUILD_VERSION=9`,
the boot image packed with the daily knobs and the initramfs that reads
partition names from the eMMC only. The daily root got the partlabel udev
rule first (`61-t715-removable-partlabel.rules`, `udevadm verify` clean on
udev 262). Checked after the reboot: the eMMC in HS200 at 1.8 V, the card
in SDR104 and mounted, the two slot rails held by the SD host alone, no
`/dev/disk/by-partlabel` link on the card (SYSTEM, RADIO and EFS on the
eMMC), no MMC error, the modem back online, Wi-Fi and the sound devices
up, no failed unit.

## 7. Hot plug

Checked on the tablet on 2026-11-08 by hand: a card pulled out logs
"mmc1: card 0007 removed", and put back it is initialised again in
SDR104 within a second ("new ultra high speed SDR104 SDHC card"), the
switch back from 3.3 V to 1.8 V included; Omarchy's udiskie mounted it at
once. A card in the slot at boot is there from the start (`mmcblk1` at
about 6 s). Unbinding and binding the card's block driver simulates a
reinsertion for tests without a hand at the tablet.

## 8. Power

Without a card, the MMC core powers the slot off: LDO17 goes off. The
SD host itself stays runtime-active — `runtime_suspended_time` 0 — as
the eMMC's does: `dw_mci_exynos_probe()` takes a runtime PM reference
and never drops it, so the controller's clocks never gate. What that
costs is not measured yet (section 10).

## 9. The system side

What the session does with a card is the image's, not the kernel's, and
is described in [docs/image/ROOTFS.md](../image/ROOTFS.md), section
"microSD card": the session mounts a new card by itself (Omarchy's
`udiskie --automount`, `/run/media/alarm/<LABEL>`), `t715-sdcard` sends
notifications and serves the "SD card" tile in quick settings, a udev rule keeps
`/dev/disk/by-partlabel/*` on the eMMC, and the initramfs reads
partition names from the eMMC only.

## 10. Next

- Measure the cost of the always-active SD host (section 8).
- A 200 MHz SDR104 bus, if a clock that allows it can be found
  (section 5).
- Other cards: an SDXC card (exFAT), a slow one, one that refuses UHS.
