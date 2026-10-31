# Milestone 6a — audio hardware description (WM1814)

**Scope.** This milestone describes the audio hardware of the Galaxy Tab S2
8.0 LTE (SM-T715, `gts28ltexx`) in the mainline 6.12 device tree: the Cirrus/
Wolfson WM1814 codec on HSI2C channel 3 and the Exynos5433 I2S0 controller.
There is deliberately **no sound node and no machine driver**: mainline has no
`samsung,pacific-arizona` driver, and a machine driver is a C-code milestone.
Everything the future machine driver will need is documented here.

Files:

- `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m6.dtsi` — hardware description
- `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m6.dts` — m2 + m6.dtsi include
- `arch/arm/configs/gts28ltexx_m6.config` — config fragment (audio chain)
- this document

---

## 1. Value-by-value source table

Every value in the m6 dtsi, with its ground truth in the stock live device
tree (`dumps/live_fdt.dts`, decompiled from `/sys/firmware/fdt`) and the
mainline consumer (binding YAML and/or parsing driver).

### 1.1 Bus: HSI2C @ 0x14e70000

| DT item | value | live FDT source | mainline mapping |
|---|---|---|---|
| channel | `hsi2c_3` | `hsi2c@14E70000`, `live_fdt.dts:1959-1972` | `exynos5433.dtsi:1637-1648` defines `hsi2c_3` at `reg = <0x14e70000 0x1000>`; mapped by register address |
| status | `okay` | `live_fdt.dts:1970` (`status = "okay"`) | — |
| pinctrl | default `hs_i2c3_bus` | stock group `codec-i2c` (phandle `0x55`) on `gpd1-3`/`gpd1-2` | `exynos5433-pinctrl.dtsi:636-642`: `hs_i2c3_bus` = gpd1-3/gpd1-2 `EXYNOS_PIN_FUNC_3`, `PULL_UP` — same pins, same function/pull; so the mainline default reproduces the stock group and no override is needed |

Stock quirks of this bus left out: `samsung,check-transdone-int`
(`live_fdt.dts:1972`) — no mainline binding, no mainline user; the mainline
hsi2c driver always polls/transfers the same way (see §4).

### 1.2 Codec node `audio-codec@1a`

Node label `wm1814`, unit address `@1a`, on `hsi2c_3`.

