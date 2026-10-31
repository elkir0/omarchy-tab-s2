# Fingerprint sensor (SM-T715)

**Verdict: feasible under condition.** Raw image capture from mainline Linux is
possible only with a kernel that takes the sensor's SPI bus back from the secure
world, plus a sensor driver and a matcher written from scratch. Reusing the
fingerprints enrolled on the device, or the stock matcher, is **impossible**: the
templates are sealed by a Kinibi trustlet and the matcher runs only inside TrustZone.

Offline study of 2026-10-30. Nothing here
ran a blob, called SMC or touched the secure world. The result of the one test made on
the device is in §7.

## 1. Summary

| Question | Answer | Strongest evidence |
|---|---|---|
| SPI reachable from the normal world? | Not in the stock configuration: the bus is reserved for the secure world by software. Whether a hardware lock exists as well is §7 | source, stock `Image.stock` strings, trustlet decompile |
| Which sensor? | Synaptics/Validity **VFS7xxx "Viper"**, revision Viper2 A0, not Egis | device tree, `dmesg` `type: viper`, driver constants, `libsynaFpSensorTestNwd.so` `vip2A0_*` |
| Trustlet role | Capture control, matching, template sealing, auth tokens | strings and decompile of `ffffffff…0e.tlbin` and of the secure SPI driver `ffffffffd0…0e.tlbin` |
| libfprint under Linux? | No driver exists. Raw capture needs a new SPI client, reverse engineering of the protocol and a new matcher | libfprint survey, kernel and DT state |

Evidence levels: **[src]** read in kernel source, **[bin]** read in a shipped binary,
**[dump]** read in an on-device dump, **[inf]** inferred, **[open]** not established.

## 2. Hardware path

- Sensor node `vfsspi-spi@0` (`compatible = "vfsspi,vfs7xxx"`) sits on SPI2 at
  `0x14d40000` (`samsung,exynos543x-spi`): `dumps/live_fdt.dts:2096,2108`, alias at
  `:5243`. **[dump]**
- GPIOs: DRDY `gpa1-7`, reset `gpf5-2`, LDO `gpf4-0`, LDO2 `gpf4-1`, OCP enable
  `gpf3-3`:
  `src/kernel_universal5433/arch/arm/boot/dts/exynos5433-gts28_fingerprint-sensor_00.dtsi`.
  **[src]**
- The SPI2 pins are bank `gpd5`, named as the fingerprint bank by
  `CONFIG_SENSORS_FP_SPI_GPIO="gpd5"` and `CONFIG_SENSORS_FP_SPI_NUMBER=2`
  (`arch/arm/configs/lineage_gts28ltexx_defconfig:2216,2177`). **[src]**
- The board overlay strips DMA from the normal world's view of this controller
  (`/delete-property/ dmas; /delete-property/ dma-mode`): the secure world runs its
  own secure DMA, §3. **[src]**

## 3. Is the SPI reserved for the secure world?

Yes in the stock configuration, enforced in software across three normal-world drivers,
with the bus I/O performed inside a TrustZone driver.

**3.1 The secure build flag was active in the stock kernel.**
`ENABLE_SENSORS_FPRINT_SECURE` is exported whenever `CONFIG_SENSORS_FINGERPRINT=y` and
`CONFIG_SEC_FACTORY != true` (`Makefile:715-719`), and applied to the fingerprint,
pinctrl and SPI drivers (`drivers/fingerprint/Makefile:7`, `drivers/pinctrl/Makefile:4`,
`drivers/spi/Makefile:6`). **[src]** The stock firmware is a `user/release-keys` build
(`dumps/getprop.txt`), so not SEC_FACTORY. `dumps/stock/Image.stock` confirms it: it holds
the secure branch's strings (`ENABLE_SPI_CLOCK`, `VFSSPI_IOCTL_SET_SENSOR_TYPE`,
`vfsspi_sec_dma_prepare`) and none of the other branch's
(`ValiditySensor: spi_sync`, `sensor type is VIPER`, `VFSSPI_IOCTL_RW_SPI_MESSAGE`,
`vfsspi_type_check`). **[bin]** The live `dmesg` shows `tz: 1`, set only in the secure
`#ifdef` (`vfs7xxx.c:1323-1325`, `dumps/dmesg.txt:71`). **[dump]**

