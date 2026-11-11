# Battery — SM5703 fuel gauge (read-only) and charger

The charger, the battery thermistor and what they changed for USB are in §8.

SM-T715 (gts28ltexx), mainline 6.12 arm32. Goal: show the battery level
in userspace (UPower, Phosh, Hyprland bars read
`/sys/class/power_supply`). **Build-tested only; not yet run on the
device.**

Deliverables (kernel tree `src/linux-6.12`):

| File | What |
|---|---|
| `drivers/power/supply/sm5703_fuel_gauge.c` | i2c driver, regmap, polling, power_supply `sm5703-fuelgauge` |
| `drivers/power/supply/Kconfig`, `Makefile` | `CONFIG_BATTERY_SM5703` (tristate, `depends on I2C`, `select REGMAP_I2C`) |
| `Documentation/devicetree/bindings/power/supply/siliconmitus,sm5703-fuel-gauge.yaml` | binding, compatible `siliconmitus,sm5703-fuel-gauge` only |
| `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-battery.dtsi` | `&hsi2c_7 { fuel-gauge@71 }` — **not yet included** from the board file |
| `arch/arm/configs/gts28ltexx_battery.config` | `CONFIG_POWER_SUPPLY=y` (unset in the defconfig) + `CONFIG_BATTERY_SM5703=m` |

Sources: `src/kernel_universal5433/drivers/battery/sm5703_fuelgauge.c`
(cited below as `fg.c:N`), `include/linux/battery/fuelgauge/sm5703_fuelgauge_impl.h`
(`impl.h:N`), `drivers/battery/sec_battery.c`, `include/linux/battery/sec_charging_common.h`,
and the device's stock tree `dumps/live_fdt.dts`.

---

## 1. Hardware and device tree

- `live_fdt.dts:1617-1643`: `hsi2c@14EF0000` (mainline `hsi2c_7`,
  `i2c@14ef0000` in `arm64/exynos/exynos5433.dtsi`), pins `gpd2-7`/`gpd2-6`
  function 4 (`live_fdt.dts:6084-6091`, identical to mainline
  `hs_i2c7_bus`), no `clock-frequency` (100 kHz). Child
  `sm5703-fuelgauge@71`, compatible `samsung,sm5703-fuelgauge`.
- `live_fdt.dts:1638`: `fuelgauge,fuel_int = <&gpa1 4 0>` (pin config
  `fuel-irq`, `live_fdt.dts:350-357`). Described as optional
  `interrupts` in the binding, not wired in the dtsi: the driver polls.
- `live_fdt.dts:1636-1641`: `capacity_calculation_type = 0x0c`,
  `capacity_max = 990`, `capacity_max_margin = 60`, `capacity_min = 0`.
  `0x0c` = `DYNAMIC_SCALE (4) | ATOMIC (8)` (`sec_charging_common.h:326-341`).
- The gauge is a separate I2C device; the SM5703 charger at 0x49 has its
  own driver (§8).

## 2. Read-only policy

The gauge runs from the battery across reboots. The stock driver loads
the battery model and calibration at its own boot (`fg.c:758-950`,
`sm5703_fg_reg_init`) and keeps tuning it at runtime. The mainline driver
writes **nothing**:

- the regmap's `writeable_reg` returns false for every register;
- `readable_reg` lists only the 8 registers used (0x00, 0x01, 0x05-0x09,
  0x10), so a regmap debugfs dump cannot read `INTFG` (0x02), which the
  stock IRQ handler reads to clear the interrupt (`fg.c:1311-1312`);
- no IRQ, no alarms, no calibration, no model load, no reset.

Probe reads `FG_OP_STATUS` (0x10): the stock driver treats
`(val & 0xff) == 0x07` (`DISABLE_RE_INIT`, `impl.h:110`) as "model loaded"
(`fg.c:410-423`). Otherwise the driver warns that readings are unreliable
(the gauge lost its model, e.g. after a full drain or battery disconnect),
but still registers.

## 3. Register decoding

All registers are 16-bit words read LSB first: the stock driver does a
2-byte `i2c_smbus_read_i2c_block_data()` into a `u16` on little-endian
ARM (`fg.c:57-89`, "not use big endian" at `fg.c:87-88`). Mainline uses
`regmap` with `val_bits = 16`, `REGMAP_ENDIAN_LITTLE`; on the Exynos
HSI2C (`I2C_FUNC_I2C`) it is the same write-reg / repeated-start / read-2
transfer.

| Reg | Name (`impl.h`) | Stock decode | Mainline property |
|---|---|---|---|
| 0x00 | DEVICE_ID (`:20`) | logged only, no value checked (`fg.c:399-408`); `< 3` selects an older top-off mapping (`fg.c:891`) | printed at probe, not checked |
| 0x01 | CNTL (`:21`) | bit 14 `ENABLE_TEMP_MEASURE` (`impl.h:98`) set at init (`fg.c:903-905`) | gates `TEMP` |
| 0x05 | SOC (`:25`) | `[15:8]` integer %, `[7:0]` /256 %, result in 0.1 % with truncation (`fg.c:257-266`) | `CAPACITY` (scaled, §4) |
| 0x06 | OCV (`:26`) | `[10:8]` integer V, `[7:0]` /256 V, unsigned, mV (`fg.c:174-183`) | `VOLTAGE_OCV` = `(raw & 0x7ff) * 15625 / 4` µV |
| 0x07 | VOLTAGE (`:27`) | same format as OCV (`fg.c:281-290`) | `VOLTAGE_NOW`, same formula |
| 0x08 | CURRENT (`:28`) | `[10:8]` integer A, `[7:0]` /256 A, **bit 15 = sign** (sign-magnitude, bits 14:11 ignored), mA (`fg.c:343-355`) | `CURRENT_NOW` µA, same sign |
| 0x09 | TEMPERATURE (`:29`) | `[14:8]` integer °C, `[7:0]` /256 °C, bit 15 = sign, 0.1 °C (`fg.c:149-161`) | `TEMP` (0.1 °C) |
| 0x10 | FG_OP_STATUS (`:30`) | `[7:0] == 7` = initialised (`fg.c:216-217`, `:414-416`) | probe warning only |

Voltage/current LSB is 1/256 V (A) = 3.90625 mV (mA). Mainline keeps
µV/µA resolution; the stock mV value is exactly `floor(µV / 1000)`.

Cross-check against the stock kernel log (`dumps/dmesg.txt`):

| Line | Stock print | Mainline decoding of the same raw word |
|---|---|---|
| 6 | `temperature: read = 0x20a0, temperature = 326` | 32×10 + 160×10/256 = 326 (32.6 °C) |
| 7 | `ocv: read = 0x444, ocv = 4265` | 0x444 × 15625 / 4 = 4 265 625 µV |
| 9 | `soc: read = 0x5a60, soc = 903` | 903 ‰ → 903×1000/990 = 912 → **91 %** |

