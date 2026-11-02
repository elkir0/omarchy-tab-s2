# Modem — Shannon SS333 cellular modem (SM-T715)

**Scope.** The LTE modem of the Galaxy Tab S2 8.0 LTE (SM-T715, `gts28ltexx`)
under the mainline 6.12 kernel and the Omarchy desktop: CP boot, telephony
(SIM, registration, SMS, calls), mobile data through NetworkManager, and the
call audio link. The design, its sources and the reasoning behind every value
are in `research/modem/research/SYNTHESIS.md` (v2). This document is the
operating summary.

**Status (2026-10-30, on the device).**

| Milestone | Result | Evidence |
|---|---|---|
| CP boot to ONLINE | **works**: BOOT over SPI, MIPI-LLI mount, TOC/MAIN/NV/FIN, ONLINE ≈ 9.9 s after power-on | loader and kernel logs, §6 |
| Recovery after a CP crash | **works**: forced crash → CRASH_EXIT → silent reset → ONLINE ≈ 14 s later, daemon restart contract | §6.3 |
| SIM and registration | **works**: USIM, CS and PS registered, UMTS/LTE | `shannonctl status` |
| SMS | **works**: SMS sent to the own line and received (same text and sender) | §6.4 |
| Mobile data | **works**: NetworkManager brings the bearer up through the ModemManager facade; `rmnet0` gets address, default route and DNS | §6.5 |
| LTE | **works**: tens of Mbit/s down, SMS on LTE, calls fall back to 3G and return to LTE; registered at boot with no client; the unit runs `--modes lte,umts,gsm --radio-on` | §6.7 |
| Calls (signalling) | **works**: outgoing calls (voicemail, own line) and an incoming call answered from the desktop: dialing/incoming → active → released, CP audio clock reported | §6.6 |
| Call audio | **works both ways** on the speaker and the main microphone, checked by ear from the desktop (PipeWire running, `t715-call-profile` selects the Voice Call profile): a call was heard on the speaker, and speech recorded through the tablet's microphone came back; headset not tested | §7 |
| Cold boots, units | **6/6** cold boots to ONLINE (9.89-9.94 s) through `shannon-loader.service`; `shannond.service` with the facade; NetworkManager data at the first attempt once the PDP retry below was fixed | §6.1 |
| Starts by itself | **works** on the persistent root: CP ONLINE 22.8 s after the kernel started, no command typed | §5.1 |
| From the desktop | **works** as the desktop user in the graphical session: `nmcli` data, SMS to the own line, voicemail call | §5.1 |

> **Emergency calls: do not rely on this tablet.** Emergency numbers were
> never dialled during the bring-up (it is forbidden for tests), `shannond`
> refuses them, and nothing has verified that an emergency call would work
> under Linux. Use a phone.

Nothing here writes the RADIO, EFS or `m9kefs*` partitions: their SHA-256
was checked before and after every hardware session and never changed.

---

## 1. Hardware

| Part | Value |
|---|---|
| CP | Samsung Shannon SS333 (same family as the Galaxy S6), firmware in partition RADIO (p13): TOC, BOOT (0x29FC bytes), MAIN (0x21271A0 bytes), NV (0x100000, from EFS), OFFSET |
| Boot link | SPI4 @ 0x14d00000, mode 0, 8 bit, 100 kHz, hardware auto chip select (gpv7-1 CLK, gpv7-2 nCS, gpv7-4 MOSI; gpv7-3 MISO parked) |
| Main link | MIPI-LLI @ 0x10f24000 over the M-PHY (shared reference clock, HS-G2A); the **CP is the master**, it mounts the link; the AP side answers `HIBERN8_EXIT_DONE` with `LLI_MOUNT_CTRL` |
| Shared memory | `cp-shmem@de000000`, 8 MiB, `no-map`; remap value 0x0001BC97 in `IAL_LL/BE_INIT_ADDR_REMAP`; `cp-guard@de920000` (0x60000, `no-map`) above it as a canary zone |
| Clocks | CMU_CPIF: `aclk_cpif_200` at 100 MHz (assigned), the two 150 MHz symbol clocks, the SRC_SEL_CPIF1 muxes |
| IRQs | GIC SPI 184 (LLI), 185 (LLI signal/doorbell) |

