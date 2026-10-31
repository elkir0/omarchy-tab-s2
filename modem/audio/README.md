# Call audio (modem <-> WM1814 AIF2)

Call PCM runs between the Shannon SS333 (CP) and codec AIF2 on a
codec-to-codec "baseband" link; the AP only routes it inside the codec.
Design: `research/modem/research/SYNTHESIS.md` D8, §6.4 (G19, G20) and
`research/modem/research/analysis/voice_audio_design.md` (VA).

| Piece | Where |
|---|---|
| Codec patch: `ASRC RATE 2`, `ASYNC Sample Rate 2`, `ASYNCCLK rate 2` in `ISRC1/2 FSL/FSH`, SR2/SR3 = 8/16 kHz, legal ASRC defaults (ASYNC rate 2 = 48 kHz, `ASRC_RATE2` = ASYNC rate 2) | `sound/soc/codecs/wm8998.c`, branch `t715-voice` of `sm-t715-linux/02_sources/linux-voice` |
| Machine: `gts28-modem` DAI <-> `wm8998-aif2`, `Modem RX Switch` / `Modem TX Switch` (off at boot), `Modem Rate` (`8kHz`/`16kHz`, EBUSY while the link is powered), FLL2 = MCLK1 24 MHz ref + AIF2BCLK sync | `sound/soc/samsung/gts28_wm1814.c`, same branch |
| UCM verb `Voice Call` (Speaker, Headphones, Mic on `hw:${CardId},0`) | `image/rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814/` |
| Build | `out/mainline-voice/` (zImage, DTB, `modules.tar.xz`: `snd-soc-wm8998.ko`, `snd-soc-gts28-wm1814.ko` changed) |
| Offline check | `python3 -I research/ucm/validate_ucm.py image/rootfs/overlay/usr/share/alsa --card wm1814 --kernel <tree> --docker --image t715-phosh-test:aarch64` |

The verb only sets routes. Nothing is powered until `Modem RX Switch` and
`Modem TX Switch` are on; DAPM then starts FLL2 (modem DAI `hw_params`),
ASYNCCLK, AIF2, ISRC2 and the ASRCs, and stops FLL2 when both switches are
off again.

## G19: dry run without the CP (VA stages 1-2)

As root on the tablet, kernel and modules from `out/mainline-voice/`, the two
UCM files installed. PipeWire holds the card: stop it for the test (as the
desktop user: `systemctl --user stop wireplumber pipewire pipewire-pulse`).

```sh
# 1. Regression and controls
dmesg | grep -iE 'wm1814|wm8998|gts28|asoc'      # card up, no "Failed to set ASYNCCLK/AIF2 clock"
aplay -l                                           # still only device 0 (playback-pri)
amixer -c wm1814 controls | grep -E "Modem|ASRC RATE|ASYNC Sample|ISRC2 FS"
amixer -c wm1814 cget name='ISRC2 FSH'             # items end with 'ASYNCCLK rate 2'
amixer -c wm1814 cget name='Modem RX Switch'       # off
amixer -c wm1814 cget name='Modem Rate'            # 8kHz
alsaucm -c wm1814 set _verb HiFi set _enadev Speaker
speaker-test -D hw:wm1814,0 -c 2 -r 48000 -F S16_LE -t sine -l 1   # HiFi speaker as before
# (main mic: docs/hardware/AUDIO_M6.md §7.4 item 4)

R=$(ls -d /sys/kernel/debug/regmap/*001a* | head -1)/registers
reg() { grep -E "^($(echo "$*" | tr ' ' '|')):" "$R"; }
reg 0103 0104 0114 0ee3          # 0011 0012 0003 4800 (probe defaults)

# 2. Voice Call routes, then force the link on with no CP clocks
alsaucm -c wm1814 set _verb "Voice Call" set _enadev Speaker set _enadev Mic
amixer -c wm1814 cset name='Speaker Digital Volume' 80   # -24 dB for the test
amixer -c wm1814 cset name='Modem Rate' 8kHz
dmesg -C
amixer -c wm1814 cset name='Modem RX Switch' on
amixer -c wm1814 cset name='Modem TX Switch' on
sleep 1
reg 0d21 0d22 0d23 0112 0113 0114 0102 0191 01a1 0ee0 0ee1 0ee2 0ee3 0ef3 0ef4 0559 055a
dmesg | grep -iE 'FLL|ASRC|ISRC|AIF2|ASYNC|CLKGEN|clock|event failed'
grep -l ': On' /sys/kernel/debug/asoc/wm1814/dapm/* /sys/kernel/debug/asoc/wm1814/*/dapm/* 2>/dev/null
amixer -c wm1814 cset name='Modem Rate' 16kHz      # must fail: Device or resource busy

# 3. Back to HiFi (switches off first)
amixer -c wm1814 cset name='Modem TX Switch' off
amixer -c wm1814 cset name='Modem RX Switch' off
reg 0191 01a1 0112                                 # FLL2_ENA, SYNC_ENA, ASYNC_CLK_ENA back to 0
alsaucm -c wm1814 set _verb "Voice Call" set _enadev Speaker set _enadev Mic set _verb HiFi
systemctl --user start pipewire pipewire-pulse wireplumber   # as the desktop user
```

