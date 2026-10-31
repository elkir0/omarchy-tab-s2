# Milestone 3 — Native display (DECON + MIC + MIPI-DSI + S6E3HA2)

SM-T715 (Galaxy Tab S2 8.0 LTE, Exynos5433, board `gts28`) — mainline
Linux 6.12, arm32 (LPAE).  This milestone replaces the bootloader
framebuffer (simpledrm, milestone 1) with the real display pipeline:
DECON → MIC → MIPI-DSI → Samsung S6E3HA2 1536×2048 AMOLED panel.

Build-tested only — no device was touched.  Every value below traces to
the stock device tree (`dumps/live_fdt.dts`), Samsung's downstream
kernel (`src/kernel_universal5433`), or a mainline file; nothing
is invented.

## Files

| File | What |
|---|---|
| `src/linux-6.12/drivers/gpu/drm/panel/panel-samsung-s6e3ha2-tabs2.c` | new panel driver (dynamic-AID brightness, backlight 0..255) |
| `src/linux-6.12/drivers/gpu/drm/panel/panel-samsung-s6e3ha2-tabs2-dimming.h` | brightness tables + dynamic-AID gamma computation (private to the driver, shared with the host test) |
| `boot/tests/test_s6e3ha2_tabs2_gamma.py` | host test: header vs a Python port of the stock algorithm |
| `src/linux-6.12/drivers/gpu/drm/panel/Kconfig` | `DRM_PANEL_SAMSUNG_S6E3HA2_TABS2` entry |
| `src/linux-6.12/drivers/gpu/drm/panel/Makefile` | `obj-$(CONFIG_DRM_PANEL_SAMSUNG_S6E3HA2_TABS2)` line |
| `src/linux-6.12/Documentation/devicetree/bindings/display/panel/samsung,amoled-mipi-dsi.yaml` | `samsung,s6e3ha2-tabs2` compatible + `vddr-supply` |
| `src/linux-6.12/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m3.dtsi` | display enablement |
| `src/linux-6.12/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-m3.dts` | board file (m2 + m3) |
| `src/linux-6.12/arch/arm/boot/dts/samsung/Makefile` | one `dtb-$(CONFIG_ARCH_EXYNOS) += …-m3.dtb` line |
| `src/linux-6.12/arch/arm/configs/gts28ltexx_m3.config` | config fragment |
| `docs/hardware/DISPLAY_M3.md` | this document |

## Panel mode — sources

`live_fdt.dts:1045-1061` (stock panel node `s6e3ha2_qxga`):

| Value | Stock property | live_fdt.dts line |
|---|---|---|
| 1536×2048 | `resolution = <0x600 0x800>` | 1054 |
| refresh 60 | `timing,refresh = <0x3c>` | 1058 |
| size 122×163 mm | `size = <0x7a 0xa3>` | 1057 |
| h-porch ⟨1,1,1⟩ | `timing,h-porch = <1 1 1>` | 1060 |
| v-porch ⟨15,1,1⟩ | `timing,v-porch = <0xf 1 1>` | 1055 |
| DSI HS clock | `timing,dsi-hs-clk = <0x400>` (1024 MHz) | 1046 |

Porch mapping `[hbp, hfp, hsa]` / `[vbp, vfp, vsa]`:
`decon_dt_exynos5430.c:460-471`.

→ mode: `clock = 190682 kHz` (1539 × 2065 × 60 = 190 682 220 Hz),
hsync 1537/1538, htotal 1539, vsync 2049/2050, vtotal 2065.

## DSI clock arithmetic — stock 1024 MHz vs mainline 512 MHz

Stock `timing,dsi-hs-clk = <1024>` is a **lane-rate** request in MHz.
Downstream `dsim_reg_calculate_pms` (`dsim_reg_5430.c`) halves it
(`target = hs_clk / 2 = 512 MHz`) then solves for PLL PMS and writes
PLLCTRL with **(p=3, m=64, s=0)** → VCO 512 MHz; per-lane DDR rate =
2 × 512 = 1024 Mbps, byte clock = 512/8 = 64 MHz.