Control GPIOs (all active high):

| Line | Pin | Direction (AP) |
|---|---|---|
| CP_ON | gpr3-1 | out |
| CP_RESET | gpc0-5 | out |
| PDA_ACTIVE | gpg2-1 | out |
| PHONE_ACTIVE | gpa2-3 | in |
| CP2AP_STATUS (`cp_status`) | gpa2-5 | in |
| IPC_INT2CP | gpa2-6 | out |
| AP_DUMP_INT | gpr2-0 | out |
| CP2AP_WAKEUP | gpa3-1 | in |
| AP2CP_WAKEUP | gpf5-0 | out |
| AP2CP_STATUS | gpf1-2 | out |

## 2. Kernel

Series `kernel/patches/t715-modem/` (16 patches on `t715-bringup`, see
`kernel/README.md`), built with:

```bash
bash kernel/kbuild-mainline.sh --fragment gts28ltexx_modem.config
```

| Piece | Module / file | Notes |
|---|---|---|
| CMU_CPIF clocks | built in (`clk-exynos5433.c`) | IDs 12-25 appended; nothing changes at boot unless a consumer asks |
| MIPI-LLI | `exynos5433-mipi-lli.ko` | `allow_hw` (default 0); `remap_ok` re-read at every `SW_RESET_DONE`, mount refused otherwise; AFC re-run until a mount gets credits (`afc_valid`); IRQ storm guards; debugfs `mipi-lli/status` |
| modem_v1 | `sec_modem_v1.ko` | Samsung 3.10 driver ported to 6.12 ARM32; userspace ABI unchanged (`/dev/umts_*`, `rmnet0-3` RAWIP); `allow_hw` (default 0): no line moves and `MODEM_ON` is refused until it is set; SPI tripwire (BOOT length, CRC, one write per power-on); debugfs `ss333/status` |
| SPI | `spi-s3c64xx.ko` | DMA timeout ×10 for auto chip select ports: the controller idles about 3-4 clocks per byte, so 10 748 bytes at 100 kHz take 1.29 s |
| Device tree | `exynos5433-gts28ltexx-modem.dtsi`, `-modem-ss333.dtsi`, `spi4` alias | reserved memory, LLI node, `mif_pdata` with the 10 GPIOs and 13 io-devices, SPI4 `modem-boot@0` |
| Call audio | `snd-soc-wm8998.ko`, `snd-soc-gts28-wm1814.ko` | baseband DAI to codec AIF2, `Modem RX/TX Switch`, `Modem Rate` |

The test BOOT keeps the three modem modules off the automatic load
(`t715.modblacklist=exynos5433_mipi_lli,sec_modem_v1,spi_s3c64xx`); they are
loaded by hand and `allow_hw` is written afterwards (§5).

## 3. CP boot sequence (shannon-loader)

`modem/loader/` (C11, static ARMv7, GPL-2.0-or-later, written from the
specification; no Samsung code). One process: preflight (no side effect) →
boot attempt B1-B17 → online (holds `umts_boot0`, `umts_ipc0`, `umts_rfs0`,
`sd_notify READY=1`) → supervisor (silent reset after a crash, at most 5 per
30 min). It writes only `/run/shannon/cp-state` (`session=N state=…`).

Measured on the device (2026-10-30):

| Step | Time |
|---|---|
| B1-B3 SET_TX_LINK(LLI), MODEM_ON (LLI reset, `SW_RESET_DONE`, remap check), BOOT_ON | 1.03 s |
| B4-B7 DL_START, SET_TX_LINK(SPI), BOOT over SPI (10 748 bytes, CRC32 0x5DB1F04C, pinned SHA-256) | 1.29 s |
| link mount after the SPI write: `HIBERN8_EXIT_DONE` +22.6 ms, `Mount intr` +1.8 ms, CP2AP_STATUS high 0.05 ms later | — |
| B8 `cp_status` = 1 | 0.10 s |
| B11 0x900D → 0xA00D (closes the eFuse window) | < 1 ms |
| TOC, MAIN (16 975 frames, 34.7 MB, 3.38 s; CRC accepted 3.3 s), NV (512 frames), FIN | 6.9 s |
| B13-B17 BOOT_OFF, holders, BOOT_DONE, STATUS 4 | 0.54 s |
| **power-on to ONLINE** | **9.9 s** |