**3.2 Under the flag the normal world cannot move data.**

- `vfsspi_read()` and `vfsspi_write()` return 0 at once (`vfs7xxx.c:281-283, 316-318`).
  **[src]**
- The only ioctl that ran `spi_sync()` on user data, `VFSSPI_IOCTL_RW_SPI_MESSAGE`, and
  its helpers are compiled out (`vfs7xxx.c:49-55, 357-435, 887-896`). **[src]**
- `drivers/spi/spi-s3c64xx.c` skips the fingerprint port
  (`sdd->port_id == CONFIG_SENSORS_FP_SPI_NUMBER`): `s3c64xx_spi_setup` returns before
  claiming the chip select (`:1137-1139`), `s3c64xx_spi_hwinit` returns before writing
  any register (`:1297-1299`), the RX and TX interrupts stay disabled (`:1625-1627`). The
  normal-world master never initialises SPI2. **[src]**
- `drivers/pinctrl/pinctrl-samsung.c` short-circuits bank `gpd5` in every config, get,
  save, restore, init and sleep path (`:330-343, 456-469` and following): the normal
  world reads 0 and never drives those pins. **[src]**
- What the kernel driver keeps: reset and suspend GPIO, LDO power, the DRDY interrupt
  turned into a signal to the user daemon, SPI clock prepare, secure DMA prepare
  (`vfsspi_sec_spi_prepare`, `vfsspi_sec_dma_prepare`, `vfs7xxx.c:437-524`) and two SMC
  calls, `MC_FC_FP_PM_SUSPEND/RESUME` (`0x83000021/22`, `vfs7xxx.c:1855,1872`). The
  secure DMA target is `pdma1@15600000`, the only PL330 with `#dma-secure-mode = <0x01>`
  (`dumps/live_fdt.dts:1911`). **[src, dump]**

**3.3 The bus is driven inside TrustZone.**
`/system/app/mcRegistry/ffffffffd0000000000000000000000e.tlbin` is a Kinibi driver (MCLF
magic, service type 1, driver id `0x40004`). Its strings: `[Secure SPI] sec_spi_init`,
`SEC_SPI_DRIVER_%u.%u_%s`, a full `SPI SFR DUMP` of the controller's registers, and the
mapping helpers `sec_map_l5` and `sec_AddrMapCurClientResource`. **[bin]** The function at
offset `0x2646` is the transfer engine: it polls `base+0x14` (SPI_STATUS), writes
`base+0x18` (TX) and reads `base+0x1c` (RX), with the base computed per port as
`port * 0x10000 + 0x14d20000`. Port 2 gives `0x14d40000`, the sensor's controller. The
trustlet maps and programs the physical SPI registers itself. **[bin]**

**3.4 What this does not prove.** A hardware lock (TZPC) on the SPI2 block. The stock
kernel declines to touch port 2, so nothing above shows that a different kernel could not.
One argument the other way: the factory build (`CONFIG_SEC_FACTORY`) compiles the
non-secure path, with `spi_sync` from the normal world, against the same bootloader and
secure OS. That only makes sense if SPI2 is open to the normal world at boot. **[inf]**

## 4. Which sensor is it?

Synaptics/Validity **VFS7xxx "Viper"**, Viper2 A0.

- Device tree `compatible = "vfsspi,vfs7xxx"` (`dumps/live_fdt.dts:2111`); the driver
  advertises `VENDOR "SYNAPTICS"`, `CHIP_ID "VIPER"` (`vfs7xxx.c:179-181`). **[src, dump]**
- `dmesg` reports `type: viper` (`dumps/dmesg.txt:71,242,1924`). **[dump]**
- The non-secure detection path identifies Viper by an SPI EP0 read, `rx[2]` in
  `{0x01, 0x41}` and `rx[5] == 0x68`, else Raptor (`vfs7xxx.c:1472-1588`). **[src]**
- `lib/libsynaFpSensorTestNwd.so` exports Viper2 A0 scripts (`vip2A0_getFlexId`,
  `vip2A0_2291_*`, `synaFpSensorTest`). **[bin]**
