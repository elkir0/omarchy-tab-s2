# Milestone 4 — Input devices (touchscreen + GPIO keys)

**Board file:** `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m4.dts`
→ `exynos5433-gts28ltexx-m2.dts` + `exynos5433-gts28ltexx-m4.dtsi`.
**Config fragment:** `arch/arm/configs/gts28ltexx_m4.config` (superset of
`gts28ltexx_m2.config`, see below). **Mainline tree:** Linux 6.12,
32-bit (ARMv7/LPAE) build.

Scope: the Synaptics RMI4 touchscreen and the four physical keys. Only
existing mainline drivers are used. The board files describe; they are
not a port of the downstream driver.

Sources cited as `live_fdt.dts:LINE` = `dumps/live_fdt.dts`, or
`synaptics_i2c_rmi.c:LINE` =
`src/kernel_universal5433/drivers/input/touchscreen/synaptics_dsx2/synaptics_i2c_rmi.c`
(the driver enabled by the stock defconfig:
`CONFIG_TOUCHSCREEN_SYNAPTICS_I2C_DSX2=y`,
`lineage_gts28ltexx_defconfig:1935`).

## 1. Touchscreen (Synaptics RMI4 over I2C)

### 1.1 I2C bus

| m4 value | Stock source | Mainline mapping |
|---|---|---|
| `&hsi2c_5` + `status = "okay"` | `live_fdt.dts:1645-1653` — `hsi2c@14ED0000`, `compatible "samsung,exynos5-hsi2c"`, status okay | `exynos5433.dtsi:1665` `hsi2c_5: i2c@14ed0000` (same address) |
| `clock-frequency = <400000>` | `live_fdt.dts:1658` — `samsung,i2c-max-bus-freq = <0x61a80>` (400000) | i2c-exynos5 reads `clock-frequency` (`drivers/i2c/busses/i2c-exynos5.c:870`) |
| (nothing — inherited) | `live_fdt.dts:1649` — `pinctrl-0 = <0x5e>` = `hs-i2c5-bus` group (gpj1-0/gpj1-1, func 4, pull-up; `live_fdt.dts:5116-5125`) | `exynos5433.dtsi:1673` already sets `pinctrl-0 = <&hs_i2c5_bus>`; `exynos5433-pinctrl.dtsi:793-799` matches (func `EXYNOS_PIN_FUNC_4`, pull up) |

Left out on the bus node: `samsung,check-transdone-int` and
`samsung,i2c-sda-delay = <0x64>` (`live_fdt.dts:1628/1654`) —
downstream-only properties, not read by the mainline i2c-exynos5
driver.

### 1.2 Touchscreen node `touchscreen@20`

