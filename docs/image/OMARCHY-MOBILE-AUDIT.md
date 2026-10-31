# What we took from omarchy-mobile, and what we did not

Audit of 2026-10-30. It compares this image with omarchy-mobile at `5f7ba48`, the
commit we integrated, and at `9332a78`, 47 commits later: every package, the touch
shell, the Omarchy patches and the telephony plan. Nothing was changed by it.

**How far to trust a line.** **Checked** means read on the tablet or in the code
during the audit, by the person writing this. **Read** means found in the sources and
not run. Nothing here was tried on the tablet unless it says so.

## Verdict

Nothing essential was forgotten, and much of what is missing is missing upstream
too: MMS, USSD, hold, conference, visual voicemail and cell broadcast are phases of
its plan that it has not built. The same goes for the "Mobile network" sheet. On data,
PIN entry, technologies, signal and CP crash recovery our stack is ahead of upstream's
bridge.

Three things did turn up. Some controls look as if they work and do not. Decisions
written when this was a test image in RAM no longer hold now that it is the daily
system, and the tablet has no screen lock or firewall. And several apps went missing
by accident.

## 1. Controls that do nothing

| Control | What really happens | Basis | Effort |
|---|---|---|---|
| **Airplane mode** | Wi-Fi and Bluetooth drop, but the modem stays registered and transmitting, and calls still ring: the tile uses rfkill, and our modem has no rfkill device | **Checked**: `rfkill` lists Bluetooth and Wi-Fi only. `nmcli radio wwan off` is the likely fix, untried | small |
| **Delivery reports**, in Messages, on by default | Never requested, so a message never reads "Delivered" | **Checked**: `model.py:1395` does not pass the flag to `core.send_sms` | small |
| **Speaker** in the call screen | Toggles, changes nothing. It starts off while the sound comes from the speaker | **Checked**: `EnableSpeaker` only returns its argument | small |

No button fails on an "unsupported" answer from the facade: no app has a button for
those methods.

## 2. Security: the daily system is still set up as a test image

The first persistent-root builds kept the test image's defaults; section 9 says what changed.

| Point | State | Basis | Effort |
|---|---|---|---|
| Screen lock | None. P4 waited for a persistent root, which exists since 2026-10-29. `omamobile-set-pin` and the keypad patches are ready upstream, some already shipped dormant | **Checked** | large |
| Password | `alarm`, and sudo asks for none | **Checked** in `docs/image/ROOTFS.md` | small, with the lock |
| Firewall | None. `ufw` is installed and off, "it would block SSH on usb0". Upstream answers with one rule | **Checked** | small |
| SSH | Listens on every interface, Wi-Fi and LTE included. Keys only, root by key | **Checked**, `ss` and `sshd_config.d` | small, with the firewall |
| Lock rule for the call card | Upstream keeps the call above the lock; `t715-tablet.lua` lacks that rule. Harmless today, and with a lock a ringing call could not be answered | Read | small, with the lock |

## 3. Left out for a reason that has gone

| Item | Why it was left out | Why that is gone, and the gain | Effort |
|---|---|---|---|
| Omarchy's web apps, 11 of 12 | Chromium did not exist here | It does. YouTube, WhatsApp, Maps, Photos, Discord in the drawer. Keep Docker hidden. Untried | small |
| Hotspot tile | "Would drop the only Wi-Fi link" | LTE is an uplink now. One catalogue line. AP mode on this firmware is untried | small |
| `omarchy-refresh-pacman` left unguarded (patch 0016) | Needed `omamobile-update` | **Checked**: it copies Omarchy's `pacman.conf` over ALARM's, losing `IgnorePkg` and the repositories, then upgrades. Reached from a terminal by `omarchy channel` or `omarchy-reinstall-pkgs`. Upstream's patch would do nothing here: it has to be rewritten. A `.bak` is kept | small |
| Keyboard reset at login | "Stay-awake keeps the screensaver off" | The screensaver is in the menu, and the root persists: a crash during it leaves the keyboard off for good, on a device with no other. One line. Today the setting reads `true` | small |
| Wayvnc mirror | "Needs a persistent root" | It has one | small |
| Update notice | "An update is gone at the next boot" | Not on the persistent root. Nothing tells the owner updates exist | small |
| `omamobile-setup-user.service` masked | "The image is the same at every boot" | False on the persistent root: a new package's steps are run by hand. Keep it masked, for boot time, and fix the sentence | small |
| Suspend, `omamobile-sleepd` | Boot loop, resume untested | The boot loop is gone, since RECOVERY is the rescue. Resume is still untested, and it needs a lock and a modem wake source. The biggest battery lever | large |