Rungs for bring-up: `--stop-after={preflight,power,spi,lli,stage0,toc,main,nv,fin}`
(every rung ends with `MODEM_OFF`, after the 10 s eFuse settle when the BOOT
already ran).

## 4. Telephony userspace

| Component | Where | Role |
|---|---|---|
| `shannond` | `modem/shannond/` (Python 3, GPL-2.0-or-later) | sole owner of `umts_ipc0` (Samsung IPC 4.1) and `umts_rfs0` (RFS: NV and file service in a tmpfs sandbox, seeded from the verified NV copy); state, events, commands; `shannonctl` CLI over `/run/shannond/control` |
| ModemManager facade | `shannond --mm` (`modem/shannond/shannond/mm/`) | exports `org.freedesktop.ModemManager1` (MM 1.24 API) so NetworkManager, mmcli-style clients and GNOME Calls work unchanged; the real ModemManager must stay absent or masked |
| Units | `modem/systemd/shannon-loader.service` (Type=notify), `shannond.service` (`--mm`) | install disabled; enable only after the gates in SYNTHESIS §6 |
| D-Bus policy | `modem/shannond/dbus/org.freedesktop.ModemManager1.conf` | → `/usr/share/dbus-1/system.d/` |
| Audio hook | `modem/audio/voice-hook.sh` | `shannond --audio-hook`: codec switches and rate at call audio open/close |
| Test tools | `modem/tools/cp-force-crash.py`, `modem/tools/canary.py`, `modem/tools/cp-kill.py`, `modem/audio/call-audio-check.sh`, `modem/tools/wavfine.py` | crash gate, guard canary, emergency CP off, call audio checks |

Facts learned on the device that the code now follows:

- The CP sends a new `SMS_DEVICE_READY` NOTI after every SET: answer only the
  first one per CP session (otherwise a 250 Hz ping-pong).
- A daemon started while the CP is already ONLINE gets no spontaneous frame:
  it reads `PWR_PHONE_STATE`, the PIN status and the registration with GETs.
- LTE registrations arrive as `NET_REGIST` NOTIs with domain 1: re-read the CS
  and PS domains.
- `SMS_DELIVER_REPORT` is acknowledged by a NOTI, not by `GEN_PHONE_RES`.
- SIM file access (`SEC_RSIM_ACCESS`) needs app selector 4 and the USIM AID
  (the partial AID `A0000000871002` works) for files under ADF USIM.
- The first PDP activation of a CP session fails with GEN 0x8005 (the CP
  starts the PS attach) and the CP then forgets the context definition: an
  activation alone keeps failing with 0x8001. `shannond` retries
  `GPRS_DEFINE_PDP_CONTEXT` and `GPRS_PDP_CONTEXT` together (up to 16 × 3 s);
  the second try connects.
- `NET_MODE_SEL` is a RAT mask (bit 0 GSM, bit 1 WCDMA, bit 3 LTE).
  The daemon and the unit use `--modes lte,umts,gsm`; LTE stays out of the
  mask until an attach APN is known (§6.7).
- **LTE needs `GPRS_LTE_ATTACH_APN_INFO` before the attach.** Without it the
  network accepts the CP, then rejects it at once (reject 0x0a) and the CP
  stays in limited service (§6.7). `shannond` sends it before radio on; a
  connection request sends its own APN before waiting for registration.

## 5. Installing and using it

### 5.1 Permanent install (persistent root)

Boot a BOOT built from the modem series on the persistent root (the daily
knobs plus `t715.modblacklist=exynos5433_mipi_lli,sec_modem_v1,spi_s3c64xx`,
`out/boot-modem-persist/boot.img`), then:

