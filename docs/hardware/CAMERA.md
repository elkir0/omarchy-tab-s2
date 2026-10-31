# Cameras: from Linux to an image

Study of 2026-10-30, then results on the tablet of 2026-10-31.

**Both cameras work under Linux, with no ISP and no A5 firmware running** (section 11): one
V4L2 node each (`t715-camera.ko`, in the daily kernel), raw Bayer through MIPI CSIS and
FIMC-LITE into memory. The front camera takes a recognisable photograph, auto-exposed and
developed on the tablet in about 10 s. The rear one delivers 8 megapixel frames, so far
only with the tablet lying on it, in the dark. No preview, no autofocus, no libcamera: the
Photo and Selfie entries of the drawer take one picture at a time.

Evidence tags: **[S]** read in source, **[D]** read in the stock device tree,
**[B]** read in a shipped binary, **[I]** deduced, **[U]** not established,
**[T]** seen on the tablet. Sections 1 to 10 are the study as written before the test;
what the tablet then showed is in section 11, which wins over them.

Abbreviations: `stock` = `src/kernel_universal5433`,
`fis` = `stock/drivers/media/platform/exynos/fimc-is`,
`linux` = `src/linux-modem-lli` (t715-parity, 6.12),
`is4` = `linux/drivers/media/platform/samsung/exynos4-is`,
`live_fdt` = `dumps/live_fdt.dts`,
`fw` = `dumps/vendor_firmware/fimc_is_fw2_4h5.bin`
(2,489,282 bytes, sha256 `78882745…bb49a73`). Offsets in `fw` are file offsets.
The image is linked at 0: its pointer tables hold file offsets [B].

`dumps/stock/running_kernel.config` is empty. Config facts come from
`stock/arch/arm/configs/lineage_gts28ltexx_defconfig`, which may differ from the
shipped kernel. `dumps/dmesg.txt` and `last_kmsg.txt` hold no camera session.

## Verdict

**Feasible, and done for the front camera, through the RAW path:** sensor → MIPI CSIS →
FIMC-LITE → DMA into CMA, with no ISP and no A5 firmware running. Linux does the demosaic
and the exposure in software.

The decisive fact: the sensor init sequences are in `fw`, in the clear.
S5K4H5 is a plain table, S5K6B2 is inline code that decodes statically (section 7).
The setfiles hold ISP tuning, not sensor init. Stock also has an ARM-only path that
runs without the A5, the "vision" scenario (section 3), so the hardware route exists
in shipped code.

What is left for applications: a preview, autofocus on the rear camera (DW9807), and
libcamera, whose `simple` pipeline wants a media controller and a sensor subdev. The sensors'
tables stay outside the repository (section 7): `t715-cam-seq.py` makes them from the
owner's own ISP firmware, and they go to `/usr/lib/firmware/t715/` on the tablet.

**FIMC-IS (the A5 ISP) is not reachable as a port.** No signature, no secure boot and
no hard lock was found, but it is a large vendor stack with an undocumented protocol
(section 6). GScaler is not a capture path (section 5).

## 1. Inventory

| item | rear | front | evidence |
|---|---|---|---|
| sensor | S5K4H5 | S5K6B2 | `live_fdt:826,947` [D] |
| vendor `sensor_id` (not an I2C ID) | 13 | 7 | `live_fdt:833,954`; `libexynoscamera.so` `createSensorInfo` [D, B] |
| pixel array used | 3280×2458 | 1936×1090 | `fimc-is-device-4h5.c:193-200`, `-6b2.c:735-742` [S] |
| MIPI lanes | 4 | 1 | `-4h5.c:204`; `vtcam_mipi_lane_num = 1`, `live_fdt:2889`, `-6b2.c:746,754-760` [S, D] |
| CSIS | CSIS0 `0x12120000`, SPI 138 | CSIS1 `0x12130000`, SPI 139 | `live_fdt:820,941,841,960`, `mach/map.h:308-309`, `mach/irqs.h:338-344` [D, S] |
| FIMC-LITE | A `0x12100000`, SPI 140 | B `0x12110000`, SPI 141 | `live_fdt:820,840,941,959` [D] |
| MIPI PHY (mainline id) | `mipi_phy 0`, PMU enable shared with DSIM0 | `mipi_phy 2` | `phy-exynos-mipi-video.c:157-215` [S] |
| MCLK | `sclk_isp_sensor0`, `gpd7-0` fn 2 | `sclk_isp_sensor2`, `gpd7-2` fn 2 | `live_fdt:846,964,5892,6923` [D] |
| MCLK rate | 24 MHz from oscclk, both dividers /1 | same | `setup-fimc-is-sensor.c:573-581` [S] |
| I2C pins | ISP ch0, `gpc2-0/1` | ISP ch2, `gpc2-4/5` | `live_fdt:842,961,6061,6045` [D] |
| I2C address (7-bit) | 0x37 | 0x35 | `i2c_addr`, `live_fdt:823,944`; `fimc-is-device-sensor.c:1378-1392` [D, S] |
| reset (high = running) | `gpc0-4` | `gpc0-3` | `live_fdt:819,940` [D], polarity from the sequences [S] |
| standby | none | `gpc0-0` | `live_fdt:958` [D] |
| power domain | pd-cam0 | pd-cam0 | `live_fdt:836,956` [D] |
| System MMU in front | `0x12150000` SPI 128 | `0x12160000` SPI 130, `0x142b0000` SPI 160 | `live_fdt:1588,1839,3315` [D] |