Mainline `samsung_dsim_pll_find_pms(fin=24 MHz, fout=512 MHz)`
(`drivers/gpu/drm/bridge/samsung-dsim.c`) returns the **same (3, 64, 0)**
— exact: 64 × 24 / 3 = 512, with m ∈ [41, 125] and VCO ∈ [500, 1500] MHz
in range.  Requesting `burst = <1024000000>` instead would find
(2, 85, 0) = 1020 MHz (m = 128 would be needed for exact 1024·…, capped
at 125) — a different PLLCTRL value than stock programs.  Hence:

```
samsung,burst-clock-frequency = <512000000>;   /* PMS (3,64,0), VCO 512 MHz */
samsung,esc-clock-frequency   = <16000000>;    /* byte 64 MHz / 4 */
samsung,pll-clock-frequency   = <24000000>;    /* fin = OSCCLK */
```

These are byte-for-byte the TM2 upstream values for the same DSI block
(`exynos5433-tm2-common.dtsi:348-351`).

**Esc clock**: stock DT asks for 7 MHz (`esc_clk = <0x6acfc0>`,
live_fdt.dts:1037).  Mainline computes esc_div = DIV_ROUND_UP(byte, esc)
and bumps the divider if esc > 20 MHz — 7 MHz would also work, but 16 MHz
is the same-SoC upstream-proven value, so it was kept; the escape clock
only affects the LP communication rate, not the display data path.

## Pixel clock — cmu_disp assigned clocks

Mainline DECON never calls `clk_set_rate`; the divider programming must
come from DT `assigned-clocks`.  Modelled on TM2's `&cmu_disp`
(`exynos5433-tm2.dts:25-53`) **minus all five decon_tv / DSD entries**
(no HDMI on this board), parents verbatim from TM2.

Rates (TM2 uses 250/400 MHz for its TV path; ours differs):

| Clock | Value | Why |
|---|---|---|
| `CLK_FOUT_DISP_PLL` | 1500 MHz | exact `exynos5433_pll_rates[]` entry (clk-exynos5433.c:748, PMS 250/4/0) |
| `CLK_DIV_SCLK_DECON_VCLK_DISP` | 187.5 MHz | 1500/8; 3-bit divider (clk-exynos5433.c:2732); → ~59 Hz refresh |

The panel mode wants 190.68 MHz; the PLL table has no ~190.68 MHz
entry.  187.5 MHz gives 187.5e6 / (1539 × 2065) = 59.0 Hz; the next
entry up, 1600/8 = 200 MHz, gives 63 Hz.  59 Hz is the closest below
60 and was chosen (an AMOLED self-refresh panel tolerates a small
refresh mismatch; overshooting would violate the 60 Hz mode).

## Panel init sequence — transcription with sources

`ldi_init` order and every SEQ array come from
`s6e3ha2_tabs2_mipi_lcd.c:1124-1181` + `s6e3ha2_tabs2_param.h`
(line numbers in the table below are param.h lines).  The driver
writes them with `mipi_dsi_dcs_write_buffer` in the stock order:

| Step | Bytes | Source (param.h) |
|---|---|---|
| Sleep out `0x11`, 5-6 ms | — | lcd.c `ldi_init` step 7-8 |
| Test key F0 on | `F0 5A 5A` | 34-42 |
| Test key FC on | `FC 5A 5A` | 54-62 |
| Interface single-DSI 1/2 | `F2 67`, `F9 09` | 64-72 |
| wait 120 ms | — | lcd.c step 10 |
| Panel reads: ID, code, coordinate, MTP, ELVSS, TSET | `04` `D6` `A1` `C8` `B6` `B8` | lcd.c step 11 + probe reads, see *Brightness and gamma* |
| TE on | `35 00` | 74-77 |
| TSP hsync | `BD 11 01 02 16 02 16` | 79-82 |
| Pentile | `C0 00 0F D8 D8` | 84-87 |
| POC 1/2 | `B0 20`, `FE 08` | 89-97 |
| PCD det low | `CC 5C` | 180-183 |
| ERR_FG | `ED 44` | 99-102 |
| TE start | `B9 10 07 FF 00 09` | 185-188 |
| Column/page window | `2A 00 00 05 FF`, `2B 00 00 07 FF` | 104-112 |
| Brightness | see *Brightness and gamma* | lcd.c `update_brightness` |
| Test key FC off | `FC A5 A5` | 59-62 |
| Test key F0 off | `F0 A5 A5` | 39-42 |
| Display on `0x29` | — | lcd.c `ldi_enable` |