```bash
bash device/modem-install.sh --apn <operator APN> --user <desktop user>
```

It installs the loader, `shannond`, the units, the D-Bus policy, the udev
rules, the modprobe blacklist and the `Voice Call` UCM files, enables
`shannon-modem-prepare.service`, adds the `t715-mobile` gsm connection
(autoconnect off) and puts the desktop user in the `radio` group. At every
boot that service loads the modules, sets `allow_hw`, waits for the battery
to cool below 39 °C, then starts `shannon-loader.service` (CP ONLINE) and
`shannond.service` (ModemManager facade). It is `Type=simple`, so the wait
holds no boot target and leaves no queued job. Under a kernel without the
modem series its condition skips the whole chain.

**Battery gate.** The CP is never powered on under 5 % (`SL_BAT_MIN_PERCENT`).
It only guards a power-on, for the eFuse window of the CP's boot: a running CP
stays on to the end of the battery. The bring-up rule said 50 %, which left a
reboot under that without a modem, so the owner lowered it on 2026-10-31. 5 % is a
margin, not a measurement. The loader's exit 8 is not restarted: a CP refused
here stays off until `systemctl restart shannon-loader` or the next boot.

**Temperature gate.** The CP is never powered on at 55.0 °C or more
(`shannon-loader --max-temp=55.0` in the unit; the loader's default and the
original SYNTHESIS rule 1 say 40.0). Since the `t715-charger` kernel the
value is the battery thermistor (ADC channel 2, `docs/hardware/BATTERY.md`
§8), 40-45 °C in use. Before, it was the SM5703 gauge's own sensor, which
reads 48-66 °C on a charger and would have held the modem back. Stock Android
powers the CP on at any temperature, so the owner raised the gate to 55.0 on
2026-10-30, a guard against real overheating only. The prepare service waits
for less than 54.0 °C; `journalctl -u shannon-modem-prepare` shows any wait.

From the desktop (the user in `radio`):

```bash
shannonctl status
```

```bash
shannonctl sms send <number> "text"
```

```bash
shannonctl call dial <number>
```

```bash
nmcli connection up t715-mobile
```

(`/usr/local/bin/shannonctl` links to `/usr/lib/shannond/bin/shannonctl`;
numbers and texts are masked unless `--show` is given.) The NetworkManager
applet sees the modem as "umts_ipc0" (gsm).

To remove it: `systemctl disable shannon-modem-prepare.service` and delete
the installed files listed in `device/modem-install.sh`.

### 5.2 omarchy-mobile's tools

omarchy-mobile's telephony talks to the ModemManager API, which `shannond`
serves in place of its `omamobile-mmd`. Packages: `docs/image/ROOTFS.md`.