**Current sign.** Stock: magnitude negated when bit 15 is set, and a
positive value means charging (`ta_exist = is_charging && batt_current >= 0`,
`fg.c:205`; also `fg.c:1113-1114`). The stock log agrees:
`Inow(207mA)` on the charger at `dmesg.txt:53`, `Inow(-246mA)` after
unplugging at `dmesg.txt:1669`. The power_supply ABI also uses
positive = charging, so the sign is passed through unchanged.

**Temperature.** `TEMP` is the battery thermistor since `t715-charger`
(§8), Android's `Tbat`. The gauge's own sensor, decoded from its register
with no thermistor table, is `TEMP_AMBIENT` and the fallback when the ADC
fails (the stock driver reports it for both, `fg.c:1153-1157`): it reads
48-66 °C on a charger with the battery at 40-45 °C. If `CNTL` bit 14 is
clear the gauge does not measure temperature and `TEMP_AMBIENT` returns
`-ENODATA`.

## 4. CAPACITY and capacity_max

Stock pipeline for the value Android shows (`fg.c:1091-1151`):

1. raw SOC in 0.1 % (`fg.c:257-266`);
2. `scaled = (soc - capacity_min) * 1000 / (capacity_max - capacity_min)`
   (`fg.c:588-599`, applied because type 0x0c has `DYNAMIC_SCALE`);
3. clamp to 0..1000, keep integer % (`fg.c:1105-1111`);
4. `ATOMIC` smoothing: at most ±1 % per read from the previous value
   (`fg.c:602-628`), plus a low-voltage "cold mode" forcing 0 %.

`capacity_max` starts at the DT value 990 at every boot (`fg.c:1698`),
is recomputed at probe if raw SOC > 990 (`fg.c:1700-1702`), at every full
charge (`CHARGE_FULL`, `fg.c:1188-1205` -> `fg.c:656-698`, kept within
990 ± 60), and can be restored by Android userspace through
`batt_capacity_max` (`sec_battery.c:3606-3620`,
`CONFIG_DISABLE_SAVE_CAPACITY_MAX` unset).

Mainline does steps 1-3 with constants `capacity_max = 990` and
`capacity_min = 0`: pure arithmetic on the SOC register, the stock
boot-time value. Steps 4 and the dynamic `capacity_max` are left out:
they depend on state the stock driver holds in RAM or on events from the
charger. Consequence: mainline can differ from Android by a few percent
when Android has learnt a `capacity_max` other than 990 (at most
1000/930 ≈ +7.5 % or 1000/1050 ≈ −5 % relative), and it can step by more
than 1 % between reads.

## 5. STATUS, PRESENT, TECHNOLOGY

The stock gauge returns `-ENODATA` for `STATUS` (`fg.c:1064-1067`): the
charger driver owned it. Without a charger driver, mainline derives it
from `CURRENT_NOW` and `CAPACITY`:

| Condition | STATUS |
|---|---|
| current > +50 mA | Charging |
| current < −50 mA | Discharging |
| \|current\| ≤ 50 mA and capacity ≥ 100 | Full |
| \|current\| ≤ 50 mA and capacity < 100 | Not charging |

50 mA ≈ 13 LSB; the stock OCV tracking uses 60 mA as its own "low
current" threshold (`fg.c:502`). With the charger in its constant-voltage
phase at a displayed 100 % (`Inow` ≈ +200 mA at `dmesg.txt:53`) the
status is Charging until the current tapers below 50 mA.

`PRESENT` = 1 (built-in battery, no detection on the gauge),
`TECHNOLOGY` = Li-ion.

Polling: a freezable delayed work re-reads SOC and current every 30 s
and calls `power_supply_changed()` when the capacity or the status
changes, so UPower gets uevents without an IRQ.

Debounce (2026-10-29): on the Mac's USB port at 99 %, the current read
every 2 s swung between −109 and +113 mA (mean +72 mA). The status taken
from a single reading flipped between Charging, Not charging and
Discharging. The board has no line-power supply, so UPower derives
`OnBattery` from the battery state: it went yes/no twice in 3 minutes,
and gsd-power played its plug/unplug sound each time (heard under
Phosh as sounds with no action, in step with the charging icon). The
`STATUS` property now returns a debounced value: a reading that differs
from it is re-checked every 10 s, and only three readings in a row that
agree replace it. A real plug or unplug therefore shows after 20 to
50 s.

The line-power supply this needed exists since `t715-charger`:
`sm5703-charger`, type Mains, which UPower reads for `OnBattery` (§8).

## 6. Left out, and why

| Item | Reason |
|---|---|
| Battery model / calibration load (`fg.c:758-950`) | writes; relies on Android having loaded it |
| `CURR_CAL` temperature compensation written before every SOC read (`fg.c:205-255`) | writes; `CURR_CAL` keeps the value Android last wrote (the log shows `0x8100`, `dmesg.txt:8`) |
| OCV tracking / RS manual mode switching (`fg.c:425-585`, `CONFIG_SM5703_OCV_TRACKING=y` in `lineage_gts28ltexx_defconfig:4096`) | writes `RS_MAN`, `CNTL`; the gauge stays in the mode Android left |
| SW reset + re-init when `FG_OP_STATUS` is wrong (`fg.c:216-229`) | writes; mainline only warns |
| Alarms and fuel-alert IRQ (`fg.c:700-738`, `:1285-1322`) | writes; polling instead |
| `VOLTAGE_AVG`, `CURRENT_AVG` (`fg.c:307-396`) | software averages of 5 reads, not chip values |
| `CHARGE_FULL`, `ENERGY_NOW`, `CAPACITY_LEVEL` | stock returns `-ENODATA` or has no decoding |
| Dynamic `capacity_max`, atomic smoothing (§4) | state held by the stock driver / Android |
| STATUS register 0x04 | the stock driver only masks alarm bits from it |

## 7. First test on the device

Prerequisites: include `exynos5433-gts28ltexx-battery.dtsi` from the board
file, build with `--fragment gts28ltexx_battery.config`, and boot Android
first so the gauge is initialised. Note Android's battery % and whether
the charger is plugged just before rebooting.

```sh
modprobe sm5703_fuel_gauge          # if not auto-loaded
dmesg | grep -i sm5703              # "device ID 0x...., CNTL 0x...., FG_OP_STATUS 0x...."
                                    # no "battery model not loaded" warning
                                    #   (FG_OP_STATUS low byte must be 0x07)
cat /sys/class/power_supply/sm5703-fuelgauge/uevent
cat /sys/kernel/debug/regmap/*-0071/registers   # raw words, if debugfs is mounted
upower -d                           # or the Phosh/Hyprland battery indicator
```