Disable: `0x28` → `0x10` → 120 ms (`ldi_disable`).

### Power sequencing

`decon_board_gts28` (live_fdt.dts:1063-1085): VDD3→VDDR→VCI on,
10-11 ms; reset (active-low) high 5-6 ms → low 5-6 ms → high 5-6 ms;
off = reset asserted + rails disabled.

### Supplies / reset

| Rail | Regulator | Stock name |
|---|---|---|
| vdd3 | ldo39 | VDD3_1.8V |
| vddr | ldo37 | VDDR_1.6V |
| vci | ldo25 | VCI_3.0V |

Reset: `gpg0-0` **active low** (live_fdt.dts:1074-1076).

## Brightness and gamma (dynamic AID)

First light showed the console geometry right but the picture very dark
and purple-tinted.  Compared with stock `update_brightness()`, the first
version of the driver (a) never wrote the per-level gamma `0xCA`, (b)
wrote zeros into bytes 3..22 of `0xB6`, where stock sends back the
panel's own read-back values, (c) sent AID `B2 DF 20` for brightness 122
where stock sends `inter_aor_cmd[122]` = `B2 0D 30` (the AID table is
indexed by brightness, not by level), and (d) never wrote TSET `0xB8`.
The driver now does what stock does.  Stock file references below are
relative to `src/kernel_universal5433/drivers/video/exynos/panels/`
(`lcd.c` = `s6e3ha2_tabs2_mipi_lcd.c`, `param.h` =
`s6e3ha2_tabs2_param.h`, `daid_tabs2.h` = `dynamic_aid_s6e3ha2_tabs2.h`).

Code layout: everything that is pure computation (tables, MTP decode,
dynamic AID, AID/ELVSS/VINT/ACL choices) is in
`panel-samsung-s6e3ha2-tabs2-dimming.h`, included only by the driver;
the large tables in it were extracted mechanically from the stock headers
(every row carries its stock line).  It only needs `<linux/types.h>`,
`<linux/math64.h>` and `<linux/errno.h>`, so the host test compiles the
very same file (see *Validation*).

### What is read from the panel

| Reg | Bytes | Stock reader | Used for |
|---|---|---|---|
| `04` | 3 | `s6e3ha2_read_id`, lcd.c:511-523 | ID, logged; a failure skips the other reads (stock: "panel is not connected well") |
| `D6` | 5 | `s6e3ha2_read_code`, lcd.c:525-535 | logged only |
| `A1` | 4 | `s6e3ha2_read_coordinate`, lcd.c:495-509 | logged only |
| `C8` | 44 | `s6e3ha2_read_mtp`, lcd.c:537-557 | MTP → gamma; bytes 40-43 = manufacture date |
| `B6` | 22 | `s6e3ha2_read_elvss`, lcd.c:559-570 | bytes 3..22 of every `0xB6` write |
| `B8` | 8 | `s6e3ha2_read_tset`, lcd.c:572-585 | `0xB8` write, last byte replaced by the temperature |

Protocol, as `s6e3ha2_read()` (lcd.c:413-450) over `s5p_mipi_dsi_rd_data()`
(`decon_display/decon_mipi_dsi.c:349-354`): set maximum return packet
size = length, then DCS read (`MIPI_DSI_DCS_READ`, all lengths > 2),
up to 5 tries until exactly *length* bytes come back.  Mainline:
`mipi_dsi_set_maximum_return_packet_size()` + `mipi_dsi_dcs_read()`.

