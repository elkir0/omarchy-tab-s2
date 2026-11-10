# Roadmap

Where the port stands and what comes next. The dated working journals behind it are not
published (`docs/journal/README.md`); what they established is in `docs/hardware/`,
`docs/image/` and `docs/DEPLOY.md`.

## State at 1.0.3 (2026-11-10)

Since 1.0.2, tested on the same tablet (`CHANGELOG.md` has the release's own test
notes):

- **A Wi-Fi start that fails is brought back by itself**: the service `t715-wifi-guard`,
  in the root image, checks the Wi-Fi at boot and whenever the kernel logs a failure and
  power-cycles the whole chip until a start succeeds, up to six tries (`docs/image/ROOTFS.md`);
  the kernel series `t715-wifi-recovery` makes an unbind and a bind of the PCIe host
  power-cycle the Wi-Fi — the PCIe PHY powered down as the vendor kernel does, WLAN_EN
  switchable — and brcmfmac no longer crashes on a halted firmware
  (`kernel/patches/t715-wifi-recovery`, `docs/hardware/WIFI_BT_M5.md` section 7.9). The
  chip's own failure as its radio starts is not fixed.
- Everything else is 1.0.2's: the microSD card, Bluetooth at 3 Mbaud with keyboards,
  mice and a pointer; the kernel has 1.0.2's thirteen series and this one.

## State at 1.0.2 (2026-11-08)

Since 1.0.1, tested on the same tablet (`CHANGELOG.md` has the release's own test
notes):

