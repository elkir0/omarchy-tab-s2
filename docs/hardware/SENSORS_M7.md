# Milestone 7 — Motion sensors (LSM6DS3 + YAS537) and cover Hall switch

**Board file:** `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m7.dts`
→ `exynos5433-gts28ltexx-m2.dts` + `exynos5433-gts28ltexx-m7.dtsi`.
**Config fragment:** `arch/arm/configs/gts28ltexx_m7.config` (superset of
`gts28ltexx_m2.config`, see §5). **Mainline tree:** Linux 6.12,
32-bit (ARMv7/LPAE) build.

Scope: describe the motion sensors and the flip-cover Hall switch with
existing mainline drivers only — `st_lsm6dsx` (accelerometer+gyro),
`yamaha-yas530` (magnetometer) and `gpio-keys` (cover switch) — so
iio-sensor-proxy can report screen orientation and lid state. The board
files describe; they are not a port of the downstream drivers.

Sources cited as `live_fdt.dts:LINE` = `dumps/live_fdt.dts`, or
`<file>:LINE` under `src/kernel_universal5433/` (downstream) or
`src/linux-6.12/` (mainline).

## 1. I2C bus — HSI2C channel 10

| m7 value | Stock source | Mainline mapping |
|---|---|---|
| `&hsi2c_10` + `status = "okay"` | `live_fdt.dts:1925-1958` — `hsi2c@14DE0000`, `compatible "samsung,exynos5-hsi2c"`, reg `0x14de0000 0x1000`, status okay | `exynos5433.dtsi:1735` `hsi2c_10: i2c@14de0000` (same reg, compatible `samsung,exynos5433-hsi2c`/`samsung,exynos7-hsi2c`; SoC-level fallback, same hardware block) |
| `clock-frequency = <400000>` | `live_fdt.dts:1938` — `samsung,i2c-max-bus-freq = <0x61a80>` = 400000 | i2c-exynos5 reads `clock-frequency` (`drivers/i2c/busses/i2c-exynos5.c:870`) |
| (nothing — inherited) | `live_fdt.dts:1929` — `pinctrl-0 = <0x71>` = `hs-i2c10-bus` group (gpg3-0/gpg3-1, func 4, pud 0; `live_fdt.dts:5696-5702`) | `exynos5433.dtsi:1743` already sets `pinctrl-0 = <&hs_i2c10_bus>`; `exynos5433-pinctrl.dtsi:706-711` same pins + func 4 (mainline adds pull-up; harmless for an I2C bus and the usual mainline setting) |