| Tool | State on the device (2026-10-30) |
|---|---|
| Bar: cellular icon, technology, call chip (`omamobile-cell-watch`, `omamobile-call-watch`) | **works**: "LTE", then "3G" and a green timer during a call |
| Mobile data tile | **works** through its scripts (on in 1 s, ping, off), on NetworkManager's gsm connection |
| `omatel-agent` (`Phone1`, `Messages1`) | **works**: call placed and hung up through it, SMS sent to the own line and both directions stored |
| Call card (`omamobile.call`) | runs: ringing card, and in-call controls over the lock screen, with a layer rule that keeps it above the lock; on an unlocked tablet the in-call screen is the Phone app's. No Speaker button there or in `omaphone`: the tablet has no earpiece, the sound follows the jack |
| Airplane mode | **works** in the session, both ways, through the tile: `nmcli radio wwan off` turns the radio off (facade disabled, CP in low power, no registration), `shannond` keeps it off across a restart and a boot (`radio_off` in `settings.json`), `--radio-on` then leaves it alone |
| Phone app (`omaphone`) | **works**: the owner placed a call from it and the Mute button muted (2026-10-30) |
| Messages app (`omamessages`) | **works**: lists conversations; a message opened from an `sms:` link was sent from the app to the own line and came back (2026-10-30) |
| New message | sound (feedbackd `message-new-sms`) and a glance at the screen, from `omatel-agent`, under the rules of its notification plus Do Not Disturb |
| Delivery reports | `DeliveryReportRequest` reaches the TPDU (first octet 0x21, read in the log), and a `SMS_STATUS_REPORT` would set `DeliveryState`. **None was seen** in the tests: "Delivered" is not shown on the device yet |
| Service messages | port-addressed and binary SMS, TP-PID 0x40, DCS group 1100 and `//VVM` are acknowledged and dropped in `shannond` (`service_message`, one log line, no content): no blank bubble, no false conversation, nothing of a `//VVM` STATUS on the bus. An MMS notice goes the same way: there is no MMS client |
| Emergency numbers | `Sim.EmergencyNumbers` publishes the list `shannond` refuses (read back: 11 numbers), so the apps show their full page instead of a toast. Nothing else changed: **no emergency call can be placed** |
| Region of numbers | `t715-call-profile` fills omatel's `region` from the line's own number once registered, unless the owner chose one (`shannond/region.py`) |
| A long call | `t715-call-profile` holds logind's idle inhibitor for the length of a call: the screen stays on, and t715-keys leaves it alone |
| `mmcli` (`modemmanager`, daemon masked) | **works**: `mmcli -L`, `-m 0`, `-i 0` |
| Réseau mobile (`t715-mobile-settings`) | state, data, roaming, technologies, APN, from the drawer or a long press on the data tile. Its display was checked on the real modem and SIM, and the commands behind each control were run from the desktop session: `nmcli` modify, up and down, `SetCurrentModes`. **The controls themselves have not been pressed. It suggests an APN by operator code from `mobile-broadband-provider-info` when that database knows the operator.|
| Technologies (`SetCurrentModes`, `mmcli --set-allowed-modes`) | **works**: automatic, 3G and 2G, 3G, 2G. 3G only came down from LTE to UMTS, automatic went back to LTE |
| SIM PIN | `t715-sim-pin` (dialog, attempts left) or `mmcli -i 0 --pin=...`: the PIN path is **not tested**. Turning the PIN on or off, changing it and PUK are not implemented: the facade answers "unsupported", and they could only be tried on a spare SIM |

A persistent root made before these packages needs, once for the desktop
user: the link `~/.config/omarchy/plugins/omamobile.call`, `cellWatch` and
`callWatch` true and `omamobile.call` in `~/.config/omarchy/shell.json`, and
`systemctl --user enable omatel-agent`. A new image does this at build time.

`HoldAndAccept` (a second call while one is active) is not implemented in the
facade, and `Modem.Signal` is not exported: `omatel-agent` runs without it.

### 5.3 Bring-up procedure (test BOOT, image mode)

```bash
bash device/write-part.sh BOOT out/boot-modem-voice/boot.img
```

```bash
bash device/modem-bringup.sh --apn <operator APN> --tag <name>
```

`device/modem-bringup.sh` pushes the userspace, installs the units and the
D-Bus policy, loads the three modules, sets `allow_hw`, fills the guard
canary, waits for the battery gate, starts `shannon-loader.service` and
`shannond.service`, then lets NetworkManager bring a `t715-mobile` gsm
connection up, checks traffic over `rmnet0` and takes it down; it finishes
with `device/modem-snap.sh` (innocuity hashes of EFS, `m9kefs1-3`, RADIO).

Manual control afterwards:

```bash
env PYTHONPATH=/usr/lib/shannond python3 /usr/lib/shannond/bin/shannonctl status
```

```bash
nmcli connection up t715-mobile
```

Emergency CP off (CP_RESET low, then CP_ON low, through `/dev/mem`):

```bash
python3 /root/modem/tools/cp-kill.py
```

## 6. Results on the device

### 6.1 Cold boots

Each one: `systemctl reboot` with the CP off, then `device/modem-bringup.sh`
(push, units, modules, `allow_hw`, battery gate, `shannon-loader.service`,
`shannond.service`, NetworkManager).