| property | value | live FDT source (line) | mainline binding / parser |
|---|---|---|---|
| `compatible` | `"wlf,wm1814"` | `:1979` | `Documentation/devicetree/bindings/mfd/wlf,arizona.yaml`; matched by `drivers/mfd/arizona-i2c.c` `of_match` (`wlf,wm1814`, arizona-i2c.c:103-105) |
| `reg` | `<0x1a>` | `:1980` | I2C address 0x1a |
| `interrupt-parent` | `<&gpa0>` | `:2008` (phandle `0x4b` = `gpa0`) | `exynos5433-pinctrl.dtsi:32` — `gpa0` is in `pinctrl_alive` |
| `interrupts` | `<4 IRQ_TYPE_LEVEL_LOW>` | `:2015` = `<0x04 0x00 0x00>` | stock cells are (pin, 0, 0) — downstream `arizona_i2c_probe` hard-codes `IRQF_TRIGGER_LOW`; mainline `#interrupt-cells = <2>` for `gpa0`, so the trigger moves into the cell: `IRQ_TYPE_LEVEL_LOW`. Same wiring as TM2 (`exynos5433-tm2-common.dtsi:1284-1287`) |
| `clocks`/`clock-names` | `<&pmu_system_controller 0>` / `"mclk1"` | not in stock DT (downstream gates CLKOUT from `mach-exynos`, see §3) | TM2 precedent `exynos5433-tm2-common.dtsi:1281` (`clocks = <&pmu_system_controller 0>`); consumed by `arizona_core_init_request`/`arizona_request_mclk` (`drivers/mfd/arizona-core.c`, `mclk1` name) |
| `gpio-controller`/`#gpio-cells = <2>` | — | `:1981`, `:2019` | required by `wlf,arizona.yaml:204-213`; cell count matches stock `#gpio-cells = <0x02>` |
| `interrupt-controller`/`#interrupt-cells = <2>` | — | implicit in stock; TM2 precedent | required by binding; mainline arizona irqchip uses 2 cells |
| `#sound-dai-cells = <1>` | — | not in stock | required by `sound/wlf,arizona.yaml` (`const: 1`); the machine driver picks `aifN` by index |
| `pinctrl-0` | `codec_reset_pins`, `codec_ldoena_pins`, `codec_irq_pins` | `:1987` = `<0x57 0x58 0x59 0x5a>` (4 groups) | see §1.3 — the stock 4th group (`audio-ctl`, sub-mic bias GPIO) has no mainline consumer at this milestone |
| `wlf,reset` | `<&gpc0 7 GPIO_ACTIVE_HIGH>` | `:1998` = `<0x5b 0x07 0x00>`; `0x5b` = `gpc0` | parsed as `wlf,reset` gpiod in `drivers/mfd/arizona-core.c`; gpiolib-of rename table (`gpiolib-of.c:496+`) maps it under `CONFIG_MFD_ARIZONA` |
| `wlf,ldoena` | `<&gpf0 0 GPIO_ACTIVE_HIGH>` | `:1975` = `<0x27 0x00 0x00>`; `0x27` = `gpf0` | `arizona-ldo1.c` consumes `wlf,ldoena`; rename table under `CONFIG_REGULATOR_ARIZONA_LDO1` |
| `AVDD-supply` | `<&ldo18_reg>` | `:1989` = `<0x5c>`; `0x5c` = LDO18 = `V_CODEC_1.8V_AP` | required (`wlf,arizona.yaml:204-213`); regulator aliases registered via `mfd-core.c:189-196` |
| `LDOVDD-supply` | `<&ldo18_reg>` | `:2003` | optional in binding (else-branch, `mfd/wlf,arizona.yaml:31-40`); WM1814 uses the DVFS LDO1 which is `arizona_ldo1_hc` with supply name `LDOVDD` (`arizona-ldo1.c:95-97`, WM1814 → `arizona_ldo1_dvfs` selection at `:317-320`) |
| `DBVDD1-supply` | `<&ldo18_reg>` | `:2017` | required |
| `DBVDD2-supply` | `<&ldo18_reg>` | `:2000` | conditionally **required for wm1814** (`mfd/wlf,arizona.yaml:52-64`) |
| `DBVDD3-supply` | `<&ldo18_reg>` | `:2018` | conditionally **required for wm1814** (`:66-80`) |
| `CPVDD-supply` | `<&ldo18_reg>` | `:2014` | required |
| `SPKVDDL-supply` | `<&ldo18_reg>` | `:2013` | required for wm1814 (else-branch `:95-104`) |
| `SPKVDDR-supply` | `<&ldo18_reg>` | `:2021` | required for wm1814 (else-branch `:95-104`) |
| `wlf,inmode` | `<DIFF DIFF DIFF DIFF>` (= 0 0 0 0) | `:1990` = `<0x00 0x00 0x00 0x00>` | `sound/wlf,arizona.yaml:28-47` (≤4 cells, 0-2); parsed `arizona.c:2795`; for wm1814 cells are `<IN1A IN2A IN1B IN2B>`; 0 = differential |
| `wlf,dmic-ref` | `<2 ARIZONA_DMIC_MICBIAS1 3 0>` | `:2016` = `<0x02 0x01 0x03 0x00>` | `arizona.c:2803-2810`; consumed per input pair at `arizona.c:330` (`dmic_ref[i] << IN1_DMIC_SUP_SHIFT`); `ARIZONA_DMIC_MICBIAS1 = 1` (`dt-bindings/mfd/arizona.h:82`). Index 2 = IN2 → its DMIC reference is MICBIAS1; index 3 = 0 (unused pair, MICVDD default) |
| `wlf,out-mono` | `<0 1 1 0 0 0>` | `:1996` | `sound/wlf,arizona.yaml:46-…` (≤6 cells); `arizona.c:2812-2818` |
| `wlf,max-channels-clocked` | `<2 0 0>` | `:1984` | `sound/wlf,arizona.yaml:70-81` (≤3 cells, one per AIF) |
| `wlf,micd-detect-debounce` | `<300>` | `:2012` = `<0x12c>` | `extcon/wlf,arizona.yaml:50`; parsed in `arizona-jack.c` |
| `wlf,micd-bias-start-time` | `<0x1>` | `:2013` | `extcon/wlf,arizona.yaml:62` |
| `wlf,micd-rate` | `<0x7>` | `:1997` | `extcon/wlf,arizona.yaml:70` |
| `wlf,micd-force-micbias` | (boolean) | `:1988` | `extcon/wlf,arizona.yaml:89` |
| `wlf,micd-configs` | `<0x0 1 0>` | `:2017` | `extcon/wlf,arizona.yaml:94-114`: one 3-cell group = (accdet pin 0, MICBIAS 1, pol-gpio 0) |
| `wlf,micd-timeout-ms` | `<1000>` | `:1992` `wlf,micd-timeout = <0x3e8>` (µs-flavoured downstream name) | mainline property is `wlf,micd-timeout-ms` (`extcon/wlf,arizona.yaml:85`), parsed `arizona-jack.c:1230`; 0x3e8 = 1000 |
| `wlf,micd-software-compare` | (boolean) | `:1995` | `extcon/wlf,arizona.yaml:45`, parsed `arizona-jack.c:1237` |
| `wlf,gpsw` | `<ARIZONA_GPSW_CLAMP_DISABLED>` (= 3) | `:2011` = `<0x03>` | `extcon/wlf,arizona.yaml:118-123` (0-3); `ARIZONA_GPSW_CLAMP_DISABLED = 3` (`dt-bindings/mfd/arizona.h`) |
| `wlf,gpio-defaults` | `<0xa101 0xa101 0xa101 0xa101 0x8101>` | `:2006` | `mfd/wlf,arizona.yaml:151-163` — exactly five 16-bit register values, raw (values ≥ 0x8000 carry `ARIZONA_GPN_DIR`, config as GPIO output; the stock values are register images, kept verbatim) |

**MICVDD — why there is no `MICVDD-supply`.** The MFD registers
`parent_supplies` (= `wm5102_supplies`: MICVDD, DBVDD2/3, CPVDD, SPKVDDL/R,
`drivers/mfd/arizona-core.c:853-860, 922-931`) as supply **aliases**
(`drivers/mfd/mfd-core.c:189-196`). Alias registration
(`drivers/regulator/core.c:2473-2502`) never validates that the supply
exists — it only fails on -ENOMEM/-EEXIST — and the MICVDD alias resolves to
the MFD's **own internal** `arizona-micsupp` regulator, whose consumer map
uses the parent device name (`arizona-micsupp.c:321/358`). If an alias stays
unresolved the consumer silently falls back to the dummy regulator with a
warning (`core.c:2213-2218`). The binding only requires `DCVDD-supply`/
`MICVDD-supply` for cs47l24/wm1831 (`mfd/wlf,arizona.yaml:21-40`), and the
upstream TM2 wm5110 node has no MICVDD-supply and works. So: internal supply,
no property, correct.

### 1.3 Pinctrl groups

Stock groups (`live_fdt.dts`) → mainline groups (in the m6 dtsi):