The third cell of `gpio_reset` is ignored by stock, which drives levels explicitly
(`-4h5.c:107,137,144`) [S].

Rear accessories: DW9807 actuator (`actuator_id = 13`, `exynos-fimc-is-sensor.h:100`)
at 0x0C on ISP ch1, `gpc2-2/3` (8-bit 0x18 in `i2c_addr = 0x186e`) [D, S]. Rear EEPROM
on HSI2C4 `0x14ec0000`, `gpj0-0` SDA, `gpj0-1` SCL, address 0x58 (`live_fdt:3114-3137`)
[D]. There is no companion chip (`CONFIG_COMPANION_USE` off) and no OIS [S].

Neighbours in the same GPIO bank: `gpc0-5` is the CP reset and `gpc0-7` the codec
reset (`exynos5433-gts28ltexx-modem-ss333.dtsi:51`, `-audio.dtsi:79`). A typo here
resets the modem.

## 2. Power

Every rail is an S2MPS13 LDO, already declared in our DT with the stock limits.

| rail | LDO | voltage | use |
|---|---|---|---|
| `CAM_SEN_A2.8V_AP` | 29 | 2.80 V | rear analog |
| `CAM_SEN_CORE_1.2V_AP` | 23 | **1.30 V** | rear core. The name says 1.2; stock DT min = max = 1.3 V (`live_fdt:2523-2527`). The voltage selection code is commented out (`fimc-is-sec-define.c:2797`) |
| `CAM_AF_2.8V_AP` | 26 | 2.80 V | actuator, also needed for the EEPROM |
| `CAM_IO_1.8V_AP` | 22 | 1.80 V | rear I/O, EEPROM |
| `VT_CAM_2.8V` | 27 | 2.80 V | front analog |
| `VT_CAM_1.8V` | 21 | 1.80 V | front I/O and core (`cam_1.2v_not_used`, `live_fdt:965`) |

`linux` `exynos5433-gts28ltexx.dts:522-562` matches, and `s2mps11.c:586-594` covers
these ranges [S].

Stock runs in this order: pd-cam0 on (runtime PM, `fimc-is-device-sensor.c:1231`), then
MIPI power and MCLK configured (`:2373-2380`), then the pin sequence below (`:1474`).
`PIN_FUNCTION` adds a 1 ms sleep (`setup-fimc-is-sensor.c:94-103`). The MCLK pad stays
in its off state until the pinctrl step.

**Rear on** (`-4h5.c:126-139`): A2.8 → core → AF, 2 ms → IO, 2 ms → pinctrl `ch0`
(I2C ch0 and MCLK) → reset high → pinctrl `af0`.
**Rear off** (`:142-152`): AF off, 2 ms → pinctrl `off0` → reset low → IO → core → A2.8.

**Front on, normal** (`-6b2.c:609-627`): standby low → VT 2.8 → VT 1.8, 1 ms → reset high
→ pinctrl `ch1` (I2C ch2 and MCLK). Reset rises before MCLK reaches the pad.
**Front off** (`:630-650`): standby low → pinctrl `off1` → reset low → VT 1.8 → VT 2.8.
**Front on, vision** (`:653-669`): reset stays low, standby goes high.

Mainline exposes all of this: LDOs, `fimc_is_ch{0,1,2}_{i2c,mclk}` pin groups, and
`sclk_isp_sensor{0,1,2}` with their muxes and dividers (`clk-exynos5433.c:341-346,
495-506, 658-663`) [S]. Stock drive strengths differ from the mainline groups (raw 1
rear, raw 2 front, against 0), so new groups are needed.

## 3. I2C, and who drives it

Two scenarios exist in stock (`fimc-is-device-sensor.c:703-741`) [S]:

* **Normal.** The A5 opens the sensor and drives it through its own controllers. The
  kernel only sends channel and address (`:1378-1392`).
* **Vision (`FIMC_IS_SENSOR_DRIVING`).** The kernel drives the sensor itself. For the
  front sensor this uses `i2c@35`, a GPIO bit-banged bus on `gpc2-4` SDA and `gpc2-5` SCL
  with 2 µs delay (`live_fdt:3329-3341`), `sensor_6b2_init` (`-6b2.c:136-238`) and stream
  on by writing 0x4100. Clock setup for this case is complete in `setup-fimc-is-sensor.c:
  355-500`. Nothing in this path needs the A5. `libexynoscamera.so` has vision entry
  points (`m_startVisionInternal`, `generateFrameVision`) [B].

ISP I2C controllers, as the A5 sees them: ch0 `0xE0130000`, ch1 `0xE0140000`, ch2
`0xE0120000` (table at `fw 0x25b35c`) [B]. ARM addresses are probably `0x14130000`,
`0x14140000`, `0x14120000`, by analogy with `0xE0180000` = MCUCTL `0x14180000` and
`0xE01C0000` = FIMC-LITE C `0x141C0000` [I]. They look like s3c2410 blocks with
extensions [I]. Clocks `CLK_PCLK_ISP_I2C0-2` and `CLK_SCLK_ISP_I2C0-2` are in CMU_CAM1
(`clk-exynos5433.c:5471,5487`) [S]. No mainline binding covers them.

**Linux should not use them.** It should use `i2c-gpio` on the same pins, as stock does
on ch2. Rear SDA/SCL (`gpc2-0` SDA, `gpc2-1` SCL) follow by analogy [I]. Bit-banging ch0
is not proven by stock. The pads have no internal pull (`samsung,pin-pud = 0`), so
pull-ups are external, on a rail that must be on [I]. Which rail is [U].

EEPROM: stock enables `CAM_IO_1.8V_AP` and `CAM_AF_2.8V_AP` (`fimc-is-device-eeprom.c:
167-170`, `fimc-is-sec-define.c:2576-2582`), no MCLK and no reset. It reads with a 2-byte
big-endian address, then a separate read (`:951-1000`). HSI2C4 works with mainline
`i2c-exynos5` as `hsi2c_4`, currently disabled. 8 KiB map: header version at 0x20, AWB at
0x220, AP shading at 0x1CE0 (`fimc-is-eeprom-rear-4h5_v001.h`) [S]. Header prefixes
known to stock: `F08LL`, `H08LL`, `J08LL`, `K08LL` (`fimc-is-sec-define.h:92-95`), and
`fw` ends with `K08LLKC01SA` [B].

Sensor ID: both follow the CCS layout. `fw` reads revision from 0x0002 on both sensors
(`0x6D800` for S5K4H5, around `0x776F0` for S5K6B2) [B]. The firmware does not compare a
model ID for either, so `fw` gives no expected value. Model ID at 0x0000-0x0001 is the
CCS convention [I]. `0x485B` for S5K4H5 is a recollection from public vendor drivers,
unconfirmed. The S5K6B2 value is [U]. Stage (a) records what the hardware returns.

## 4. MIPI CSIS

5433 stock uses the classic s5pcsis path (`FIMC_IS_CSI_VERSION == 0`,
`fimc-is-config.h:72`). The block is the family of `is4/mipi-csis.c`, with a different
register layout [S]:

| item | 5433 stock (`fimc-is-hw-csi.c`) | mainline (`mipi-csis.c`) |
|---|---|---|
| lane count | CTRL[3:2] (`:55`) | CONFIG[1:0] (`:66,359`) |
| HS settle | DPHYCTRL[31:24] (`:64`) | DPHYCTRL[31:27] (`:53,351`) |
| interrupt mask | `0xf1101117`, per-channel FS/FE (`:91`) | `0xfc00103f` (`:90`) |
| clock settle | field at [23:22] | absent |
| compatible | none upstream | s5pv210, exynos4210, exynos5250 (`:1012-1023`) |

No `samsung,exynos5433-csis` exists in `linux`, and a web search found none upstream.
A new `csis_drvdata` variant covering the three register differences is needed, about
80 lines [I]. Stock sets `WCLK_EXTCLK` when enabling (`:450-459`). Settle: rear 15 for
every mode (`-4h5.c:46-63`), front 16 for 1936×1090 (`-6b2.c:78-84`).