| Boot | Battery wait | ONLINE after power-on | Data through NetworkManager |
|---|---|---|---|
| 1 | 2 min 40 | 9.91 s | second attempt (unit and PDP fixes applied during the boot) |
| 2 | 6 min 20 | 9.94 s | second attempt |
| 3 | 6 min 40 | 9.91 s | second attempt |
| 4 | 5 min 40 | 9.90 s | second attempt |
| 5 | 4 min | 9.93 s | second attempt; cause found (§4) |
| fresh CP session after the fix | — | — | **first attempt, 10.7 s** |
| 6 | 6 min 40 | 9.89 s | **first attempt** (≈ 10 s), whole chain green |
| persistent root, autostart | none (gate 55 °C) | 9.91 s (22.8 s after the kernel started) | first attempt from the desktop session, 11 s |

The battery gate (< 40 °C before a CP power-on) is the slowest step: the
tablet warms up while it boots and charges over USB.

### 6.2 Innocuity

The SHA-256 of EFS, `m9kefs1-3` and RADIO did not change between the first
power-on and every gate after it; the `cp-guard` canary was intact after every
CP session.

### 6.3 Crash recovery

`modem/tools/cp-force-crash.py --yes` (IOCTL_MODEM_FORCE_CRASH_EXIT, test
only): CRASH_EXIT 171 ms later, POLLHUP on the holders, loader silent reset
1/5, ONLINE again 9.9 s after the new power-on. `shannond` ran its restart
contract (queue drained, sequence reset, RFS re-seeded, wait for the new
session and `PWR_PHONE_PWR_UP`); the facade went registered → failed →
disabled; radio on → registered.

### 6.4 SMS

Own number read from EF_MSISDN (kept in `/run`, never printed); an SMS sent
to it came back about 3 s later with the same text and sender.

### 6.5 Data

`nmcli connection up` → connected in about 1 s; `rmnet0` /32 with a
default route (metric 20700) and the operator DNS; ping, DNS and HTTPS over
`rmnet0` (2 MB at 2.26 MB/s), nothing over Wi-Fi.

### 6.6 Calls

Outgoing call to the voicemail short code: CALL_OUTGOING, audio path and
volume, CALL_STATUS dialing → alerting → active, SND_CLOCK_CTRL NOTI
(narrowband 8 kHz), CALL_RELEASE → released.

### 6.7 LTE

Tests of 2026-10-30, through
a runtime drop-in (`--modes lte,umts,gsm`, payload log). RAT byte 0x21 is LTE,
0x04 UMTS. Volumes are over `rmnet0`, with the RAT read before and after each
transfer.

| Session | Registration | NetworkManager | Throughput |
|---|---|---|---|
| Fresh CP, no attach APN | UMTS at 13 s, LTE accepted at 19.6 s, then rejected in the same burst (`st=2`, then CS 4 and PS 7, reject 0x0a); stuck for 5 min | fails after 60 s | none |
| Same CP, attach APN sent during a UMTS window | LTE, CS and PS home, reject 0 | 0.2 s | 3 × 30 MB down: 4.3, 4.7, 5.1 MB/s; 5 MB up: 0.68 MB/s; stable |
| Fresh CP, attach APN before radio on, 3 runs | LTE home at 16, 20, 17 s after UMTS at 9-13 s; one run showed reject 0x0a for about 3 s, then home | 0.2-0.3 s, first attempt | 10 MB down: 4.8, 3.9, 2.9 MB/s |
| Radio cycle, connected in the UMTS window, 5 runs | UMTS, about 7 s | about 3 s | 2 MB down: 0.8-1.1 MB/s |

- **Cause: the attach APN, not the signal, the band or the plan.** The
  rejection repeats with a good signal. The CP accepts
  the attach APN in low-power mode too (GEN 0x8000, 3 of 3), which is where
  libsec-ril's start-up order puts it. An earlier note of this bring-up blamed
  weak LTE: that was wrong, based on one sample taken with `--no-lte-attach`.
- **Not known.** The band: no frame seen carries a frequency, and the catalogued
  `NET_CELL_INFO` record has none. 4G+: `GPRS_LTE_CA_STATUS` p0 (CA active) read 0 in every frame; p1 is probably the bandwidth in MHz.