Expected:

| Property | Expected range |
|---|---|
| `POWER_SUPPLY_TYPE` | `Battery` |
| `POWER_SUPPLY_CAPACITY` | 0-100, within a few % of Android's last value |
| `POWER_SUPPLY_VOLTAGE_NOW` | 3 400 000-4 400 000 (µV); ~4.39 V when charging at full |
| `POWER_SUPPLY_VOLTAGE_OCV` | 3 400 000-4 350 000, close to `VOLTAGE_NOW` at low current |
| `POWER_SUPPLY_CURRENT_NOW` | negative on battery (−100 000 to −2 000 000 µA), positive on the charger (up to ~2 100 000) |
| `POWER_SUPPLY_TEMP` | ~150-450 (0.1 °C), the battery thermistor (§8) |
| `POWER_SUPPLY_STATUS` | `Discharging` unplugged, `Charging` plugged |
| `POWER_SUPPLY_PRESENT` / `TECHNOLOGY` | `1` / `Li-ion` |

Checks:

1. Capacity vs Android: compare with the % shown before the reboot. A
   constant offset of a few % points to Android's learnt `capacity_max`
   (§4); a value stuck at 0 or garbage points to an uninitialised gauge.
2. Plug/unplug the charger: `CURRENT_NOW` and `STATUS` are read from the
   chip on every sysfs read, so `cat` shows the new sign at once; the
   change uevent (what UPower reacts to) follows within 30 s (poll
   interval).
3. Leave it discharging for 10 min: `CAPACITY` should drop slowly and
   monotonically; `udevadm monitor -s power_supply` should show a change
   event when it does.
4. Raw sanity: in the regmap dump, SOC/256 (in %), VOLTAGE & 0x7ff / 256
   (in V) must match the decoded sysfs values.

## 8. Charger, thermistor and USB detection (`t715-charger`)

`drivers/power/supply/sm5703_charger.c` for the chip,
`sm5703_charger_policy.h` for the decisions, pure C tested on the host by
`sm5703_charger_policy_test.c`. Hardware: `hsi2c_8` (`i2c-27` here), address
0x49, device ID 0x01. Measurements of 2026-11-01 and 02.

**Why a driver.** `VBUSCNTL` reads 1800 mA after sboot, but the real input
limit stays near 500 mA until a host *writes* that register. On a Mac port,
screen off: +39 mA as booted, +699 mA after writing 0x21, -20 mA at 0x07. So
the tablet charged at +270-380 mA on a fast charger and could not hold up
with the screen on. What stock writes against what sboot leaves:

| Register | After sboot | Stock |
|---|---|---|
| `VBUSCNTL` 0x0D | 0x22, reads 1800 mA, acts as about 500 | 0x21, 1750 mA |
| `CHGCNTL2` 0x0F | 0x22, 1800 mA | 0x28, 2100 mA |
| `CHGCNTL3` 0x10 | 0x08, float 4200 mV | 0x1b, float 4390 mV |
| `CHGCNTL4` 0x11 | 0x80 | 0xa0 |
| `CHGCNTL5` 0x12 | 0xfa, AICL 4.5 V | 0xd8, AICL 4.3 V |
| `CHGCNTL6` 0x13 | 0x00, 3 MHz | 0x08, 1.5 MHz |

**What it does.** No IRQ: a 10 s poll and extcon notifiers. It never touches
INT1-4 (read-clear), INTMSK or `CHGCNTL1`. The mode bits of `CNTL` move only
between 4 (off) and 5 (on). A TA gets 1750/2100 mA, a USB port or an unknown
cable 450/450 mA. On VBUS arrival or a cable change the input limit is written
twice, 450 then the target, because equal writes would be skipped and the
write is what releases the limit. With no valid temperature, charging stops.
`.shutdown` leaves 4200 mV and 450 mA, verified at the next boot. Types as
Mains, so UPower reports `on-battery: no`.

**Thermal rules.** Stock, on the thermistor (ADC channel 2, 12 bits, stock's
66-point table): 55.0 °C stops, until 50.0; 45.0 °C lowers the float to 4200 mV
and the charge to 2000 mA; 10.0 °C does the same until 15.0; -5.0 °C stops,
until 0.0. One difference: **WARM ends at 43.0 °C, not 40.0.** With no cpuidle
or cpufreq the battery idles at 41-42 °C, so at 40.0 the first warm spell caps
the tablet at the WARM float for good: kernel 3 sat 2 h 30 at 83 %, +25 mA.

**Rate.** Fast charger, screen off: 57 to 71 % in 36 min, about +1 A. Input
sweep at float 4390: 900 mA +437, 1100 +613, 1300 +795, 1500 +972, 1750 +980.
`VBUSLIMIT` is set at 1500, not at 1750, so the real input stops near 1.5 A:
the supply or the cable, not proven which.

**Boot on a charger.** On one boot the charge started only 85 s in: `Not
charging`, -500 to -1100 mA, `VSYSOK` low at 25 s, then +675 mA by itself. Cause
unknown; a charger plugged after boot starts at once (+656 mA). On 11-02 a boot
on the fast charger charged from 10 s in.

**USB and cable detection.** Five faults of ours, one of the Mac's:

1. *Frozen at boot.* The pad gpa3-6 resets with a pull-down, stock sets none.
   INTB stayed low, no falling edge came, and the cable type and the D+/D-
   switch stayed as boot left them. Fixed in the board's pinctrl.
2. *An event lost for good.* INTB stays low until the INT registers are read.
   After a plug on the Mac, `muic-attach` had not fired, INTB was low, and INT1
   still held 0x01, so the route was open and no later event could arrive.
   Fixed by a level trigger in the DT and in `extcon-sm5502.c`.
3. *No cable at boot, no USB until the next boot.* The initramfs stops its
   gadget at about 5 s. With no cable the stop takes 5.5 s against 1.5 s: three
   of the nine boots measured, one of them the day the Mac lost the tablet.
   dwc3 times out on the halt, silently, and the UDC core kept
   `gadget->connected` on that error, so the next bind did nothing: `DCTL` 0,
   pull-up off. `usb_gadget_disconnect_locked()` now clears it either way.
   Timeout injected on the device: with the fix `DCTL` 0x8c000a00, link On;
   without it `RUN/STOP` stays clear, link Disconnected. A real boot with no
   cable on 11-02 stopped in 1.47 s, so it did not hit the fault: only the
   injection proves the fix. What makes the stop slow is not known.