When: stock reads them once at probe (lcd.c:1734-1741, same order) with
test key F0 open, from a panel the bootloader already initialised.  Under
DRM the link is first usable in `prepare`, so the reads run at `ldi_init`
step 11 "Module Information READ" (lcd.c:1146-1147, where stock itself
re-reads the ID at every power-on): after reset, sleep-out, interface
setting and the 120 ms wait, with keys F0 **and** FC open (both are open
at that point of `ldi_init`).  The ID is read at every prepare; the other
registers until they have been read once.  They are therefore read right
after a reset, before the driver has written `0xB6`/`0xB8`.

### How the gamma is computed

`init_gamma_table()` (lcd.c:841-944) → `dynamic_aid()` (dynamic_aid.c:424-503),
ported function by function, int/s64 types and `div_s64`/`div64_s64`
truncation as in stock:

1. **MTP decode**, `init_mtp_data()` lcd.c:797-823: bytes 0-5 = V255
   R/G/B (sign in bit 0 of bytes 0/2/4, magnitude in 1/3/5); bytes 6-29 =
   V203…V3 (bit 7 sign); VT R/G = low/high nibble of byte 33, VT B = byte
   34.  → 30 signed offsets `mtp[iv][c]`.
2. **Point voltages**, `calc_point_voltages()` dynamic_aid.c:58-125, with
   VREG = 6800 × 100 (`VREG_OUT_X1000` daid_tabs2.h:352, `MUL_100`
   dynamic_aid.c:434) and VREF_H = 0 (`init_dynamic_aid()` lcd.c:777-795
   never sets it; `lcd_info` is kzalloc'd, lcd.c:1646):
   VT = VREG − VREG·`vt_voltage_value[mtp]`/860;
   V255 = VREG − VREG·(0x100 + mtp + 72)/860;
   V203…V11 = VT − (VT − V_next)·(0x80 + mtp + 64)/320;
   V3 = VREG − (VREG − V11)·(0x80 + mtp + 64)/320
   (`gamma_default`, `gamma_formula`, `vt_voltage_value`: daid_tabs2.h:436-466).
3. **Output voltages** of all 256 grays, linear between points,
   `calc_output_voltages()` dynamic_aid.c:127-172 (int arithmetic).
4. **Per level** (66 levels `IBRIGHTNESS_2NT` … `IBRIGHTNESS_500NT`,
   daid_tabs2.h:21-89): target luminances = `brightness_base_table[level]`
   (daid_tabs2.h:468-535) × gamma 2.15 curve (2.20 for 360/500 nit,
   daid_tabs2.h:537-604; curves dynamic_aid_gamma_curve.h:459-562),
   `calc_l_values()` :231-258; nearest gray on the 360-nit 2.20 lookup
   curve (`init_l_lookup_table()` :189-206, `min_diff_gray()` :208-229)
   plus `offset_gradation` (daid_tabs2.h:732-800), `calc_m_gray_values()`
   :260-289; the voltages at those grays, `calc_m_rgb_voltages()` :291-326;
   register = (t1 + 1)·den / t2 − num − mtp + `offset_color`
   (daid_tabs2.h:802-870), clamped to 0..255 (V255 not clamped above),
   `calc_gamma()` :328-389.
5. **0xCA layout**, lcd.c:880, 896-914: `CA`, V255 R/G/B as (bit 8, low
   byte) pairs, then V203 … V3 and VT one byte per colour, two trailing
   `00` → 36 bytes (`GAMMA_PARAM_SIZE`, param.h:4, 114-120).

Only additions: three guards where stock would read out of bounds or
divide by zero on nonsensical MTP data (VT index outside
`vt_voltage_value[0..15]` → `-ERANGE`; a gray index outside 0..255 →
`-ERANGE`; t2 = 0 → `-EDOM`).  The driver then logs
`dynamic AID: MTP outside the stock tables` and does not write `0xCA`.
The gray-index guard cannot fire with the stock tables (the gray indices
depend only on static tables: 3..255 for every level).

Self-checks from the stock data itself: `gamma_default` relocated is
exactly the stock power-on template `SEQ_GAMMA_CONTROL_SET`; the 360-nit
(reference) level comes out as that template too for any realistic MTP
(the MTP terms cancel at the reference level; only extreme synthetic
offsets drift it by a step or two), while lower levels depend on the MTP.

### Brightness table

Backlight device `s6e3ha2_tabs2`, `max_brightness` 255, default 122
(`MAX_BRIGHTNESS`/`DEFAULT_BRIGHTNESS`, lcd.c:55-56).  Brightness → level
via `brightness_table[]` (daid_tabs2.h:92-350); 63 of the 66 levels are
reachable (24 nit, 34 nit and the 500-nit HBM level are not):

```
brightness:nit   0-2:2 3:3 4:4 … 17:17 18-19:19 20:20 21:21 22:22 23-24:25
25:27 26:29 27:30 28:32 29:37 30:39 31:41 32-33:44 34-35:47 36-37:50
38-39:53 40-41:56 42-44:60 45-47:64 48-50:68 51-53:72 54-57:77 58-60:82
61-64:87 65-68:93 69-72:98 73-77:105 78-81:111 82-87:119 88-92:126
93-98:134 99-105:143 106-111:152 112-119:162 120-126:172 127-134:183
135-143:195 144-151:207 152-161:220 162-171:234 172-182:249 183-194:265
195-206:282 207-219:300 220-231:316 232-243:333 244-255:360
```

Each update sends, in stock order (`update_brightness()` lcd.c:1087-1122),
only the parts that changed (all of them when forced):

`F0 5A 5A` → `CA` gamma[level] → `B2` `inter_aor_cmd[brightness]` →
`B6` MPS, `ELVSS_TABLE[elvss level]`, 20 read-back bytes → `F4 AB 21` →
`F7 03`, `F7 00` → ACL `55 xx` + `B5 xx` → `B8` 7 read-back bytes + 25 →
`53 00` → `F0 A5 A5`.

| brightness | level | nit | AID | caps | ELVSS level (byte) | ACL |
|---|---|---|---|---|---|---|
| 0 | 0 | 2 | `B2 F3 70` | off (`8C`) | 0 (`0D`) | 15 % |
| 30 | 28 | 39 | `B2 9E 50` | off | 12 (`14`) | 15 % |
| 31 | 29 | 41 | `B2 7A 50` | on (`9C`) | 13 (`15`) | 15 % |
| 62 | 41 | 87 | `B2 FE 20` | on | 19 (`19`) | 15 % |
| 102 | 49 | 143 | `B2 04 30` | on | 22 (`17`) | 15 % |
| **122** | 52 | 172 | `B2 0D 30` | on | 25 (`15`) | 15 % |
| 126 | 52 | 172 | `B2 DF 20` | on | 25 (`15`) | 15 % |
| 183 | 59 | 265 | `B2 D6 00` | on | 32 (`12`) | 15 % |
| 244 | 64 | 360 | `B2 EF 00` | on | 37 (`0D`) | 15 % |
| 255 | 64 | 360 | `B2 67 00` | on | 37 (`0D`) | off (`55 00`, `B5 40`) |

AID varies within a level (120…126 all use the 172-nit gamma, AID
0x3025 → 0x20DF): stock's fine steps.  CAPS is off up to 39 nit
(`LEVEL_IS_CAPS_OFF`, lcd.c:48; `MPS_TABLE` param.h:237), VINT is always
`0x21` (param.h:313-321), HBM always off.

When it is sent: in `prepare` (ldi_init step 13, forced), again right
after display-on (forced, as `s6e3ha2_power_on()` lcd.c:1228-1232), then
on each `brightness` write while the panel is on (`ldi_enable`).

### Deviations from stock (and why)

- Panel reads at prepare step 11 with F0+FC open instead of at probe with
  F0 only — the DSI link does not exist at probe under DRM; reading right
  after reset also returns the panel's own `B6`/`B8` values.
- `max_brightness` 255 instead of 355 (`EXTEND_BRIGHTNESS`): 256…354 are
  the same 360-nit level as 255 and 355 is HBM (outdoor boost) — not
  exposed.
- `actual_brightness` returns the brightness, not the candela stock's
  `get_brightness()` returns (lcd.c:1304-1309), so it stays within
  0…max for the backlight class; the candela is in the log line.
- Read failures: stock would send its zero-filled buffers.  Here a failed
  `C8` read means no `0xCA` write, a failed `B6` read sends only
  `B6 MPS ELVSS` (3 bytes), a failed `B8` read sends no TSET.
- The three undefined-behaviour guards above.
- Temperature fixed at the stock default 25 °C (stock takes it from an
  Android-written sysfs node); `siop`/`power_reduce`/`lux` nodes not ported.
- The 100 ns delay between `F7 03` and `F7 00` (taken from the TM2
  driver) is gone; stock has none.

### What to look for in the next boot log

`dmesg | grep -i s6e3ha2`, in this order on the first prepare:

```
ID: xx, yy, zz
code (D6h): .. .. .. .. ..
coordinate (A1h): .. .. .. ..
MTP (C8h, 44 bytes): ..                      <- keep this line
ELVSS (B6h, 22 bytes): .. .. 0b              <- last byte: see below
TSET (B8h, 8 bytes): ..
gamma 172 nit (CAh): ca 00 .. 00 .. 00 .. … 00 00 00 00 00
caps: 1, temperature: 0, elvss: 25, b159c
vint: 21
acl: 2, brightness: 122
temperature: 25, tset: 25
hbm: 0, brightness: 122
brightness=122, bl=52, candela=172
```

then the same block (without the gamma line) after display-on.  Checks:

- The ELVSS read's last byte is the `elvss_base` the stock kernel printed
  on this tablet: `elvss: 22, b179c` (`dumps/dmesg.txt:75`) → `0b`;
  so the `caps/elvss` line should read `b159c` at brightness 122.  The
  `caps/vint/acl/tset/hbm/brightness=` lines use the stock format and can
  be compared with the stock log directly.
- The gamma line must be reproducible offline from the MTP line:
  `python3 boot/tests/test_s6e3ha2_tabs2_gamma.py --mtp <the 44 MTP bytes>`
  prints every level; level 52 (172 nit) must match the logged line.
  (Per-level `dev_dbg` lines exist but `CONFIG_DYNAMIC_DEBUG` is off in
  the m3 config.)
- Failure lines: `read c8h (44 bytes) failed`, `panel is not connected
  well, skipping reads`, `dynamic AID: MTP outside the stock tables`.

### How to test brightness

```
ls /sys/class/backlight/                                  # s6e3ha2_tabs2
cat /sys/class/backlight/s6e3ha2_tabs2/max_brightness     # 255
for b in 0 30 31 62 122 200 255 122; do
    echo $b > /sys/class/backlight/s6e3ha2_tabs2/brightness; sleep 2
done
dmesg | grep -E "brightness=|elvss:|acl:"
```

Each write logs `brightness=N, bl=L, candela=C` (and the ELVSS/ACL lines
when they change).  Expect a visible ramp from 2 nit (0) to 360 nit
(255) with neutral greys at every step; a tint that remains points at the
MTP/gamma lines above.

## Config fragment

`arch/arm/configs/gts28ltexx_m3.config` = m2.config +:

- `CONFIG_DRM_EXYNOS=y` — defconfig has `m`; the DECON/DSI/MIC bools
  demote to the parent's `m` otherwise.
- `CONFIG_DRM_EXYNOS5433_DECON=y`, `CONFIG_DRM_EXYNOS_DSI=y`,
  `CONFIG_DRM_EXYNOS_MIC=y` (already bool-`y` in defconfig, kept explicit)
- `CONFIG_DRM_PANEL_SAMSUNG_S6E3HA2_TABS2=y`
- `CONFIG_BACKLIGHT_CLASS_DEVICE=y` (panel driver depends on it)
- `CONFIG_PHY_EXYNOS_MIPI_VIDEO=y` — provider for `&mipi_phy`
- `CONFIG_CMA=y`, `CONFIG_DMA_CMA=y` — contiguous framebuffer memory
  (exynos_defconfig precedent); size left at default (16 MB)

`CONFIG_PM`-family symbols were checked: `ARCH_EXYNOS` selects the full
chain `EXYNOS_PMU` → `PM_GENERIC_DOMAINS` → `EXYNOS_PM_DOMAINS`, so
`pd_disp` is covered without fragment additions (verified in
out/mainline-m2/.config).

`CONFIG_EXYNOS_IOMMU` is **not** enabled: the decon node carries
`iommus` properties but the driver works without it (CMA buffers are
dma-direct); exynos_defconfig enables it, but adding it grows the kernel
beyond this milestone's scope.  System MMU support can be added when GPU
(m5) lands.

## What was left out — and why

- **mDNIe / DPP / SCC** — stock color pipeline; separate subsystem, out
  of scope.
- **HBM on** (`53 C0`) — stock only at brightness 355 (outdoor mode,
  `EXTEND_BRIGHTNESS`); the backlight here stops at 255, so HBM off is
  always written.
- **ESD / err_fg interrupt** (stock `oled-errfg-gpio` gpb0-4) — needs a
  DSI-read-based recovery path; future work.
- **PCD detection** — `CC 5C` written (matches stock default state), but
  the PCD interrupt is not wired.
- **Partial update / ACL fine control** — stock features tied to
  DECON partial windows and mDNIe; out of scope.
- **Temperature feedback** — stock takes the temperature from a sysfs
  node written by Android; here it stays at the stock default 25 °C
  (TSET byte 25, ELVSS table "above −20 °C").
- **decon_tv / DSD clocks** — HDMI path, not on this board.
- **te-gpios** — not used: DECON's exynos5433 match data is I80_HW_TRG;
  TE arrives via the display-muxed TES pin (gpg0-1, `disp_teson`) and
  `samsung,disp-sysreg`, exactly as upstream TM2 works today.

## First test checklist

1. **Serial console + baseline**: boot the m2 image, confirm console,
   `cat /proc/device-tree/model`.
2. **Probe order / deferrals** (expected, benign): panel waits for DSI
   host; DSI host waits for panel — the `prepare_prev_first` flag
   resolves this.  `dmesg | grep -E "decon|dsi|mic|panel|s6e3ha2"`.
3. **Regulators**: `dmesg | grep -i regulator` — three ldo enables
   (ldo25/37/39) per power-on; no `-EPROBE_DEFER` storm.
4. **Pinctrl**: `cat /sys/kernel/debug/pinctrl/pinctrl@.../pinmux-pins`
   — gpg0-1 shows `disp_teson` function 2; gpg0-0 output.
5. **Clocks**: `cat /sys/kernel/debug/clk/clk_summary` — `disp_pll`
   1500 MHz (PMS 250/4/0), `div_sclk_decon_vclk_disp` 187.5 MHz; DSI
   PLL locked at 512 MHz (`dsi_hs_clk`/byte 64 MHz).
5b. If refresh looks wrong on first light, re-check step 5 first: a
   wrong DECON vclk parent (e.g. `mout_sclk_decon_vclk_user` not
   repointed to `mout_disp_pll`) shows up as a garbled panel.
6. **simpledrm takeover**: `dmesg | grep -i simpledrm` — the firmware
   fb is replaced once exynos-drm binds.
7. **Picture**: brightness should come up at the stock default
   (brightness 122 → 172 nit) with neutral colours; see *Brightness and
   gamma* for the log lines to check and the backlight test.  Expect solid color or console; the AMOLED
   self-refresh tolerates the 59 Hz vs 60 Hz mode mismatch.
8. **TE**: `cat /proc/interrupts | grep -E "decon|TE"` — with I80_HW_TRG
   there is no TE IRQ line; DECON waits on the hardware trigger.

## Validation performed

- Full fragment build: `bash kernel/kbuild-mainline.sh --fragment
  gts28ltexx_m3.config` — exit 0.  zImage 3 057 616 bytes (< 9 MiB
  budget), all five gts28ltexx DTBs (incl. `-m3.dtb`), modules.tar.xz,
  and the ARM64 non-regression phase OK.  Output in
  `out/mainline-m3/`.
- `W=1` build of `panel-samsung-s6e3ha2-tabs2.o` — zero warnings.
- Dynamic-AID brightness (2026-10-28): fragment build exit 0, zImage
  3 522 672 bytes, ARM64 non-regression OK; `W=1` on the panel object
  (driver + dimming header) — zero warnings; object 15.2 KB text.
- `python3 boot/tests/test_s6e3ha2_tabs2_gamma.py` — 15 tests OK.
  It parses the stock tables from the Samsung sources, re-implements
  the stock code in Python (C integer semantics), compiles the kernel
  header unmodified in a harness with the kbuild container's gcc
  (`-Wall -Wextra -Werror -fsanitize=undefined`) and compares: every
  table and constant, the per-brightness choices for 0..255, the ELVSS
  command for all 76 (caps, level) pairs, and the 66 × 36-byte `0xCA`
  tables for 34 synthetic MTP read-backs (29 valid, 5 that stock would
  index out of bounds with, rejected identically).  Stock-derived sanity
  values: gamma curves are (i/255)^2.15 / ^2.20 within ±1; default
  gamma relocates to `SEQ_GAMMA_CONTROL_SET`; the seven brightness /
  ELVSS points of the stock log (`dumps/dmesg.txt` "lcd panel:"
  lines) match.  Bug injection: 16 mutations of the header, 14 caught;
  the 2 survivors (DIV_100 rounding, `min_diff_gray` tie-break) are
  equivalent — they only affect gray indices that depend on static
  tables alone and come out identical for all 66 levels.
- `make CHECK_DTBS=y samsung/exynos5433-gts28ltexx-m3.dtb`
  (dtschema 2026.9, `apt-get install python3-pip` +
  `pip3 install --break-system-packages dtschema` in the container,
  same recipe as m2).  Five findings, all attributed:
  - root `compatible` not in `samsung-boards.yaml`, `oscclk`
    `clock-frequency`, usb `vdd10/vdd33` — **pre-existing**,
    identical on the m2 dtb, owned by m1/the SoC dtsi (see DT_M2.md);
  - `dsi@13900000: 'vddcore-supply' is a required property` — the
    only m3-introduced finding; see errata below.
  The pinctrl node was renamed `disp_teson-pins` → `disp-teson-pins`
  (label unchanged) after the first run flagged the underscore; the
  finding is gone.
- `make DT_SCHEMA_FILES=…panel/samsung,amoled-mipi-dsi.yaml
  dt_binding_check` — exit 0 (yamllint not installed in the image; the
  YAML lint step is skipped, validation itself runs).

## Errata / open risks

- The 512 MHz burst value reproduces stock's PLLCTRL **exactly**, but
  it is one-half of the naive reading of `timing,dsi-hs-clk` — verify
  on hardware that the panel trains at 1024 Mbps/lane.
- 187.5 MHz vclk → 59 Hz vs the panel mode's 60 Hz: watch for tearing
  or TE complaints on first light; adjust to 200 MHz (63 Hz) if needed.
- DSIM `rx_timeout` / `stop_holding_cnt` etc. from the stock DT are
  fixed defaults in the mainline driver; not ported.
- **`vddcore-supply` absent on `&dsi`** (the one new dtbs_check
  finding): the binding conditionally requires `vddcore`/`vddio` for
  `samsung,exynos5433-mipi-dsi`, but this board's PMIC has **no MIPI
  core rail** — TM2's `VDD10_MIPI2L_1.0V_AP` (ldo6) has no equivalent
  in the stock dump (regulator list, live_fdt.dts:2349-2573: nothing
  between CAM_SEN_CORE 1.2 V and VDDR 1.6 V).  The stock DT models no
  DSI supplies at all.  At runtime the DSI host gets the dummy
  regulator (CONFIG_REGULATOR fallback) — the same class of behavior
  as stock leaving the rail unmanaged.  If DSI init proves flaky on
  hardware, look for an unregulated always-on 1.0-1.05 V rail on the
  schematic and map it then.