| m4 value | Stock source | Mainline mapping |
|---|---|---|
| `compatible = "syna,rmi4-i2c"` | `live_fdt.dts:1663` — `"synaptics,rmi4"` | Only compatible accepted by `drivers/input/rmi4/rmi_i2c.c`; binding `Documentation/devicetree/bindings/input/syna,rmi4.yaml` |
| `reg = <0x20>` | `live_fdt.dts:1662` — `reg = <0x20>` | same |
| `interrupt-parent = <&gpa1>`; `interrupts = <1 IRQ_TYPE_LEVEL_LOW>` | `live_fdt.dts:1674` — `synaptics,irq_gpio = <0x42 0x01 0x00>`; bank phandle `0x42` = `gpa1` (`live_fdt.dts:143-152`), so gpa1-1. Trigger: `live_fdt.dts:1669` — `synaptics,irq_type = <0x2008>` = `IRQF_TRIGGER_LOW (0x8) \| IRQF_ONESHOT (0x2000)`; the stock driver passes it straight to `request_threaded_irq()` (`synaptics_i2c_rmi.c:1526`). Mainline takes the trigger type from DT and adds `IRQF_ONESHOT` itself (`drivers/input/rmi4/rmi_driver.c:221-228`), so the DT carries only `IRQ_TYPE_LEVEL_LOW` | binding: `interrupts` maxItems 1 |
| `vdd-supply = <&ldo30_reg>` | `live_fdt.dts:1661` — `synaptics,regulator_avdd = "tsp_avdd"` → S2MPS13 LDO30 `tsp_avdd` 3.3 V (m2 `ldo30_reg`) | binding `vdd-supply` |
| `vio-supply = <&ldo31_reg>` | `live_fdt.dts:1665` — `synaptics,regulator_dvdd = "tsp_io"` → S2MPS13 LDO31 `tsp_io` 1.85 V (m2 `ldo31_reg`) | binding `vio-supply`; driver requests "vdd"/"vio" and enables them in bulk (`rmi_i2c.c:230-238`), matching the downstream avdd-then-dvdd order (`synaptics_i2c_rmi.c:3704-3712`) |
| `syna,startup-delay-ms = <150>` | `SYNAPTICS_POWER_MARGIN_TIME = 150` (`synaptics_i2c_rmi.h:127`), applied after power-on before the first I2C access (`synaptics_i2c_rmi.c:3969`) | binding `syna,startup-delay-ms`; consumed by `rmi_i2c.c:249-252` |
| no `reset-gpios` | Stock node has none (only `synaptics,irq_gpio`, `live_fdt.dts:1660-1675`) | The mainline rmi_i2c transport does not parse `reset-gpios` anyway; `syna,reset-delay-ms` left out for the same reason |
| `rmi4-f01@1 { reg = <0x1>; }` | RMI4 function 01 (device control) is always present; stock tree declares no doze/nosleep tuning | binding `rmi4-f01@1` |
| `rmi4-f11@11 { reg = <0x11>; touchscreen-size-x/y = <1536/2048>; }` | `live_fdt.dts:1671` — `synaptics,max_coords = <0x600 0x800>` = 1536 × 2048 | binding `^rmi4-f1[12]@1[12]$` (ref `touchscreen.yaml`) |
| `rmi4-f12@12 { reg = <0x12>; touchscreen-size-x/y = <1536/2048>; }` | same coordinates | The stock driver implements **both** F11 and F12 (`synaptics_i2c_rmi.c:1345/2886` and `:1353/2908`); which function the panel firmware exposes cannot be read without the device, so both sub-nodes exist and the RMI4 core binds whichever the PDT lists |
| no `touchscreen-inverted-*`, no `touchscreen-swapped-x-y` | Stock tree has no flip/swap property (node `live_fdt.dts:1660-1675`); the stock driver applies none | Mainline parses them in `rmi_2d_sensor.c:231-239` — absent means identity |

Left out of the touch node, with reasons:

- `synaptics,firmware_name` / `firmware_name2` / `project_name`
  (`live_fdt.dts:1670-1673`) — firmware reflashing is RMI4_F34 scope,
  not an input milestone; the mainline driver would try to load
  `synaptics_5807_gts28.fw` only if `RMI4_F34` is enabled (it is not in
  this fragment).
- `synaptics,num_lines = <0x29 0x1f>` (`live_fdt.dts:1664`) —
  downstream-only sensor tuning; mainline reads the real geometry from
  the F11/F12 control registers (`rmi_f11.c:1178-1193`,
  `rmi_f12.c:103-104`), so `touchscreen-size-*` is only a hint/fallback
  there.
- Touch keys (back/recent) behind `coreriver,tc300-keypad`
  (`live_fdt.dts:1885-1905`) — no mainline driver exists for this
  controller; see §3.

### 1.3 Power-up sequence provided by the DT + mainline driver

Downstream: enable `tsp_avdd`, enable `tsp_io`
(`synaptics_i2c_rmi.c:3704-3712`), wait 150 ms
(`SYNAPTICS_POWER_MARGIN_TIME`, used at `:3969`), then I2C
initialisation; the hw-reset path also waits 100 ms
(`SYNAPTICS_HW_RESET_TIME`, `synaptics_i2c_rmi.h:125`) but there is no
reset line wired in the stock tree. Mainline: `regulator_bulk_enable`
of vdd+vio then `msleep(startup-delay)`
(`rmi_i2c.c:238-252`) — same shape, delay transcribed as
`syna,startup-delay-ms = <150>`.

## 2. GPIO keys