Left out on the bus node: `samsung,check-transdone-int` and
`samsung,i2c-sda-delay = <0x64>` (`live_fdt.dts:1935/1933`) —
downstream-only properties, not read by the mainline i2c-exynos5 driver
(same decision as m4's `hsi2c_5`).

## 2. LSM6DS3 6-axis IMU — `imu@6b`

| m7 value | Stock source | Mainline mapping |
|---|---|---|
| `compatible = "st,lsm6ds3"` | `live_fdt.dts:1948` — same string | `st,lsm6dsx.yaml` compatible enum includes `st,lsm6ds3`; driver `drivers/iio/imu/st_lsm6dsx/` (chip ID `ST_LSM6DS3_ID`) |
| `reg = <0x6b>` | `live_fdt.dts:1947` | same |
| `interrupt-parent = <&gpa0>; interrupts = <0 IRQ_TYPE_LEVEL_HIGH>` | `live_fdt.dts:1951-1952` — `st,irq_gpio = <0x4b 0x00 0x00>` = gpa0-0 (bank phandle 0x4b at `live_fdt.dts:181-189`). Trigger type: the stock driver hardcodes `IRQF_TRIGGER_HIGH` when requesting the IRQ (`drivers/iio/imu/st_lsm6ds3_trigger.c:268-269`) | mainline takes the trigger type from the DT (`irqd_get_trigger_type`, `st_lsm6dsx_core.c:2552`) and adds `IRQF_ONESHOT` itself (`st_lsm6dsx_core.c:2603`); binding `st,lsm6dsx.yaml` `interrupts` maxItems 1 |
| `st,drdy-int-pin = <1>` | `live_fdt.dts:1953` — `st,drdy-int-pin = <0x01>` | binding property `st,drdy-int-pin` enum 1\|2; the stock driver defaults to 1 too (`st_lsm6ds3_core.c:3493-3498`) |
| `mount-matrix = "0","1","0", "1","0","0", "0","0","-1"` | `live_fdt.dts:1954` — `st,orientation = <1 2 1 2 1 1 1 1 0>`; derivation in §2.1 | binding `Documentation/devicetree/bindings/iio/mount-matrix.txt`; driver reads it via `iio_read_mount_matrix` (`st_lsm6dsx_core.c:2736`) |
| no `vdd-supply`/`vddio-supply` | the stock node names no rails (`live_fdt.dts:1946-1955`); the stock driver's `st,vio` regulator enable is commented out (`st_lsm6ds3_core.c:3637`) | binding makes both supplies optional |
| no `pinctrl` | stock node has only a bare `pinctrl-names = "default"` with no `pinctrl-0` (`live_fdt.dts:1950`) | nothing to transcribe; gpa0-0 is an alive-bank pin with bank defaults |

### 2.1 `st,orientation` → `mount-matrix` derivation

The stock driver parses `st,orientation` as u32[9] and stores each cell
minus 1 (`st_lsm6ds3_core.c:3511-3518`):

```
cdata->orientation[i] = ((s8)orientation[i]) - 1;
```

so the live value `<1 2 1 2 1 1 1 1 0>` becomes the integer matrix:

```
{ 0, 1, 0,      row 0: 1-1, 2-1, 1-1
  1, 0, 0,      row 1: 2-1, 1-1, 1-1
  0, 0,-1 }     row 2: 1-1, 1-1, 0-1
```

The stock buffer applies it row-per-output-axis — the SENSOR_DATA_X/Y/Z
macros (`st_lsm6ds3_buffer.c:30-46`) compute
`out[i] = Σ_j orientation[3i+j] * in[j]`, i.e.
`x' = 0·x + 1·y + 0·z = y`, `y' = 1·x + 0·y + 0·z = x`,
`z' = 0·x + 0·y + (−1)·z = −z`.

The mainline mount-matrix binding uses exactly this convention
(`mount-matrix.txt`: matrix written as
`mxx myx mzx / mxy myy mzy / mxz myz mzz`, applied as
`x' = mxx·x + myx·y + mzx·z`, …). With
`mxx=0, myx=1, mzx=0 / mxy=1, myy=0, mzy=0 / mxz=0, myz=0, mzz=−1`
the multiplication is identical, hence:

```
mount-matrix = "0",  "1",  "0",
               "1",  "0",  "0",
               "0",  "0", "-1";
```

(90° rotation about Z combined with a Z flip — the sensor sits rotated
on the main board.)

## 3. YAS537 magnetometer — `magnetometer@2e`

| m7 value | Stock source | Mainline mapping |
|---|---|---|
| `compatible = "yamaha,yas537"` | `live_fdt.dts:1941` — `compatible = "yas_magnetometer"`; the part is identified by `reg` + driver name `yas537` (`drivers/iio/magnetometer/yas537/`) | `yamaha,yas530.yaml` compatible enum includes `yamaha,yas537`; mainline driver `drivers/iio/magnetometer/yamaha-yas530.c` has a yas537 chip-info entry (1371-1385) and an of_match entry (1596) |
| `reg = <0x2e>` | `live_fdt.dts:1940` | same |
| `mount-matrix = "0","-1","0", "-1","0","0", "0","0","-1"` | `live_fdt.dts:1942` — `yas,orientation = <7>`; derivation in §3.1 | binding `mount-matrix`; driver reads it via `iio_read_mount_matrix` (`yamaha-yas530.c:1407`) |
| no `interrupts` | stock node has none (`live_fdt.dts:1939-1944`) — the stock driver polls on its own thread | binding `interrupts` optional; mainline driver works polled (triggerless buffer) |
| no `vdd-supply`/`iovdd-supply` | stock node names no rails | binding makes both optional (bulk get, `yamaha-yas530.c:1435-1443`) |
| no `reset-gpios` | stock node has none | binding **forbids** `reset-gpios` for anything but `yamaha,yas530` (allOf if/then in `yamaha,yas530.yaml`) |
| node name `magnetometer@2e` | stock `yas537@2e` | binding `$nodename` pattern `^magnetometer@[0-9a-f]+$` |

### 3.1 `yas,orientation` → `mount-matrix` derivation

`yas_parse_dt` maps the property to a "position" index
(`yas_mag_kernel.c:856-891`), and the driver looks the transformation
up in `YAS537_TRANSFORMATION[]` (`yas_mag_drv-yas537.c:108-117`). Row 7
(position 7, our value) is:

```
{ 0, -1, 0,
 -1,  0, 0,
  0,  0, -1 }
```

The stock driver applies it row-per-output-axis
(`yas_mag_drv-yas537.c:462-471`):

```
xyz_tmp[i] = transform[i*3]·v[0] + transform[i*3+1]·v[1] + transform[i*3+2]·v[2]
```

i.e. `x' = −y`, `y' = −x`, `z' = −z` — the same convention as the
mainline mount-matrix binding (§2.1), so the matrix transcribes
element-for-element:

```
mount-matrix =  "0", "-1",  "0",
               "-1",  "0",  "0",
                "0",  "0", "-1";
```

Note position 2 (`YAS537_MAG_NOTRANS_POSITION`) is the identity; the
stock value 7 is a genuine rotation+flip, consistent with the LSM6DS3's
(both describe the same physical mounting).

### 3.2 Softiron calibration — deliberately not copied

The stock node carries `yas,softiron` (9 × fixed-point units of 1/10000)
and `yas,softiron_sign` (`live_fdt.dts:1943-1944`). These are
**per-device factory calibration** written at production
(`YAS537_SET_STATIC_MATRIX` path, `yas_mag_kernel.c:877-885`). Per the
task constraint, per-device calibration data is never copied into the
repo; the mainline driver has no softiron property anyway. The values
remain available on the device tree dump for a future userspace or
per-device overlay solution.

## 4. Cover Hall switch — `hall-sensor` gpio-keys node

Stock node `live_fdt.dts:5367-5373`:

```
hall {
    compatible = "hall";
    pinctrl-0 = <0xbc>;            /* hall-irq: gpa0-1, func 0xf, pud none */
    hall,gpio_flip_cover = <0x4b 0x01 0x00>;
    status = "okay";
};
```

| m7 value | Stock source | Mainline mapping |
|---|---|---|
| node `hall-sensor`, `compatible = "gpio-keys"` | stock `hall` / `compatible "hall"` | gpio-keys binding (`input/gpio-keys.yaml`); distinct node from m4's `gpio-keys` (different compatible, no key overlap) |
| child `switch-flip-cover` | — | binding child pattern `^(button\|event\|key\|switch\|…)$` |
| `gpios = <&gpa0 1 GPIO_ACTIVE_LOW>` | `live_fdt.dts:5372` — `hall,gpio_flip_cover = <0x4b 0x01 0x00>` = gpa0-1 | gpio-keys binds the GPIO and its IRQ itself (`gpio_keys.c` `gpiod_to_irq`), so no separate `interrupts` and no transcription of the stock `hall-irq` pinctrl group (`live_fdt.dts:428-434`, func 0xf = EXTINT) |
| `linux,input-type = <EV_SW>` | stock driver registers `input_set_capability(input, EV_SW, SW_LID)` (`hall.c:373`) | `EV_SW = 0x05` (`linux-event-codes.h:43`) |
| `linux,code = <SW_LID>` | same | `SW_LID = 0x00` (`linux-event-codes.h:909`, "set = lid shut") |
| `debounce-interval = <10>` | `__flip_cover_detect` schedules the work `HZ*1/100` = 10 ms after the opening edge (`hall.c:214`), 0 after closing (`hall.c:217`); 10 ms is the conservative of the two. The SEC_FACTORY path (50 ms double-read, `hall.c:148-172/210`) is not compiled: `# CONFIG_SEC_FACTORY is not set` (`lineage_gts28ltexx_defconfig:23`) | binding `debounce-interval` (default 5) |
| `wakeup-source` | task requirement (cover must wake/unlock the device). The stock probe passes `wakeup=0` to `device_init_wakeup` (`hall.c:335/405`), but its suspend callback **unconditionally** calls `enable_irq_wake` (`hall.c:465`, `gsm_area` defaults false at `hall.c:384`), so the stock behaviour is wake-capable in practice | binding `wakeup-source` |

### 4.1 Polarity reasoning

The stock driver reports the inverted raw GPIO:

```
flip_cover = gpio_get_value(ddata->gpio_flip_cover);   /* raw level */
input_report_switch(ddata->input, SW_LID, !flip_cover); /* hall.c:168/201 */
```

so on the stock kernel: **raw GPIO low ⇒ SW_LID = 1 ⇒ cover closed**,
raw GPIO high ⇒ SW_LID = 0 ⇒ cover open. (The Hall IC pulls the line
low when the magnet — in the cover — is near.)

Mainline gpio-keys reports `state = gpiod_get_value(button->gpiod)`
directly as the switch value (`gpio_keys.c`,
`gpio_keys_gpio_report_event`), and `gpiod_get_value` returns the
**logical** level, i.e. raw XOR active_low (`gpiolib.c`). Therefore
`GPIO_ACTIVE_LOW` in the DT yields `SW_LID = !raw` — exactly the stock
mapping — without any driver change. With `GPIO_ACTIVE_HIGH` the states
would come out inverted.

### 4.2 Left out of the Hall node

- The stock `hall-irq` pinctrl group (gpa0-1, function 0xf = EXTINT,
  pud none, `live_fdt.dts:428-434`): gpio-keys requests the GPIO and
  takes its IRQ through gpiod (`gpiod_to_irq`), which configures the
  pin as interrupt source itself; same approach as m4's keys on the
  same alive bank.
- `hall,gsm_wa` (GSM-area workaround flag parsed at `hall.c:317-329`):
  absent from the live tree (verified: no such property anywhere in
  `live_fdt.dts`), and `gsm_area` defaults to false (`hall.c:384`), so
  the 7 ms double-read workaround path is dead on this device.

## 5. What was left out entirely, and why

| Left out | Stock source | Reason |
|---|---|---|
| cm36652 light/proximity (`i2c@30/cm36652@60`) | `live_fdt.dts:69-93` | **Excluded**: mainline has only `cm36651` (`drivers/iio/light/cm36651.c`). The two are different dies: cm36651 exposes the proximity function at a **second I2C address 0x19** with byte-wide registers, while cm36652 is a **single-address (0x60) word-wide** part with RGB+white ALS channels (`drivers/iio/light/cm36652.c:58-72` register map: CS_CONF1 0x00, ALS_RED..WHITE 0x08-0x0B, PS_CONF1 0x03, CONF3 0x04, THD 0x05, CANC 0x06, DATA 0x07 — nothing matches cm36651's layout). No mainline driver handles it; inventing a compatible string without a driver would produce a dead node. |
| sx9310 grip/SAR sensors | `i2c@28/@29` (per HARDWARE_MAP.md) | Out of scope per the task brief |
| `yas,softiron`/`yas,softiron_sign` | `live_fdt.dts:1943-1944` | Per-device factory calibration; never copied into the repo (§3.2) |
| `samsung,check-transdone-int`, `samsung,i2c-sda-delay` | `live_fdt.dts:1933/1935` | Downstream-only hsi2c quirks, unread by mainline i2c-exynos5 |
| LSM6DS3 supplies (`vdd-supply`/`vddio-supply`) | — | Stock node names no rails; stock regulator enable commented out |
| YAS537 `interrupts` | — | Stock node has none; the part is polled |

## 6. Config fragment

`gts28ltexx_m7.config` = full copy of `gts28ltexx_m2.config` (only one
fragment is merged per build) plus:

| Symbol | Why | Report |
|---|---|---|
| `CONFIG_IIO=y` | IIO core (parent menuconfig of both drivers) | `=y` OK |
| `CONFIG_IIO_BUFFER=y` | required by both drivers' buffer support (selected automatically, restated) | `=y` OK |
| `CONFIG_IIO_TRIGGERED_BUFFER=y` | selected by both drivers (restated) | `=y` OK |
| `CONFIG_IIO_ST_LSM6DSX=y` | st_lsm6dsx IMU driver, supports LSM6DS3 | `=y` OK |
| `CONFIG_IIO_ST_LSM6DSX_I2C=y` | I2C transport (auto-selected when I2C, restated) | `=y` OK |
| `CONFIG_YAMAHA_YAS530=y` | yamaha-yas530 driver, supports YAS537 | `=y` OK |
| `CONFIG_INPUT_EVDEV=y` | `/dev/input/event*` for iio-sensor-proxy | `=y` OK |
| `CONFIG_KEYBOARD_GPIO=y` | gpio-keys driver (depends GPIOLIB, `=y` since m2) | `=y` OK |
| `CONFIG_I2C_EXYNOS5=y` | hsi2c_10 controller driver | `=y` OK, inherited from the m2 half |

No symbol in this fragment is forced to `=m` by its dependencies. All
restated "selected" symbols are kept explicit so the fragment documents
the full sensor chain even if Kconfig would derive them.

## 7. Validation level

Build-tested only (no device interaction, per task constraints):

- `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_m7.config`
  → `out/mainline-m7/` (zImage + DTBs + `.config` +
  `modules.tar.xz`), DTB
  `out/mainline-m7/exynos5433-gts28ltexx-m7.dtb`. Required
  symbols verified `=y` in `out/mainline-m7/.config`.
- Explicit DTB target also built via the docker make command
  (`make ARCH=arm ... samsung/exynos5433-gts28ltexx-m7.dtb`), DTB
  decompiled and grepped for
  `st,lsm6ds3|yamaha,yas537|mount-matrix|linux,input-type` — all
  present.
- **dtschema dtbs_check ran** (dtschema 2026.9, installed in the build
  container via `apt-get install python3-pip` +
  `pip3 install --break-system-packages dtschema`; same method as
  DT_M2.md): `make ARCH=arm CHECK_DTBS=y
  samsung/exynos5433-gts28ltexx-m7.dtb` → exit 0. **The m7 nodes
  produced zero findings** (`imu@6b` st,lsm6ds3, `magnetometer@2e`
  yamaha,yas537, `hall-sensor` gpio-keys switch, `hsi2c_10`). All
  findings pre-exist milestone 7:
  - root `compatible = ["samsung,gts28ltexx", "samsung,exynos5433"]`
    not in `arm/samsung/samsung-boards.yaml` — needs its own binding
    entry (milestone-1 scope);
  - `oscclk` fixed-clock missing `clock-frequency` — inherited from
    `exynos5433.dtsi`;
  - `usb@15400000` missing `vdd33/vdd10-supply` — deliberate m2
    decision, documented in DT_M2.md, re-surfaced because m7 includes
    the m2 board file;
  - `sec-log@25fff000` no schema — inherited from the milestone-1 base
    `exynos5433-gts28ltexx.dts`;
  - plus the `interrupt_provider`/`interrupt_map` dtc warnings on
    `pcie@15700000`, inherited from `exynos5433.dtsi` (present on TM2
    too).

## 8. Open points (device-untestable from here)

- **Mount matrices** transcribe the stock convention exactly, but the
  physical orientation cannot be re-verified without the device; if
  iio-sensor-proxy reports a rotated screen, the fix is one property
  per sensor.
- **YAS537 accuracy** on mainline: the driver notes no linearization /
  temperature compensation formulas are known for YAS537
  (`yamaha-yas530.c:598-601`), and the factory softiron matrix is not
  applied — expect roughly-correct but uncalibrated magnitudes; compass
  heading quality will be limited until userspace calibration exists.
- **Hall switch level**: the polarity is derived from the stock driver
  code, not from an on-device measurement; if the cover state proves
  inverted on hardware, flipping `GPIO_ACTIVE_LOW` →
  `GPIO_ACTIVE_HIGH` is the one-line fix.
- **wakeup-source vs stock `wakeup=0`**: documented divergence in §4;
  the task requires `wakeup-source`, and the stock suspend path enables
  IRQ wake anyway.
