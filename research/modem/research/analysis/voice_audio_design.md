# Voice-call audio on the SM-T715: SS333 modem ↔ WM1814 AIF2 under mainline 6.12

Design note (analysis only; no project file was changed). Date 2026-10-29.

**Scope.** Android is gone. The tablet runs our mainline 6.12 ARM32 kernel, the `gts28_wm1814.c` machine
driver (AIF1 only) and the UCM tree under `04_arch_rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814/`.
This note specifies the work needed to carry call PCM directly between the Shannon SS333 and the codec's
AIF2, without going through the AP. It covers the routes, the clocking, the codec gaps, the machine driver,
UCM, the telephony daemon's sound IPC and a staged test plan.

**Evidence tags.** **[P]** means proven: read in the cited file and line. **[I]** means inferred, with
the reasoning given. **[P-web]** means read in a public source (URL given) during this analysis. Samsung
binaries were only passed through `strings`; none was executed. A **[P-str]** tag proves only that a string
is present in the binary. What the string means is always tagged [I].

**Path abbreviations.**

| Tag | Path |
|---|---|
| `K3/` | `src/kernel_universal5433/` (Samsung 3.10) |
| `ML/` | `src/linux-6.12/` (tree at `ed71dc803`, i.e. `kernel/patches/t715-bringup` applied) |
| `MP09` | a local script, not in this repository (identical to `mixer_paths.xml` up to line 1463) |
| `STK/` | a local script, not in this repository |
| `LOS/` | `src/device_gts28ltexx/` (LineageOS device tree copy) |
| `HS/` | `src/hardware_samsung-18.1/` |
| `RN` | `research/modem/research/research_notes/Modem Shannon SS333 sous Linux/linux_stack_voice.md` |
| `OVL/` | `04_arch_rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814/` (the deployed UCM) |
| `HAL`, `ARIL`, `SRC`, `SECRIL` | `strings` of `STK/lib/hw/audio.primary.universal5433.so`, `STK/lib/libaudio-ril.so`, `STK/lib/libsecril-client.so`, `STK/lib/libsec-ril.so` |

---

## 0. Key findings and the design in one page

1. **Stock uses `mixer_paths_rev09.xml`, not the LineageOS `mixer_paths_0.xml`** our UCM generator was fed.
   [P] The live DT sound node has `mixer-paths = "mixer_paths_rev09.xml"` (`dumps/live_fdt.dts:5346`).
   For speakerphone calls stock uses the **sub mic** (IN1R → LHPF2, `MP09:1077-1091`). LineageOS switched
   it to the main mic (`LOS/configs/audio/mixer_paths_0.xml:310-324`).
2. **AIF2 format.** I2S, normal clock polarity, codec as clock consumer. Two 16-bit slots: BCLK =
   32 × fs, so 256 kHz at 8 kHz NB and 512 kHz at 16 kHz WB. AIF2 is clocked from ASYNCCLK = FLL2 = 49.152
   MHz. FLL2 uses **MCLK1 24 MHz as its reference and is synchronised to AIF2BCLK**. [P]
   `K3/sound/soc/samsung/pacific_arizona.c:1094-1106, 1113-1118, 1129-1147`; no `aif_format` property in
   `live_fdt.dts:4337-4341`.
3. **The ASRC/ISRC clock plan needs three settings mainline cannot express.** They are `ASYNC Sample Rate 2`
   = 48 kHz, `ASRC RATE 2` = ASYNC rate 2 and `ISRC2 FSH` = ASYNC rate 2. In addition, mainline's
   `wm8998_asrc_ev` **returns -EINVAL** if the ASRC's async side points at an 8 or 16 kHz rate, which is the
   power-on default. [P] `ML/sound/soc/codecs/wm8998.c:69-90`; `ML/drivers/mfd/wm8998-tables.c:213-214,
   802`. The fix is a ~40-line `wm8998.c` patch (§3.3), or register writes from the machine driver as a
   stop-gap. Also, `SAMPLE_RATE_1` resets to 8 kHz (`wm8998-tables.c:209`), so the machine must force 48 kHz
   as downstream does (`pacific_arizona.c:1173-1175`).
4. **Machine design: a codec-to-codec link, gated by the telephony daemon.** The link is "baseband": a
   machine-registered modem DAI ↔ `wm8998-aif2`, with `c2c_params` NB/WB. FLL2 is started in the modem
   DAI's `.hw_params`, which DAPM calls when the link powers. The link is gated by two pin switches,
   `Modem RX`/`Modem TX`. The daemon enables them only once the CP reports that its PCM clocks run. This
   reproduces the stock HAL, which waits for the CP's unsolicited "PCM clock enable" before opening the
   voice PCMs. [P-str] `HAL`: "This routine is waiting unsol event for call(CP_CLK_NONE->CP_PATH_READY)",
   "### onUnsolPcmClkState%s : Clock - %s, wb_amr - %d", "start_call_by_cp_clock_status".
   [P] `RIL_UNSOL_SNDMGR_CLOCK_CTRL = 20022` (`src/lineage/android_device_samsung_gts28ltexx/include/telephony/ril_unsol_commands_vendor.h:87-88`).
5. **UCM.** Add a single `"Voice Call"` verb next to `HiFi` in `OVL/`, with Speaker, Headphones and Mic
   devices on `hw:${CardId},0`. Its control names and values must be the mainline ones. The generated
   `research/ucm/out/` tree uses downstream names that do not exist in mainline, such as `ASRC RATE 2`,
   `SYNCCLK rate 1`, `HP1 Bias`, `RCV Switch` and `AIF2 Mode`, and the card name `gts28lte`. WirePlumber ≥
   0.5.15 selects that profile by the `^Voice Call` name.
6. **CP side.** The daemon needs these SND messages: audio path, volume, TX mute, two-mic off and clock
   STOP, plus listening for the unsolicited clock-control and WB-AMR reports. Their semantics are proven at
   the OEM-hook level (`HS/ril/libsecril-client/secril-client.cpp:57-102, 626-965`). **The IPC-level
   numbering on SS333 is not proven.** The libsamsung-ipc numbering is the best candidate (§6.2).

---

## 1. Android in-call routes (stock T715XXU2CRH1)

### 1.1 How the stock HAL picks paths

- [P-str] `HAL` builds mixer path names as `<scenario><device>`, with a separate `gain-` path. The scenario
  strings include `incall_nb`, `incall_nb_extra_vol`, `incall_wb`, `incall_wb_extra_vol` and `volte_cp_*`.
  The output suffixes are `-handset`, `-speaker`, `-headset`, `-headphone` and `-bt-sco-headset`. The input
  suffixes are `-handset-mic`, `-speaker-mic`, `-headset-mic`, `-headphone-mic` and `-bt-sco-headset-in`.
  Log strings include `select_devices() output_route "%s"`, `select_devices() output_gain "%s"` and
  `%s - reset mixer values`.
- [I] The output/input pairing in a call follows the names: speaker ↔ `-speaker-mic`, wired headset
  ↔ `-headset-mic`, headphones without a mic ↔ `-headphone-mic`, and BT ↔ `-bt-sco-headset-in`. Each
  `<path name="…">` exists in MP09 for every pair (line ranges below).
- [I] "Reset mixer values" is the libaudioroute reset to the state captured at init. Init is the top-level
  `<ctl>` list of the XML (MP09:8-148) applied on top of the driver defaults. So **ending a call restores
  every control touched by `incall_*` to those values**, and then the HAL applies the media paths.
- [P] `incall_nb_handover-*`, `*_extra_vol-*`, `volte_cp_*` and `volte_vt_cp_*` are aliases of
  `incall_nb/wb-*` (MP09:459-491, 562-568, 572-697). VoLTE calls therefore use the same CP→codec route.
- [P] `call_nb_volume_index` and `call_wb_volume_index` are empty (MP09:177-183). The codec does **not**
  scale with the in-call volume index; volume is the CP's job (§6).
- [P] The default output is the speaker (`STK/etc/audio_policy.conf:3`). `AUDIO_DEVICE_OUT_EARPIECE` is
  declared as attached (`:2`), but **the tablet has no earpiece** (brief). LineageOS empties all handset
  paths (`LOS/configs/audio/mixer_paths_0.xml:147-149, 178-180, 221-223, 306-308`). The stock
  `incall_*-handset` paths drive EPOUT/`RCV` (MP09:377-390), which is an unconnected output here [I].
- [P-str] `HAL` has "### Send stop PCM clock IPC" (on "Leaving IN_CALL state") and opens voice PCMs on
  the baseband link: "%s pcm_open voice_out(%d) %p", "%s pcm_open voice_in %p", and `pcm_config_vx`. [P]
  `MP09:5` `baseband_link="1"`; downstream link 1 is "baseband" (`pacific_arizona.c:1221`).

### 1.2 Static (boot-time) settings relevant to AIF2 (MP09 top level)

| Control | Value | Line | Role |
|---|---|---|---|
| `ASRC2L/R Input` | `AIF2RX1` | 44-45 | AIF2 (overridden in call) |
| `SPKOUTL/R Input 3` | `None` | 49-50 | CP→speaker slot, off |
| `HPOUTL/R Input 2` | `None` | 53-54 | CP→HP slot, off |
| `AIF3TX1/2 Input 2` | `AIF2RX1` | 57-58 | CP→BT |
| `LHPF1/2 Mode` | `High-pass` | 62-63 | mic HPF |
| `AIF2TX1/2 Input 2` | `None` | 66-67 | BT mic→CP, off |
| `IN1L/IN1R/IN2 Volume` | 30 | 73-75 | mic PGA |
| `AIF2TX1/2 Input 1` | `ASRC1L/ASRC1R` | 80-81 | uplink default |
| `AIF1TX1/2 Input 2` | `ASRC2L/ASRC2R` | 84-85 | call recording |
| `LHPF1..4 Coefficients` | `240 58` (LHPF3 `240 1`) | 88-91 | HPF corner |
| `Input Ramp Up` | `8ms/6dB` | 98 | pop control |
| `ASRC RATE 1` | `SYNCCLK rate 1` | 100 | **AIF2 clock plan** |
| `ASYNC Sample Rate 2` | `48kHz` | 101 | **AIF2 clock plan** |
| `ASRC RATE 2` | `ASYNCCLK rate 2` | 102 | **AIF2 clock plan** |
| `Sample Rate 2` / `3` | `8kHz` / `16kHz` | 111-112 | BT (ISRC1) |
| `ISRC1 FSL` / `FSH` | `SYNCCLK rate 3` / `rate 1` | 115-116 | BT |
| `ISRC2 FSL` / `FSH` | `ASYNCCLK rate` / `ASYNCCLK rate 2` | 119-120 | **AIF2 clock plan** |
| `HPOUT DRE/EDRE`, `SPKOUT EDRE`, `RCV/SPK/HP/VPS/HDMI Switch`, `Main/Sub/Headset Mic Switch` | 0 | 138-148 | all off |

