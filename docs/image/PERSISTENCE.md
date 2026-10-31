# Persistence: keeping settings across reboots (decided: persistent root)

Today nothing survives a reboot. The root image is read-only on USERDATA
(`/sdcard/linux/rootfs-omarchy.img`) with a RAM overlay, so each boot asks
again for the Wi-Fi password, forgets Bluetooth pairings, the home screen
layout, the theme, Firefox's profile (cookies, logins), and repeats
Omarchy's first-login steps. For daily use this is the biggest annoyance
left.

Two rules constrain the choice (`docs/journal/HANDOVER.md`):

- **Linux mounts USERDATA read-only**; it is changed from Android only.
  USERDATA holds the owner's Android data: a Linux crash while it is mounted
  read-write could damage it (and Linux did hang on 2026-10-29, during a
  GPU stress test).
- **heimdall writes RECOVERY only**; no other partition is repurposed.

And one privacy fact: whatever stores the Wi-Fi password or Bluetooth link
keys on USERDATA's `/sdcard` is readable by any Android app with storage
access.

## Options

| # | How | Survives | Risk | Effort |
|---|---|---|---|---|
| 1 | **Build-time user data**: `image/tools/build-rootfs` takes optional files the owner provides (a NetworkManager keyfile, a `home.json`, a theme name), as it already takes the SSH key; they go into the owner's image, never into git | the Wi-Fi network(s) and chosen settings, as built | none to Android; the password sits inside the image file on `/sdcard` (readable by apps with storage access); a new image is needed to change it | S |
| 2 | **State carried by Android**: Linux reads an allow-list from `/sdcard/linux/omarchy-state/` at boot (read-only); a `t715-state-export` command writes a tarball to `/tmp`, which the owner moves to the tablet from Android (or the Mac pushes it over ADB) | whatever was exported last | none to Android; same privacy as 1; manual step to save | M |
| 3 | **Read-write state image on USERDATA**: a preallocated `/sdcard/linux/state.img` (ext4, made from Android), loop-mounted read-write by Linux for `/home/alarm`, NetworkManager and BlueZ state | everything, live | breaks the read-only rule: USERDATA is mounted read-write while Linux runs, and a hang or power loss could leave it to fsck (writes stay inside the preallocated file, which limits but does not remove the risk) | M |
| 4 | **A dedicated partition** (e.g. CACHE) for Linux state | everything, live | breaks the RECOVERY-only rule; Android or an update may wipe or reformat it | M |

## Recommendation

Start with **option 1** for the Wi-Fi network only (the biggest annoyance,
no risk to Android data), as a `--wifi-keyfile FILE` option of
`image/tools/build-rootfs`: the owner writes the file themself (their password
never passes through anyone else), the build checks it is a valid
NetworkManager keyfile with mode 0600, and DEPLOY.md says the image then
carries a secret and must not be shared. Option 2 can follow for pairings
and settings. Options 3 and 4 change a safety rule and need the owner's
explicit decision (and a) first.

Decision needed from the owner: option 1 for Wi-Fi now, yes or no; and
whether the password may sit in an image file on `/sdcard`.

## Decision (2026-10-29)

The owner refused option 1 (no Wi-Fi configuration baked into the image)
and decided that the tablet keeps no Android: Omarchy becomes its only
system. With Android's data no longer to protect, the read-only rule on
USERDATA has no reason left, and option 3 becomes the plain answer, in a
simpler form: no state image, the root itself is a directory of USERDATA,
mounted read-write (the "persistent root", commit `435265c`,
`boot/README.md`). Everything survives reboots, not only
Wi-Fi. `DEPLOY.md` 11.6 has the procedure; it was verified on the
reference tablet the same day (`docs/journal/ONDEVICE-2026-10-29.md`,
"Persistent root").

The remaining steps, each needing the owner's go-ahead: the Linux kernel
in BOOT so that the tablet starts Linux at power-on (Android no longer
boots; the stock BOOT and the TWRP backup stay on the Mac to restore it),
then removing Android's apps and data and the old Phosh images from
USERDATA.