PHY: mainline already has `samsung,exynos5433-mipi-video-phy` (`phy-exynos-mipi-video.c:
157-215`), and the node exists (`exynos5433.dtsi:924`). It matches stock
`setup-exynos5-mipiphy.c`: PMU `0x710 + 4n`, reset in sysreg CAM0 `0x1014` (bit 0, 1) and
CAM1 `0x1020`. CSIS0 shares its PMU enable with DSIM0, which mainline handles through
`coupled_phy_id` [S]. `CONFIG_PHY_EXYNOS_MIPI_VIDEO=y` is already set.

Clocks for CSIS1 and FIMC-LITE B, from stock (`setup-fimc-is-sensor.c:433-467,517-520`):
`mout_aclk_cam0_{552,400,333}_user` → `aclk_cam0_*`, `mout_phyclk_rxbyteclkhs0_s2a` →
`phyclk_rxbyteclkhs0_s2a`, `mout_aclk_csis1_a` and `mout_aclk_lite_b_a` →
`mout_aclk_cam0_400_user`. All exist in `cmu_cam0` [S]. Front uses the 400 MHz branch,
so it does not depend on the ISP PLL. Rear uses 552 MHz from the ISP PLL, whose state on
our kernel is [U]. `mout_aclk_csis0_a_p` has a typo, `mout_aclk-cam0_400_user`
(`clk-exynos5433.c:4779`), so the rear CSIS cannot select the 400 branch without a fix.

## 5. Capture chain

**FIMC-LITE.** The stock 5433 register map matches `is4/fimc-lite-reg.h`: CIGCTRL,
CIOCAN, CIOSA at 0x30, CIOSAN at 0x200, CIFCNTSEQ at 0x100, CIGENERAL at 0xFC, and a
colour-bar test bit (`fimc-is-device-flite.c:52-186`) [S]. CSIS0→LITE A and CSIS1→LITE B
need no mux (`:796-805`). Mainline gaps [S, I]:

* `VIDEO_EXYNOS_FIMC_LITE` depends on `SOC_EXYNOS4212 || 4412 || 5250 || COMPILE_TEST`
  (`is4/Kconfig`).
* `OLOCAL_DISABLE` (CIGCTRL bit 22) is never set in mainline. Stock sets it when not
  feeding 3AA (`flite_hw_set_output_local`, `:532-542`).
* The driver knows one clock, `"flite"`, while the 5433 has about a dozen gates per
  channel in `cmu_cam0`.
* `media-dev.o` only builds with `VIDEO_S5P_FIMC` (`is4/Makefile:2`).