4. *Charging late after a plug.* The MUIC reports the cable 30-50 ms before
   VBUS reaches the charger (`STATUS5` UVLO, then VBUSOK), so the work the
   notifier pulled forward saw no VBUS and charging waited for the 10 s poll.
   While a cable is reported without VBUS, the work now looks every 200 ms,
   ten times: a TA plug charged 210 ms after its attach.
5. *A cable type missing.* Once, after a real replug, extcon reported no cable
   for more than 10 s while the Mac had enumerated, until the next plug. The
   driver drops an attach whose type it cannot read, silently: `DEV_TYPE1`
   still 0, or `ADC` at ground. Not seen again in two plugs traced every
   20 ms, where `DEV_TYPE1` was set at the attach. Such an attach is now read
   again every 200 ms for 2 s, and logged: `cable identified N ms after its
   attach` or `still unidentified`. Unproven cause, defensive fix: on a TA, a
   missing type would charge at the USB 450 mA.
6. *macOS.* Twice, after an unplug of more than a minute, the Mac kept the
   session, device in ioreg, `en14` active, and ignored the tablet plugged
   back into that port: 6 min on 11-01, and on 11-02 after the boot with no
   cable, while the tablet had `RUN/STOP` set and was ready. Short unplugs of
   a few seconds, three of them, went through. The tablet is on a root port
   of the Mac, with no hub. `device/mac-usb-reenum.c` clears it: enumerated
   at once. Not reproduced by the soft unplug below.

**Soft unplug.** `CONTROL` 0x1a (manual) and `MANSW1` 0x00 at 20-0025 cut VBUS
(`STATUS5` UVLO) and D+/D- with the cable in place; 0x1e and 0x27 put them
back. The Mac drops the session and enumerates again in seconds, the charger
goes to no cable and back. It raises no MUIC detach and did not reproduce the
stop timeout of point 3 (0.0 s).

**Real tests with the installed kernel, 11-02.** Replugs on the Mac: three,
the Mac back each time in about 3 s with no help. Boot with no cable, then the
Mac: the tablet ready, the Mac stale (point 6). Fast charger plugged after
boot: `DCP`, 1750/2100 mA, charging 210 ms after the attach, then 70 to 85 %
in 49 min with the screen on: WARM at 45.0 °C, NORMAL again 9 min later at
43.0 °C, and on past the 83 % where kernel 3 stayed. Not verified: a charge to
100 %.

## 9. Idle power with the screen off (2026-11-02)

Measured on battery, screen off, 5 min a window. Every window had the CPU
99.4 % idle and the display power domain off, so none of this is the panel or
a busy task:

| Window | Power |
|---|---|
| As shipped | 2.26 W |
| Accelerometer released | 2.19 W (−67 mW) |
| Wi-Fi power save on, accelerometer streaming again | 1.67 W (about −0.5 W, −0.4 to −0.6 W depending on the reference window) |
| Both fixes installed, 15 min | 1.48 W (378 mA, 346 interrupts a second) |

The last window is not a clean sum of the two before it: the chip cooled from
44 to 38 °C during it, which accounts for part of the gap with 1.67 W.

**The accelerometer.** On the lock screen the panel blanks 5 s after a wake,
and the lock did it itself, with `omarchy-brightness-display off`: `t715-keys`
never heard of it, never wrote its `touch-off` flag, so `t715-rotate` kept the
accelerometer streaming — the sensors' I2C bus at about 510 interrupts a
second, 0 once released — and the touchscreen stayed enabled under the dark
panel. `t715-lock-blank-through-keys.patch` (omamobile-omarchy 0.1.27-1.2,
`image/pkg/omamobile-omarchy/`) gives the lock's blank the path of every other
screen-off: the same SIGUSR1 as hypridle's idle timeout, touch off, the flag,
then DPMS, with Omarchy's own blank as the fallback.

**Wi-Fi power save.** `22-t715-wifi-powersave.conf`
(`image/rootfs/overlay/etc/NetworkManager/conf.d/`) sets `wifi.powersave = 3`
on the brcmfmac interface, overriding Omarchy's off (`docs/image/ROOTFS.md`,
"Firewall"): the largest single idle saving measured so far, at the price of
some latency on incoming traffic while the radio dozes.

**What remains**, about 1.5 W, is the CPU rails at their 1.2 GHz voltages with
no cpuidle, the memory at its top level and the modem link; CPU frequency
scaling (`docs/hardware/CPUFREQ.md`, stage 1) is the next lever.

## 10. Screen-off drain and its causes (2026-11-04)

**What the owner saw.** Left with the screen off, the tablet lost about
25 % in 5 h, against far less under Android. UPower's history for that day:
from 95 % to 55 % in 4 h 41 min, one point every 7 minutes, about 1.3 W all
along.
Nothing sleeps: `/sys/power/mem_sleep` offers `[s2idle]` only, every sleep
target is masked, there is no cpuidle driver, and every CPU cluster stays
powered.

**What stays on with the screen off**, read on the daily kernel
(`#1`, built 2026-11-03):

| What | State | Why |
|---|---|---|
| PCIe link to the BCM4358 | ASPM off on both ends (`LnkCtl: ASPM Disabled`), though both support L1, L1.1 and L1.2 | the kernel's default policy keeps the bootloader's setting |
| G3D power domain | on, `aclk_g3d` and the G3D PLL running at 266 MHz while the GPU is runtime suspended | panfrost keeps its clock prepared for its whole lifetime, which keeps `cmu_g3d` resumed (`GPU.md`, "When the domain actually switches") |
| A57 cores | four online at 1.2 GHz and 1 062 500 uV | no hot-unplug: `exynos_cpu_can_disable()` refuses every CPU |
| Modem | CP online, wakeup sources `lli_ap_wlock` and `ss333_cp_power` active since boot, a `CP2AP_WAKEUP` pulse every 15 to 60 s | the modem stack, frozen since 2026-11-02 |
| AUD power domain | on | the Bluetooth UART (`11460000.serial`) and `114b0000.pinctrl` have no runtime PM, which genpd counts as active |
| A53 frequency | 12 transitions a second at idle, each a voltage write to the PMIC: 210 interrupts a second on `14e40000.i2c` (S2MPS13), the largest interrupt source | schedutil |

**ASPM, measured.** Battery, screen off, USB cut by the MUIC (`MANSW1` 0x00,
`CONTROL` 0x1a), six alternating windows of 7 minutes after a 5-minute settle,
first 60 s of each dropped, means fitted with a linear drift:

| Wi-Fi link | Power | Against L1 + substates |
|---|---|---|
| ASPM off (the boot default until now) | 1 350 mW | +277 ± 19 mW |
| L1 only | 1 296 mW | +223 ± 21 mW |
| **L1 + L1.1 + L1.2, no L0s** | **1 073 mW** | — |