What to read in step 2 (bits from `include/linux/mfd/arizona/registers.h`):

| Register | Expect |
|---|---|
| `0d23` | bit 1 FLL2_CLOCK_OK = 1 (FLL2 runs from the MCLK1 reference without BCLK) |
| `0d21` | bit 7 ASRC1_LOCK = 1, bit 8 ASRC2_LOCK = 1; bit 0 CLKGEN_ERR_ASYNC = 0, bit 6 UNDERCLOCKED = 0 (FLL2_LOCK, bit 3, may stay 0: no BCLK to synchronise to) |
| `0d22` | bit 15 ASRC_CFG_ERR = 0, bit 6 ISRC2_CFG_ERR = 0, bit 9 ASYNC_CLK_ENA_LOW = 0; bit 13 AIF2_ERR may be 1 (no BCLK) |
| `0112` | ASYNC_CLK_ENA (0x0040) set, source 5 (FLL2), frequency 3 (49 MHz): `0345` |
| `0113` / `0114` / `0102` | `0011` (AIF2 at 8 kHz) / `0003` / `0003` (SAMPLE_RATE_1 forced to 48 kHz) |
| `0191` / `01a1` | bit 0 FLL2_ENA = 1 / bit 0 FLL2_SYNC_ENA = 1 |
| `0ee2` / `0ee3` / `0ef3` / `0ef4` | `0000` / `4800` / `4800` (ISRC2 FSH = 9) / `4000` (ISRC2 FSL = 8) |
| `0ee0`, `0ee1`, `0559`, `055a` | ASRC1L/1R/2L/2R enabled; AIF2 TX1/TX2 and RX1 enabled |
| dmesg | no `FLL2: Timed out waiting for lock`, no `ASoC: PRE_PMU: ASRC... event failed`, no `Unsupported ASRC rate`, no `Failed to start FLL2` |
| DAPM | `baseband-playback`, `baseband-capture`, `ASYNCCLK`, `AIF2RX1`, `ISRC2INT1`, `ASRC2L`, `SPK` On |

No pop when the switches toggle (listen). Failures and next steps (SYNTHESIS
§6.4): `FLL2: Timed out` means FLL2 cannot run from the reference alone (U11:
gate strictly on the CP clock report); `Unsupported ASRC rate` points at a rate
field (check `0102`, `0113`, `0114`, `0ee2`, `0ee3`).

## G20: what the daemon plays on the ALSA side

`shannond --audio-hook CMD` runs `CMD open RATE PATH` and `CMD close RATE
PATH` (`modem/shannond/shannond/core.py`): `open` when the CP reports its PCM
clock on (SND 09/09 CLOCK_CTRL NOTI, odd value) or after the 3 s
`CLOCK_CTRL` E {1} fallback, again with the new rate on a SND 09/0A
WB_AMR_RPT change (0 = narrowband 8000, otherwise 16000); `close` when the
clock goes off or the last call is released, before it sends `CLOCK_CTRL`
E {0}. The IPC side (AUDIO_PATH 0x06 speaker / 0x07 headphone, volume,
TWO_MIC off, MIC_MUTE off) is sent by the daemon at DIALING/ACTIVE.