### 1.3 Output routes set when a call starts (NB and WB identical unless noted)

`AIF2 Mode = Slave` and `ASRC RATE 2 = ASYNCCLK rate 2` are set in every path below. **A** marks AIF2
routing; **M** marks media or normal routing.

**Speaker:** `incall_nb-speaker` MP09:392-407, `incall_wb-speaker` 509-524.

| Control | Value | Kind |
|---|---|---|
| `AIF2 Mode` | `Slave` | A (machine control) |
| `ASRC RATE 2` | `ASYNCCLK rate 2` | A |
| `ISRC2INT1 Input`, `ISRC2INT2 Input` | `AIF2RX1` | A (CP left slot to both) |
| `ASRC2L Input` / `ASRC2R Input` | `ISRC2INT1` / `ISRC2INT2` | A |
| `SPKOUTL Input 1` / `SPKOUTR Input 1` | `AIF1RX1` / `AIF1RX2` | M (AP sound still mixed) |
| `SPKOUTL Input 3` / `SPKOUTR Input 3` | `ASRC2L` / `ASRC2R` | A (call downlink) |
| `SPK Switch` | 1 | M (pin) |
| `AIF1TX1 Input 2` / `AIF1TX2 Input 2` | `ASRC2L` / `ASRC2R` | A→AP (call recording) |
| gain (`gain-incall_nb-speaker` 1928-1932, WB 2006-2010) | `Speaker Digital Volume` 128, `SPKOUTL/R Input 1 Volume` 32 | M |

**Wired headset and headphones:** `incall_nb-headset` 409-425. `incall_nb-headphone` (427-429),
`incall_wb-headset` (526-528) and `incall_wb-headphone` (530-532) all alias it. The routes are the speaker
ones with `HPOUTL/R` in place of `SPKOUTL/R`: `HPOUTL/R Input 1 = AIF1RX1/2` (M), `HPOUTL/R Input 2 =
ASRC2L/R` (A) and `HP Switch = 1`, plus `HPOUT DRE Switch = 0` (stock-only control). The gains are
`Noise Gate Switch` 0, `HPOUTL/R Input 1/2 Volume` 32, and an `HPOUT Digital Volume` of 126 (NB
headset, 1934-1941), 130 (NB headphone, 1943-1950), 132 (WB headset, 2012-2019) or 124 (WB headphone,
2021-2028).

**Bluetooth SCO:** `incall_nb-bt-sco-headset` 431-456, WB 534-559.

- Downlink: the A chain above, then `ISRC1 FSL = SYNCCLK rate 2` (8 k; WB: `rate 3` = 16 k),
  `ISRC1 FSH = SYNCCLK rate 1`, `ISRC1DEC1/2 Input = ASRC2L/R` and `AIF3TX1/2 Input 2 = ISRC1DEC1/2`.
- AP mixing: `ISRC1DEC3/4 Input = AIF1RX1/2` and `AIF3TX1/2 Input 1 = ISRC1DEC3/4`.
- Also set: `Sample Rate 2 = 8kHz` (WB `16kHz`), plus the call recording routes.
- [P] BT SCO is wired to the codec's AIF3 on this board. Evidence: `LOS/../device_gts2-common/bluetooth/libbt_vndcfg.txt:6-7`
  (`SCO_USE_I2S_INTERFACE = TRUE`, `SCO_I2SPCM_IF_ROLE = 0`), the downstream link "bluetooth sco" ↔
  `vegas-aif3` (`pacific_arizona.c:1230`), codec master (`:1185-1199`), and AIF3 in the SYSCLK rate-2
  domain (`:912`).

### 1.4 Input routes (uplink to the CP)

| Path (MP09 lines) | Mic chain | AIF2 chain (A) | Pin |
|---|---|---|---|
| `incall_nb-speaker-mic` 1077-1091 (WB alias 1183-1185) | `IN1R Mux = B`, `LHPF2 Input 1 = IN1R` (**sub mic**) | `ASRC RATE 1 = SYNCCLK rate 1`, `ASRC1L/R Input = LHPF2`, `ISRC2DEC1/2 Input = ASRC1L/R`, `AIF2TX1/2 Input 1 = ISRC2DEC1/2` | `Sub Mic Switch = 1` |
| `incall_nb-headset-mic` 1093-1106 (WB 1187-1189) | `IN2 Mux = B`, `LHPF1 Input 1 = IN2L` | same, from `LHPF1` (no `ASRC RATE 1` line) | `Headset Mic Switch = 1` |
| `incall_nb-headphone-mic` 1108-1122 (WB 1191-1193) | `IN1L Mux = B`, `LHPF1 Input 1 = IN1L` (main mic) | same, from `LHPF1` | `Main Mic Switch = 1` |
| `incall_nb-bt-sco-headset-in` 1124-1140 (WB 1195-1211) | `ISRC1INT1/2 Input = AIF3RX1/2` (ISRC1 8 or 16 k → 48 k) | `ASRC1L/R Input = ISRC1INT1/2`, then as above | — |

Every mic path also sets `AIF1TX1/2 Input 1` to the mic LHPF (call recording, M).

Mic gains (rev09):

| Path | `IN…` PGA | `IN… Digital Volume` | `LHPF… Input 1 Volume` | Lines |
|---|---|---|---|---|
| speaker-mic | `IN1R Volume` 21 NB / 18 WB | 128 | 32 | 2677-2681, 2752-2756 |
| headset-mic | `IN2 Volume` 30 NB / 27 WB | 128 | 32 | 2683-2687, 2758-2762 |
| headphone-mic | `IN1L Volume` 24 | 128 | 32 | 2689-2693, 2764-2768 |
| BT | `AIF2TX1/2 Input 1 Volume` and `AIF1TX1/2 Input 1 Volume` 32 | — | — | 2695-2700, 2770-2775 |

The machine pins are `Main Mic` = IN1BL/MICBIAS2, `Sub Mic` = IN1BR/MICBIAS3 plus the GPIO gpr3-2, and
`Headset Mic` = IN2B/MICBIAS1 (`pacific_arizona.c:856-878, 624-641`).

### 1.5 When the call ends

- [I] The HAL resets the mixer to the init state (§1.1). For the call controls this means
  `SPKOUTL/R Input 3`, `HPOUTL/R Input 2` and `AIF2TX1/2 Input 2` = `None` (MP09:49-54, 66-67),
  `ASRC2L/R Input = AIF2RX1` (44-45), `AIF2TX1/2 Input 1 = ASRC1L/R` (80-81) and all pin switches = 0
  (141-148). Controls absent from the top level (`ISRC2INT*/DEC* Input`, `ASRC1L/R Input`, `LHPF1 Input
  1`) return to their boot values, that is the register reset (`None`).