The battery was at 31 °C and the TMU at 36-37 °C, against 44 °C in section 9:
part of the gap with the 1.48 W of section 9 is temperature. Wi-Fi throughput
over SSH was 21-34 MB/s with and without ASPM (radio-limited); ping 2-4 ms.
`60-t715-wifi-aspm.rules` (`image/rootfs/overlay/etc/udev/rules.d/`, installed
on the tablet) sets it at every boot. A first version acted on the PCI device's
add event, before brcmfmac's probe: the chip, with no firmware yet, answered
`brcmf_chip_recognition` with 0xffffffff and the boot had no Wi-Fi. Acting on
the interface's add event, once the firmware runs, two boots and a live
re-probe were clean. Left: brcmfmac's own reset path (`brcmf_pcie_reset()`,
after a firmware crash) reloads the firmware with the substates still on;
none of the 7 boots in the journal had such a reset.

**The GPU domain, first try (failed).** A panfrost flag that unprepares the
clocks at runtime suspend, for `samsung,exynos5433-mali`, hung the test kernel
at panfrost's probe, then looped (watchdog reset, RECOVERY again: that test
image had `t715.wdtguard=0`; recovered through Download mode and heimdall). The
cause, from the clock tree: `aclk_g3d` comes from the G3D PLL through
`mout_aclk_g3d_400`, and so do CMU_G3D's own register clock and the G3D block's
APB. Gating `aclk_g3d` cascades to `fout_g3d_pll`, whose `pll_35xx` ops
disable it, and CMU_G3D's runtime suspend then reads its registers with no
clock (`clk-exynos-arm64.c` `exynos_arm64_cmu_suspend()`: `samsung_clk_save()`
first). Upstream never takes that path, since panfrost never releases the
clock. Second try, on branch `t715-power`: the block runs from CMU_TOP's
`aclk_g3d_400` at 800/3 MHz (`assigned-clocks` in the board's GPU file), which
CMU_G3D holds while resumed, and the flag (`panfrost.rt_clk_off`) is off until
set through sysfs (on by default in the daily candidate). Booted in RECOVERY,
image mode, CP off, watchdog guard on:
`aclk_g3d` at 266 666 667 Hz, the G3D PLL off; with the flag set, `pd_g3d`
reads `off-0` while the GPU idles, comes back for every frame, and a screenshot
taken after the cycles shows the home screen drawn right. 17 power-offs in the
hour, no kernel line. One register does not survive a power-off of the
domain: SYSREG_G3D + 0x700 (0x14a90700), the G3D block's NoC timeout, which
the bootloader sets and stock sets again after every power-on
(`pm_domains-exynos5433.c:101-102`, "set noc-bus timeout"). It read 0 after
the cycles; panfrost's power-on quirk for this SoC now writes 1 through the
`sysreg_g3d` syscon (board GPU file), and it read 1 after 35 power-offs.
Without it, a GPU transaction that stalls would hang the bus instead of
failing. Stock also turned BUCK6 off through a PMIC pin with the domain
(`s2m_set_g3d_pin()`), which the board keeps on, and switched the G3D TMU
core off and on around it, which mainline does not.

GPU job faults (`DATA_INVALID_FAULT`, a page fault at VA 0, `JOB_BUS_FAULT`)
showed once, at a session start of the first candidate; the daily kernel had
the same kind on 2026-11-03 (`Page fault in AS0 at VA 0x200`,
`JOB_BUS_FAULT`) with the domain never off, so they are older than this work.

**The A57 cores offline.** Stock's hot-unplug handshake, ported to
`exynos_cpu_die()` for the 5433 (`platsmp.c`, branch `t715-power`): the HOTPLUG
boot flag, the core's local power off in the PMU, `SMC_CMD_SHUTDOWN` with the
cluster when no other core of it is online (decided by MPIDR: by then
`__cpu_disable()` has reset the sibling masks), and a `cpu_kill` that waits
for the PMU status. `cpu_can_disable` allows cpu4-7 only.
`image/tests/ondevice/hotplug-a57.sh`: 30 cycles each of one core, two cores,
the whole cluster and the whole cluster with the A53s busy, then the cluster
off for 120 s. All passed, 234 power-ups (`STATUS 0x10380000 -> 0x2004000f`,
1 ms each), the sha256 of a 32 MiB buffer the same on every A57 after every
stage, no kernel line.

**Both, measured** in the same boot (Wi-Fi radio off, CP off, screen off, eight
alternating 6-minute windows, `image/tests/ondevice/power-windows.sh`, fitted
by `image/tests/power-stats.py`):

| Change | Saving |
|---|---|
| A57 cluster offline | 169 ± 4 mW |
| G3D domain off while the GPU idles | 30 ± 5 mW |

With ASPM, the three changes take about 475 mW off the screen-off draw of
section 9's figures: from about 1.35 W to about 0.87 W, roughly 11 h to
17 h of standby on the 15.2 Wh battery. `t715-keys` takes cpu4-7 offline
whenever it turns the touchscreen off, that is with the screen, and back with
it (`60-t715-big-cores.rules` lets wheel write their `online` files).

**The daily candidate's soak.** Kernel `#5` of branch `t715-power` (the GPU
flag on, the NoC timeout quirk), BOOT's knobs, booted from RECOVERY on the
persistent root with the CP online; `image/tests/ondevice/soak-sample.sh`
every 30 s for 2 h, `usage-sim.sh` alongside. The screen stayed off
throughout, so the simulator ran its headless cycles (a real-time H.264
decode on the A53s, then idle). 239 samples: cpu4-7 offline, `pd_g3d` off,
the CP online, no failed unit, no kernel line, the hottest zone at 45 °C.
Then, in the same boot, after the cluster had been off for 2 h, the four A57s
came back in 0.17 s, and `hotplug-a57.sh` passed 20 cycles of each of its
first four stages (80 cycles, 40 of them the whole cluster), the CP still
online. The boot's one GPU fault (`DATA_INVALID_FAULT` on job slot 1) came at
the session start, 40 s in, before the soak.