- **The fix, in `shannond`.** `GPRS_LTE_ATTACH_APN_INFO` goes before
  `PWR_PHONE_STATE` radio on, once per CP session and profile, from `--lte-apn`
  (`/etc/shannond.env`, written by `device/modem-install.sh --apn`, never in the
  repository). A connection request sends its APN before it waits for
  registration, and with no APN known the mode mask leaves LTE out, so calls
  work on 3G. `--radio-on` turns the radio on as soon as the CP is ready: without
  it nothing arrives until a client enables the modem. A short reject 0x0a
  before LTE home is normal.
- **Checks of the fix, desktop session, 2026-10-30** (fresh CP session each):

| Session | NetworkManager | LTE home | Data on LTE | SMS on LTE | Outgoing call |
|---|---|---|---|---|---|
| `--lte-apn` configured | first attempt, 12 s (from radio off) | 18 s | 5 MB at 3.1 MB/s | received, same text and sender | active in 6 s on UMTS (act 0x04), back on LTE within 10 s of the hang-up |
| No APN configured (new install) | first attempt, 14 s | 22 s | 5 MB at 3.6 MB/s | received, same text and sender | active in 7 s on UMTS, back on LTE within 3 s |

That new-install row started from radio off. With `--radio-on` the first
connection finds the modem already registered on 3G: the attach APN brings LTE
back into the mode mask, and for a few seconds the CP refuses the activation
(status 3, cause 255, then GEN 0x8005). `shannond` sends the definition and the
activation again every 3 s. A network cause, such as 27, still fails at once.
On a fresh image `nmcli connection up` took 21 s and ended on LTE (2026-10-30).

  After a cold boot with `--radio-on`, LTE is registered (CS and PS home, façade
  REGISTERED) with no client and no command.

### 6.8 Cost on the desktop

Did the modem work slow the desktop down? Same workload on each boot, 2026-10-30, same persistent
root except the rescue: CPU, memory, `glmark2-es2-wayland` at 1280x720, Firefox
scrolling a local page with a throwaway profile, then three noisy local clips
played at full width.

| Boot | sha256 MB/s | memory | glmark2 | Firefox frames/s | clips dropped: VP9 720p, VP9 1080p, H.264 1080p |
|---|---|---|---|---|---|
| rescue, kernel `00021`, no Wi-Fi network | 512 | 3.9 GB/s | 177 | 54.1 | not run |
| daily BOOT `00024`, no modem module | 510 | 3.9 GB/s | 176 | 38.2 | 31 %, 42 %, 43 % |
| modem BOOT, CP online, on LTE | 510 | 3.8 GB/s | 185 | 38.9 | 35 %, 40 %, 44 % |
| same, 2 other runs | 510-513 | 3.9 GB/s | 175-182 | 39.2, 53.9 | 31-33 %, 41-43 %, 44-45 % |

- No difference attributable to the modem. Firefox moved between about 38 and
  54 frames/s from run to run; the 38-39 runs had Wi-Fi interrupts and
  Firefox at 250-350 % CPU, likely a new profile's first-run network traffic.
- The kernels differ only by the modem: the config adds the modem, MIPI LLI and
  SPI, the GPU node is the same, the GPU stays at 266 MHz. Since 2026-10-29 only
  telephony packages changed on the persistent root.
- Not measured: YouTube itself, and page scrolling on it. Firefox renders on the
  CPU (`docs/journal/ONDEVICE-2026-10-29.md`), which stays at 1.2 GHz: that is the
  ceiling, with or without the modem.
- One `JOB_BUS_FAULT` panfrost job fault in the last modem run, none in the daily
  run. One sample: its cause is not known.

## 7. Call audio

Call PCM runs between the CP and codec AIF2 (baseband codec-to-codec link);
the AP only routes it inside the WM1814. `shannond --audio-hook
voice-hook.sh` sets `Modem Rate` and the `Modem RX/TX Switch` when the CP
reports its PCM clock (`SND_CLOCK_CTRL` NOTI), and turns them off at the end
of the call; the `Voice Call` UCM verb sets the routes. Details, register
reads and the commands: `modem/audio/README.md`.