| stock group | phandle | pins / stock settings | bank | mainline group | kept / adapted |
|---|---|---|---|---|---|
| `codec-irq` `:676-681` | `0x5a` | `gpa0-4`, `pin-pud = 0` (NONE) | `pinctrl_alive` | `codec_irq_pins`: gpa0-4, `PULL_NONE` | kept, value-identical |
| `codec-ldoena` `:5495-5500` | `0x58` | `gpf0-0`, `pin-con-pdn = 0x3` | `pinctrl_imem` | `codec_ldoena_pins`: gpf0-0, `FUNC_OUTPUT` | kept; the `pin-con-pdn` (power-down state) cell is dropped per the m5 milestone policy (stock pdn cells are not portable to mainline pinctrl) |
| `codec-reset` `:5873-5881` | `0x57` | `gpc0-7`, `pin-function = 0x1` (OUTPUT), `pin-pud = 0x1` (PULL_UP), `pin-con-pdn = 0x3` | `pinctrl_peric` | `codec_reset_pins`: gpc0-7, `FUNC_OUTPUT`, `PULL_UP` | kept, value-identical minus pdn cell |
| `audio-ctl` `:3901-3906` | `0x59` | `gpr3-2`, `pin-con-pdn = 0x3` | `pinctrl_fsys` | — **left out** | this is the sub-mic bias enable GPIO (`audio_pdata.sub_mic_bias_gpio = <0x4d 0x2 0x0>`, `0x4d` = `gpr3`; consumed by `pacific_of_get_pdata`, `pacific_arizona.c:1437-1444`, driven by the `Sub Mic` DAPM widget hook `wm1814_ext_submicbias`, `pacific_arizona.c:624-641`). Mainline has no binding for `audio_pdata`/`sub_mic_bias_gpio`; the machine-driver milestone should model it like TM2's `mic-bias-gpios = <&gpr3 2 GPIO_ACTIVE_HIGH>` (`exynos5433-tm2-common.dtsi:125`). Nothing requests the pin at this milestone, so the group is not described yet; note `gpr3-2` is otherwise claimed by the default `sd1_bus4` group (`exynos5433-pinctrl.dtsi:327`) |

### 1.4 I2S0 and CLKOUT

| item | value | source |
|---|---|---|
| `&i2s0` status | `okay` | stock i2s node `i2s@11440000` (phandle `0xbe`, referenced by the sound node `samsung,audio-cpu = <0xbe>`, `live_fdt.dts:5350`) is the Exynos5433 I2S0; mainline `exynos5433.dtsi` defines `i2s0` with `compatible "samsung,exynos5433-i2s"`; pinctrl `i2s0_bus` (gpz0-0..6, FUNC 2) is the SoC dtsi default (`exynos5433-pinctrl.dtsi:140-147`) |
| `&pmu_system_controller` assigned-clocks | `<&pmu_system_controller 0>` parent `<&xxti>` | the downstream `exynos5_audio_set_mclk` gates CLKOUT by writing `0x1000`/`0x1001` to `EXYNOS_PMU_DEBUG` (`mach-exynos/include/mach/exynos-audio.h:18-45`); the mainline equivalent is the TM2 pattern `assigned-clocks/assigned-clock-parents = <&pmu_system_controller 0>/<&xxti>` (`exynos5433-tm2-common.dtsi:1248-1251`) which reparents CLKOUT onto the 24 MHz board oscillator and enables it |

---

## 2. Kconfig: what is enabled, and the WM8998 finding

`gts28ltexx_m6.config` (merged on `gts28ltexx_defconfig` by the build script)
sets, all `=y`: `SOUND`, `SND`, `SND_SOC`, `SND_SOC_SAMSUNG`,
`SND_SAMSUNG_I2S`, `MFD_ARIZONA_I2C`, `MFD_WM8998`,
`REGULATOR_ARIZONA_LDO1`, `REGULATOR_ARIZONA_MICSUPP`, `GPIO_ARIZONA`,
`EXTCON`, `MFD_EXYNOS_LPASS`, `DMADEVICES`, `PL330_DMA` (plus the whole m2
block).

**The ASoC codec component (`CONFIG_SND_SOC_WM8998`) cannot be enabled from a
fragment, and that is a property of mainline, not of this config:**

- `SND_SOC_WM8998` is a **promptless** tristate
  (`sound/soc/codecs/Kconfig:2414-2416`: `tristate` + `depends on
  MFD_WM8998 && MFD_ARIZONA`, no prompt line). Kconfig ignores user values
  for symbols without a prompt: `olddefconfig` drops the line even when it is
  appended directly to `.config` (verified by hand, twice — the symbol is
  absent from the final `.config`).
- Its only in-tree activators are: `imply` from `SND_SOC_ALL_CODECS`
  (`codecs/Kconfig:343`), which `depends on COMPILE_TEST` (`:17`) —
  unacceptable on a device config; or `select` from a machine driver.
- Every in-tree Arizona codec is enabled exactly that way — e.g. TM2:
  `SND_SOC_SAMSUNG_TM2_WM5110` `select SND_SOC_WM5110`
  (`sound/soc/samsung/Kconfig:118-125`). Mainline has **no** WM8998 machine
  driver, so no select exists.
- `SND_SOC_ARIZONA` (helper library containing `arizona.o`+`arizona-jack.o`,
  `codecs/Makefile:48`) is likewise promptless and defaults to y only when
  `SND_SOC_WM8998=y` (`codecs/Kconfig:366-377`).

Consequence: at this milestone the **MFD probes** (`arizona-i2c` matches
`wlf,wm1814`, brings up core, `arizona-ldo1` (DCVDD/LDOVDD),
`arizona-micsupp` (MICVDD), `arizona-gpio`, haptics, pwm cells) but the
`wm8998-codec` cell has no driver and the `snd-soc-arizona` jack/extcon code
is not built. That is fine for a hardware-description milestone: there is no
sound node to bind anyway. The machine-driver milestone must add a Kconfig
stanza that `select SND_SOC_WM8998` (which also flips `SND_SOC_ARIZONA`
and the jack detection to y via its defaults).