**In BOOT from 2026-11-04** (`out/boot-power-daily/boot.img`,
`8a22c8c7e6cd`, the soak's image but for one header byte), the rescue back
in RECOVERY (`058d0481b509`) first. First boot from BOOT: the CP and Wi-Fi up
35 s after the restart, ASPM `powersupersave`, the NoC timeout at 1,
no kernel line, no GPU fault; `t715-keys` turned the screen off at 49 s
and cpu4-7 went offline with it. Replaced by `#6` on 2026-11-05
(section 11); this image stays as the way back.

**What is left**, by the source studies (`research/cpuidle/FINDINGS.md`,
`research/suspend/FINDINGS.md`): suspend to RAM, the only way to Android's
standby, which needs the CP off before every suspend (the modem port's
`modem_suspend()` returns -EBUSY while the CP is powered,
`drivers/misc/modem_v1/modem_main.c:615-618`).

## 11. What stays awake with the screen off (2026-11-04)

**Baseline.** Kernel `#5` in BOOT, the persistent root, the CP online, Wi-Fi
connected with power save and ASPM L1.2, Bluetooth soft-blocked, the A57s
offline and the G3D domain off: **856 mW** on battery (215.8 mA at 3.97 V,
120 s after a 90 s settle, `image/tests/ondevice/screenoff-inventory.sh`).
The test kernel of section 10 drew 827-831 mW in the same state with the CP
off and the Wi-Fi radio off, so the CP and the Wi-Fi together cost only tens
of milliwatts: nearly all of the draw is the SoC awake.

**What the inventory saw** (two snapshots 127 s apart, screen off, idle 97.5 %):

| item | rate | cause |
|---|---|---|
| I2C 14e40000 (the PMIC, S2MPS13) | 473 interrupts/s | 20.6 A53 frequency changes a second (schedutil), each a BUCK voltage write; 91 % of the time at 400 MHz, 2.8 % at 1.2 GHz; `sugov:0` 1.5 % of a CPU |
| `quickshell` (the shell) | 4.2 % of a CPU, 67 wake-ups/s | its main thread polls with a 15-16 ms timeout (`ppoll`, read from `/proc/PID/mem`): Qt's animation timer, so an animation runs while nothing is drawn. Not found by reading the QML (no unconditional infinite animation in Omarchy's shell or in omamobile's plugins; no media player; the session locked) |
| `t715-keys` | 1 % of a CPU in children | `hyprctl monitors -j` every 5 s while dark, to see whether something else lit the screen |
| MCT ticks | 52-120/s per A53 | the wake-ups above |
| Wi-Fi (brcmf_pcie_intr) | 10.5/s | traffic |

Power domains: all off but AUD, held by `exynos-lpass` for its UART
(`0009-mfd-exynos-lpass-keep-LPASS-active-while-its-UART-is.patch`: a
runtime PM reference from probe, by design; unbinding Bluetooth does not
release it). Running PLLs: BUS 800 MHz, MFC 666 MHz, AUD 196.6 MHz. Every
CMU_TOP bus clock stays at its top rate (`aclk_bus0/1/2_400` 400 MHz) and
the branches that feed the powered-off domains (MSCL, MFC, ISP, HEVC, G2D,
CAM0/1 at 400 MHz, GSCL and DISP at 333) stay enabled: mainline marks those
gates `CLK_IS_CRITICAL` (`clk-exynos5433.c:604-652`), as a domain's bus must
run through its power transitions. `vdd_int` stays at 0.975 V and `vdd_mif`
at 1.0125 V with DRAM at 825 MHz (CPUFREQ.md section 6), where stock goes
down to 78 MHz at 0.8125 V when idle.

**Measured, two factors** (`power-windows.sh`, eight alternating 6-minute
windows, the daily kernel, the screen off): the A53 policy held at 400 MHz
while dark, +0.2 ± 5.3 mW, nothing, though it halves the interrupts (the
PMIC's I2C traffic and the voltage steps cost nothing measurable); the
Wi-Fi radio on and connected against off, **+90.1 ± 5.3 mW**, the largest
share that can be touched without the modem. `t715-keys` does not cap the
A53s for that reason; it brings the A57s back before it lights the screen
rather than after, and reads the panel's DPMS file instead of starting
`hyprctl` every 5 s while dark.

**Why the Wi-Fi costs that much.** With the screen off the BCM4358 receives
about 8.5 frames a second and sends almost nothing (510 frames in, 2 out,
in 60 s; 513 `brcmf_pcie_intr` interrupts): the network's broadcasts and
multicasts. brcmfmac enables power save as `PM_FAST` with a `pm2_sleep_ret`
of cfg80211's timeout, which is -1 unless wireless extensions set it (this
kernel has none, `net/wireless/core.c:1461`); `min_t(u32, -1, 2000)` makes
it 2000 ms (`cfg80211.c` `brcmf_cfg80211_set_power_mgmt()`). The chip
stays awake 2 s after each frame, so it never sleeps. Android's bcmdhd
switches to `PM_MAX`, every third DTIM and a unicast-only packet filter
when the screen goes off.

Kernel `#6` (branch `t715-power`) adds three brcmfmac parameters, read at
each power save request (`iw dev wlp1s0 set power_save on`): `ps_timeout`
(ms), `ps_mode` (2 `PM_FAST`, 1 `PM_MAX`) and `bcn_li_dtim`. Their defaults
keep `#5`'s behaviour. brcmfmac cannot be reloaded on this board: after a
`modprobe -r` the firmware boots again but the core reports "No clock" and
no command answers; only a power cycle brings it back. The chip's WL_REG_ON
(WLAN_EN, gpj2-0) is the PCIe host's `vdd18` supply, modelled
`regulator-always-on`, so nothing ever cycles it but a reboot. Without
`regulator-always-on` (test image, 2026-11-05), unbinding the PCIe host
(`15700000.pcie`) cuts it, binding it again powers the chip up, and
brcmfmac comes back with a working radio.

**Suspend, up to the firmware call** (test kernels of branch `t715-sleep`
with research/suspend's 5433 code, `image/tests/ondevice/pmtest.sh`,
image mode, the CP off, the watchdog armed and kept running through the
test; every crash ended in `oops=panic` and a reboot into BOOT, and its
dump was read back from `/sys/fs/pstore/dmesg-ramoops-0`). Three things
stood in the way, found in this order:

1. **brcmfmac.** `pm_test=devices` fails at `brcmf_pcie_pm_enter_D3`: the
   firmware never answers the D3 request, -EIO, the suspend aborts. With
   the Wi-Fi unbound, `devices` passes. Still open. With WL_REG_ON no
   longer always-on, the PCIe host cuts the chip's power in its noirq
   suspend: brcmfmac unbound before `pm_test` `platform`+`none` and bound
   after came back and held; unbound around a real suspend-to-idle, its
   firmware loaded but the chip's interrupt then went silent
   (`research/suspend/PORT.md` section 10).
2. **GPIO_FINGER belongs to the secure world.** `pm_test=platform` oopses
   in the late phase, in `samsung_pinctrl_suspend()`. With
   `/sys/power/pm_print_times`, the controller is `14cb0000.pinctrl` (the
   faulting page maps 0x14cb0000): gpd5, the fingerprint sensor's SPI.
   Its bus clock runs and the controllers on the same clock read fine just
   before, but a read from Linux aborts; stock skips that bank in its
   sleep save and restore when the fingerprint is secure
   (`ENABLE_SENSORS_FPRINT_SECURE`, `CONFIG_SENSORS_FP_SPI_GPIO="gpd5"`).
   The first dump had been put down to AUD; the AUD bus clock added for it
   changed nothing. Fix: `pinctrl_finger` disabled (nothing in Linux uses
   gpd5).
3. **The AUD domain does not power off.** Once `exynos-lpass` lets it go,
   genpd powers AUD off in the noirq phase: "Power domain AUD disable
   failed", and the block stays unreachable. The first access after resume
   aborts: CMU_AUD's own register restore, or PipeWire opening the PCM
   (`i2s_runtime_resume`, `ENABLE_PCLK_AUD`). Stock opens every AUD clock
   gate before the domain goes off (`lpass_reset_clk_default()`); mainline
   CMU_AUD only moves its muxes to OSC. Fix: the gates in CMU_AUD's
   suspend values (`clk-exynos5433.c`). Stock's boot-time LPI mask for the
   AUD trace bus alone did not do it; both are in the test kernel.

With the three fixes (`research/suspend/patches/0006-0008`, image
`test-recovery-sleep6`), the whole ladder passes: `freezer`, `devices`,
`platform`, `processors`, `core` and `none`. `none` runs the 5433 sleep
entry with every register written, the wake masks, the SLEEP column and
the clock writes included, and stops short of `SMC_CMD_SLEEP` (the
`exynos5433_sleep=dryrun` switch). Five more dry runs in a row pass, about
0.9 s each, with AUD reachable afterwards. A real suspend-to-idle (`rtcwake
-m freeze -s 10`) sleeps and wakes on the PMIC RTC alarm, 11.4 s, no
error. sboot drops the boot header's command line and the kernel keeps
1023 characters of the whole, sboot's own taking 878: a test switch goes
into `CONFIG_CMDLINE` only if it fits in the 145 left, otherwise it is a
module parameter set at run time.

**The Wi-Fi settings, measured** on kernel `#6` from RECOVERY, the
persistent root, the CP online, the screen off, nine alternating 5-minute
windows (`power-windows.sh` actions `wps_*`, which set the parameters and
turn power save off and on): the stock driver (`PM_FAST`, 2 s) 851, 974
and 835 mW; `PM_FAST` with 100 ms 776, 774 and 754 mW; `PM_MAX` waking for
every third DTIM 854, 748 and 773 mW. The fit gives -118 ± 49 mW for 100 ms
and -94 ± 49 mW for `PM_MAX`; without the stock window at 974 mW the 100 ms
gain is about 75 mW. 100 ms does as well as `PM_MAX` without a mode to
switch with the screen and without `PM_MAX`'s slow transfers (one PS-Poll
per buffered frame), and it is the timeout mac80211 drivers use, so the
root image sets it: `/etc/modprobe.d/t715-brcmfmac.conf`,
`options brcmfmac ps_timeout=100`. The gateway answers a ping in 8 ms with
it, screen off.