- The Egis library (`lib/libegis_fp_normal_sensor_test.so`, `/dev/esfp0`) and the Egis
  symbols in `libbauthserver.so` belong to Samsung's multi-vendor service, which selects
  `/dev/vfsspi` or `/dev/esfp0` at run time. The device tree, the `viper` line and the
  kernel driver settle it for this board. **[bin, src, dump]**

## 5. What the trustlet does and who talks to it

Two Kinibi binaries matter, both registered by `mcDriverDaemon` (`init.rc:1415`):

- **Secure SPI driver** `ffffffffd0…0e.tlbin`: §3.3.
- **Fingerprint trustlet** `ffffffff00000000000000000000000e.tlbin` (MCLF, service type
  3). Its strings show the whole sensitive pipeline: capture control and the matcher
  (`Trustlet FingerPrint::Starting`, `vigis_api`, `vigis_controller`, `FpEndCapture`,
  `identify_image_quality`), template sealing (`encode_metadata`, per-template AES and
  HMAC, key wrap through `tlApiWrapObjectExt` and `tlApiDeriveKey`), auth tokens
  (`CreateAuthToken`, `IntegrityCheckAuthToken`) and FIDO. The raw image and the
  templates never leave TrustZone. **[bin]**

Call chain: `fingerprintd` → HAL `lib/hw/fingerprint.default.so` (`ss_fingerprint_*`) →
`lib/libbauthserver.so` (`BAuth_*`, device I/O through `/dev/vfsspi`) →
`lib/libbauthtzcommon.so` → `vendor/lib/libMcClient.so` (`mcOpenSession`, `mcMallocWsm`,
`mcNotify`), with ION and `/dev/s5p-smem` shared buffers. `tlc_open` in
`libbauthtzcommon` opens two MobiCore sessions, the driver and the trustlet. **[bin]**

## 6. Can we capture an image and match under Linux without the secure world?

Raw capture is possible only with new code. "Unlock with the existing prints" is not.

- **The bus has to come back.** The stock driver has no data path under the flag (§3.2).
  The source shows what its other branch does: `read`, `write`, `RW_SPI_MESSAGE` and
  `type_check` return, `spi-s3c64xx` initialises port 2, pinctrl owns `gpd5`. **[src]**
- **Nothing drives it in mainline.** In `exynos5433.dtsi`, `spi_2@14d40000` is disabled
  with no child, and no `vfs7xxx` driver exists. The master driver does bind
  `samsung,exynos5433-spi`, so SPI2 can be brought up; the sensor client is missing. **[src]**
- **No libfprint driver fits.** Its Validity drivers are USB; this Viper is a raw SPI
  sensor with a proprietary Synaptics protocol. Its only SPI driver, `elanspi`, is Elan's.
  `fpi_spi_transfer` works over `/dev/spidev`, so a driver is possible, and it would be
  entirely new. **[inf, web]**
- **Matching and existing templates are out of reach.** The matcher is Synaptics' "vigis",
  in the trustlet only; templates are sealed with keys derived inside TrustZone. **[bin]**

What it would take: (1) a mainline SPI client for `vfsspi,vfs7xxx`, or spidev, on `spi_2`,
with the LDO, reset, DRDY and clock sequence of §2; (2) reverse engineering of the Viper
command set, with no public specification; (3) a libfprint driver and a matcher. That is
a large project, with no end in sight.

## 7. Test on the device

Not run. The rule allows a read of the bus only once it is established that the bus is
not reserved, and §3 establishes that it is, by software, in the stock configuration.
§3.4 argues against a hardware lock but does not prove it, and the read has a second
danger: on this SoC an unclocked register block can hang the bus.

What the test would be: one read of `CH_CFG` at `0x14d40000`, no write to the controller,
with `pclk_spi2` on, from a RECOVERY test kernel (`docs/hardware/CPUFREQ.md` §8.3), CP off.
A clean read would mean software reservation only. An abort would mean a hardware lock,
and the route of §6 stops there.

## 8. Not established

1. Whether the SPI2 block has a hardware lock (TZPC), or is only avoided in software.
2. The Viper capture protocol: register map, capture mode, frame format. It is in no
   source or dump here and needs live work on a non-secure kernel.
3. The sealing key's derivation, and whether a stock template could ever be migrated: the
   trustlet keeps this in TrustZone.