The `Voice Call` verb and the output device must be active first: WirePlumber
selects the profile in G21; in G20, run
`alsaucm -c wm1814 set _verb "Voice Call" set _enadev Speaker set _enadev Mic`
by hand (PipeWire stopped) at call start. A hook that plays the D8 order:

```sh
#!/bin/sh
# shannond --audio-hook: $1 = open|close, $2 = 8000|16000, $3 = output path
CARD=wm1814
ctl() { amixer -q -c "$CARD" cset "name=$1" "$2"; }
pins_off() { ctl 'Modem TX Switch' off; ctl 'Modem RX Switch' off; }
case "$1" in
open)                       # first open and NB/WB change: pins off -> rate -> pins on
	case "$2" in 16000) rate=16kHz ;; *) rate=8kHz ;; esac
	pins_off
	ctl 'Modem Rate' "$rate" || exit 1   # EBUSY if a switch is still on
	ctl 'Modem RX Switch' on
	ctl 'Modem TX Switch' on
	;;
close)                      # AP route off before the CP stops BCLK
	pins_off
	;;
esac
```

G20 checks (VA §7 stages 3-6): log every SND NOTI; with the switches on,
`0d21` bit 3 FLL2_LOCK = 1 and `0d22` bit 13 AIF2_ERR = 0 once the CP drives
BCLK (256 kHz NB, 512 kHz WB); audible downlink, clean uplink. Silence: try
`amixer -c wm1814 cset name='ISRC2INT1 Input' AIF2RX2` (and `ISRC2INT2`) for
the other slot. Wrong output: path bytes 0x06/0x07 versus 0x07/0x08 (C27).
At call end FLL2 must be off (`0191` bit 0 = 0).

The link and the call endpoints ignore ASoC suspend, but MCLK1 (FLL1 and the
FLL2 reference) comes from the SoC clock output: the daemon should hold a
logind sleep inhibitor for the duration of a call.

## Results on the device (2026-10-30)

Kernel `t715-modem` with the two voice commits, UCM files installed by hand
(the image does not carry `VoiceCall.conf` yet), PipeWire stopped,
`shannond --audio-hook voice-hook.sh` with `VOICE_HOOK_UCM=1`.

| Check | Result |
|---|---|
| G19 dry run | `0d23` = 0103 (FLL2_CLOCK_OK), `0d21` = 218c (FLL2_LOCK, ASRC1/2 locked, no CLKGEN or UNDERCLOCKED error), `0d22` = 0000, `0112` = 0345, `0113`/`0114`/`0102` = 0011/0003/0003, `0191`/`01a1` = 1/1, ISRC2 4800/4800; FLL2, SYNC and ASYNCCLK back to 0 with the switches off. One transient `ASRC underclocked` line at power-up |
| Hook | opens at the CP's `SND_CLOCK_CTRL` NOTI (8 kHz), closes at release; FLL2 locked on the CP's BCLK in call, `0d22` = 0 |
| Downlink | voicemail prompts recorded through ASRC2L → AIF1TX1: about −21 dBFS speech with exact digital zeros between sentences, against −70 dBFS before the route |
| Uplink | codec tone generator into ASRC1 while depositing a voicemail on the own line, then the voicemail played back and recorded: a chopped tone (0.4 s on/off) comes back as the same bursts; a steady tone comes back for 1.6 s only (the CP's noise processing removes stationary tones) |
| Desktop | PipeWire running, `t715-call-profile` switching to "Voice Call (Mic, Speaker)": outgoing and incoming calls were heard on the speaker, and speech recorded through the main microphone came back; the uplink level was high, so `IN1L Volume` is 21 (stock 24) |
| Not done | wired headset (not plugged); automatic profile selection by WirePlumber itself (0.5.13 on the image, needs ≥ 0.5.15) |

`call-audio-check.sh` repeats the downlink and uplink checks;
`modem/tools/wavfine.py` reads the recordings (1 kHz share only, never the
audio). Never send `SND_LOOPBACK_CTRL`: `{02 06}` was accepted (GEN 0x8000)
and the CP then stopped answering every IPC request until a power cycle.