Verification: `grep -E
"^CONFIG_(MFD_ARIZONA_I2C|MFD_WM8998|SND_SOC_WM8998)="` matches the first
two; the third is structurally impossible until the machine driver exists
(deliberate, documented deviation from the milestone's example grep).

---

## 3. Clocking chain (documented, not yet wired)

The full chain the machine driver will set up, from board oscillator to
codec clock domains — transcribed from `pacific_arizona.c` (downstream,
`src/kernel_universal5433/sound/soc/samsung/pacific_arizona.c`):

```
xxti (24 MHz board oscillator)
  └─ pmu_system_controller CLKOUT [gate: downstream writes 0x1000 to
     EXYNOS_PMU_DEBUG; mainline: assigned-clock-parents, m6 dtsi §1.4]
      └─ WM1814 MCLK1 pin ("mclk1" clock in DT; 24 MHz,
         PACIFIC_DEFAULT_MCLK1, pacific_arizona.c:51; MCLK2 32 kHz
         :52 not described — no mainline clock for it, board wiring
         undocumented in the live tree)
          ├─ FLL1: REFCLK ← NONE, FLL1 ← MCLK1 24 MHz → 49.152 MHz
          │   (pacific_start_sysclk :1713-1756; sysclk_rate 49152000
          │   :106-109; card init applies SYSCLK ← FLL1 at 48000*1024
          │   :1636-1640)
          │    └─ SYSCLK: AIF1 ← SYSCLK (:905-908); AIF3 ← SYSCLK_2 (:913)
          └─ FLL2: mode 0: REFCLK ← MCLK1 24 MHz → ASYNCCLK;
             else FLL2 ← AIF2BCLK (bclk) → ASYNCCLK
             (pacific_aif2_hw_params :1129-1170; asyncclk_rate 49152000
             :108; AIF2 ← ASYNCCLK :909-912)
```

SoC side (`hw_params`, `pacific_aif1_hw_params :984-1032`): both DAI sides
`SND_SOC_DAIFMT_I2S | NB_NF | CBM_CFM` (codec masters BCLK/LRCLK); CPU DAI
`SAMSUNG_I2S_CDCLK 0 CLOCK_IN` and `SAMSUNG_I2S_OPCLK 0 MOD_OPCLK_PCLK`.
I2S0 in mainline is the i2sv7 type with `QUIRK_PRI_6CHAN | QUIRK_SEC_DAI |
QUIRK_NEED_RSTCLR | QUIRK_SUPPORTS_TDM` (`sound/soc/samsung/i2s.c:1687-1692`);
DAI names `samsung-i2s` / `samsung-i2s-sec` (`i2s.c:1172`).

---

## 4. Machine driver specification (transcribed for the future milestone)

Everything below is what a mainline `pacific-arizona` machine driver must
reproduce. Source: `pacific_arizona.c` (line numbers from the downstream
tree) with the mainline equivalent noted where one exists.

### 4.1 Card identity and probe

- `compatible = "samsung,pacific-arizona"` (`:2106-2108`); stock sound node
  `live_fdt.dts:5344-5352`.
- Card picked by presence of a codec node named `wm5102`/`wm5110`/`wm1814`
  (`card_ids[]`, `:2021-2023`) — for this board always wm1814.
- Probe parses `clocks`/`clock-names = "mclk"` from the sound node, then per
  DAI link index `samsung,audio-cpu` / `samsung,audio-codec` phandle arrays
  (`:2056-2071`). Stock sound node has `clocks = <0x10 0x10cc>` (CLKOUT),
  `samsung,audio-cpu = <0xbe>` (I2S0), `samsung,audio-codec = <0xbf ×8>`
  (the same wm1814 phandle eight times — one per link).
- `/audio_pdata` node (`live_fdt.dts:4337-4341`) supplies
  `mic_bias_gpio` (absent here) and `sub_mic_bias_gpio = <gpr3 2 0>`
  (`:4340`, consumed `:1437-1444`). Mainline equivalent: TM2 puts
  `mic-bias-gpios` inside the codec node (`tm2-common.dtsi:125`).

### 4.2 DAI links (`pacific_wm1814_dai[]`, `:1213-1283`)

| # | name | CPU DAI | codec DAI | notes |
|---|---|---|---|---|
| 0 | `playback-pri` | (from `samsung,audio-cpu` = I2S0) | `vegas-aif1` | playback & record |
| 1 | `baseband` | `snd-soc-dummy-dai` | `vegas-aif2` | voice call to modem, `ignore_suspend` |
| 2 | `bluetooth sco` | `snd-soc-dummy-dai` | `vegas-aif3` | BT SCO, `ignore_suspend` |
| 3 | `playback-sec` | `samsung-i2s-sec` | `vegas-aif1` | deep-buffer playback via I2S0's secondary DAI |
| 4-7 | `playback-eax0..3` | `samsung-eax.0..3` | `vegas-aif1` | EAX effect sinks |

**DAI-name mismatch to resolve at that milestone:** the downstream codec
driver registers `vegas-aif1/2/3` (`vegas.c:1159/1180/1201`); mainline
`wm8998.c` registers `wm8998-aif1/2/3` (`:1153/1175/1197`). A mainline
machine driver must use the `wm8998-aifN` names (and mainline has no
`samsung-eax` driver at all — links 4-7 have no mainline counterpart; voice
and BT SCO would use the mainline-style dummy-dai links or be deferred).

### 4.3 Widgets and routes (`:734-746`, `:856-880`)

Widgets: `HDMIL`, `HDMIR` (outputs), `HP` (headphone), `SPK` (speaker),
`RCV` (earpiece), `VPS` (line), `HDMI` (line), `Headset Mic`, `Main Mic`,
`Sub Mic` (with `wm1814_ext_submicbias` PRE_PMU/POST_PMD hook driving the
gpr3-2 GPIO, `:624-641`).

Routes: `HPOUTL/R → HP`; `SPKOUTLN/LP/RN/RP → SPK`; `EPOUT → RCV`;
`LINEOUTL/R → VPS`; `AIF1RX1/2 → HDMIL/R → HDMI`; `MICBIAS2 → Main Mic →
IN1BL` (main mic SEL tied to GND); `MICBIAS3 → Sub Mic → IN1BR`;
`MICBIAS1 → Headset Mic → IN2B`.

Output topology matches the m6 dtsi's `wlf,out-mono = <0 1 1 0 0 0>`:
SPKOUTL/R and EPOUT are mono (single speaker, single earpiece), HP is stereo.

### 4.4 Clocking, formats, jack

See §3 above (media clocking `:881-914`, FLL1 `:1713-1756`, FLL2
`:1124-1170`, formats/CPU sysclks `:984-1032`).

Jack detection: the mainline `arizona-jack.c` (in `snd-soc-arizona`) consumes
the `wlf,micd-*`/`wlf,gpsw`/`wlf,hpdet-*` properties documented in §1.2.
Out-of-scope tuning for this milestone; see §5 for the properties that exist
downstream but have **no** mainline parser (they were dropped, not
translated).

### 4.5 tm2_wm5110.c deltas (the mainline precedent to copy)

`sound/soc/samsung/tm2_wm5110.c` is the reference for a *mainline* Arizona
machine driver. Differences from the downstream pacific driver that the
future milestone must reconcile:

| aspect | pacific (downstream) | tm2 (mainline) |
|---|---|---|
| MCLK | 24 MHz via `exynos5_audio_set_mclk` PMU write or `"mclk"` clock (`:48-52`, `:1710-1713`) | `MCLK_RATE 24000000U` via clock API (`:23`, `:40-54`) |
| FLL1 | REFCLK ← NONE then FLL1 ← MCLK1 (`:1717-1755`) | REFCLK ← MCLK1 **and** FLL1 ← MCLK1 (`:40-54`) |
| SYSCLK rate | 49.152 MHz (`:106-109`) | 147456000 / 135475200 families (`:109-117`) |
| API | legacy `snd_soc_codec_*`, codec pointer in priv | component API, DAI links carry `dai_fmt` |
| codec DAI names | `vegas-aifN` | `wm5110-aifN` |
| amp | none (on-codec SPKOUT) | `max98504` extra codec |
| mic bias GPIO | `/audio_pdata` sub_mic_bias_gpio | `mic-bias-gpios` in codec node |

---

## 5. Left out, and why

Downstream codec-node properties with **no mainline parser** (mainline
`arizona.c`/`arizona-jack.c`/`wm8998.c` never read them; keeping them would
be dead DT data, and dt-schema would reject most):

| stock property (live_fdt.dts:…) | value | why not ported |
|---|---|---|
| `wlf,micbias1`/`wlf,micbias2` `:1986,1993` | `<0xaf0 0 1 0 0>` 5-cell | downstream `arizona` (extcon) parser only; mainline micbias config is register-default |
| `wlf,micd-ranges` `:1999` | 10 cells | not parsed by mainline arizona-jack (mainline uses `wlf,micd-det-debounce`+fixed thresholds); no binding |
| `wlf,micd-dbtime` `:1975` | `<0x01>` | mainline binding enum is `[2, 4]` (`extcon yaml:78-83`); stock value 1 is out of range — cannot be expressed |
| `wlf,hpdet-channel` `:1994` | `<0x00>` | mainline binding range is 1-2 (`extcon yaml:20-27`); 0 invalid (and 0 ≡ default HPDETL anyway) |
| `wlf,init-mic-delay` `:1983` | `<0x1e>` | downstream-only |
| `wlf,hs-mic` `:2002` | `<0x03>` | downstream-only |
| `wlf,use-jd-gpio` / `wlf,jd-gpio-nopull` `:1989,1994` | booleans | downstream-only (mainline has `wlf,use-jd2` instead) |
| `wlf,jd-wake-time` `:2022` | `<0x1388>` | downstream-only |
| `wlf,micd-open-circuit-declare` `:1993` | `<0x01>` | downstream-only |
| `wlf,micd-pol-gpio` `:1997` | `<0x00>` (null) | downstream-only; mainline models polarity via `wlf,micd-configs` cell 3 |
| `wlf,moisture-det-channel` `:2001` | `<0x01>` | downstream-only |
| `wlf,hpdet-moisture-imp` `:2004` / `wlf,hpdet-short-circuit-imp` `:2007` / `wlf,hpdet-ext-res` `:2020` | `<0x7d0>` / `<0x03>` / `<0x0b>` | downstream-only impedance calibration |
| `samsung,check-transdone-int` (bus) `:1972` | — | downstream hsi2c quirk, no mainline user |

Also not in this milestone (out of scope per the brief):

- the **sound node** itself (no machine driver to bind; AIF2/AIF3 voice/BT
  links, EAX links, HDMI audio path);
- `mixer-paths = "mixer_paths_rev09.xml"` (`live_fdt.dts:5346`) — Android
  userspace config, not DT-relevant for mainline;
- the stock `audio-ctl` pinctrl group (see §1.3) — will be added with the
  machine driver as a `mic-bias-gpios`-style property;
- MCLK2 (32 kHz) wiring — the live tree does not document its source;
  mainline `arizona-core.c` accepts a missing `mclk2` clock.

## 6. Verification performed

- Full fragment build: `bash kernel/kbuild-mainline.sh --fragment
  gts28ltexx_m6.config` — exit 0 (arm32 zImage + all gts28ltexx DTBs +
  modules; arm64 non-regression OK).
- Explicit DTB target `make … samsung/exynos5433-gts28ltexx-m6.dtb` — OK;
  decompiled DTB contains `wlf,wm1814` and `samsung,exynos5433-i2s`, and the
  corrected values (`wlf,dmic-ref = <0x02 0x01 0x03 0x00>`,
  `wlf,micd-timeout-ms = <0x3e8>`, `wlf,micd-software-compare`).
- `make CHECK_DTBS=y samsung/exynos5433-gts28ltexx-m6.dtb` (dtschema 2026.9
  in the container): **zero findings on any m6 node** (wm1814 codec, hsi2c_3,
  i2s0, the three pinctrl groups). Remaining findings are all pre-existing,
  identical on the m2/m3/m5 DTBs (see DT_M2.md/DISPLAY_M3.md): root
  `compatible` not in `samsung-boards.yaml`, `xxti` fixed-clock
  `clock-frequency`, usb `vdd10/vdd33-supply` (SoC dtsi), `sec-log`
  compatible, pcie `interrupt_provider` (SoC dtsi:1965).
- `.config` audit: all fragment symbols `=y` except `SND_SOC_WM8998` — see
  §2 for why that one is structurally unreachable from a fragment.

---

## 7. Machine driver (6b)

**Scope.** Milestone 6b adds the sound card: a mainline ASoC machine driver
for the I2S0 ↔ WM1814 AIF1 link, its Kconfig/Makefile entries, a DT binding
and the `sound` node. It is **build-tested only** (never run on the device).
The source for every value is the downstream
`src/kernel_universal5433/sound/soc/samsung/pacific_arizona.c`
(line numbers below are from that file). For this board it is built with
`CONFIG_SND_SOC_SAMSUNG_PACIFIC_WM1814=y`, `CONFIG_MFD_VEGAS=y` and
`CONFIG_MFD_FLORIDA` unset (`lineage_gts28ltexx_defconfig:2551-2552,3074`),
so the `#else` (`WM5102_*`) branch of `pacific_start_sysclk` is the one that
runs. The structure follows the mainline `tm2_wm5110.c`.

Files (kernel tree `src/linux-6.12`):

- `sound/soc/samsung/gts28_wm1814.c` — the driver (module `snd-soc-gts28-wm1814`)
- `sound/soc/samsung/Kconfig` — `SND_SOC_SAMSUNG_GTS28_WM1814` (tristate;
  depends on `SND_SOC_SAMSUNG && MFD_ARIZONA && MFD_WM8998 && I2C`; selects
  `SND_SOC_WM8998` and `SND_SAMSUNG_I2S`). Selecting `SND_SOC_WM8998` also
  turns on the promptless `SND_SOC_ARIZONA` (§2), so the codec component
  and `snd-soc-arizona` are finally built.
- `sound/soc/samsung/Makefile` — `snd-soc-gts28-wm1814-y` + `obj-` line
  (the file's two-line convention)
- `Documentation/devicetree/bindings/sound/samsung,gts28-wm1814.yaml`
- `arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m6.dtsi` — `sound` node
- `arch/arm/configs/gts28ltexx_m6.config` —
  `CONFIG_SND_SOC_SAMSUNG_GTS28_WM1814=m`

### 7.1 What is implemented

| item | value | source |
|---|---|---|
| compatible | `samsung,gts28-wm1814` | new; stock `samsung,pacific-arizona` (`live_fdt.dts:5345`) has no mainline binding |
| DT properties | `samsung,model`, `samsung,audio-cpu = <&i2s0>`, `samsung,audio-codec = <&wm1814>`, `clocks = <&pmu_system_controller 0>` / `clock-names = "mclk"` | stock sound node `live_fdt.dts:5344-5352`, parsed `:2050`, `:2057-2075`; property names as in mainline `samsung,arndale.yaml` |
| card name | `samsung,model = "wm1814"` (ALSA card id `wm1814`) | TM2 precedent `model = "wm5110"` (`exynos5433-tm2-common.dtsi:126`); downstream name was "Pacific WM1814 Sound" (`:1996`) |
| DAI link | one: `playback-pri` (stream `playback-pri`), CPU `samsung-i2s` (I2S0 primary DAI, also the PCM platform), codec `wm8998-aif1` | `pacific_wm1814_dai[0]`, `:1214-1219`; `vegas-aif1` → mainline `wm8998-aif1` (§4.2) |
| format / clock roles | `I2S \| NB_NF \| CBP_CFP` (= downstream `CBM_CFM`): codec provides BCLK/LRCLK; set once through `dai_link.dai_fmt` | `:1001-1013` |
| CPU DAI clocks (`hw_params`) | `SAMSUNG_I2S_CDCLK, 0, SND_SOC_CLOCK_IN`; `SAMSUNG_I2S_OPCLK, 0, SAMSUNG_I2S_OPCLK_PCLK` | `:1019-1031` (downstream passes `MOD_OPCLK_PCLK` = `3 << 30`; mainline takes the selector 3 and shifts it, `i2s.c:523-526` — same I2SMOD value) |
| MCLK1 | 24 MHz (`GTS28_MCLK_RATE`) | `PACIFIC_DEFAULT_MCLK1`, `:51` |
| FLL1 | REFCLK ← none, then FLL1 ← MCLK1 24 MHz → 49.152 MHz | `pacific_start_sysclk`, `:1740-1752` |
| SYSCLK | ← FLL1 at 49.152 MHz (= 48000 × 1024); AIF1 clocked from SYSCLK; both set in `late_probe` | `:106-107`, `:1627-1633`, `:903-906` |
| FLL1 / MCLK lifetime | started when the codec DAPM context leaves `BIAS_OFF` (→ `STANDBY`), stopped at `BIAS_OFF`; the sound-node MCLK is enabled around it | `pacific_set_bias_level` `:1829-1856`, `pacific_stop_sysclk` `:1803-1827`, MCLK `:1719-1721`, `:1820-1821` |
| widgets | `HP` (headphone), `SPK` (speaker), `Main Mic` (no event) | `wm1814_dapm_widgets[]`, `:737-738`, `:743` |
| routes | `HP ← HPOUTL/HPOUTR`; `SPK ← SPKOUTLN/LP/RN/RP`; `Main Mic ← MICBIAS2`, `IN1BL ← Main Mic` | `pacific_wm1814_dapm_routes[]`, `:861-872` |
| controls | pin switches `HP Switch`, `SPK Switch`, `Main Mic Switch` | `pacific_controls[]`, `:686-687`, `:691` |
| PM | `snd_soc_pm_ops` | `:2116` |

FLL2/ASYNCCLK are **not** used: they only clock AIF2 (modem, `:908`,
`:1129-1170`), which is left out; so the downstream `ASYNCCLK ← FLL2`
(`:895-898`, `:1635-1640`) and the FLL2 stop (`:1814-1818`) are dropped.

### 7.2 Deviations from §3/§4 and why

1. **Bias test.** Downstream tests `card->dapm.bias_level` and then
   overwrites it with the codec's level (`:1840`, `:1852`) — a hack that
   breaks the core's own bias bookkeeping. The driver tests the codec
   context's `dapm->bias_level`, which still holds the old level while the
   card callback runs (`soc-dapm.c:721-748`); same behaviour (FLL1 starts on
   OFF→STANDBY, before DAPM powers the codec's SYSCLK widget).
2. **SYSCLK applied once.** Downstream re-applies SYSCLK/AIF clocking on
   every AIF1 `hw_params` (`pacific_set_media_clocking`, `:884-914`, called
   `:999`); its values never change, so the driver sets them once in
   `late_probe`. With SYSCLK = 49.152 MHz the codec constrains AIF1 to the
   48 kHz family (`arizona.c` `arizona_startup`), as downstream; TM2's
   per-rate 147.456/135.4752 MHz switch is not used (WM8998 class, spec
   §4.5).
3. **Format** is set through `dai_link.dai_fmt` (mainline idiom) instead of
   `snd_soc_dai_set_fmt` in `hw_params`; same value on both sides.
4. **FLL1 reference.** Kept as downstream (REFCLK ← `ARIZONA_FLL_SRC_NONE`),
   not TM2's REFCLK ← MCLK1. It is *not* a no-op in mainline:
   `arizona_init_fll()` defaults the reference to the 32 kHz source (MCLK2),
   which this board does not describe; clearing it makes FLL1 run from
   MCLK1 alone (`arizona_enable_fll`, `else if (fll->sync_src >= 0)`
   branch). Downstream passes `ARIZONA_CLK_SRC_MCLK1` as the FLL source; it
   equals `ARIZONA_FLL_SRC_MCLK1` (0).
5. **MCLK in the sound node is redundant in mainline, kept as specified.**
   Mainline `arizona.c` already enables the codec's own `mclk1` clock
   whenever an FLL references MCLK1 (`arizona_set_fll_clks`,
   `arizona.c:2380-2414`), which is why TM2 has no sound-node clock. The
   driver's `mclk` is optional (`devm_clk_get_optional`) and only adds a
   reference count; dropping it later is two DT lines plus the clk calls.
6. **§4.3 wording.** `wlf,out-mono = <0 1 1 0 0 0>` makes OUT2 (LINEOUT)
   and OUT3 (EPOUT) mono; OUT4 (SPKOUT) is **stereo** (index 0 = OUT1,
   `arizona.c:246-249`), matching the stock mixer config ("SPK(stereo)",
   `lineage/.../mixer_paths_0.xml:22-25`). The `SPK` routes use both sides.

### 7.3 Left out

- Links 1-7: `baseband` (AIF2/modem), `bluetooth sco` (AIF3),
  `playback-sec` (`samsung-i2s-sec`), `playback-eax0..3` (no mainline
  `samsung-eax`), and therefore FLL2/ASYNCCLK/SYSCLK_2.
- Widgets/routes `RCV`/`EPOUT`, `VPS`/`LINEOUT`, `HDMI`/`HDMIL`/`HDMIR`,
  `Headset Mic` (MICBIAS1 → IN2B) and `Sub Mic` (MICBIAS3 → IN1BR with the
  gpr3-2 bias GPIO, `:624-641`; the pin is claimed by `sd1_bus4`, §1.3).
- Jack detection: `snd_soc_component_set_jack()` is never called, so
  `arizona-jack` stays idle (HP is powered whenever routed).
- Downstream extras: HP impedance controls/hpdet and micd callbacks,
  voice-control/ez2ctrl input device and sysfs class, wake lock,
  `ignore_pmdown_time` (`:1599`), `ignore_suspend` pins (`:1609-1625`),
  the `channels_max` copy (`:1595-1596`), `suspend_post`/`resume_pre`
  (AIF1 forced slave, MCLK2 switch, `:1893-1944`), MAX98504 VI-sensing
  startup/shutdown (not on this board).

### 7.4 First-test checklist (device)

The card needs the modules `snd-soc-gts28-wm1814`, `snd-soc-wm8998`,
`snd-soc-arizona` (udev loads them from the `samsung,gts28-wm1814` and
`wm8998-codec` modaliases) on top of the built-in I2S/LPASS/Arizona MFD of
the m6 fragment.

1. **Card present.**
   - `dmesg | grep -iE 'arizona|wm1814|wm8998|asoc|i2s'` — expect
     `arizona <bus>-001a: WM1814 revision <X>` (`arizona-core.c:1247`). A
     transient `ASoC: CPU DAI samsung-i2s not registered` or `CODEC DAI
     wm8998-aif1 not registered` (`soc-core.c:1198/1209`, info level) is
     probe ordering and harmless if the card appears. Not expected:
     `ASoC: failed to instantiate card`, `Failed to set SYSCLK`,
     `Failed to set AIF1 clock`.
   - `cat /proc/asound/cards` and `aplay -l` — expect card `wm1814`,
     device 0 `playback-pri wm8998-aif1-0`; `arecord -l` lists the same
     device.
2. **Speaker** (values from `mixer_paths_0.xml:22-25`, `:151-156`,
   `:358-362`):
   ```
   amixer -c wm1814 cset name='SPKOUTL Input 1' AIF1RX1
   amixer -c wm1814 cset name='SPKOUTR Input 1' AIF1RX2
   amixer -c wm1814 cset name='SPKOUTL Input 1 Volume' 30
   amixer -c wm1814 cset name='SPKOUTR Input 1 Volume' 29
   amixer -c wm1814 cset name='Speaker Digital Volume' 126
   amixer -c wm1814 cset name='Speaker Digital Switch' on
   amixer -c wm1814 cset name='SPK Switch' on
   speaker-test -D hw:wm1814,0 -c 2 -r 48000 -F S16_LE -t sine -l 1
   ```
   (`Speaker Digital Switch` defaults to muted: register 0x429/0x42d reset
   value 0x0180 has the mute bit set, `wm8998-tables.c:305/308`.)
3. **Headphone** (`mixer_paths_0.xml:27-30`, `:158-162`, `:364-369`):
   ```
   amixer -c wm1814 cset name='HPOUTL Input 1' AIF1RX1
   amixer -c wm1814 cset name='HPOUTR Input 1' AIF1RX2
   amixer -c wm1814 cset name='HPOUTL Input 1 Volume' 32
   amixer -c wm1814 cset name='HPOUTR Input 1 Volume' 32
   amixer -c wm1814 cset name='HPOUT Digital Volume' 119
   amixer -c wm1814 cset name='HPOUT Digital Switch' on
   amixer -c wm1814 cset name='HP Switch' on
   speaker-test -D hw:wm1814,0 -c 2 -r 48000 -F S16_LE -t sine -l 1
   ```
   Use 48 kHz-family rates only (8/16/32/48/96 kHz): 44.1 kHz is refused
   by the codec's constraint (§7.2 item 2); use `plughw:` for 44.1 kHz
   files. Mixer input volumes: 32 = 0 dB; digital volumes: 128 = 0 dB,
   0.5 dB/step.
4. **Main mic** (`mixer_paths_0.xml:246-250`, `:442-446`; the stock path
   goes IN1L → LHPF1 (high-pass) → AIF1TX1/2, here IN1L feeds AIF1TX
   directly for a first test):
   ```
   amixer -c wm1814 cset name='IN1L Mux' B
   amixer -c wm1814 cset name='IN1L Volume' 30
   amixer -c wm1814 cset name='IN1L Digital Volume' 128
   amixer -c wm1814 cset name='AIF1TX1 Input 1' IN1L
   amixer -c wm1814 cset name='AIF1TX2 Input 1' IN1L
   amixer -c wm1814 cset name='Main Mic Switch' on
   arecord -D hw:wm1814,0 -c 2 -r 48000 -f S16_LE -d 5 /tmp/mainmic.wav
   ```
   To reproduce the stock high-pass path instead: `LHPF1 Mode` =
   `High-pass`, `LHPF1 Input 1` = `IN1L`, `LHPF1 Input 1 Volume` = 32,
   `AIF1TX1 Input 1` = `AIF1TX2 Input 1` = `LHPF1` (stock mode and
   coefficients: `mixer_paths_0.xml:58` and `:80`, `240 58`).
5. **If there is no sound / recording hangs**: `dmesg` for
   `FLL1: Timed out waiting for lock` (MCLK1/CLKOUT not running, check
   `grep clkout /sys/kernel/debug/clk/clk_summary` during playback: enable
   count ≥ 1, rate 24000000), `Failed to start FLL1`, `Failed to set I2S
   CDCLK/OPCLK`; DAPM state is under `/sys/kernel/debug/asoc/wm1814/`.
   Stock controls with no mainline equivalent (`SPKOUT EDRE Switch`,
   `HPOUT DRE/EDRE Switch`, `HP1 Bias`, `DAC Comp`, `FRF Coefficients`) are
   simply absent.

### 7.5 Verification performed (build only)

- `bash kernel/kbuild-mainline.sh --fragment gts28ltexx_m6.config` — exit 0
  (zImage 4137496 bytes, arm64 non-regression OK); no compiler, dtc or
  modpost warning outside the pre-existing defconfig "override" notices.
- `.config`: `CONFIG_MFD_WM8998=y`, `CONFIG_SND_SOC_SAMSUNG_GTS28_WM1814=m`,
  `CONFIG_SND_SOC_WM8998=m`, `CONFIG_SND_SOC_ARIZONA=m` — the §2 blocker is
  gone. `modules.tar.xz` carries `snd-soc-gts28-wm1814.ko`
  (`alias=of:N*T*Csamsung,gts28-wm1814`), `snd-soc-wm8998.ko`,
  `snd-soc-arizona.ko`.
- Decompiled `exynos5433-gts28ltexx-m6.dtb`: `sound` node with
  `samsung,gts28-wm1814`, phandles resolving to `i2s@11440000`, the
  `wlf,wm1814` codec and the PMU (`clocks = <pmu 0>`).
- `make W=1 sound/soc/samsung/gts28_wm1814.o` (same container and volume):
  zero warnings. `checkpatch.pl --strict`: 0 errors, 0 warnings, 1 CHECK
  (the `SND_SOC_DAILINK_DEFS` macro layout, identical in `tm2_wm5110.c`).
- `make dt_binding_check DT_SCHEMA_FILES=samsung,gts28-wm1814.yaml`: **not
  run** — the `t715-kbuild` image has no dtschema (`dt-doc-validate not
  found`); earlier milestones installed it ad hoc with pip, which was not
  done here. The YAML parses and mirrors `samsung,arndale.yaml`.