- **The microSD card works**: FAT32 and exFAT, up to UHS-I SDR104 on a 100 MHz bus; a card
  mounts by itself on insertion, with notifications and an "SD card" tile in quick settings
  (`kernel/patches/t715-sdcard`, `docs/hardware/SDCARD.md`, `docs/image/ROOTFS.md` "microSD
  card"), and two guards keep a card from impersonating the eMMC: a udev rule keeps
  `/dev/disk/by-partlabel/*` on the eMMC, and the initramfs reads partition names from the
  eMMC only.
- **Bluetooth at 3 Mbaud**, was 460800 baud: room for high-quality audio
  (`kernel/patches/t715-bluetooth`, `docs/hardware/WIFI_BT_M5.md` section 7.8). A speaker
  played cleanly in SBC while the link carried all the old baud rate could.
- **Bluetooth keyboards and mice connect**, through UHID, which no kernel had before
  (`kernel/patches/t715-bluetooth`); a mouse shows a pointer, hidden on touch and after 3 s
  still, and the Bluetooth adapter no longer goes missing on some boots (the address script
  raced the kernel's auto-off window).

## State at 1.0.1 (2026-11-08)

Since 1.0 Beta 1, tested on the same tablet (`CHANGELOG.md` has the release's own test
notes):

- **The GPU and the A57 cores scale**: the GPU from 160 to 700 MHz at the vendor's eight Mali
  levels on the G3D PLL, the A57s from 800 MHz to 1.5 GHz in the vendor's body bias and EMA
  with their own cooling maps; the A53s still 400 MHz to 1.2 GHz (`kernel/patches/t715-power-gpu`,
  `kernel/patches/t715-turbo`, `docs/hardware/CPUFREQ.md` section 9,
  `docs/hardware/GPU.md` section 10.14).
- **Battery saver tile**: power-saver takes the A57s offline, caps the A53s at 1 GHz and the
  GPU at 266 MHz, and turns Hyprland's animations off; balanced gives everything back
  (`docs/hardware/BATTERY.md` section 13).
- **Heat and low-battery guard**: every 30 s, while balanced is active, a battery at 52.0 °C
  or more (cleared at 49.0 °C), or at 20 % or less off the charger, caps the A57s at 1.2 GHz
  and the GPU at 420 MHz (`docs/hardware/BATTERY.md` section 13).
- **Stay awake tile**: it keeps the screen on now, and starts off: the screen goes off after
  two minutes by default (omamobile-shell 0.2.94-4).
- **Animations on**: with the GPU scaling to 700 MHz they are smooth again; 1.0 Beta 1 had
  them off (a fixed 266 MHz GPU felt snappier without them), and the Battery saver still
  turns them off.
- **First boot on Windows**: a `rootfs-omarchy.img.sha256` sidecar written on Windows, with
  CR LF, a byte order mark and an upper-case hash, is accepted (1.0 Beta 1's images refuse it).

## State at 1.0 Beta 1 (2026-11-05)

Since 0.9.3, tested on one tablet (`CHANGELOG.md` has the release's own test notes):

- **Install for other people**: `docs/INSTALL.md`, Odin packages next to `boot.img` and
  `recovery.img` (`image/tools/make-release`, `image/tools/pack-odin`), a first boot that shows its
  progress and its errors on screen and checks the image against its `.sha256`, and no root shell
  on the USB cable by default.
- **Power with the screen off**: 754 mW, about 20 hours (`docs/hardware/BATTERY.md` sections 9-11):
  the A57 cores offline with the screen (`kernel/patches/t715-power`), the GPU's power domain off
  while it idles, the Wi-Fi link in ASPM L1.2 with a 100 ms power save timeout, the lock screen's
  blanking. The A53s scale from 400 MHz to 1.2 GHz under schedutil (`t715-cpufreq`).
- **Modem switch**: the Modem tile and Réseau mobile turn the CP off now and at boot, or only
  while the screen is off; a powered CP costs 155 mW of the standby draw
  (`docs/hardware/MODEM.md` 5.4, `docs/hardware/BATTERY.md` section 12).
- **Cameras**: libcamera's software ISP on the CPU and omarchy-mobile's Camera app on both
  cameras (`kernel/patches/t715-camera-mc`, `docs/image/PACKAGES.md`); the sensors' tables are
  made at the first boot from the tablet's own firmware.
- **Coding agents**: Pi preinstalled; Claude Code as an opt-in installer with a signed manifest.
- **Omarchy 4.0.6, pinned** (`docs/image/REPACK.md`): 4.5.0 breaks omarchy-mobile's touch patches.

## Next: the roadmap after 1.0.2 (2026-11-09)

Every function of the tablet that this port does not drive yet, or drives only in part, with what
it would bring and what it would take. Sleep comes first and is under way; the rest is ranked by
what it brings against what it costs. **Study** means a source study first, written up under
`docs/hardware/`, then a decision: nothing goes in that does not earn its place.

| # | Function | What it brings | What it takes | State |
|---|---|---|---|---|
| 1 | Sleep (suspend to RAM) | standby in days instead of about 20 hours | large: test kernels, then tests with the owner at the tablet | under way |
| 2 | A modem that sleeps | about 150 mW less with the screen off and the modem on | small: calls and SMS with a SIM, then the release kernel | validated without a SIM |
| 3 | Automatic brightness | the screen follows the room's light | medium: a new light sensor driver | not started |
| 4 | Headphones and headsets | plug detection, the headset's microphone, headsets in calls | small to medium | not started |
| 5 | USB host (OTG) | USB keys, keyboards, hubs, Ethernet adapters | medium | not started |
| 6 | Bus and memory clocks | less power while awake | medium for the buses, large for the memory | a bus test kernel is built |
| 7 | Deep CPU idle states | less power while awake | large: a new cpuidle driver | studied |
| 8 | Telephony features | MMS, USSD, call hold, SIM PIN, network choice | small to large, item by item | not started |
| 9 | Hardware video decoding | H.264 in mpv and GStreamer on less CPU and battery | small kernel side | studied |
| 10 | Grip sensors | the radios' transmit power back-off, as on Android | study first | not started |
| 11 | MHL video out | a screen or a TV on the USB port | study first: is the chip there? | not started |
| 12 | Fingerprint reader | unlocking with a finger | one test decides; then very large | studied |
| 13 | Calls without 2G and 3G (VoLTE) | calls once those networks are switched off | study; likely out of reach | not started |

### 1. Sleep (under way)

With the screen off the SoC stays awake: 754 mW, about 20 hours (`docs/hardware/BATTERY.md`
section 11). Stock Android suspends to RAM: the PMU's sleep table, the wake masks, then one
`SMC_CMD_SLEEP` to the secure monitor, a call mainline's firmware interface already makes; its log
shows 8 sleeps in 256 s on this tablet. A test kernel (branch `t715-sleep`, not published yet)
runs the 5433 sleep entry up to that call: every `pm_test` level passes, five dry runs in a row,
and a suspend-to-idle wakes on the RTC alarm. Three fixes got it there: GPIO_FINGER left to the
secure world, the AUD clock gates opened before the domain powers off, the AUD trace bus out of
the LPI handshake.

The steps, the riskiest last:

1. The test series on the daily kernel's tree (`#10`: the microSD card, Bluetooth at 3 Mbaud).
   Done on 2026-11-09 (branch `t715-sleep2`), with two additions: a switch that arms a
   dry run kernel for one real sleep at a time, and stock's power-down state for the eight
   PMIC and power-control pins below. Its scripts: `image/tests/ondevice/pmtest.sh`,
   `wifi-sleep.sh`, `sleep-regs.sh`, `real-sleep.sh`.
2. The Wi-Fi through a suspend-to-idle. Stock keeps the chip powered through sleep: a D3
   request to its firmware, PME_Turn_Off, PERST#, then a D0 message on resume. Our firmware
   (linux-firmware's 7.112.300.14) acked brcmfmac's D3 request once in two tries on
   2026-11-09, through the SBMBX doorbell (stock's doorbell 1 goes unread); when it does
   not, it is not reading its mailbox at all. The fallback, cutting the chip's power and
   probing it afresh, is unreliable too: in off/on cycles with no suspend it fails about once
   in four, with ASPM off as well, in a PCIe link-down event right after the firmware brings
   its radio up, and the same failure now and then left the daily system without Wi-Fi at
   boot. Two causes are fixed since 2026-11-09 (`docs/hardware/WIFI_BT_M5.md` section 7.9):
   mainline never powered the PCIe PHY down, so after one failed start the link stayed
   unusable until a reboot; and the combo chip's shared part stays powered while Bluetooth
   is up, so a failed start needs the whole chip power-cycled. The kernel series
   `t715-wifi-recovery` and the service `t715-wifi-guard`, in the daily system since that
   day and in 1.0.3, bring a failed start back that way (20 simulated boots: 11 good at
   once, 8 brought back, 1 not), and brcmfmac no longer crashes on a halted firmware. Left:
   the chip's own failure as its radio starts (its supplies and crystal as stock powers it,
   the firmware's 37.4 MHz path), then the Wi-Fi off before a sleep and brought back after
   it, or the D3 path again. The test kernel has a run-time switch for each piece (stock's
   handshake, the chip kept powered), and the tests run unattended from RECOVERY
   (`t715.autotest=1`, `t715.crashlog=1`; `image/tests/ondevice/autotest-wifi.sh`,
   `wifi-d3.sh`, `wifi-cycle.sh`, `wifi-guard-test.sh`).
3. The reads the first real sleep needs: the power-down state of WRSTBI (gpf5-4: low, it resets
   the PMIC's bucks) and of the other power-control pins, as sboot leaves them and as the test
   kernel sets them; `XXTI_SYS_PWR_REG` with `PMU_DEBUG`; and the PMIC's PWREN-controlled
   modes.
4. The first real `SMC_CMD_SLEEP`, the owner at the tablet: the CP off, the Wi-Fi off, USB
   unplugged, woken by the power key. Done on 2026-11-09: seven real sleeps, seven clean wakes,
   one by the power key and six by the RTC alarm (10 and 20 s); every core, the panel, the
   storage and the touchscreen came back. Left: 100 cycles, and the drain over an hour asleep.
5. Stock's power-down pin table (214 entries) and the devices back in: Wi-Fi, Bluetooth's wake,
   USB.
6. The PMIC rails that stock runs under PWREN, off in sleep.
7. The policy: sleep when the screen goes off, after a delay; the CP off before and back on
   after, as the modem port requires (`docs/hardware/BATTERY.md` section 10); the power key, the
   Home key, the cover and Bluetooth devices wake it; an RTC wake now and then to watch the
   battery. While it sleeps no call or SMS comes in, and the Wi-Fi cannot wake it: its host wake
   sits on an EINT (gpf) that mainline cannot arm.

Later, the owner's call: the modem kept on through sleep, with stock's handshake (the CP-led
unmount, CP2AP_WAKEUP armed as a wake source), a change to the modem stack.

### 2. A modem that sleeps

The optional series `t715-linkpm` lets the CP release the MIPI-LLI link and sleep
(`research/modem/LINK-PM.md`, `docs/hardware/MODEM.md` section 5.5). Measured on 2026-11-06,
screen off, no SIM, twelve 9-minute windows: 590 mW against 744 with the link held, about 150 mW
less, and no more than with the CP off. Left: calls and SMS with a SIM, crash recovery under
`fsm`, then the release kernel and `fsm` by default. A CP switched off leaves the AP's LLI
mounted, which probably explains why CP off draws a little more than `fsm`.

### 3. Automatic brightness

The ambient light sensor is a Capella CM36652 (stock `i2c@30/cm36652@60`) with red, green, blue
and white channels; mainline's `cm36651` is a different die (`docs/hardware/SENSORS_M7.md`). It
takes a new IIO driver after Samsung's, its node, then iio-sensor-proxy's ambient light and a
brightness policy in the shell. The proximity half has no use on a tablet with no earpiece.

### 4. Headphones and headsets

The jack plays only when Headphones is picked by hand: the machine driver never hands the jack
to `arizona-jack`, so nothing detects the plug, and the headset's microphone (MICBIAS1 to IN2B)
is left out (`docs/hardware/AUDIO_M6.md` section 7.3). Calls on a wired headset were never tried.
Bluetooth headsets in calls need the SCO link (AIF3, left out too) or SCO over the UART.

### 5. USB host (OTG)

The port runs as a USB device only (`dr_mode = "peripheral"`, `docs/hardware/DT_M2.md`): it
carries the USB cable's network link. Host mode takes the role switch from the SM5703 MUIC's ID
detection, dwc3 in dual role, and 5 V out to the device (the SM5703 charger's boost, to check).

### 6. Bus and memory clocks

The internal buses stay at their top rate with `vdd_int` at 0.975 V, and the DRAM at 825 MHz with
`vdd_mif` at 1.0125 V, where stock scales both down at idle, the DRAM to 78 MHz
(`docs/hardware/BATTERY.md` section 11, `docs/hardware/CPUFREQ.md` section 6). A test kernel for
the INT buses (`exynos-bus` devfreq) is built and was never booted; its run needs the owner, with
the screen on. The memory has no mainline driver: stock's DREX timing tables and its switch
sequence would need porting. The gain is not measured.

### 7. Deep CPU idle states

Stock powers idle cores and clusters down through the secure monitor
(`research/cpuidle/FINDINGS.md`); mainline has no cpuidle driver for this SoC, so idle cores only
wait for an interrupt. It takes a new 5433 cpuidle driver with stock's monitor calls and PMU
writes. It counts while the screen is on, and less once sleep works.

### 8. Telephony features

From `docs/image/OMARCHY-MOBILE-AUDIT.md` section 7: USSD (a typed `*...#` goes out as a call),
call hold and conference, the voicemail indicator, cell broadcast alerts, MMS (`mmsd-tng` on
armv7h, `Sms.Data`, an APN, the app side), SIM PIN and PUK management, network scan and manual
choice. Small to large, item by item, in `shannond`'s facade and the apps.

### 9. Hardware video decoding

The MFC v8 decodes H.264, VP8, MPEG and VC-1, not VP9 or AV1 (`docs/image/VIDEO-DECODE.md`): a
browser on YouTube gains nothing, mpv and GStreamer would play H.264 on less CPU and battery. The
kernel side is a node and the firmware.

### 10. Grip sensors

Two Semtech SX9310 (stock `sx9310` and `sx9310_wifi`), which mainline's `sx9310` driver handles
(`docs/hardware/HARDWARE_MAP.md` section 12). On Android they lower the radios' transmit power
when a body is near. Study first what stock does with them, the modem's side included.

### 11. MHL video out

The stock device tree has a SiI8240 MHL transmitter on `hsi2c_11` (`docs/hardware/HARDWARE_MAP.md`
section 4), and its driver handled cable events under Android. First check that the chip answers
on its bus; mainline has no SiI8240 driver, and the 5433's HDMI block would feed it.

### 12. Fingerprint reader

A Synaptics Viper sensor on SPI2, which stock's setup leaves to the secure world
(`docs/hardware/FINGERPRINT.md`). One read of SPI2's `CH_CFG` from a RECOVERY test kernel, CP
off, decides (section 7): an abort means a hardware lock, and the end of it; a clean read opens a
large project: an SPI client, the Viper protocol by reverse engineering with no specification, a
libfprint driver and a matcher. The read can ride along with a sleep test session.

### 13. Calls without 2G and 3G

No IMS or VoLTE path exists: calls fall back to 3G or 2G (CSFB) and stop where an operator
switches those off (`research/modem/research/SYNTHESIS.md`, "Horizon"); data does not depend on
them. Study what the CP firmware and stock's IMS stack would need; likely out of reach.

### Fixes and the system, alongside

- **The Camera app's GPU faults**: job faults, page faults and GPU resets while it runs, with
  1.0 Beta 1's kernel and 1.0.1's alike (`CHANGELOG.md`, 1.0.1's known issues); find whether
  Mesa's Midgard driver, the preview's buffers or the kernel's import path makes them
  (`docs/hardware/GPU.md` section 10.10).
- **Omarchy's keyboard shortcuts with a Bluetooth keyboard**: they did not answer with the
  keyboard tried on 2026-11-08, its 226 default bindings loaded (`docs/hardware/WIFI_BT_M5.md`
  section 7.8); not investigated yet.
- **The touch shell's crash while a Bluetooth mouse paired**, once (Quickshell 0.3.2,
  SIGSEGV, the shell back by itself after about 40 s): find what in the BlueZ property
  updates took it down (`docs/hardware/WIFI_BT_M5.md` section 7.8).
- **The Wi-Fi guard's backlog after a recovery**: once a recovery with failed tries ends,
  the service replays those tries' kernel lines, one check every 10 s (9 lines, about a
  minute and a half, in the 1.0.3 test). Harmless, nothing is cycled, but it should skip
  the lines older than its last check.
- **NetworkManager at shutdown**: read what the shutdown hooks catch, then fix the wait.
- **Omarchy 4.5** once omarchy-mobile's touch patches follow it.
- **Installs on other tablets**: the Odin, Heimdall and TWRP paths of `docs/INSTALL.md` were
  never run end to end; a first-boot wizard; a TWRP zip; a USB link Windows can use (RNDIS or
  NCM) and a USB vendor ID of our own instead of the one the gadget borrows.

### Not planned

- **Hibernation to disk**: once suspend to RAM works it would add a resume through sboot and a
  full kernel boot, and gigabytes written to the eMMC at each sleep. At most a
  suspend-then-hibernate at very low battery, after item 1.
- **The A57s above 1.5 GHz, the A53s at 1.3 GHz**: decided against, power and heat for little
  (`docs/hardware/CPUFREQ.md` section 0).
- **WPA3**: the Wi-Fi firmware has none.
- **VP9, AV1 and HEVC in hardware**: the MFC has no VP9 or AV1, and HEVC is a separate block with
  no mainline driver.
- **The camera's hardware ISP**: a Cortex-R5 running vendor firmware, with no mainline driver;
  libcamera's software ISP stays.
- **The prints enrolled under Android**: sealed by a trustlet, and the matcher runs only inside
  TrustZone.
- **Emergency calls**: never dialled during the bring-up, by rule; do not rely on the tablet.