All four keys live in the stock `gpio_keys` node
(`live_fdt.dts:7021-7060`, `compatible = "gpio-keys"`). The stock
GPIO specifiers are 3-cell (`<bank pin flags>`); the flag cell is
`0x0f` for every key. Downstream gpiolib's simple xlate copies the raw
cell into `of_gpio_flags` (`drivers/gpio/gpiolib-of.c:127`,
`*flags = gpiospec->args[1]`) and gpio_keys tests only bit 0,
`button->active_low = flags & OF_GPIO_ACTIVE_LOW`
(`drivers/input/keyboard/gpio_keys.c:836`) — so the effective wiring is
**active low**, the same as the TM2 board
(`exynos5433-tm2-common.dtsi:56-85`). Bits 1-3 of the stock flag cell
(0x0e) encode open-drain/single-ended variants that the downstream
input path ignores; they are not transcribed.

No `debounce-interval` appears in the stock tree; the downstream
driver defaults to 10 ms
(`drivers/input/keyboard/gpio_keys.c:859`). The stock `interrupts`
cells duplicate the GPIO as wake path — gpio-keys mainline binds the
GPIO as interrupt itself, so only `gpios` is needed. The stock tree
sets no pinctrl for the keys beyond the banks' defaults, and no
`linux,input-type` (defaults to `EV_KEY`).

| Key | m4 label | Stock node | GPIO (stock) | GPIO (m4) | Code (stock) | Code (m4) | Wakeup |
|---|---|---|---|---|---|---|---|
| Volume up | `button-volume-up` | `live_fdt.dts:7027-7033` | `<0x26 0x00 0x0f>` = gpa2-0 | `<&gpa2 0 GPIO_ACTIVE_LOW>` | `0x73` = 115 | `KEY_VOLUMEUP` (`linux-event-codes.h:189`) | no |
| Volume down | `button-volume-down` | `live_fdt.dts:7044-7050` | `<0x26 0x01 0x0f>` = gpa2-1 | `<&gpa2 1 GPIO_ACTIVE_LOW>` | `0x72` = 114 | `KEY_VOLUMEDOWN` (`linux-event-codes.h:188`) | no |
| Home | `button-home` | `live_fdt.dts:7035-7042` | `<0x4b 0x03 0x0f>` = gpa0-3 | `<&gpa0 3 GPIO_ACTIVE_LOW>` | `0xac` = 172 | `KEY_HOMEPAGE` (`linux-event-codes.h:252`) | yes (`gpio-key,wakeup = <1>`) |
| Power | `button-power` | `live_fdt.dts:7052-7058` | `<0x26 0x07 0x0f>` = gpa2-7 | `<&gpa2 7 GPIO_ACTIVE_LOW>` | `0x74` = 116 | `KEY_POWER` (`linux-event-codes.h:191`) | yes (`gpio-key,wakeup = <1>`) |

Bank phandle resolution: `0x26` = `gpa2` (`live_fdt.dts:334-341`),
`0x4b` = `gpa0` (`live_fdt.dts:181-189`), `0x42` = `gpa1`
(`live_fdt.dts:143-152`). `debounce-interval = <10>` on every button =
downstream default (`gpio_keys.c:859`), restated for explicitness.
`gpio-key,wakeup` (downstream spelling) → `wakeup-source`
(gpio-keys.yaml), recognised by the mainline driver
(`gpio_keys.c:815-817`). The stock tree sets no pull-up/down pinctrl
for these keys (they are alive-bank pins with SoC defaults; TM2 also
runs them unpulled) — so no pinctrl is added.

## 3. What was left out, and why

| Left out | Stock source | Reason |
|---|---|---|
| Coreriver `tc300-keypad` touch keys (back/recent) | `live_fdt.dts:1885-1905` | No mainline driver for `coreriver,tc300-*`; task places it out of scope |
| S-Pen / digitizer | — | No such node in the live tree for this device |
| `synaptics,firmware_name*`, `project_name` | `live_fdt.dts:1670-1673` | RMI4_F34 firmware reflashing not enabled; input milestone scope |
| `synaptics,num_lines` | `live_fdt.dts:1664` | Downstream tuning; mainline reads geometry from sensor registers |
| `samsung,check-transdone-int`, `samsung,i2c-sda-delay` | `live_fdt.dts:1628/1654` | Downstream-only hsi2c quirks, unread by mainline i2c-exynos5 |
| Key flag bits 1-3 (`0x0e`) of stock GPIO specifiers | `live_fdt.dts:7028` et al. | Open-drain/single-ended flags ignored by the downstream input path (`gpio_keys.c:836` reads only bit 0) |
| `gpio-key,wakeup` on home/power as raw property | `live_fdt.dts:7039/7056` | Replaced by `wakeup-source`, the mainline spelling of the same thing |