Patch 0014, the lock's emergency button, was dropped with "no modem", which is now
false. It only shows a warning, so it matters only with a lock.

## 4. Missed

| Item | What happened | Effort |
|---|---|---|
| **Maps, Calculator, Clocks, GeoClue** | `omamobile-apps` was dropped because it needs `neard`, and they went with it. **Checked**: absent from the tablet, in ALARM's armv7h repositories. With no GPS the position comes from Wi-Fi, untried. The Location tile needs GeoClue | small |
| **`wf-recorder`** | The Screen record tile reads "No recorder". **Checked**: absent, in the repositories | small |
| **`pipewire-alsa`** | **Checked**: absent. ALSA-only clients bypass PipeWire | small |
| **Vibration** | The motor exists, the image's feedbackd rule already matches `pwm-vibrator`, and the kernel has no `CONFIG_PWM` nor a board node. `packages.extra` says "ring and vibration". Read, unproven on this chip | small to medium, kernel |
| **Sound and wake on SMS** | Only calls trigger feedbackd. Not in upstream either | small |
| **Screen during a long call** | hypridle darkens at 120 s and turns touch off: call-watch holds a sleep inhibitor, not an idle one. Read, not observed | small |
| **Region of phone numbers** | The region comes from `LANG`, which need not match the line's country code. Contacts in national form may get no name, and threads may split. Read. A setting in Messages | small |
| **`//VVM` messages and WAP push** | One can show as a conversation. An MMS would be a blank bubble: `Sms.Data` is never set. Per upstream's plan a STATUS message can carry IMAP credentials | small |
| **Emergency lists** | shannond refuses 15, 17, 18 and 115, which the app does not know, so a toast shows instead of the full page, and nothing is placed. `Sim.EmergencyNumbers` is empty. **Checked** in the code. Publishing the list is safe: check by reading the property, never by dialling | small |
| **Dead menu rows** | Update > Firmware would install fwupd for nothing, and Update > Config > Plymouth rebuilds for a kernel no package owns: the step that hides them is pre-marked as done | small |
| **`--wayland-text-input-version=3`** | Upstream's second flag for the keyboard in Chromium. Test first: the keyboard did rise in the address bar | small |
| **Packages of this image** | `t715-modem` and the `omamobile-*` packages have no repository: `pacman -U` or a new image | medium |
| **GPS** | A separate BCM4752 on a serial port, not the modem as we assumed. Needs a chroot with Samsung's `gpsd`. No plan exists | large |
| **Charging** | Linux cannot limit or stop charging: there is no charger driver, so no guard and no limit | large |
| **Waydroid** | Android apps. ARM images exist, binder and much else is missing from the kernel, GPU at 266 MHz. Nothing was run | large, uncertain |

Lower value, for the record: Hyprland's DPMS retry patch, not seen failing at 60 Hz;
`tools/power-ab`; a check of `omarchy-update-orphan-pkgs`. Wi-Fi power save is **off**
(**checked**), which costs battery, and whether turning it on is safe here is unknown.

An "incoming call leaves a missed call with no number" was predicted from the code.
**Checked: no entry in the call log has an empty number.** Not confirmed.

## 5. New upstream since 5f7ba48

Most of the 47 commits are Pixel ports. For this tablet:

| Item | Gain | Take it? |
|---|---|---|
| Shell 0.2.40-42: one bottom strip, keyboard on the pill | Taps at the bottom centre of apps stop being eaten, the Phone app's tabs among them. Nothing floats over a terminal's input line | Yes, as a patch |
| Shell 0.2.43: app names in recent apps | Readable names, needed with web apps | Yes, as a patch |
| `omatel` 0.2.4, `omaphone` 0.2.2 | Notifications named Messages or Phone instead of omatel, and a stuck tab highlight fixed. Nothing for telephony. About two hours of qemu | With the next rebuild |
| Omarchy patch 0023, the lock's glance view | Time and notifications before the PIN | After the lock. It needs 0014 |
| Shell 0.2.44: widgets stop when hidden | **No gain here, and a cost**: a `bl_power` read every 2 s becomes unconditional | No |
| Patch 0022, weather, OWL, mouse on the home screen | Nothing here | No |

Cherry-pick rather than move to 0.2.45: the patches were measured to apply at fuzz 0 on
ours, while a bump breaks 0004 and brings the 2 s poll. Applying is all that was
measured: nothing ran under Quickshell.

## 6. Left out, and rightly