**`#6` in BOOT from 2026-11-05** (`out/boot-power6/boot.img`,
`1ecbdca02837`; `#5`'s image stays as the way back). Its 2-hour soak from
RECOVERY was clean (the CP online and the Wi-Fi connected in all 239
samples, 239 gateway pings of 239, no kernel line, no failed unit), and so
were four control reboots; it also came back from BOOT after each of the
five panics of the suspend tests (the first one checked in full).
As installed, the same method as the baseline above
(`screenoff-inventory.sh`, a 90 s settle, then 119 gauge samples over
10 minutes, the CP online, the Wi-Fi connected, cpu0-3): **754 mW**
(184 mA at 4.10 V), 102 mW under `#5`'s 856. On the 15.2 Wh battery that
is about 20 hours with the screen off, 5 % an hour.

Since 2026-11-10 the tablet suspends to RAM daily: once its screen has
been dark for a minute, on battery, `t715-sleep` powers the CP and the
Wi-Fi/Bluetooth chip down and sleeps the whole tablet, waking on Power,
Home, the cover, a cable or the RTC alarm (`docs/image/ROOTFS.md`,
"Sleep"; the roadmap's item 1, `docs/ROADMAP.md`). The power drawn asleep
is not measured yet.

## 12. The modem's share of standby (2026-11-05)

**A real standby.** Off USB for 1 h 54 min, the screen off but for ten
seconds (the Home key, in `t715-keys`' log), the tablet lost 8 points in 103
minutes by upower's history: 4.7 % an hour, about 0.71 W on the 15.2 Wh
battery. The owner read it as 8 % an hour. It is the 754 mW of section 11: the CP online and the Wi-Fi
connected, the CP here without a SIM (CS registration denied, UMTS, radio
on).

**Measured** (`power-windows.sh` actions `modem_off`, `modem_on`, `wwan_off`
and `wwan_on`, kernel `#6` from BOOT, the persistent root, the Wi-Fi
connected, the screen off, nine alternating 5-minute windows after a 4-minute
settle, the first 90 s of each dropped; `power-stats.py --skip 90`):

| State | Windows |
|---|---|
| CP online, radio on (no SIM) | 750, 814, 742 mW |
| CP online, radio off (airplane mode's `nmcli radio wwan off`) | 742, 734, 753 mW |
| CP off (shannond and the loader stopped, `MODEM_OFF`) | 572, 588, 604 mW |

The fit gives **+155 ± 22 mW for the CP powered**, its radio off, and +28 ±
22 mW for the radio on, which the noise does not separate from zero. Airplane
mode therefore saves next to nothing; powering the CP off saves a fifth of the
screen-off draw: about 0.59 W, 3.9 % an hour, 26 hours on the battery,
against 20 with the CP online. The interrupt rate and the CPUs' idle share did
not change with the CP (700-790 interrupts a second, 98-99 % idle in every
window): the cost is the CP's own, not the AP's.

Why a CP with its radio off costs that much: the port holds the MIPI-LLI link
up for as long as the CP runs (`start_pm` raises AP2CP_WAKEUP and keeps it;
decision D2 of `research/modem/research/SYNTHESIS.md`, "cost accepted: higher
idle power during bring-up"), so the CP is never let go to sleep. Stock
Android releases the link about every three seconds through a CP-led
handshake (SYNTHESIS §2.16), and the CP can sleep in between. Porting that
state machine (D2's fallback F2) is what would make a modem kept on cheap.
Until then the switch is the lever: `t715-modem-power off`, the Modem tile, or
Réseau mobile's "Éteindre en veille" (`docs/hardware/MODEM.md` §5.4).

The measurement powered the CP off and on three times: each stop ended with
`MODEM_OFF` 3.6 s after the request, each power-on reached ONLINE in 9.92 to
9.94 s, and `power-windows.sh` put the modem back online at its end (CP
session 4 of that boot). The 40 to 50 `NOSPC in RAW_TXQ` lines of the
kernel's modem driver during each power-on are the boot channel's flow
control while MAIN streams; the tablet's first boot that day had as many.

## 13. Battery saver (the quick settings tile, 2026-11-07)

The **Battery saver** tile in quick settings switches power-profiles-daemon
(PPD) between `balanced` and `power-saver` through Omarchy's
`omarchy-powerprofiles-set`. On this kernel PPD has only its `placeholder`
driver (no platform driver for this board), so the switch alone changes
nothing. `t715-power-profile` (`/usr/local/sbin/`, run as root by
`t715-power-profile.service` at boot and by `t715-power-profile.path`
whenever PPD rewrites `/var/lib/power-profiles-daemon/state.ini`, which it
does on every switch) applies real caps instead:

- **power-saver**: the A53 cluster (the lowest `cpu_capacity`) capped at
  1 GHz (`SAVER_LITTLE_MAX_KHZ`), the A57 cluster offline — section 10
  measured 169 ± 4 mW for that alone — `cpufreq/boost` off, and the GPU's
  devfreq `max_freq` at 266 MHz (`SAVER_GPU_MAX_HZ`), which the operating
  points of kernel #7 (100, 133, 200 and 400 MHz, `GPU.md`) turned into
  200 MHz; those of the daily kernel #8 (160 to 700 MHz) keep 266 MHz.
  Hyprland's animations go off. The flag
  `/run/t715-power/saver` is left behind: `t715-keys` reads it and keeps
  the A57s offline even when the screen lights (one log line per lit
  period), so a wake cannot undo the saver until the tile goes back to
  balanced.
- **balanced**: every cpufreq policy on `schedutil` at its
  `cpuinfo_max_freq`, `boost` on, the GPU on `simple_ondemand` at its top
  frequency, the flag removed and the A57s back online — but only when the
  panel's DPMS state is `On`: `t715-keys` keeps them offline while the
  screen is dark, and waking them there would be undone at the next
  screen-off. The animations come back.

Hyprland's animations follow the saver too: the tablet block of
`looknfeel.lua` reads the flag at Hyprland's start and on every config
reload, and `t715-animations.path` with `t715-animations.service` in the
user session (`/usr/local/bin/t715-animations`) flip the running Hyprland
through `hyprctl eval`. Kernel #8 scales the GPU from 160 to 700 MHz;
with the GPU at a fixed 266 MHz (the kernels before #7) the desktop felt
snappier without animations, and the image kept them off. The off-device
test is `image/tests/test_t715_animations.sh`. Checked on the tablet on
2026-11-08 with kernel #8: power-saver turned the animations off within a
second of the switch, with the A57s offline, the A53s at 1 GHz at most and
the GPU at 266 MHz at most; balanced turned them back on, with cpus 0-7
online, the A53s at 1.2 GHz and the GPU at 700 MHz at most.

The clusters are told apart by the cpus' `cpufreq` links, never by cpu
numbers: an offline cpu keeps its link but loses its `cpu_capacity`, and
the A57s are offline whenever the screen is dark or the saver is on. Only
the big cluster is ever taken offline (cpu0 has no `online` file).
`/etc/t715-power-profile.conf`, sourced when present, overrides
`SAVER_LITTLE_MAX_KHZ` (1000000), `SAVER_BIG` (`offline`, or `keep` to
leave the A57s as they are) and `SAVER_GPU_MAX_HZ` (266666667). The GPU
part needs the GPU devfreq of the daily kernel #7; `cpufreq/boost` does not
exist on this kernel, and that part is skipped with a log line. The savings
are not measured yet; the A57 figure above is section 10's, with the
screen off.

Checked on the tablet on 2026-11-07, kernel #7: the tile on gave
power-saver (A57s offline, A53s at 1 GHz at most, GPU at
200 MHz at most), and the tile off gave balanced three seconds after the
switch (cpus 0-7 online, both clusters at 1.2 GHz at most,
GPU at 400 MHz at most, the flag gone).

Off the device: `image/tests/test_t715_power_profile.sh` runs the script
on a fake sysfs (both profiles, the orders, the clamping, the config file,
the profile sources, the guard, the usage), and
`image/tests/test_t715_keys.sh` has a group for the flag.
`image/tests/verify-rootfs.sh` checks the files and the units in the
built image.

The same script has a **battery heat and low-battery guard**, asked for by
decision D6 of CPUFREQ.md (sections 5.4 and 11) before any cap above
1.2 GHz is daily: `t715-power-profile guard`, run every 30 s by
`t715-power-guard.timer` (the first run a minute after boot). While
balanced is the active profile and the battery is hot or low, the A57
cluster's `scaling_max_freq` sits at 1.2 GHz (`GUARD_BIG_MAX_KHZ`) and the
GPU's devfreq `max_freq` at 420 MHz (`GUARD_GPU_MAX_HZ`); with neither
flag, both get their balanced limits back. `apply balanced` writes the
same caps while a flag exists, so a profile switch cannot slip past the
guard. Hot uses hysteresis, because a fanless tablet hovers around a
threshold: the flag is set at 52.0 °C (`GUARD_HOT_ON_DECIC`, tenths of a
degree C) and cleared only at 49.0 °C (`GUARD_HOT_OFF_DECIC`); a reading
in between keeps the previous state. These are CPUFREQ.md section 5.4's
comfort numbers, 3 °C under the modem's prepare gate. Low is set at
20 % (`GUARD_LOW_PCT`) or below, and only while no Mains or USB supply is
online: plugged in, the tablet charges its way out of it. The flags live
beside the saver's, as `/run/t715-power/hot` and `/run/t715-power/low`;
power-saver caps both parts harder than the guard, so it only keeps the
flags. One log line per flag change, none per steady run, and `GUARD=off`
in the config removes both flags and disables all of it.

External power is any `power_supply` of type `Mains` or `USB` with
`online` = 1. The gauge's own `status` is never read: it says "Not
charging" while the charger is online (checked on 2026-11-07: the gauge
read `Not charging` at 96 % while `sm5703-charger` was online and
`Charging`), so the charger's own files decide. The battery is the first
`power_supply` of type `Battery` whose `temp` answers. The guard never
onlines or offlines a cpu: an inactive big policy (its
`scaling_governor` empty, the screen dark) is skipped, and the next run
catches up once it is back.