## 4. Config fragment

`gts28ltexx_m4.config` = full copy of `gts28ltexx_m2.config` plus:

| Symbol | Why | Report |
|---|---|---|
| `CONFIG_INPUT=y` | input core | default `y`, restated |
| `CONFIG_INPUT_EVDEV=y` | event device node for userspace | `=y` OK |
| `CONFIG_INPUT_KEYBOARD=y` | keyboard class | `=y` OK |
| `CONFIG_KEYBOARD_GPIO=y` | gpio-keys driver (depends `GPIOLIB`, `=y` in m2) | `=y` OK |
| `CONFIG_RMI4_CORE=y` | RMI4 bus | `=y` OK |
| `CONFIG_RMI4_I2C=y` | I2C transport (depends `I2C`, `=y` since m2) | `=y` OK |
| `CONFIG_RMI4_F11=y`, `CONFIG_RMI4_F12=y` | the stock driver handles both 2D functions (`synaptics_i2c_rmi.c:1345/1353`); the core binds whichever the panel's PDT lists | `=y` OK, both |

No symbol in this fragment is forced to `=m` by its dependencies; the
I2C controller driver (`CONFIG_I2C_EXYNOS5=y`) is inherited from the
m2 half, where it was already required by the PMIC bus.

## 5. Validation level

Build-tested only (no device interaction, per task constraints):

- `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_m4.config`
  → `out/mainline-m4/` (zImage + DTBs + `.config` +
  `modules.tar.xz`), DTB
  `out/mainline-m4/exynos5433-gts28ltexx-m4.dtb`. Required
  symbols verified `=y` in `out/mainline-m4/.config`.
- **dtschema dtbs_check ran** (dtschema 2026.9, installed in the build
  container via `apt-get install python3-pip` +
  `pip3 install --break-system-packages dtschema`; same method as
  DT_M2.md — `python3 -m venv` fails in the image):
  `make ARCH=arm CHECK_DTBS=y samsung/exynos5433-gts28ltexx-m4.dtb`
  → exit 0. **The m4 nodes produced zero findings** (`gpio-keys`
  buttons, `syna,rmi4-i2c` node incl. `rmi4-f01/f11/f12` sub-nodes,
  `hsi2c_5`). Remaining findings all pre-exist milestone 4:
  - root `compatible = ["samsung,gts28ltexx", "samsung,exynos5433"]`
    not in `arm/samsung/samsung-boards.yaml` — needs its own binding
    entry (milestone-1 scope);
  - `oscclk` fixed-clock missing `clock-frequency` — inherited from
    `exynos5433.dtsi:46`;
  - `usb@15400000` missing `vdd33/vdd10-supply` — deliberate m2
    decision (live tree does not say which rails feed USB; documented
    in DT_M2.md), re-surfaced here because the m4 board file includes
    the m2 one.
  - plus the `interrupt_provider` dtc warning on `pcie@15700000`,
    inherited from `exynos5433.dtsi:1965` (present on TM2 too).

## 6. Open points (device-untestable from here)

- **F11 vs F12:** the panel's PDT decides; both sub-nodes are present
  and both drivers built in, so either firmware variant is covered.
  The duplicate `touchscreen-size-*` values are the stock
  `synaptics,max_coords`; the drivers override them from the sensor's
  control registers anyway.
- **Axis orientation** cannot be confirmed without touching the device;
  the stock tree declares no inversion/swap, so none is set. If the
  panel turns out flipped (it is mounted portrait in a landscape
  panel, like the TM2), fix-up is one boolean in the f11/f12 sub-nodes.
- **150 ms startup delay** is the downstream *power-margin*; if the
  panel needs the longer hw-reset-style settle, the value is one line
  to revisit.