Cameras (FIMC-IS is not driven), so `omacam` and `snapshot`. NFC: the tablet has none.
Fingerprint: **there is a sensor**, a VFS7xxx, and no mainline driver, so our "no
fingerprint sensor" should read "not driven". Torch: no flash LED found. Pixel audio
tuning, device packages, `libcamera`, `mesa` builds, `omamobile-keyring`. Forcing a
phone user agent in Chromium: 768 px wants desktop pages. `omamobile-update`: it
assumes a repository we do not have, and `omarchy update` works. OWL widgets: off,
and "heavy" was never measured here.

## 7. Telephony still to come, here and upstream

| Feature | State | Effort |
|---|---|---|
| USSD | Facade and apps; a typed `*...#` goes out as a voice call | medium |
| Hold, call waiting, conference | Waiting has a card, untested. No hold | medium |
| Voicemail indicator, visual voicemail | Dial by hand | medium to large |
| Cell broadcast alerts | Ignored | medium to large |
| MMS | Needs `Sms.Data`, one APN, `mmsd-tng` on armv7h, the app side | large |
| SIM: PUK, PIN on, off, change | Spare SIM only | small to write |
| Network scan, manual choice | `core` has them, the facade does not | small to medium |

## 8. Not established

Never recorded on the tablet: the ring being heard, DTMF on a voicemail menu, a call
coming in while on LTE, a dark screen during a call, long SMS, inline reply, a call
waiting, data during a call, no SIM, AP mode, the keyboard in Chromium's web fields, a
file chooser from the sandbox. Whether Omarchy plays a sound for a message. What the CP
does with a `*...#` code.

## 9. What became of it

Work of 2026-10-30 and 31. The levels are: **cmd** run on
the tablet by command in the real session, **seen** read on a capture of the screen, **finger**
waiting for the owner.

| Item | Now | Level |
|---|---|---|
| Airplane mode | the tile turns the modem off and back, kept across a boot | cmd; finger for the tap |
| Delivery reports | requested, in the TPDU. The network sent no report | cmd; "Delivered" not seen |
| Speaker | gone from the call card and `omaphone`: no earpiece | package; finger |
| Screen lock, password, sudo | ready and off until the owner sets a PIN | see `docs/image/ROOTFS.md` |
| Firewall, SSH | ufw on, only SSH and DHCP on `usb0` | cmd, from the Mac over Wi-Fi |
| Lock rule for the call card | in: an outgoing call's card shows above the lock | seen; an incoming call over the lock waits for the owner |
| Web apps | 11 of 12, Docker hidden, all opened in Chromium | seen |
| Hotspot tile | under "Add tiles". AP up, tile on and off, rules for the clients added and removed. Protected management frames off (`21-t715-wifi-no-pmf.conf`): a phone was refused without it, joined with it and passed traffic over LTE | finger |
| refresh-pacman | refuses, `pacman.conf` unchanged | cmd |
| Keyboard at login | reset by `t715-squeekboard.service` | package |
| Update notice | a timer, it reported 3 packages | cmd |
| Setup-user text | corrected | written |
| Calculator, Clocks, GeoClue, `wf-recorder`, `pipewire-alsa` | in the image and on the tablet: an mp4 recorded | cmd |
| Maps | **GNOME Maps is out**: `gjs` dies on an alignment fault in ALARM's `libmozjs`. The Google Maps web app stays | cmd |
| Vibration | `pwm-vibrator` on the ISA1000A, heard by the microphone, alone and with the ring | cmd |
| Sound and wake on SMS | a real SMS woke the screen in 3 s, its sound heard by the microphone | cmd |
| Screen during a call | an idle inhibitor for the whole call | cmd |
| Region of numbers, `//VVM`, WAP, emergency lists | done, on a real SMS and on the live properties | cmd |
| Dead menu rows | gone from the menu | package |
| `--wayland-text-input-version=3` | not needed: the keyboard rises in web fields | seen |
| Shell 0.2.40 to 0.2.43 | as patches: the bottom strip and the names in recents | seen |
| `omatel` 0.2.4, `omaphone` 0.2.2 | as packages | installed |
| Touch keys | `tc300k.ko`, `t715-keys`: Recent pressed by the owner. Back did nothing: Escape by name is not in squeekboard's keymap. Now by key code, and the previous page in a browser | finger |
| Cameras | `docs/hardware/CAMERA.md`: a photo from the front, frames from the rear | seen; a rear photo in the light waits for the owner |
| Fingerprint | `docs/hardware/FINGERPRINT.md`: feasible under a condition not met, the bus test not run | written |

Left as they were: Wayvnc mirror, suspend, Packages of this image, GPS, charging, Waydroid, and
section 7.