| Check | Result |
|---|---|
| Dry run (G19) | FLL2 and both ASRCs lock, no codec error; everything powers down with the switches |
| Downlink | voicemail prompts recorded from the codec (ASRC2 → AIF1 capture) at about −21 dBFS |
| Uplink | 1 kHz bursts from the codec tone generator, deposited on the voicemail of the own line, came back identical at playback |

On the desktop (PipeWire running), WirePlumber 0.5.13 does not select the
`Voice Call` profile by itself (≥ 0.5.15 does). Workaround: the user unit
`t715-call-profile.service` (`modem/audio/t715-call-profile`, enabled by
`device/modem-install.sh --user`) follows `shannond`'s call events and
switches the card to "Voice Call (Mic, Speaker)" (or "(Headphones, Mic)"
when the HiFi profile had headphones) for the length of the call. With it a call
was heard on the speaker, and speech recorded through the tablet's microphone
came back (2026-10-30). Not covered: the wired headset.
Mute: `t715-call-profile` also owns `org.mobian_project.CallAudio` on the
session bus, the service `omatel-agent` asks. `callaudiod` would not work: it
mutes PipeWire's source, and the call's microphone goes from the codec to the
modem without passing through the AP. `MuteMic` turns `Main Mic Switch` off and
reads it back. Measured during a call, through `omatel-agent`, on the signal
that feeds the uplink: −32 dBFS, −71 dBFS while muted, −33 dBFS after, and the
owner confirmed the Mute button of `omaphone` in a real call. Without
this service `omatel-agent` records the mute and changes nothing, so a Mute
button would look active with the microphone still open.

`SND_LOOPBACK_CTRL` must not be sent: it stalled the CP's IPC until a power
cycle.

## 8. Safety rules (summary of SYNTHESIS §5)

- Send the CP only the BOOT of RADIO p13, unchanged (it programs eFuses);
  never cut the CP between `cp_status` = 1 and the first of 0xA00D or 10 s.
- Never write RADIO, CDMA-RADIO, EFS, `m9kefs1-3`, BOOTLOADER, PARAM, BOTA;
  never create, rewrite or restore `nv_data.bin`; RFS writes go to tmpfs.
- Never call IOCTL_MODEM_CP_UPLOAD (it panics the AP). After a CP crash:
  `MODEM_OFF`, then a full boot.
- CP off before unloading the modules or rebooting; leave Linux with
  `systemctl reboot`.
- Battery ≥ 5 % and gauge temperature < 55 °C before every CP power-on
  (40 °C by default; 55 °C by the owner's decision of 2026-10-30, see §5.1).
- Never call an emergency number to test.
- No IMEI, IMSI, ICCID, serial, MAC, phone number, SMS content or network
  name in the repository or in logs; IPC payload logging is off by default.

## 9. Known gaps

- An incoming call first appears as a call without number (id 1, from
  `CALL_INCOMING`) that is released as soon as `CALL_LIST` reports the real
  call (id 0): clients briefly see two calls.

- LTE: the band in use and 4G+ are unknown (§6.7). An incoming call while on
  LTE was not tested (the incoming call test ran on 3G); the owner accepted
  that on 2026-10-30.
- WirePlumber 0.5.13 cannot select the `Voice Call` profile by itself; the
  audio hook sets the verb only with `VOICE_HOOK_UCM=1` (PipeWire stopped).

- `debugfs mipi-lli/status` keeps reporting `LLI_MOUNTED` after `MODEM_OFF`
  (cosmetic: the next power-on resets the link).
- `shannond`: no USSD.
- Two `NET_REGIST` reads sent together are sometimes both answered with the
  second one's `aseq`: the first one then times out after 10 s ("no answer" in
  the log, 341 times in 2 h 25 on LTE). Harmless: both answers reach the handler.
- The daily BOOT `out/boot-omarchy/boot.img` does not carry the modem series:
  the package's units skip under that kernel.