- [P-str] The HAL closes the voice PCMs ("%s pcm_close voice_out %p", "%s pcm_close voice_in %p"). It then
  sends "### Send stop PCM clock IPC" to the CP when it leaves IN_CALL. [P-web] LineageOS does the same in
  `stop_voice_session()`: `ril_set_call_clock_sync(SOUND_CLOCK_STOP)`
  ([voice.c](https://github.com/LineageOS/android_hardware_samsung/blob/lineage-18.1/audio/voice.c),
  ~l.302).

### 1.6 Stock versus the LineageOS file used by `mixer2ucm.py`

[P] The differences are: the speaker mic is the main mic (IN1L/LHPF1) instead of the sub mic
(`LOS/configs/audio/mixer_paths_0.xml:310-324`); the in-call mic gains differ (`IN1L` 30/145/45 NB and
20/127/49 WB, lines 469-495); the handset paths are empty; and there are no `Sub Mic Switch`,
`HPOUT DRE Switch` or BT in-call paths. [P] `research/ucm/out/REPORT.md` confirms that the
generator read only `mixer_paths_0.xml`.

---

## 2. AIF2 configuration

| Item | Value | Evidence |
|---|---|---|
| Format | I2S. The downstream code computes `fmt = (aif_format[1] & 0x0F) + 1`; `aif_format` is absent from the DT, so the value is 0 + 1 = `SND_SOC_DAIFMT_I2S` | [P] `pacific_arizona.c:1113`, `:1453-1454`; `live_fdt.dts:4337-4341` (no `aif_format`); `K3/include/sound/soc-dai.h:29` |
| Clock polarity | `NB_NF` | [P] `pacific_arizona.c:1113` |
| TDM | no (bit 0x10 of `aif_format` not set) | [P] `:1108-1111` |
| Clock provider | **CP**: codec `CBS_CFS` when `aif2mode == 0`. Every in-call path sets `AIF2 Mode = Slave`, and the machine control defaults to 0 | [P] `:1116-1118`, `:116-125, 284-303, 646`; MP09:378 and others; `:106-108` (no `aif2mode` initialiser) |
| Rates | 8 kHz (NB) or 16 kHz (WB). Any other rate falls back to the 8 k BCLK | [P] `:1094-1106` |
| BCLK | 256 kHz at 8 kHz, 512 kHz at 16 kHz, so **32 BCLK per frame = 2 × 16-bit slots** | [P] `:1095-1099`; [I] 256000/8000 = 32 |
| Word and slot | S16_LE, 16-bit slots, 2 channels (L/R) | [I] from BCLK/fs = 32 and I2S. [P-web] the LineageOS HAL opens the voice PCMs with `.channels = 2`, `.rate = 8000/16000`, `.format = PCM_FORMAT_S16_LE` ([voice.c](https://github.com/LineageOS/android_hardware_samsung/blob/lineage-18.1/audio/voice.c), ~l.41-55) |
| Slot use | RX: only `AIF2RX1` (left) is used, copied to both ISRC2 interpolators. TX: the same mic goes to `AIF2TX1` and `AIF2TX2` | [P] MP09:47 ("i2c dual mono(both L/R)"), :395-396, :1082-1085 |
| FLL2 | reference `FLL2_REFCLK` ← MCLK1 24 MHz; FLL2 synchronised to `ARIZONA_FLL_SRC_AIF2BCLK` at the BCLK rate; Fout 49.152 MHz | [P] `pacific_arizona.c:1129-1147`, `PACIFIC_DEFAULT_MCLK1 24000000` (`:51`), `asyncclk_rate 49152000` (`:106-108`) |
| Clock domains | SYSCLK ← FLL1 49.152 MHz carries AIF1, the inputs, the outputs, the LHPFs and the ASRC sync side. ASYNCCLK ← FLL2 49.152 MHz carries AIF2, ISRC2 and the ASRC async side. AIF3 (BT) is on SYSCLK rate 2 | [P] `pacific_arizona.c:884-914`, `:1627-1640` |
| SYSCLK sample rate | `SAMPLE_RATE_1` is forced to 48 kHz (0x3) in the AIF2 `hw_params` | [P] `:1173-1175` |
| FLL2 stop | at `BIAS_OFF` | [P] `:1814-1818`, `:1843-1845` |

**Rate chain in a call** (all [P] from MP09:100-120 and §1.3/1.4; the clock-domain reading is [I]):

```
DOWNLINK (CP → speaker)
 CP ──I2S slave 8/16k──▶ AIF2RX1 ─▶ ISRC2INT1/2 ─▶ ASRC2L/R ─▶ SPKOUTL/R Input 3 ─▶ OUT4 ─▶ SPK
                  ASYNC rate 1        FSL=ASYNC r1   async→sync     SYSCLK rate 1 (48k)
                  (8/16k)             FSH=ASYNC r2   RATE2=ASYNC r2
                                      (48k)          RATE1=SYNC r1 (48k)
UPLINK (mic → CP)
 IN1x ─▶ LHPF ─▶ ASRC1L/R ─▶ ISRC2DEC1/2 ─▶ AIF2TX1/2 ──I2S──▶ CP
  SYSCLK 48k     sync→async   FSH 48k → FSL 8/16k (ASYNC r2 → ASYNC r1)
```

- [I] This is why three rates exist. `ASYNC_SAMPLE_RATE_1` follows AIF2 (8 or 16 k). `ASYNC_SAMPLE_RATE_2`
  is fixed at 48 k as the high side of ISRC2 and the async side of the ASRC. `SAMPLE_RATE_1` is the 48 k
  media rate.
- [P] The ASRC refuses rates ≥ 0x11 (8 kHz and below, 16 k, 32 k) on either side
  (`ML/sound/soc/codecs/wm8998.c:55-61, 78-84`; `K3/sound/soc/codecs/vegas.c:102-115`).
- [I] So the integer ISRC2 converts 8/16 k ↔ 48 k inside the async domain, and the ASRC bridges 48 k async ↔
  48 k sync. ISRC2's high side cannot be the SYSCLK rate. Samsung's choice of `ASYNCCLK rate 2` for
  `ISRC2 FSH`, rather than `SYNCCLK rate 1`, implies that the ISRC needs both sides in the same domain.
- [P] The direction convention is visible in the routes: ASRC1 = sync→async (uplink), ASRC2 =
  async→sync (downlink).

---

## 3. Mainline gaps (wm8998.c / arizona.c / our machine driver)

### 3.1 Control-by-control comparison

Method: a script scanned `ML/sound/soc/codecs/wm8998.c`, expanding the `ARIZONA_MIXER_*`/`MUX_*` macros,
against every control in the MP09 in-call, gain and init paths. It is at
a local script, not in this repository.

| Stock control | Mainline state | Evidence | Needed for |
|---|---|---|---|
| `AIF2 Mode` | absent; it was a pacific machine control with no codec register | [P] `pacific_arizona.c:116-125, 646` | **drop**; the format is fixed by `dai_fmt` |
| `ASRC RATE 2` | **absent**; mainline only checks the field in `wm8998_asrc_ev` | [P] `ML/.../wm8998.c:69-90`; downstream `K3/sound/soc/codecs/vegas.c:278`, `K3/sound/soc/codecs/arizona.c:1471-1477` | **voice (required)** |
| `ASYNC Sample Rate 2` | **absent** | [P] grep in `ML/.../wm8998.c`, `ML/.../arizona.c`; downstream `vegas.c:271` | **voice (required)** |
| `ISRC2 FSH = ASYNCCLK rate 2` | control present, **value absent**: mainline offers `SYNCCLK rate`, `8kHz`, `16kHz`, `ASYNCCLK rate` (values 0, 1, 2, 8) | [P] `ML/.../arizona.c:632-640, 642-656` | **voice (required)** |
| `ISRC2 FSL = ASYNCCLK rate` | OK (same text) | [P] `arizona.c:633` | voice |
| `ASRC RATE 1 = SYNCCLK rate 1` | renamed: the value is `SYNCCLK rate` | [P] `arizona.c:633, 674-679` | voice |
| `Sample Rate 2` / `Sample Rate 3` | absent. Mainline labels values 1 and 2 as `8kHz`/`16kHz`, but WM8998 never programs SAMPLE_RATE_3 (reset 0x11 = 8 kHz), unlike wm5102/wm5110 | [P] `wm8998-tables.c:210-211`; `ML/.../wm5102.c:2093-2096`, `wm5110.c:2451-2454`; no such write in `wm8998.c` | BT only |
| `ISRC1 FSL = SYNCCLK rate 2/3` | renamed `8kHz`/`16kHz` (and `16kHz` is wrong on WM8998, see above) | [P] as above | BT only |
| `HPOUT DRE/EDRE Switch`, `SPKOUT EDRE Switch`, `HP1 Bias`, `DAC Comp`, `FRF Coefficients` | absent (Samsung codec extras) | [P] `docs/AUDIO_M6.md` §7.4 item 5; script | drop |
| `SPK/HP/Main Mic Switch` | present (our machine) | [P] `ML/sound/soc/samsung/gts28_wm1814.c:231-235` | voice |
| `Sub Mic Switch`, `Headset Mic Switch` | absent (left out of our machine) | [P] `gts28_wm1814.c:12-16` | phases 2 and 3 (§4.6) |
| `RCV/VPS/HDMI Switch` | absent (no earpiece; not needed) | [P] same | drop |
| All mux/mixer controls (`ISRC2INT1 Input`, `ASRC1L Input`, `AIF2TX1 Input 1`, `SPKOUTL Input 3`, `HPOUTL Input 2`, `LHPF1 Input 1`, `IN1R Mux`, volumes, …) and every source value (`AIF2RX1`, `ISRC2DEC1`, `LHPF2`, `IN2L`, …) | present, same names | [P] `wm8998.c:310-314, 586-620, 787-826, 843-896`; script | voice |
| The c2c voice link itself | absent; `gts28_wm1814.c` has one link | [P] `gts28_wm1814.c:271-280` | voice (§4) |

### 3.2 Two latent mainline traps for this route

1. **[P]** `wm8998_asrc_ev` returns `-EINVAL` on a bad rate (`wm8998.c:55-61, 78-90`). DAPM only logs
   "ASoC: PRE_PMU: ASRC2L event failed" and **still enables the widget** (`ML/sound/soc/soc-dapm.c:1577-1589`).
   - [P] The reset values are `ASRC_RATE2 = 0x4000`, i.e. selector 8 = ASYNC rate 1, and
     `ASYNC_SAMPLE_RATE_1 = 0x11`, i.e. 8 kHz (`wm8998-tables.c:802, 213`).
   - [I] With those values the ASRC is told its async side runs at 8 or 16 k, which it does not support.
     The result is silence or garbage, with a misleading log.
2. **[P]** The reset value of `SAMPLE_RATE_1` is 0x11, 8 kHz (`wm8998-tables.c:209`). Mainline only
   rewrites it in AIF1 `hw_params` (`arizona.c:1716-1734`). [I] A call placed before any media stream has
   run since boot would therefore trip the ASRC rate-1 check. Downstream forces 48 k in the AIF2
   `hw_params` (`pacific_arizona.c:1173-1175`); the machine must do the same (§4.3).

### 3.3 Minimal codec patch (sketch, `sound/soc/codecs/wm8998.c` only, ~40 lines)

The patch is kept local to wm8998 so that the shared `arizona_rate_text` stays as it is. The enum macros
are the mainline ones (`include/sound/soc.h:246, 415`), and the register fields are proven in
`include/linux/mfd/arizona/registers.h:1740-1741, 7865-7873, 7880-7947`. The naming follows the downstream
names (UCM-compatible) and madera's `ASRC1 Rate 2` / `ASYNCCLK rate 2` style (`ML/.../madera.c:1626-1637`).

```c
/* ISRC rates incl. ASYNC rate 2 (value 9), as downstream arizona.c:1377-1420 */
static const char * const wm8998_rate_text[] = {
	"SYNCCLK rate", "8kHz", "16kHz", "ASYNCCLK rate", "ASYNCCLK rate 2",
};
static const unsigned int wm8998_rate_val[] = { 0x0, 0x1, 0x2, 0x8, 0x9 };

static const struct soc_enum wm8998_isrc_fsh[] = {
	SOC_VALUE_ENUM_SINGLE(ARIZONA_ISRC_1_CTRL_1, ARIZONA_ISRC1_FSH_SHIFT, 0xf,
			      ARRAY_SIZE(wm8998_rate_text), wm8998_rate_text, wm8998_rate_val),
	SOC_VALUE_ENUM_SINGLE(ARIZONA_ISRC_2_CTRL_1, ARIZONA_ISRC2_FSH_SHIFT, 0xf,
			      ARRAY_SIZE(wm8998_rate_text), wm8998_rate_text, wm8998_rate_val),
};
static const struct soc_enum wm8998_isrc_fsl[] = {	/* same on ISRC_n_CTRL_2 / *_FSL_SHIFT */ };

/* ASRC async side: only the two ASYNC rates are legal (wm8998_asrc_ev:69-90) */
static const struct soc_enum wm8998_asrc_rate2 =
	SOC_VALUE_ENUM_SINGLE(ARIZONA_ASRC_RATE2, ARIZONA_ASRC_RATE2_SHIFT, 0xf, 2,
			      wm8998_rate_text + 3, wm8998_rate_val + 3);

static const struct soc_enum wm8998_async_rate2 =
	SOC_VALUE_ENUM_SINGLE(ARIZONA_ASYNC_SAMPLE_RATE_2, ARIZONA_ASYNC_SAMPLE_RATE_2_SHIFT,
			      0x1f, ARIZONA_SAMPLE_RATE_ENUM_SIZE,
			      arizona_sample_rate_text, arizona_sample_rate_val);

/* in wm8998_snd_controls[]: replace lines 310-313, add after 314 */
SOC_ENUM("ISRC1 FSL", wm8998_isrc_fsl[0]),  SOC_ENUM("ISRC2 FSL", wm8998_isrc_fsl[1]),
SOC_ENUM("ISRC1 FSH", wm8998_isrc_fsh[0]),  SOC_ENUM("ISRC2 FSH", wm8998_isrc_fsh[1]),
SOC_ENUM("ASRC RATE 1", arizona_asrc_rate1),
SOC_ENUM("ASRC RATE 2", wm8998_asrc_rate2),
SOC_ENUM("ASYNC Sample Rate 2", wm8998_async_rate2),

/* wm8998_probe(): make the "8kHz"/"16kHz" labels true, as wm5102.c:2093-2096 */
regmap_update_bits(arizona->regmap, ARIZONA_SAMPLE_RATE_2, ARIZONA_SAMPLE_RATE_2_MASK, 0x11);
regmap_update_bits(arizona->regmap, ARIZONA_SAMPLE_RATE_3, ARIZONA_SAMPLE_RATE_3_MASK, 0x12);
```

- [P] `arizona_sample_rate_text/val` are exported (`arizona.c:606-617`), and the registers are readable on
  WM8998 (`wm8998-tables.c:853-862, 1482`).
- [I] The existing value names stay unchanged, so the patch cannot break current users. An
  upstream-friendly variant would extend `arizona_rate_text` to 5 entries. In that case
  `arizona_asrc_rate1` must be pinned to 3 items, since today it uses `ARIZONA_RATE_ENUM_SIZE - 1`
  (`arizona.c:674-679`).
- **Stop-gap without a codec patch [I]:** in `late_probe`, the machine writes `ASYNC_SAMPLE_RATE_2 = 0x03`,
  `ASRC_RATE2 = 9 << 11`, `ISRC_2_CTRL_1 (FSH) = 9 << 11` and `SAMPLE_RATE_3 = 0x12` through
  `snd_soc_component_update_bits`. The regmap cache restores them across runtime PM. UCM must then **not**
  write `ISRC2 FSH`: the control cannot represent the value 9 and would overwrite it.

---

## 4. Machine-driver design (`gts28_wm1814.c`)

### 4.1 Which link type

| Option | Precedent | Fit |
|---|---|---|
| **A. Codec-to-codec (`c2c_params`)**, CPU = a modem DAI registered by the machine, codec = `wm8998-aif2` | [P] `ML/sound/soc/samsung/aries_wm8994.c:398-404, 414-460, 482-489` (Galaxy S, Samsung IPC modem). [P] `ML/sound/soc/samsung/bells.c:229-235, 283-317`: an **Arizona** AIF2 c2c "Baseband" link to a clock-master baseband, with FLL2 ← `ARIZONA_FLL_SRC_AIF2BCLK` (`bells.c:80-86`) and AIF2 ← ASYNCCLK (`:188-205`) | **Recommended.** No PCM device or helper process is needed; DAPM powers AIF2 when routes complete. |
| B. Normal PCM link, CPU `snd-soc-dummy-dai`, opened by a helper at 8/16 k | [P] downstream "baseband" link (`pacific_arizona.c:1220-1228`) and the stock HAL voice PCMs (§1.1); [P] `ML/sound/soc/samsung/tm2_wm5110.c:433-436, 457-463` | Fallback. Matches Android exactly (`ops->hw_params` runs). It needs a process holding `hw:wm1814,1` open and adds dummy-DMA quirks. |

- [P] In a c2c link the **link `.ops->hw_params` is never called**. DAPM calls `snd_soc_dai_hw_params()`
  on each DAI with `dai_link->c2c_params + rtd->c2c_params_select` (`ML/sound/soc/soc-dapm.c:3884-3996`,
  `:3944`).
- [I] So the downstream `pacific_aif2_hw_params` logic must move into the **modem DAI's own
  `.hw_params`**.
- [P] c2c links get an internal PCM with no `/dev` node (`ML/sound/soc/soc-pcm.c:2983-2988`). AIF1 stays
  `hw:wm1814,0`, so UCM and PipeWire are unaffected.

### 4.2 Sketch of the additions (illustrative; not compiled)

```c
#define GTS28_ASYNCCLK_RATE	49152000U	/* pacific_arizona.c:106-108 */

/* NB / WB: I2S, 2 x 16-bit slots -> BCLK = 32 fs (pacific_arizona.c:1094-1106) */
static const struct snd_soc_pcm_stream gts28_modem_params[] = {
	{ .stream_name = "NB", .formats = SNDRV_PCM_FMTBIT_S16_LE,
	  .rate_min = 8000,  .rate_max = 8000,  .channels_min = 2, .channels_max = 2 },
	{ .stream_name = "WB", .formats = SNDRV_PCM_FMTBIT_S16_LE,
	  .rate_min = 16000, .rate_max = 16000, .channels_min = 2, .channels_max = 2 },
};

/* priv gains: unsigned int modem_rate; unsigned int modem_users; */

static int gts28_modem_hw_params(struct snd_pcm_substream *s,
				 struct snd_pcm_hw_params *p, struct snd_soc_dai *dai)
{
	struct snd_soc_card *card = dai->component->card;
	struct gts28_machine_priv *priv = snd_soc_card_get_drvdata(card);
	struct snd_soc_component *codec = gts28_codec_component(card);
	int ret;

	if (priv->modem_users++)		/* called once per c2c direction */
		return 0;

	/* SYSCLK side of the ASRC must be 48 k (pacific_arizona.c:1173-1175) */
	snd_soc_component_update_bits(codec, ARIZONA_SAMPLE_RATE_1,
				      ARIZONA_SAMPLE_RATE_1_MASK, 0x03);

	/* FLL2: REFCLK = MCLK1 24 MHz, synchronised to AIF2BCLK (pacific :1129-1147) */
	ret = snd_soc_component_set_pll(codec, WM8998_FLL2_REFCLK, ARIZONA_FLL_SRC_MCLK1,
					GTS28_MCLK_RATE, GTS28_ASYNCCLK_RATE);
	if (!ret)
		ret = snd_soc_component_set_pll(codec, WM8998_FLL2, ARIZONA_FLL_SRC_AIF2BCLK,
						params_rate(p) * 32, GTS28_ASYNCCLK_RATE);
	if (ret)
		priv->modem_users--;
	return ret;
}

static int gts28_modem_hw_free(struct snd_pcm_substream *s, struct snd_soc_dai *dai)
{
	/* stop FLL2 only when both directions are down (refcount!) */
	if (priv->modem_users && --priv->modem_users == 0)
		return snd_soc_component_set_pll(codec, WM8998_FLL2, 0, 0, 0);
	return 0;
}

static const struct snd_soc_dai_ops gts28_modem_dai_ops = {
	.hw_params = gts28_modem_hw_params, .hw_free = gts28_modem_hw_free,
};

static struct snd_soc_dai_driver gts28_modem_dai = {	/* aries_wm8994.c:435-460 */
	.name = "gts28-modem", .ops = &gts28_modem_dai_ops,
	.playback = { .stream_name = "Modem Playback", .channels_min = 1, .channels_max = 2,
		      .rates = SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_16000,
		      .formats = SNDRV_PCM_FMTBIT_S16_LE },
	.capture  = { .stream_name = "Modem Capture",  /* same */ },
};

static const struct snd_soc_dapm_widget gts28_modem_widgets[] = {
	SND_SOC_DAPM_INPUT("Modem RX"), SND_SOC_DAPM_OUTPUT("Modem TX"),
};
static const struct snd_soc_dapm_route gts28_modem_routes[] = {	/* aries :419-422 */
	{ "Modem Capture", NULL, "Modem RX" }, { "Modem TX", NULL, "Modem Playback" },
};
/* register with devm_snd_soc_register_component() before the card (aries :672-673) */

SND_SOC_DAILINK_DEFS(baseband,
	DAILINK_COMP_ARRAY(COMP_CPU("gts28-modem")),
	DAILINK_COMP_ARRAY(COMP_CODEC(NULL, "wm8998-aif2")));

/* gts28_dai_links[1] */
{
	.name = "baseband", .stream_name = "baseband",	/* downstream name, :1221 */
	.dai_fmt = SND_SOC_DAIFMT_I2S | SND_SOC_DAIFMT_NB_NF | SND_SOC_DAIFMT_CBC_CFC,
	.c2c_params = &gts28_modem_params[0], .num_c2c_params = 1,
	.ignore_suspend = 1,
	SND_SOC_DAILINK_REG(baseband),
},
/* probe: dai_link[1].codecs->of_node = codec_np (same WM1814 node) */
```

Card-level additions:

- **Controls:** `SOC_DAPM_PIN_SWITCH("Modem RX")` and `SOC_DAPM_PIN_SWITCH("Modem TX")`, giving
  `Modem RX Switch` and `Modem TX Switch`. [P] Pin switches find component widgets because
  `dapm_find_widget(…, true)` searches other contexts (`soc-dapm.c:2641`).
- **`Modem Rate` enum (`8kHz`/`16kHz`):** its `put` returns `-EBUSY` while
  `rtd->c2c_widget[0/1]->power` (`include/sound/soc.h:1176`). Otherwise it sets
  `card->dai_link[1].c2c_params = &gts28_modem_params[sel]`. [I] This is safe because `pre_pmu` reads the
  pointer at every power-up (`soc-dapm.c:3944`). With `num_c2c_params = 1` the core creates no
  "baseband-playback"/"baseband-capture" selector controls (`soc-dapm.c:1090-1091, 4221-4236`). Those
  would be two controls that must always agree.
- **`late_probe` additions, after the existing SYSCLK setup (`gts28_wm1814.c:200-228`):**
  `snd_soc_component_set_sysclk(codec, ARIZONA_CLK_ASYNCCLK, ARIZONA_CLK_SRC_FLL2, 49152000,
  SND_SOC_CLOCK_IN)` and `snd_soc_dai_set_sysclk(aif2_dai, ARIZONA_CLK_ASYNCCLK, 0, 0)`.
  - [P] The second call moves the "AIF2 Playback/Capture → SYSCLK" DAPM routes (`wm8998.c:1004, 1010`) to
    ASYNCCLK (`arizona.c:1910-1954`), as downstream does (`pacific_arizona.c:895-912, 1635-1640`) and bells
    (`bells.c:188-205`).
  - Then `snd_soc_dapm_disable_pin()` on `Modem RX`/`Modem TX`, so the link is **off at boot**.
  - Optionally, `snd_soc_dapm_ignore_suspend()` on `Modem RX`/`TX`, `SPK`, `HP`, `Main Mic` and the codec's
    "AIF2 Playback/Capture", as downstream does (`pacific_arizona.c:1609-1621`).
  - The stop-gap register writes of §3.3 also go here if the codec patch is deferred.
- **`gts28_stop_sysclk`:** also stop FLL2 there, as a safety net
  (`set_pll(WM8998_FLL2, 0, 0, 0)`, cf. `pacific_arizona.c:1814-1818`). The existing comment at
  `gts28_wm1814.c:108-112` must then be updated.

[I] **Why the refcount.** Each c2c direction is its own widget. Each calls the CPU DAI's `hw_params` once
at PRE_PMU and `hw_free` once at PRE_PMD (`soc-dapm.c:3915-3982, 4022-4046`). If UCM drops only the mic,
the capture widget powers down; without a refcount it would stop FLL2 under a live downlink.

### 4.3 Clock ordering at power-up (why FLL2 is up before ASYNCCLK)

- [P] The supply and dai_link widgets share power-up sequence 3 (`soc-dapm.c:74-75`). Ties are broken by
  `subseq`, then by `reg` (`:1506-1515`).
- [P] The c2c widget has `reg = SND_SOC_NOPM` (−1) (`:4237-4240`), while ASYNCCLK sits at
  `ARIZONA_ASYNC_CLOCK_1` = 0x112 (`wm8998.c:506`).
- [I] Hence the link PRE_PMU, and our FLL2 start, runs before `ASYNC_CLK_ENA` is set. Within that PRE_PMU
  our CPU-DAI `hw_params` (FLL2) runs before the codec AIF2 `hw_params`. For the playback direction,
  CPU = source = first (`:3963-3981`). The codec AIF2 `hw_params` writes `ASYNC_SAMPLE_RATE_1`, the AIF2
  rate selector 8 and BCLK/LRCLK = 32 (`arizona.c:1735-1745, 1777-1880`).
- [I] The codec computes BCLK as `8000×16×2 = 256000` → table index 6 (`arizona.c:1536-1556`). The "Forcing
  stereo mode" rule in I2S (`:1817-1823`) yields the same BCLK if mono params are ever used.
- [P] `arizona_startup` accepts 8 and 16 kHz on a 49.152 MHz ASYNCCLK (`arizona.c:1607, 1616-1648`).

### 4.4 FLL2 with the modem as clock provider, and before the modem starts its clocks

- [P] Mainline enables REFCLK and SYNC paths together when both are set and differ
  (`arizona.c:2445-2467`). It widens the sync bandwidth for SYNCCLK > 100 kHz (`:2482-2490`), which
  applies at 256 and 512 kHz. It waits ~200 ms for `FLL2_CLOCK_OK` (5 × 0.2-0.4 ms + 10 × 20 ms,
  `:2512-2526`). **On timeout it only warns ("Timed out waiting for lock") and returns 0.**
- [P] `bells.c` uses the sync source alone, with no REFCLK (`bells.c:80-86`).
- [I] Samsung's REFCLK + SYNC combination is the robust choice. With MCLK1 as reference, FLL2 should lock
  and give a stable ASYNCCLK even before BCLK appears; the synchroniser then pulls it onto AIF2BCLK once the
  CP clocks run. With sync alone and no BCLK, FLL2 cannot lock: DAPM stalls ~200 ms, ASYNCCLK is absent
  or unstable, and CLKGEN_ERR_ASYNC can be expected. **This is inferred from the Arizona FLL architecture
  and must be checked in test stage 2.**
- [I] Even with the reference, powering AIF2 before the CP clocks gives silence. It also risks a frequency
  step, i.e. a click, when the synchroniser engages. **Hence the gating:** the telephony daemon enables
  `Modem RX/TX Switch` only after the CP's clock-enable report, which is what the stock HAL does (§0 item 4,
  §6). The WB/NB rate is set while the pins are off.
- [P] Stock never used codec-master mode. Every in-call path forces "Slave" (MP09:378, …).
  [I] Codec-master (`aif2mode = 1`: FLL2 from MCLK1, `pacific_arizona.c:1149-1170`) would need the CP to
  accept being a clock consumer, which is unverified (cf. `SND_CLOCK_MODE_CTRL`, §6.2). It is not
  proposed.

### 4.5 Device-tree changes

- **Phase 1 (speaker, headphones, main mic): none.** The modem DAI is registered by the machine driver
  (aries pattern), and link 1 reuses the `samsung,audio-codec` phandle.
  [P] The DT node is in `ML/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-audio.dtsi:27-36`. [I] The
  codec AIF2 pins connect directly to the CP and the AP's PCM blocks are disabled
  (`live_fdt.dts:2084-2094, 3909-3919`), so there is no AP pinmux. The binding YAML needs no change.
- **Phase 2 (stock speakerphone mic = sub mic):**
  - Add `samsung,sub-mic-bias-gpios = <&gpr3 2 GPIO_ACTIVE_HIGH>` (plus binding), the `Sub Mic` widget
    with a PRE_PMU/POST_PMD GPIO event, the routes `Sub Mic ← MICBIAS3`, `IN1BR ← Sub Mic`
    (`pacific_arizona.c:624-641, 874-875`) and a pin switch.
  - The TM2 precedent is the same pin (`ML/arch/arm64/boot/dts/exynos/exynos5433-tm2-common.dtsi:125`,
    `tm2_wm5110.c:261-273, 514`).
  - [P] gpr3-2 is shared with `sd1_bus4`, but `mshc_1` is not enabled on our board (the only hit is the
    SoC node, `exynos5433-gts28ltexx*.dts*` grep).
- **Phase 3 (wired headset):** the `Headset Mic` widget (`MICBIAS1 → IN2B`, `pacific_arizona.c:878`) and
  jack detection through `snd_soc_component_set_jack()` (arizona-jack; DT properties already present,
  `exynos5433-gts28ltexx-audio.dtsi:99-106`).

---

## 5. UCM design

### 5.1 Principles

- [P] WirePlumber's `find-voice-call-profile.lua` reacts to `voice-call-start`/`voice-call-stop`. It picks
  the highest-priority profile whose name matches `"^Voice Call"` and whose `available ~= "no"`. On stop it
  falls through to the stored-profile logic
  ([P-web] [GitHub mirror](https://raw.githubusercontent.com/PipeWire/wireplumber/master/src/device/find-voice-call-profile.lua),
  ~l.22-82; RN:166-167). The MM call states that count as active are DIALING, RINGING_OUT and ACTIVE
  (RN:167).
- [P-web] PipeWire ACP names the profile after the verb when the profile contains all of the verb's devices
  (`ucm_create_verb_profiles`); subsets become "Voice Call (…)". Profiles without PCMs are kept
  ([alsa-ucm.c](https://raw.githubusercontent.com/PipeWire/pipewire/master/spa/plugins/alsa/acp/alsa-ucm.c)).
- [I] Even so, every Voice Call device declares `hw:${CardId},0`. That gives PipeWire a sink and a source
  in the call profile, for ringback and notification sounds mixed on `SPKOUT Input 1`, call recording and
  the volume element. PinePhone's VoiceCall verb does the same (RN:160).
- **One verb only.** NB/WB is a kernel control driven by the daemon (§4.2), not a second verb. [I] Two
  "Voice Call…" verbs would both match `^Voice Call`, and WirePlumber cannot know the codec rate.
- **Division of labour.** UCM sets the routes, which stay inert. The daemon's `Modem RX/TX Switch` decides
  when audio actually flows. [I] DAPM powers a path only when it runs from an input endpoint (`Modem RX`,
  `Main Mic`) to an output endpoint (`SPK`, `HP`, `Modem TX`), so neither side alone powers anything.
- [I] All control names are the mainline ones. alsa-lib aborts an `EnableSequence` at the first failing
  `cset`, so one bad name kills the whole verb. This is why `research/ucm/out/VoiceCall.conf`
  (downstream names, card `gts28lte`) cannot be used as it is.
- **Order inside the verb:** rates first, then muxes; disabling does muxes first. [I] The ISRC and ASRC rate
  fields are then never rewritten while those blocks run, even if WirePlumber re-runs the verb in the middle
  of a call.

### 5.2 Proposed files (for `OVL/`; text only, not written)

`wm1814.conf` gains:

```
SectionUseCase."Voice Call" {
	File "/conf.d/wm1814/VoiceCall.conf"
	Comment "Phone call: modem PCM bridged inside the codec (AIF2)"
}
```

`VoiceCall.conf` (values: MP09, translated to mainline names):

```
# Voice Call verb of the SM-T715 card. The CP <-> codec PCM runs on AIF2 and the AP only routes it.
# Needs the codec patch (ASYNC Sample Rate 2, ASRC RATE 2, ISRC2 FSH value) and the "baseband" c2c link.
# The link stays off until the telephony daemon turns on 'Modem RX/TX Switch' (CP clocks running).

SectionVerb {
	EnableSequence [
		# Clock plan: AIF2 at ASYNC rate 1 (8/16 kHz, set by the link);
		# ISRC2 high side and ASRC async side at ASYNC rate 2 = 48 kHz (MP09:100-120)
		cset "name='ASYNC Sample Rate 2' 48kHz"
		cset "name='ASRC RATE 1' SYNCCLK rate"
		cset "name='ASRC RATE 2' ASYNCCLK rate 2"
		cset "name='ISRC2 FSL' ASYNCCLK rate"
		cset "name='ISRC2 FSH' ASYNCCLK rate 2"
		cset "name='Input Ramp Up' 8ms/6dB"

		# Downlink core: AIF2RX1 (left slot) -> ISRC2 interpolators -> ASRC2 (MP09:395-398)
		cset "name='ISRC2INT1 Input' AIF2RX1"
		cset "name='ISRC2INT2 Input' AIF2RX1"
		cset "name='ASRC2L Input' ISRC2INT1"
		cset "name='ASRC2R Input' ISRC2INT2"

		# Uplink core: ASRC1 -> ISRC2 decimators -> AIF2TX1/2 (MP09:1082-1085)
		cset "name='ISRC2DEC1 Input' ASRC1L"
		cset "name='ISRC2DEC2 Input' ASRC1R"
		cset "name='AIF2TX1 Input 1' ISRC2DEC1"
		cset "name='AIF2TX2 Input 1' ISRC2DEC2"
		cset "name='AIF2TX1 Input 1 Volume' 32"
		cset "name='AIF2TX2 Input 1 Volume' 32"

		# Mic high-pass (MP09:62, 88); byte syntax to confirm with amixer cget
		cset "name='LHPF1 Mode' High-pass"
		cset "name='LHPF1 Coefficients' 240,58"
	]

	DisableSequence [
		cset "name='AIF2TX1 Input 1' None"
		cset "name='AIF2TX2 Input 1' None"
		cset "name='ISRC2DEC1 Input' None"
		cset "name='ISRC2DEC2 Input' None"
		cset "name='ASRC2L Input' None"
		cset "name='ASRC2R Input' None"
		cset "name='ISRC2INT1 Input' None"
		cset "name='ISRC2INT2 Input' None"
	]

	Value {
		TQ "Voice"
	}
}

SectionDevice."Speaker" {
	Comment "Speaker (speakerphone)"

	EnableSequence [
		cset "name='SPKOUTL Input 1' AIF1RX1"
		cset "name='SPKOUTR Input 1' AIF1RX2"
		cset "name='SPKOUTL Input 1 Volume' 32"
		cset "name='SPKOUTR Input 1 Volume' 32"
		cset "name='SPKOUTL Input 3' ASRC2L"
		cset "name='SPKOUTR Input 3' ASRC2R"
		cset "name='SPKOUTL Input 3 Volume' 32"
		cset "name='SPKOUTR Input 3 Volume' 32"
		cset "name='Speaker Digital Volume' 128"
		cset "name='Speaker Digital Switch' on"
		cset "name='SPK Switch' on"
	]

	DisableSequence [
		cset "name='SPK Switch' off"
		cset "name='SPKOUTL Input 3' None"
		cset "name='SPKOUTR Input 3' None"
	]

	Value {
		PlaybackPriority 200
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
		PlaybackMixerElem "Speaker Digital"
	}
}

SectionDevice."Headphones" {
	Comment "Wired headphones (uplink from the built-in mic)"

	EnableSequence [
		cset "name='HPOUTL Input 1' AIF1RX1"
		cset "name='HPOUTR Input 1' AIF1RX2"
		cset "name='HPOUTL Input 2' ASRC2L"
		cset "name='HPOUTR Input 2' ASRC2R"
		cset "name='HPOUTL Input 2 Volume' 32"
		cset "name='HPOUTR Input 2 Volume' 32"
		cset "name='HPOUT Digital Volume' 130"
		cset "name='HPOUT Digital Switch' on"
		cset "name='HP Switch' on"
	]

	DisableSequence [
		cset "name='HP Switch' off"
		cset "name='HPOUTL Input 2' None"
		cset "name='HPOUTR Input 2' None"
	]

	Value {
		PlaybackPriority 100
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
		PlaybackMixerElem "HPOUT Digital"
	}
}

SectionDevice."Mic" {
	Comment "Built-in main microphone"

	EnableSequence [
		cset "name='IN1L Mux' B"
		cset "name='IN1L Volume' 24"
		cset "name='IN1L Digital Volume' 128"
		cset "name='LHPF1 Input 1' IN1L"
		cset "name='LHPF1 Input 1 Volume' 32"
		cset "name='ASRC1L Input' LHPF1"
		cset "name='ASRC1R Input' LHPF1"
		cset "name='AIF1TX1 Input 1' LHPF1"
		cset "name='AIF1TX2 Input 1' LHPF1"
		cset "name='Main Mic Switch' on"
	]

	DisableSequence [
		cset "name='Main Mic Switch' off"
		cset "name='ASRC1L Input' None"
		cset "name='ASRC1R Input' None"
		cset "name='LHPF1 Input 1' None"
	]

	Value {
		CapturePriority 100
		CapturePCM "hw:${CardId},0"
		CaptureChannels 2
		CaptureMixerElem "IN1L Digital"
	}
}
```

Notes on these values:

- [P] Gains come from MP09: headphones 130 (1943-1950) and main-mic in-call 24/128/32 (2689-2693). The
  speaker gains are the in-call ones (1928-1932). [P] The default `SPKOUTL Input 3 Volume` register is 0x80,
  i.e. 32 = 0 dB (`wm8998-tables.c:458`).
- [I] The verb leaves AIF1 media routing alone. `HiFi`'s own `EnableSequence` (`OVL/HiFi.conf:10-33`)
  rewrites `AIF1TX1/2 Input 1`, `SPKOUT*/HPOUT* Input 1` and `IN1L Volume` when WirePlumber switches back.
- Phase 2 adds the sub mic as the stock speakerphone mic: `IN1R Mux B`, `IN1R Volume 21`/`18`,
  `LHPF2 Input 1 = IN1R` and `ASRC1L/R Input = LHPF2` (MP09:1077-1091, 2677-2681).
- Phase 3 adds `SectionDevice."Headset"` (HP out + IN2 mic: `IN2 Mux B`, `IN2 Volume 30`/`27`,
  `LHPF1 Input 1 = IN2L`, MP09:1093-1106, 2683-2687) with `JackControl` once jack detection exists.
- **Volume:** the user volume acts on the hardware `Speaker Digital`/`HPOUT Digital` elements, so it scales
  the call audio too. [I] This is the PinePhone model. The CP volume is then set once per call to a fixed
  level by the daemon (§6.3).
- **Mute:** [I] `IN1L Digital Volume` has no switch, so a PipeWire source mute would be software-only and
  would **not** mute the uplink. The recommendation is to mute at the CP (`MIC_MUTE`/OEM `TX_MUTE`, which
  is what LineageOS does: [P-web]
  [voice.c](https://github.com/LineageOS/android_hardware_samsung/blob/lineage-18.1/audio/voice.c)
  ~l.359-363). It can be triggered by a daemon-owned ALSA user control (e.g. `Uplink Capture Switch`,
  created with `snd_ctl_add_boolean_elem_set`) declared as `CaptureMixerElem`. This needs a check that
  PipeWire then uses it as a hardware switch.
- **Bluetooth SCO:** a later phase. [I] It needs an AIF3 link and SCO routed to PCM on the BCM4358. Mainline
  arizona cannot clock an AIF at SYSCLK rate 2 (`arizona.c:1716-1750` only knows SYSCLK rate 1 or ASYNC
  rate 1). Possible approaches: AIF3 on ASYNCCLK when the BT and CP rates match (stock already wires
  `AIF3TX1/2 Input 2 = AIF2RX1`, MP09:57-58), or HFP over HCI through the AP.

### 5.3 Validating with `validate_ucm.py`

- Level 1 (structural): `python3 -I research/ucm/validate_ucm.py 04_arch_rootfs/overlay/usr/share/alsa`.
  The argument is the directory that contains `ucm2/` (`validate_ucm.py:416-430`).
  - **Current finding [P]:** run read-only today, it reports **FAIL** on the deployed `HiFi.conf`:
    "missing 'Syntax' statement". The validator requires `Syntax` in every file
    (`validate_ucm.py:299`), while alsa-ucm-conf verb files normally carry it only at the top level.
  - Fix the validator so it requires `Syntax` only in `conf.d/<card>/<card>.conf`, rather than adding
    `Syntax` to verb files. [I] alsa-lib's handling of `Syntax` inside a verb file is unverified.
- Level 2 (`--docker`, alsa-lib `snd_config_load`) is **hardwired to `ucm2/Samsung` and
  `conf.d/gts28lte`** (`validate_ucm.py:403, 406, 409`). It needs a `--card wm1814` parameter before it can
  check the deployed tree.
- Proposed level 1b, offline: cross-check every `cset` name and value against the mainline control set
  extracted from `wm8998.c` plus the machine controls, as in this note's `ctlcheck.py`. Enum values come
  from `arizona_mixer_texts` (`arizona.c:387-494`) and the rate texts. This catches `SYNCCLK rate 1`-type
  mistakes without the tablet. Once the device is reachable, replace the extracted list with a captured
  `amixer -c wm1814 controls` and `amixer -c wm1814 cget` dump.
- Level 3, on the device (later): `alsaucm -c wm1814 set _verb "Voice Call" set _enadev Speaker set _enadev Mic`,
  then `amixer -c wm1814 cget` on the routed controls, then the reverse `_disdev` and return to `HiFi`.

---

## 6. Modem side (telephony daemon ↔ CP)

### 6.1 What Android sent (OEM hook level, proven) and how the stock HAL ordered it

The OEM layer is `RIL_REQUEST_OEM_HOOK_RAW` with function 0x08 (SOUND). Bytes are
`{func, sub, len_hi, len_lo, payload…}`, where len includes the 4-byte header
(`HS/ril/libsecril-client/secril-client.cpp:57-102`).

| Call | Bytes | Values | Lines |
|---|---|---|---|
| `SetCallVolume(type, level)` | `08 03 00 06 type level` | type: VOICE 0x01, SPEAKER 0x11, HEADSET 0x31, BTVOICE 0x41 | 626-664, 85-88 |
| `SetCallAudioPath(path)` | `08 05 00 06 path 00` (**6 bytes**; byte 5 = 0 because `RIL_CALL_AUDIO_PATH_EXTRAVOLUME` is exynos4-only) | next-gen (SS333, `-DSAMSUNG_NEXT_GEN_MODEM`): EARPIECE 0x01, HEADSET 0x02, BT 0x04, STEREO_BT 0x05, HFK 0x06, **SPEAKER 0x07**, **HEADPHONE 0x08**, BT_NSEC_OFF 0x09, MIC1 0x0A, MIC2 0x0B, BT_WB 0x0C, BT_WB_NSEC_OFF 0x0D | 672-714, 90-102; `Android.mk:21-23`; `LOS/BoardConfig.mk:13` |
| `SetCallClockSync(cond)` | `08 0A 00 05 cond` | STOP 0, START 1 | 723-760; `secril-client.h:167-170` |
| `SetMute(cond)` | `08 0B 00 05 cond` | TX_UNMUTE 0, TX_MUTE 1, RX_UNMUTE 2, RX_MUTE 3, RXTX_UNMUTE 4, RXTX_MUTE 5 | 852-888; `.h:183-190` |
| `SetTwoMicControl(dev, rep)` | `08 0D 00 06 dev rep` | AUDIENCE 0 / FORTEMEDIA 1; OFF 0 / ON 1 | 931-970; `.h:196-207` |

(RN:152 says "5-byte path payload"; the code sends 6 bytes, `secril-client.cpp:679, 702, 710`.)

- [P-web] LineageOS: `SetCallVolume(…, (int)(volume * volume_steps_max))`, with steps from
  `ro.config.vc_call_vol_steps`, default `"5"`
  ([ril_interface.c](https://raw.githubusercontent.com/LineageOS/android_hardware_samsung/lineage-18.1/audio/ril_interface.c)
  ~l.31-32, 112, 193-195). [P] The stock `build.prop` has no such property (grep). [P-str] The stock HAL
  has `CscFeature_Audio_ConfigCallVolumeSteps`.
- **Stock-only calls** [P-str] `SRC`/`ARIL`: `SetSoundClockMode`, `SetAudioMode`, `SetCallRecord` (absent
  from the open-source `secril-client.cpp`).
  - `HAL` calls the clock-mode setter at `adev_open` ("Can't set SecRilSetSoundClkMode %d").
  - [I] It registers `onUnsolPcmClkState` callbacks there too ("Can't regist onUnsolPcmClkState callback
    %d"). It logs "This routine is invalid case for SLAVE_CODEC_CLOCK", which suggests the HAL tells the CP
    which side is clock provider.
- **Unsolicited reports to the AP:**
  - [P] `RIL_UNSOL_SNDMGR_WB_AMR_REPORT = 20017` and `RIL_UNSOL_SNDMGR_CLOCK_CTRL = 20022`, both
    `responseInts` (`src/lineage/android_device_samsung_gts28ltexx/include/telephony/ril_unsol_commands_vendor.h:84-89`).
  - [P-str] `SECRIL` has `IpcProtocol41::IpcRxSndClockCtrl`, `IpcRxSndWbAmrReport`,
    `SoundManager::OnClockCtrl`, `SoundRespBuilder::BuildClockCtrlResponse` and "SND-MGR: EVENT_CLOCK_CTRL".
  - [I] The chain is CP IPC SND clock-control notification → libsec-ril → unsol 20022 (ints, probably
    `{state, wb_amr}`) → HAL `onUnsolPcmClkState` ("Clock - %s, wb_amr - %d").
- **Stock HAL order** ([I] from the string set: "Entering IN_CALL state…", "waiting unsol event for call
  (CP_CLK_NONE->CP_PATH_READY)", "start_call_by_cp_clock_status", "start_call", "pcm_open voice_out",
  "select_devices() output_route", "### SetCallAudioPath ret", "end_call", "### Send stop PCM clock IPC"):
  1. The mode becomes IN_CALL.
  2. The HAL waits for the CP clock-enable unsol.
  3. It opens the voice PCMs on the baseband link (→ AIF2 `hw_params` → FLL2).
  4. It applies the `incall_*` mixer paths and sends the audio path and volume.
  5. At call end it closes the PCMs, resets the mixer, and only then sends clock STOP.
- [P-web] LineageOS orders it differently. It sends the path before opening the PCMs, never waits for a
  clock, re-opens the PCMs at 16 k on a WB-AMR report (`stop_voice_call`/`start_voice_call`), and sends
  clock STOP in `stop_voice_session` (RN:150; voice.c ~l.190-200, 224-241, 298-302).

### 6.2 IPC level (what the daemon actually writes to `/dev/umts_ipc0`)

- [P-str] `SECRIL` has IPC builders `IpcTxSndSetVolume(int,int)`, `IpcTxSndSetAudioPath(int,int)`,
  `IpcTxSndSetClockCtrl(int)`, `IpcTxSndSetClockMode(int)`, `IpcTxSndSetAudioMode(int,int)`,
  `IpcTxSndSetMute(MuteStatus)`, `IpcTxSndSetTwoMicCtrl(int,int)` and `IpcTxSndGetWbAmr()`, in both
  `IpcProtocol40` and `IpcProtocol41`.
- [P-str] The SND sub-command name tables are `SND_SPKR_VOLUME_CTRL, SND_MIC_GAIN_CTRL,
  SND_MIC_MUTE_CTRL, …, SND_AUDIO_PATH_CTRL, SND_AUDIO_SOURCE_CTRL, …, SND_LOOPBACK_CTRL` and
  `SND_VOICE_RECORDING_CTRL, SND_VIDEO_CALL_CTRL, SND_RINGBACK_TONE_CTRL, SND_CLOCK_CTRL,
  SND_WB_AMR_RPT, SND_TWO_MIC_SOL_CTRL, SND_DHA_SOL_CTRL, SND_AUDIO_MODE_CTRL, SND_CLOCK_MODE_CTRL`.
- [P] The candidate numbering is libsamsung-ipc (RN:50, 153): group SND = 0x09; `SPKR_VOLUME_CTRL 0x0901
  {type, volume}`, `MIC_MUTE_CTRL 0x0902 {mute}`, `AUDIO_PATH_CTRL 0x0903 {path}`, `AUDIO_SOURCE_CTRL
  0x0904`, `LOOPBACK_CTRL 0x0905`, `VOICE_RECORDING_CTRL 0x0906`, `VIDEO_CALL_CTRL 0x0907`,
  `RINGBACK_TONE_CTRL 0x0908`, `CLOCK_CTRL 0x0909 {sync}`, `WB_AMR_STATUS 0x090A`.
- [I] The second libsec-ril name table lists exactly 0x0906-0x090A in that order, followed by four
  SS333-era additions. That makes `TWO_MIC_SOL_CTRL 0x090B`, `DHA_SOL_CTRL 0x090C`, `AUDIO_MODE_CTRL 0x090D`
  and `CLOCK_MODE_CTRL 0x090E` plausible. **Speculative.**
- [I] The first table also has older entries (KEY_TONE…) that would put SPKR_VOLUME at 0x05. The SS333
  numbering is therefore **not proven**.
- [I] The path byte at IPC level is unknown: it could be libsamsung-ipc's older `SPEAKER 0x06/HEADPHONE
  0x07` or the next-gen OEM `0x07/0x08` passed through (RN:174).
- **How to settle it without executing anything:** statically disassemble
  `IpcProtocol41::IpcTxSnd*` and `IpcRxSndClockCtrl` in `STK/lib/libsec-ril.so`, which hard-code
  group/index/type bytes and payload layouts. This was not done here because the brief limited Samsung
  binaries to `strings`. On the device, unknown commands can be probed safely with GET requests (§7
  stage 3).

### 6.3 Daemon sequence and ordering against the ALSA routes

| # | Trigger | Daemon → CP (IPC SND) | Daemon → ALSA (`hw:wm1814`) | WirePlumber/UCM |
|---|---|---|---|---|
| 0 | startup, CP online | (optional, only if the clocks never start: `CLOCK_MODE_CTRL` "codec consumer"; value unknown. LineageOS never sent it, [P] absent from `secril-client.cpp`) | `Modem RX/TX Switch` off (kernel default) | `HiFi` |
| 1 | outgoing dial / incoming answer | `AUDIO_PATH` = speaker (OEM 0x07) or headphone (0x08) or headset (0x02); `SPKR_VOLUME` type 0x11/0x31, fixed level (e.g. 4 of 5); `TWO_MIC` OFF; `MIC_MUTE` unmute | — | MM Call DIALING or ACTIVE → profile "Voice Call" → verb + Speaker + Mic enabled (routes inert) |
| 2 | CP notification `CLOCK_CTRL` enable (+ WB flag) | — | `Modem Rate` = 8kHz/16kHz, **then** `Modem RX Switch` and `Modem TX Switch` on → link PRE_PMU → FLL2 (MCLK1 ref + AIF2BCLK sync) → AIF2/ISRC2/ASRC → audio | — |
| 3 | WB-AMR change mid-call (WB_AMR report or a new CLOCK_CTRL) | — | pins off → `Modem Rate` → pins on | — |
| 4 | output change (user picks Headphones) | `AUDIO_PATH` + matching `SPKR_VOLUME` type | [I] the daemon learns the active output from ALSA control events (`SPK Switch`/`HP Switch`) | UCM device switch |
| 5 | uplink mute | `MIC_MUTE` TX_MUTE/UNMUTE | (optionally via a user control, §5.2) | — |
| 6 | call released | after step 7: `CLOCK_CTRL` STOP (Android sends it after closing the voice PCMs, §6.1) | **first** `Modem RX/TX Switch` off (FLL2 stops in `hw_free`) | MM Call TERMINATED → back to `HiFi` (UCM disables Voice Call) |
| 7 | CP notification `CLOCK_CTRL` disable | — | pins off (idempotent) | — |

[I] The ordering rule is that **the AP route powers down before the CP stops BCLK.** This avoids running
AIF2, ISRC2 and the ASRC on a vanishing sync clock, and the pops and ASRC unlock that would follow. It is
the stock order. It also starts AIF2 only after BCLK is present (step 2), as stock does.

---

## 7. Staged test plan (for later on-device work)

Status registers are read through regmap debugfs (`/sys/kernel/debug/regmap/*-001a/registers`):

- 0xD21 (`Interrupt Raw Status 3`): ASRC2_LOCK b8, ASRC1_LOCK b7, UNDERCLOCKED b6, OVERCLOCKED b5,
  FLL2_LOCK b3, FLL1_LOCK b2, CLKGEN_ERR b1, CLKGEN_ERR_ASYNC b0.
- 0xD22 (`… 4`): ASRC_CFG_ERR b15, AIF2_ERR b13, ASYNC_CLK_ENA_LOW b9, SYSCLK_ENA_LOW b8, ISRC2_CFG_ERR b6.
- 0xD23 (`… 5`): FLL2_CLOCK_OK b1, FLL1_CLOCK_OK b0.

[P] `ML/include/linux/mfd/arizona/registers.h:922-929, 6297-6450`. DAPM state is under
`/sys/kernel/debug/asoc/wm1814/`.

| Stage | Action | Pass criteria / checks |
|---|---|---|
| 0. Offline | Build the kernel with the codec patch and the machine link (W=1, checkpatch); run validate_ucm level 1 (after the `Syntax` fix), level 1b (control names) and level 2 (after the `--card` tweak) | Builds clean; every UCM `cset` name and value exists in the mainline set |
| 1. Regression | Boot; HiFi speaker, headphone and mic tests from `docs/AUDIO_M6.md` §7.4 | `amixer -c wm1814 controls` lists `Modem RX/TX Switch`, `Modem Rate`, `ASRC RATE 2`, `ASYNC Sample Rate 2`; `ISRC2 FSH` offers `ASYNCCLK rate 2`. DAPM shows `Modem RX/TX`, `baseband-playback/capture` off. `aplay -l` still shows only device 0. dmesg has no "Can't set AIF2"/ASYNCCLK errors |
| 2. Dry run, no call | `alsaucm` Voice Call + Speaker + Mic, then force `Modem RX/TX Switch` on with no CP clocks | With REFCLK = MCLK1: no "FLL2: Timed out", FLL2_CLOCK_OK = 1, ASRC1/2_LOCK = 1, ASRC_CFG_ERR = ISRC2_CFG_ERR = CLKGEN_ERR_ASYNC = UNDERCLOCKED = 0; AIF2_ERR may be set (no BCLK). No "ASRC… event failed". No pop on toggle (listen). **This validates the clock plan without the CP.** Repeat with a debug build where FLL2 has no REFCLK: expect "Timed out waiting for lock" (proves that lock then depends on BCLK) |
| 3. CP clocks visible | Minimal IPC tool or daemon: place a call to a voicemail or announcement number; log every SND notification | A `CLOCK_CTRL` enable (and WB flag) arrives; if not, send `AUDIO_PATH`, then `CLOCK_CTRL` START (OEM value 1) and retry. **BCLK proof:** with the no-REFCLK debug build, enable the pins and see FLL2_LOCK/CLOCK_OK set at Fref = 256000 (NB) or 512000 (WB). The rate that locks is the real BCLK. AIF2_ERR clears. Safe IPC probes for numbering: GET-type `SND` requests (mute or WB-AMR status) must return a response, not a GEN_PHONE_RES error |
| 4. Downlink | Normal build; pins on after the clock unsol; Speaker device | The announcement is audible without pitch shift or crackle. ASRC2_LOCK = 1, CLKGEN_ERR_ASYNC = 0. If silent, try `ISRC2INT1 Input = AIF2RX2` (slot check) |
| 5. Uplink | Call a second phone, speak | The far end hears clean speech. ASRC1_LOCK = 1. Check both TX slots carry the mic (stock duplicates). Tune `IN1L Volume` (start 24) and check echo at speakerphone volume |
| 6. NB/WB | Calls on a 2G/3G NB link and a WB-capable (VoLTE/3G WB) link; force a mid-call change if possible | The WB flag drives `Modem Rate`; the pins-off → rate → pins-on cycle is glitch-free; no "Can't change output on active FLL" (`arizona.c:2113`) |
| 7. Devices and controls | Switch Speaker ↔ Headphones mid-call; volume; mute | UCM switch with no route loss; the daemon sends the matching `AUDIO_PATH` and volume type; PipeWire volume moves `Speaker Digital Volume`; mute reaches the CP |
| 8. End to end | GNOME Calls + MM-API daemon + WirePlumber ≥ 0.5.15 (callaudiod disabled, RN:168); 20 call cycles; screen off during a call; CP crash mid-call | The profile switches to "Voice Call" on DIALING/ACTIVE and back to HiFi; no leaked FLL2 (FLL2 off after the call, debugfs); the codec reaches BIAS_OFF afterwards; recovery after a CP reset |

### Main risks

| Risk | Symptom | Mitigation |
|---|---|---|
| FLL2 not locked to BCLK (wrong Fref NB/WB, BCLK absent, no REFCLK) | "FLL2: Timed out waiting for lock" (warning only, `arizona.c:2525`), pitch or slip noise, periodic clicks | REFCLK = MCLK1 + sync (stock); gate on the CP clock unsol; set NB/WB before power-up; the stage 2/3 lock tests |
| Clock-domain or rate errors | "Unsupported ASRC rate1/rate2" + "PRE_PMU … event failed" (`wm8998.c:58, 82`); ASRC_CFG_ERR, ISRC2_CFG_ERR, CLKGEN_ERR_ASYNC, UNDERCLOCKED | Codec patch; force SAMPLE_RATE_1 = 48 k (§3.2); rates in the verb before the muxes; never change ISRC/ASRC rates while powered |
| Pops and clicks | Thump at call start or end | Power the route only while BCLK runs; route-off before clock STOP; `Input Ramp Up 8ms/6dB`; DAPM output sequencing (`arizona_out_ev`) |
| FLL2 stopped under a live direction | The downlink dies when the mic device is removed | Refcount in the modem DAI (§4.2) |
| Wrong format or slot | Garbled audio or silence | Stock-proven I2S 2×16 NB_NF; slot swap test (stage 4) |
| CP never sends clock-enable, or needs START or CLOCK_MODE | AIF2 silent, FLL2 sync never locks | Stage 3 fallbacks (`CLOCK_CTRL` START, `CLOCK_MODE_CTRL`); static RE of libsec-ril for values |
| IPC numbering or path bytes differ from libsamsung-ipc | The CP answers with an error or routes wrongly | Static RE of `IpcProtocol41::IpcTxSnd*`; GET probes |
| Echo at speakerphone | The far end hears itself | Stock relies on CP-side processing (two-mic/DHA, [I]); keep `TWO_MIC` OFF with a single mic, tune gains; the sub mic (phase 2) as stock |
| WirePlumber does not switch | The profile stays HiFi | Check that the WP modem-manager hook is enabled; correct MM Call `State`; profile available ≠ "no" (no jack detection → "unknown", which ≥ 0.5.15 accepts) |
| Suspend during a call | Audio stops when the screen turns off | `ignore_suspend` on the link, the pins and AIF2 widgets (§4.2) |
| Small leak per call [I] | `arizona_startup` adds a hw constraint rule to the c2c link's throwaway runtime (`arizona.c:1645-1647`, `soc-dapm.c:3909`); the rules array is never freed | Low impact; note for upstream, or skip constraints when `substream->pcm` is internal |

---

## 8. Unknowns

- The SS333 IPC SND numbering and payloads (volume levels, path bytes, clock-control and clock-mode values,
  the content of the unsolicited clock report). These need static analysis of `libsec-ril.so`, which was
  not done (strings only), or on-device probing.
- Whether the CP starts AIF2 clocks by itself at call setup or only after `AUDIO_PATH` or an explicit
  START. Whether it ever needs `CLOCK_MODE_CTRL`.
- How FLL2 behaves with REFCLK + SYNC when BCLK is absent (lock status, frequency step when the
  synchroniser engages): inferred, not observed.
- Which CP slot carries the downlink (left assumed from stock) and the BCLK polarity margin (NB_NF from
  stock).
- The sub-mic hardware path under mainline (GPIO bias plus MICBIAS3) and its acoustic advantage over the main
  mic for speakerphone.
- Whether WirePlumber's modem-manager voice-call hook is enabled by default in the Arch profile, and how
  PipeWire handles hardware mute without a switch element.
- The alsa-lib byte-control syntax for `LHPF1 Coefficients` in a UCM `cset` (`240,58` assumed).
- BT SCO in calls (AIF3 clocking in mainline, BCM4358 SCO routing) is out of scope for this phase.