**RAW to DMA without ISP is possible by the stock design.** FIMC-LITE DMA is programmed by
the ARM. In the vision scenario the path is sensor → CSIS → FIMC-LITE DMA, with no 3AA and
no A5 (`flite_stream_on`, `:1595-1725`) [S]. The 2013 Exynos5 IS series split the same
pipeline: sensor, MIPI-CSIS and FIMC-LITE to memory, then FIMC-IS as post-processing
(https://lore.kernel.org/all/1375455762-22071-7-git-send-email-arun.kk@samsung.com/T/).

**GSCL.** Not a capture path here. Mainline `exynos-gsc` is memory-to-memory and has no
Bayer format. Stock `gsc-capture.c` hangs off an `exynos_isp_info` link that nothing on
this board provides [I]. FIMC-LITE's local output goes to 3AA only (`:176-184`).

**System MMU.** Our kernel has `# CONFIG_EXYNOS_IOMMU is not set`, and the camera SMMUs
are not in the mainline `exynos5433.dtsi`. Stock always maps through them. Bypass with
physically contiguous CMA (256 MiB available, all RAM below 4 GiB) is the plan, as MFC
would use. The reset state of an Exynos SysMMU is bypass [I], not proven for this
instance. Keep `aclk/pclk_smmu_lite_*` running.

Bandwidth: stock raises DVFS for camera (front preview: CAM 111 MHz, INT 200 MHz, MIF
413 MHz; rear: CAM 666-777 MHz, MIF 667-825 MHz, `live_fdt:2929-3014`) [D]. Mainline bus
levels during capture are [U]. A full-size rear stream may overflow FIMC-LITE. Front or
rear mode 7 are the safe first choices.

## 6. FIMC-IS

Facts [S]:

* Load: `request_firmware`, `memcpy` to a 20 MiB region aligned to 64 MiB
  (`fimc-is-device-ischain.c:889-913`, `fimc-is-core.c:173`, `fimc-is-core.h:87-89`).
* Start: base written to BBOAR (`:1507`), then PMU `ISP_ARM_CONFIGURATION` and `OPTION`
  bit 15 (`:1374-1400`).
* SMC: three families of writes to the ISP GIC at `0x141E0000/0x141F0000`, through
  `SMC_CMD_REG` (`:1512-1522`). Mainline has the same definitions in
  `mach-exynos/smc.h:29-33`.
* Interface: mailbox on MCUCTL `0x14180000`, shared registers ISSR0-63, INTGR0 towards
  the A5, SPI 165 back; shared region at `0x013C0000`, parameters in the last 0x5000
  bytes of the region; calibration at `0x013D0000`.
* Setfile: pointer returned by the firmware, then loaded by the host (`fimc_is_hw_saddr`,
  `fimc_is_ischain_loadsetf`).

No hard lock found: `fw` is plain ARM with readable strings [B]. The kernel checks only a
version tag. `CONFIG_EXYNOS_CONTENT_PATH_PROTECTION` has no use in `fis` [S]. Whether
sboot's monitor serves those SFR writes to our kernel is [U].

Real obstacles: about 33,700 lines of `fis/*.c` against 4,000 in mainline
`fimc-is*.c`, which is Exynos4x12 only (`fimc-is.c:953`). Mainline protocol is command
set 110 (`fimc-is-command.h:16`), 5433 is 132 (`fimc-is-config.h:70`). Every 3AA, ISP,
DRC, DIS, 3DNR, FD, SCC and SCP node plus the `camera2_shot` metadata would be needed,
with `videobuf2-ion` replaced, and the firmware is not redistributable. Estimate: many
months with no register documentation [I]. It is not worth starting before RAW works.

## 7. Sensor init: where the tables are

`fw` is a multi-sensor image (IMX134/175/219/220/240, SR261/544, S5K3H7, 3L2, 2P2, 8B1,
6D1, OV5693…). Function names survive in the data at `0x18AE00`, `0x195600` [B].

**S5K4H5: plain tables.** Pointer array at `0x25CC50` (via `0x6DC78`): eight mode tables
from `0x188490`, then eight descriptors from `0x18AC50`. A table is 106 entries of three
little-endian u32: `width, address, value`, 318 words each (`0x18ADB0`). Width 1 or 2
selects the write size (`0x6DACC-0x6DB12`). The load is wrapped in group hold, 0x0104 = 1
then 0 (`0x6DAC0`, `0x6DB1E`). Stream on and off write 0x0100 (`0x6E57E`, `0x6E5BA`).
Each table carries PLL, geometry, exposure and analog tuning; there is no separate global
init and no software reset. Common PLL: 24 MHz ext, pre 6, mult 140, vt_pix 2 → 280 MHz;
op pre 6, mult 169 → 676 Mbit/s per lane, 4 lanes. Output is RAW10 [I, from throughput
and `fimc-is-hw-csi.c`].

| # | table | output | FLL | LLP | fps |
|---|---|---|---|---|---|
| 0 | `0x188490` | 3280×2458 | 2528 | 3688 | 30.0 |
| 1 | `0x188988` | 3280×1846 | 2007 | 4650 | 30.0 |
| 2 | `0x188E80` | 1640×924 | 1260 | 3706 | 60.0 |
| 3 | `0x189378` | 816×460 | 630 | 3706 | 120 |
| 4 | `0x189870` | 3280×2458 | 3160 | 3688 | 24.0 |
| 5 | `0x189D68` | 3280×1846 | 2506 | 4650 | 24.0 |
| 6 | `0x18A260` | 816×604 | 657 | 3706 | 115 |
| 7 | `0x18A758` | 1640×1228 | 5010 | 3706 | 15.1 |

This order is exactly `config_4h5` (`-4h5.c:46-63`), which confirms the identification.
Runtime exposure: coarse at 0x0202, analog gain at 0x0204, digital gains from 0x020E
(`0x6E4A8-0x6E518`). Defaults at the table head: coarse 1250, gain 0x0020.

**S5K6B2: inline Thumb-2.** No table: functions write one register per call through
helpers at `0xD5704` (8-bit) and `0xD568E` (16-bit).

| function | start | writes |
|---|---|---|
| `S5K6B2_Init_30fps_1lane` | `0x77498` | 42 |
| `S5K6B2_Init_24fps_1lane` | `0x777A4` | 42 |
| `S5K6B2_Init_30fps_2lane` | `0x77B9E` | 43 |
| `S5K6B2_Init_24fps_2lane` | `0x77EE0` | 45 |
| `S5K6B2_Init_30fps_Binning_2x2` | `0x78244` | 41 |
| `S5K6B2_SetSize_*` | `0x78548`, `0x7875C`, `0x7891C` | 12 |

Lanes 1 mode, as used here: ext 24 MHz, pre 6, mult 183 → 732 Mbit/s (also written as
0x02DC at 0x3351-0x3354), LLP 2152, FLL 1126, 30.2 fps, 0x0114 = 0. Output 1936×1090.
Three further writes are conditional on the revision read from 0x0002. Stream on and off
write 0x0100 (`0x79120`, `0x79194`).

**Vision mode, in GPL source.** `sensor_6b2_init` (`-6b2.c:136-238`) is a complete list
for this mode: 8-bit output mixing Gr and R, an AE engine inside the sensor, stream on at
0x4100. It sets no geometry; `DEFAULT_SENSOR_WIDTH/HEIGHT` of 184×104 (`:45-46`) suggest a
very small frame [I]. It is the fallback and the only table not derived from `fw`.

**Setfiles.** `setfile_4h5.bin` and `setfile_6b2.bin` start with magic `0x12345679` and
`HELSIE01`. A scan finds no `width, address, value` run of 8 or more, and no sensor mode
geometry [B]. They are ISP tuning. They are not needed for RAW.

**Handling.** These bytes are Samsung's and must not enter the repository. Options, for a
later decision: read `fw` at runtime with `request_firmware` from the owner's own copy and
validate its sha256, for S5K4H5; keep the S5K6B2 transcription out of tree for tests. The
vision list is the clean source.

## 8. What user space does

`libexynoscamera.so` selects a sensor class from `/sys/class/camera/*/*_sensorid`
(`createSensorInfo` only knows 13 and 7) and drives V4L2 nodes. It holds no sensor init.
AE, AWB and image processing run in the A5 and the ISP hardware [B].

With RAW, Linux must supply everything:

* Black level, demosaic, white balance, gamma, in software. EEPROM AWB and shading data
  can feed this.
* Exposure loop writing the registers of section 7.
* Bayer order: [U]. The first image decides. Note mainline `fimc-lite.c` only lists GRBG
  codes, which does not matter to the hardware.

First image: pull the buffer over SSH and process it on the Mac. Later: libcamera
`simple` pipeline with SoftISP, which needs a V4L2 sensor subdev with exposure, gain,
vblank, hblank, pixel-rate and link-frequency controls.

## 9. Roadmap

Route: test kernel in RECOVERY, `t715.persist=0`, per `docs/hardware/CPUFREQ.md` 8.3, CP
off. Everything is a module, loaded by hand, with `allow_hw=0` by default.

| stage | proves | risk | kernel | Kconfig |
|---|---|---|---|---|
| a0 EEPROM | rails, HSI2C4 | very low | DT, probe module | `T715_CAM_PROBE=m` |
| a1 front ID | front power, MCLK, bit-bang | low | same | same |
| a2 rear ID | rear power, ch0 bit-bang | low | same | same |
| b CSIS sees frames | sensor init, lane, PHY, CSIS | medium: PD and clocks of CAM0, hang possible | test module + DT below | same |
| c0 colour bars | FIMC-LITE, DMA, SMMU bypass | medium: stray DMA | same | same |
| c image in memory | full chain | medium | same | same |
| d rear | 4 lanes, ISP PLL | medium | clock typo fix | same |
| e V4L2 | libcamera | low | CSIS variant, FIMC-LITE fixes, two sensor drivers | list below |

Stages a to c need no `VIDEO_DEV`: a debugfs test module is enough and fails more
readably. Patch for stage a: see the bring-up notes.

**Stage b.** Extend the module to map CSIS1 and take the PHY. Order follows stock:
CSIS before sensor stream on (`fimc-is-device-sensor.c:2141,2160`). Program CSIS reset,
DPHYCTRL settle `16 << 24`, CTRL lanes 0, CONFIG RAW10 `0x2b << 2` plus end interval 1,
RESOL `1936 << 16 | 1090`, INTMSK `0xf1101117`, CTRL enable, shadow update, DPHY on 0x3.
Then send the sensor sequence, then 0x0100 = 1, and read INTSRC (0x14). Frame start and
end bits with error bits clear prove it. Dump `clk_summary` first.

```dts
&cmu_cam0 {
	assigned-clocks = <&cmu_cam0 CLK_MOUT_ACLK_CAM0_552_USER>,
			  <&cmu_cam0 CLK_MOUT_ACLK_CAM0_400_USER>,
			  <&cmu_cam0 CLK_MOUT_ACLK_CAM0_333_USER>,
			  <&cmu_cam0 CLK_MOUT_PHYCLK_RXBYTECLKHS0_S2A_USER>,
			  <&cmu_cam0 CLK_MOUT_ACLK_CSIS1_A>,
			  <&cmu_cam0 CLK_MOUT_ACLK_CSIS1_B>,
			  <&cmu_cam0 CLK_MOUT_ACLK_LITE_B_A>,
			  <&cmu_cam0 CLK_MOUT_ACLK_LITE_B_B>;
	assigned-clock-parents = <&cmu_top CLK_ACLK_CAM0_552>,
				 <&cmu_top CLK_ACLK_CAM0_400>,
				 <&cmu_top CLK_ACLK_CAM0_333>,
				 <&cmu_cam0 CLK_PHYCLK_RXBYTEECLKHS0_S2A_PHY>,
				 <&cmu_cam0 CLK_MOUT_ACLK_CAM0_400_USER>,
				 <&cmu_cam0 CLK_MOUT_ACLK_CSIS1_A>,
				 <&cmu_cam0 CLK_MOUT_ACLK_CAM0_400_USER>,
				 <&cmu_cam0 CLK_MOUT_ACLK_LITE_B_A>;
};

&soc {
	cam_front: cam-front@12130000 {
		compatible = "samsung,t715-cam-capture";
		reg = <0x12130000 0x1000>, <0x12110000 0x1000>;
		interrupts = <GIC_SPI 139 IRQ_TYPE_LEVEL_HIGH>,
			     <GIC_SPI 141 IRQ_TYPE_LEVEL_HIGH>;
		phys = <&mipi_phy 2>;
		phy-names = "csis";
		power-domains = <&pd_cam0>;
		clocks = <&cmu_cam0 CLK_ACLK_CSIS1>, <&cmu_cam0 CLK_PCLK_CSIS1>,
			 <&cmu_cam0 CLK_ACLK_LITE_B>, <&cmu_cam0 CLK_PCLK_LITE_B>,
			 <&cmu_cam0 CLK_PHYCLK_RXBYTECLKHS0_S2A>,
			 <&cmu_cam0 CLK_ACLK_SMMU_LITE_B>,
			 <&cmu_cam0 CLK_PCLK_SMMU_LITE_B>;
		clock-names = "aclk_csis", "pclk_csis", "aclk_lite",
			      "pclk_lite", "phy", "aclk_smmu", "pclk_smmu";
	};
};
```

**Stage c0.** `dma_alloc_coherent`, FIMC-LITE reset, source size, CIOCAN, YUV422 format,
OLOCAL disabled, test bit 15, capture start, then look for bars in the buffer. Whether the
test pattern runs without an incoming pixel clock is [U]; a failure here is not conclusive
on its own. Stage b's frames allow going directly to c. A wrong DMA address corrupts RAM,
so `t715.persist=0` is mandatory.

**Stage c.** Same with RAW10 (`0x2b << 24`), 1936×1090, one buffer, CIOCAN per
`flite_hw_set_dma_offset`, sensor exposure set. The result is a recognisable frame.

**Stage e.**

```
CONFIG_MEDIA_SUPPORT=m
CONFIG_MEDIA_CAMERA_SUPPORT=y
CONFIG_MEDIA_PLATFORM_SUPPORT=y
CONFIG_MEDIA_PLATFORM_DRIVERS=y
CONFIG_V4L_PLATFORM_DRIVERS=y
CONFIG_VIDEO_V4L2_SUBDEV_API=y
CONFIG_VIDEO_SAMSUNG_EXYNOS4_IS=m
CONFIG_VIDEO_S5P_FIMC=m
CONFIG_VIDEO_S5P_MIPI_CSIS=m
CONFIG_VIDEO_EXYNOS_FIMC_LITE=m
```

Add to these `MEDIA_CONTROLLER` and `VIDEO_DEV`, pulled in by defaults. New code: a CSIS
variant, FIMC-LITE Kconfig and clocks and OLOCAL, media-dev without FIMC nodes, two sensor
subdevs on the model of `s5k6a3.c`, which itself has no register table. Rough estimate:
days to stage c once stage a passes, weeks to libcamera [I].

## 10. Not established

* Model ID values; which rail powers the I2C pull-ups; rear SDA/SCL order.
* Whether MCLK reaches the pad without pd-cam0. The design mirrors stock and holds it on.
* ISP PLL state, CMU_CAM0 gate state after power-up, mainline bus levels.
* SMMU bypass for FIMC-LITE.
* ARM addresses of the ISP I2C blocks.
* Bayer order and vision-mode frame size.

## 11. Results on the tablet, 2026-10-31

Test kernel in RECOVERY (`kernel/patches/t715-camtest/`), `t715.persist=0`,
`t715.returnafter=5400`, modem modules left out of the image, CP off. Tools:
`research/parity/camera/`. The sensor's register sequence stays private: decoded from `fw`
by `ex6b2b.py`, it never enters the repository.

| Stage | Result |
|---|---|
| a0 EEPROM | HSI2C4, 0x58: a `K08LL` header, as stock expects. 0x59 answers NACK **[T]** |
| a1 front ID | bit-banged I2C on `gpc2-4/5`, 0x35: `6B 20 01 09 0A FF`, twice over two power cycles, model id **0x6B20**. 0x34 answers NACK. MCLK 24 MHz **[T]** |
| a2 rear ID | bit-banged I2C on `gpc2-0/1`, 0x37: `48 5B 03 00 0A FF`, model id **0x485B**, the same way. 0x36 answers NACK **[T]** |
| b frames | CSIS1 `INTSRC` 0xa1100000 at every read: frame start and end on channel 0, and no error bit. FIMC-LITE B `CISTATUS` frame start and end, sensor frame counter moving **[T]** |
| c0 colour bars | skipped: real frames came first |
| c image | RAW10 in one 16-bit word per pixel, MSB-aligned on bit 9. DMA wrote exactly 1936 x 1090 x 2 bytes: the 0x5A marker of the buffer starts right there **[T]** |
| photograph | exposure 0x7ff0 lines, gain 0x0080, FLL 0x8000, 4 frames averaged on the tablet, half-resolution demosaic: a sharp, recognisable room **[T]** |

Answers to what section 10 left open:

- The model ids read as above. The rear one is the value recalled from public drivers.
- `gpc2-0` is SDA and `gpc2-1` SCL on the rear: bit-banging ch0 works, with the pull-ups up.
- System MMU for FIMC-LITE B: CTRL 0, CFG 0x00100000, STATUS 0 with its clocks on, in
  bypass, and the DMA landed at the physical address of a CMA buffer.
- Bayer order: GRBG gives natural colours.
- The sensor needs nothing from pd-cam0 beyond what the sequence holds; the bus keeps
  working with the rails of section 2.

**The hang at stop.** The first test module held 22 gates and dropped them all at stop: five
CPUs stalled together, which means the fabric, not one CPU, and `panic_on_rcu_stall` brought
the tablet back through the watchdog path, unattended, in about two minutes. Most of those
gates are `CLK_IGNORE_UNUSED` in `clk-exynos5433.c`: the block's bus, on by default, which
nothing should ever turn off. Stock enables only `aclk_csis`, `pclk_csis` and the LITE gate.
The driver holds those, with the PHY's byte clock, and stops cleanly, stream after stream.

**The interrupt.** Requested at probe, FIMC-LITE's line fired as soon as the power domain
came up, before the clocks, and the handler's register read took a synchronous external
abort, in interrupt context: a panic. It is masked until the block is armed. It is cleared
by writing 0 to `CISTATUS`, as stock does: masking only the source bits leaves it level high,
62000 interrupts in a few seconds.

**The driver.** `drivers/media/platform/samsung/t715-camera.c`, `kernel/patches/t715-parity/`:
SGRBG10 in 16-bit words, 2 buffers minimum, end of frame swaps the address during the
vertical blank, and exposure, analogue gain and vertical blank are V4L2 controls. Rear:
CSIS0 at 400 MHz needs the fix of a typo in `clk-exynos5433.c`. Frames at 3280x2458, one
interrupt per frame, no overflow seen at 30 fps. `t715-photo` (`image/pkg/t715-camera/`) steers
the exposure from the frames, averages 4, does a half-resolution demosaic and writes a PNG:
10 s at full exposure, with a static binary and no library.

In low light, front camera only: gain alone gives noise, while a
long frame by FLL gives a clean image.

**The rear needs the panel lit.** With the screen off (DPMS), the rear gives no frame: the
sensor streams, its frame counter moves, and CSIS0's `INTSRC` stays 0, twice in a row. With the
screen on, frames arrive at once. CSIS0 is coupled to DSIM0 in `phy-exynos-mipi-video.c`, and
the front's CSIS1 does not need the panel: a dark panel seems to take the shared D-PHY with it.
That cause is an inference; the on and off results are measured. Photo starts from a lit
screen, so the drawer is not affected. Over SSH, light the screen first. `t715-photo` gives up
after 15 s with no frame.

A clean test route remains for what is next: `kernel/patches/t715-camtest/`, on `7d34675d8`
of `t715-parity`, the commit before the cameras, adds `t715-cam-probe` and `t715-cam-capture`,
debugfs modules that drive each step by hand. `research/parity/camera/` has their tools.
