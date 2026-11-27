# Installing Omarchy in 64 bits on the Samsung Galaxy Tab S2

This guide takes a Samsung Galaxy Tab S2 8.0 LTE (SM-T715) from stock Android to Omarchy 4.5 in
64 bits, with the 2.1.2 release: you copy one image to a microSD card, flash one package with
Odin, and the tablet installs itself. No command to type on the tablet, nothing to build.

It is an unofficial port, not affiliated with Omarchy, Omarchy Mobile or Samsung. How it works,
for whoever wants to know: [section 7](#7-what-the-installer-does) here, then
[ARM64.md](ARM64.md) and the two repositories it points to.

## Read this first

- **This is a bootloader exploit.** The tablet's signed bootloader only starts 32-bit kernels; the
  64-bit system starts through a loader written into the PARAM partition (the boot brick,
  [elkir0/bnuuyloader](https://github.com/elkir0/bnuuyloader), built on
  [bnuuyloader](https://github.com/meowybnuuy/bnuuyloader) by bnuuy). It is made for one
  bootloader, `T715XXU2CRH1`, and checked before anything is written.
- **The Knox warranty bit is blown for good**, by flashing anything unofficial. There is no way
  back from that.
- **Android stops booting.** Its data stays on the internal storage, unused. Back up whatever you
  care about first. This comes with no warranty: you can lose your data and your tablet.
- **Do not rely on this tablet for an emergency call.** Use a phone.
- **The installer saves what cannot be rebuilt.** Before it writes PARAM, it copies PARAM and EFS
  (your IMEI) to the folder `linux` of the internal storage. Copy them to a computer afterwards
  (section 5).
- **Everything was made and tried on one tablet** (hardware revision 9). Yours would be one of the
  first others: report what you see.

## 1. What you need

| What | Why |
|---|---|
| A Galaxy Tab S2 8.0 **LTE**, model **SM-T715** | the only model covered. The Wi-Fi model (SM-T710) and the 9.7-inch ones are other tablets |
| Firmware **`T715XXU2CRH1`** (Android 7.0) | the loader is made for that bootloader's addresses, and the modem accepts only that firmware's radio. Settings → About → Software information → Baseband and build number end in `CRH1`. On another firmware, flash the stock `T715XXU2CRH1` with Odin first: the installer refuses any other bootloader and writes nothing |
| The internal storage **not encrypted** | unless you encrypted it yourself (Settings → Lock screen and security → Encrypt device), it is not. The installer cannot read an encrypted storage, says so, and writes nothing |
| About **13 GB free** on the internal storage | the system's copy (about 6 GB) and a margin |
| A **microSD card** of 8 GB or more, **exFAT** | the image is one file of 6 GB: FAT32 cannot hold it. Cards of 64 GB and up come in exFAT; format a smaller one as exFAT on the computer. Or copy the image to the internal storage instead (section 3) |
| The battery at **30 %** or more | the install writes for about ten minutes; under 30 % it waits for the charger |
| A computer with **Odin** (Windows) or **Heimdall** (Linux, macOS) and the USB cable | to flash the installer once, in download mode |

## 2. Download and check

From the [2.1.2 release](https://github.com/elkir0/omarchy-tab-s2/releases):

| File | What it is |
|---|---|
| `omarchy-arm64.img.xz` | the 64-bit Omarchy system, compressed (unpacked: `omarchy-arm64.img`) |
| `omarchy-arm64.img.sha256` | the image's checksum: the installer refuses an image without it |
| `omarchy-tab-s2-2.1.2-AP.tar.md5` | the installer, for Odin's AP slot (it holds `boot.img` and `recovery.img`) |
| `boot.img`, `recovery.img` | the same installer, for Heimdall |
| `SHA256SUMS` | the checksum of every file |

Unpack the image and check everything:

```bash
xz -dk omarchy-arm64.img.xz
shasum -a 256 -c SHA256SUMS
```

On Linux, `sha256sum -c SHA256SUMS` does the same. On Windows: unpack with 7-Zip, and in
PowerShell `Get-FileHash omarchy-arm64.img` prints the SHA-256 to compare with its line.

## 3. Put the image where the installer finds it

Copy **both** `omarchy-arm64.img` and `omarchy-arm64.img.sha256` into a folder named `linux`:

- **on the microSD card** (the simplest): `linux/omarchy-arm64.img` and
  `linux/omarchy-arm64.img.sha256` on the exFAT card, then put the card in the tablet. The
  installer reads the image from the card, and the card is not changed;
- **or on the internal storage**, while Android still runs: `Internal storage/linux/`, from the
  card with Android's file manager, over MTP from the computer, or with
  `adb push` (over Wi-Fi: Android drops big files over USB). Check that the size on the tablet is
  the size on the computer.

Optional: to log in over SSH, add your public key as `linux/authorized_keys` on the internal
storage (for example your `~/.ssh/id_ed25519.pub`). Without it, SSH stays closed.

## 4. Flash the installer

0. While Android still runs: Settings → About tablet → Software information, tap *Build number*
   seven times; then Settings → Developer options → **OEM unlocking** on. Without it the
   bootloader may refuse the installer ("Custom binary blocked"). Some tablets do not show the
   option at all; download mode then may show an RMM or KG state. Flash anyway: if the
   installer's white text comes up, the bootloader accepted it. If it refuses, flash the stock
   firmware back.
1. Turn the tablet off. Hold **Volume down + Home + Power** until the warning screen, then
   **Volume up**: download mode.
2. Connect the USB cable.
3. **Odin**: put `omarchy-tab-s2-2.1.2-AP.tar.md5` in the **AP** slot and press *Start*.
   **Heimdall**: `heimdall flash --BOOT boot.img --RECOVERY recovery.img`.
4. When Odin says PASS, or Heimdall has finished, the tablet restarts by itself into the
   installer. If it stays in download mode, hold **Volume down + Power** until the screen goes
   black, then let go. The bootloader may start RECOVERY rather than BOOT this first time: both
   hold the installer, so it makes no difference.

## 5. The install

The screen shows, in white text on black:

1. `Omarchy for the Galaxy Tab S2, 64 bits: installer 2.1.2`;
2. `Checking the image...` (about two minutes);
3. `Installing Omarchy: N%` (about four minutes);
4. `Writing the loader...`, then `Omarchy is installed. Restarting into it...`.

On the reference tablet the whole install took seven minutes, from the restart into the installer
to the 64-bit desktop. The tablet restarts, shows the boot picture, and Omarchy comes up with its
first-run notifications: the one that asks you to set the tablet up opens the setup (your name, a
real PIN or password in place of the image's placeholder, the AI apps to install, the language of
dictation, your coding agent). Wi-Fi works from the first start: connect from quick settings.

Once Omarchy runs, copy the two backups to a computer and keep them:
`linux/PARAM-stock-backup.img` (your tablet's own PARAM, the way back) and `linux/EFS-backup.img`
(your IMEI), with their `.sha256`. In Omarchy they are under `/run/t715/userdata/media/0/linux/`,
readable by root (`sudo cp`). The image file can be deleted after the first start, from the card
or the internal storage; the log of the install stays next to it: `omarchy-arm64-install.log`.

## 6. When something goes wrong

The installer writes nothing until its checks pass, and PARAM last. A message on screen says what
happened; the install log, when the storage could be written, is `linux/omarchy-arm64-install.log`
on the internal storage. Hold **Volume down + Power** to restart.

| What you see | What it means | What to do |
|---|---|---|
| `This tablet's bootloader is ...; Omarchy needs T715XXU2CRH1` | another firmware | flash the stock `T715XXU2CRH1` firmware with Odin (all four slots), then the installer again. Nothing was written |
| `Omarchy's image was not found` | no `linux/omarchy-arm64.img` on the card or the internal storage | copy it (section 3), restart |
| `... .sha256 is missing` or `The image file is damaged (bad checksum)` | the sidecar is missing, or the copy is incomplete | copy both files again, restart |
| `The internal storage could not be read: is it encrypted?` | an encrypted Android storage | flash the stock firmware, decrypt or reset Android, start again |
| `Not enough free space` | under about 13 GB free | free space from Android (flash the stock firmware back first), or start from a reset tablet |
| `PARAM does not hold the stock image ... that this installer knows`, after lines starting with `PARAM:` | PARAM was changed by something else, or a firmware whose PARAM differs. The installer knows two stock PARAMs of `T715XXU2CRH1`: the one of a tablet updated over the air, and the one Odin flashes (the BL's `param.bin`). The `PARAM:` lines say which of its pictures differ from the stock ones, are missing or are not in it, and whether bytes after them are not zero | flash the stock `T715XXU2CRH1` firmware with Odin, all four slots (BL included), then the installer again. Nothing was written. If it says this again, post a photo of the screen in the XDA thread |
| `PARAM holds the stock pictures, then N bytes S-Boot does not read` | PARAM holds the stock archive, and older bytes after it that a flash of the firmware left | nothing: the install goes on, the loader has zeros there, and `linux/PARAM-stock-backup.img` keeps PARAM as it was |
| `Battery at N %` | under 30 % | plug the charger in: the install starts by itself at 30 % |
| `Note: this chip's voltage fuses differ from the reference tablet's` | your chip's ASV fuse word is not the reference tablet's (`0x33010008`); the install goes on | report it with the install log: the CPU's voltage tables are the reference chip's ([ARM64.md](ARM64.md)) |
| `Omarchy did not finish starting last time. The tablet restarts and tries again.` | the 64-bit system did not come up: the loader hands two starts back to the installer, then tries again | nothing, at first. If it never comes up, report it with the install log |
| `Rescue: PARAM does not hold Omarchy's loader. Writing it back.` | something changed PARAM | nothing: the installer puts its loader back and restarts |
| A black screen and nothing, at every start | the loader hangs before it can hand back | download mode, then flash `linux/PARAM-stock-backup.img` back to PARAM with Heimdall (`heimdall flash --PARAM PARAM-stock-backup.img`), then the stock firmware |

**Going back to Android**: flash the stock `T715XXU2CRH1` firmware with Odin (BL, AP, CP, CSC).
That puts back BOOT, RECOVERY, PARAM and the rest. The `omarchy-arm64` folder and the backups stay
on the internal storage until Android's own reset (or the CSC file, not HOME_CSC) wipes it.

## 7. What the installer does

For whoever wants to know before flashing. The installer is the release's `boot.img` and
`recovery.img`: the 32-bit kernel of the 1.0.5 release and this repository's initramfs
(`boot/initramfs/init`, `t715.golden`), with the loader's files from `boot/golden/`. S-Boot starts
it as it would start Android, since PARAM still holds Samsung's stock image. Then, in order, and
each step only once:

1. **Checks, before any write**: S-Boot's version (`androidboot.bootloader` on its command line
   must be `T715XXU2CRH1`), PARAM's first 7340032 bytes (the archive of pictures S-Boot shows) must
   have the sha256 of one of two stock images of that firmware (`boot/golden/stock.sha256`, a line
   each: a tablet updated over the air keeps the pictures of 2016, a tablet flashed with Odin gets
   the BL's `param.bin` with pictures of 2018; the second since 2.1.3), or hold one of those archives followed by bytes
   that are not zero, left by an earlier write (S-Boot reads only the archive, and the loader has
   zeros there; since 2.1.2), the battery, the
   image's checksum, and the image itself (an aarch64 system carrying its kernel). The chip's
   voltage fuses are read and logged: the CPU tables are the reference tablet's (see
   [ARM64.md](ARM64.md)).
2. **The system**: the image's tree is copied into `omarchy-arm64` at the top of the internal
   storage's partition (USERDATA), then the tablet's own Wi-Fi calibration and Bluetooth firmware
   from its SYSTEM partition (they are Samsung's, never in the image), and your SSH key if you put
   one there.
3. **The kernel**: Android's `/cache` becomes a 64 MiB file system, and the 64-bit kernel goes into
   a slot behind it in the CACHE partition, read back.
4. **The loader**: PARAM and EFS are copied to `linux/`; the loader is made from **your own**
   PARAM (no PARAM image can be distributed: it holds Samsung's firmware and your tablet's data):
   Samsung's boot logo is replaced by the loader's (`boot/golden/logo.jpg`), and the result must
   have the sha256 the installer was built for before it is written. There is one per stock image
   (`boot/golden/loader.sha256`, a line each): the loader made from your PARAM must be the one on
   the line of your PARAM's stock image, never another. The two stock images differ only in the
   boot logo and in the dates of the archive's headers.
   Only those first 7340032 bytes are written; S-Boot keeps data of its own after them.
5. **Restart**: at every start from now on, the loader starts the 64-bit kernel, which boots
   `omarchy-arm64`.

From then on the installer in BOOT and RECOVERY is the system's rescue: if the 64-bit system does
not come up, the loader hands the next starts back to it, which says so and restarts; if PARAM
ever loses the loader, it forges it again from the saved copy. To check on a computer what the
installer would write from a PARAM you dumped yourself:
`python3 boot/golden/check-param.py PARAM.img`.

The release is built from this repository: the image with `arm64/rootfs/build.sh`, the release with
`arm64/release/make-release.sh` (the kernel from [elkir0/bnuuyloader](https://github.com/elkir0/bnuuyloader)'s
`t715/build-arm64.sh`). Power users who want to do it by hand, step by step: the long route,
[GO-ARM64.md](https://github.com/elkir0/bnuuyloader/blob/main/t715/docs/GO-ARM64.md).

## 8. From 2.0.0: the reinstall

A tablet on 2.0.0 already has the loader in PARAM and an installed system, so the 2.0.0 installer
there only acts as the rescue. The installer since 2.1.0 adds a reinstall (from 2.0.0, or from a 2.1 release to a later one), asked by a file named
`reinstall` in the `linux` folder of the internal storage:

1. Copy the new release's `omarchy-arm64.img` and `omarchy-arm64.img.sha256` into `linux/` on a microSD
   card or the internal storage (section 3).
2. Create the file `linux/reinstall` in the internal storage. From the running system:
   `sudo touch /run/t715/userdata/media/0/linux/reinstall`.
3. Flash the new release's installer with Odin or Heimdall (BOOT and RECOVERY), as for a first install
   (section 4). The tablet then restarts into your 2.0.0 system as before: the loader starts it,
   and the installer waits in BOOT.
4. Hand the next start to the installer, from the running system:
   `echo '<3>KBOOT: try' | sudo tee /dev/kmsg >/dev/null && sudo systemctl reboot`.
   That line tells the loader that this start did not finish, so it gives the next start to the
   installer. Starting in RECOVERY with the keys does not reach the installer: the loader runs
   there too and starts the 64-bit system.

The installer then checks the image, renames the installed system `omarchy-arm64.previous` (kept,
never deleted: your files can be copied from
`/run/t715/userdata/omarchy-arm64.previous/home/...` later), deletes the `reinstall` file and
installs the new system. The loader stays in PARAM, and the rescue's saved stock PARAM is carried
over. A second reinstall refuses while `omarchy-arm64.previous` exists, and says how to delete it.
The internal storage needs room for the new system next to the one kept, about 6 GB (the image can
stay on the microSD card): the installer checks it first and writes nothing when it is short. If
the install stops before the new system is in place, the kept one is put back and the tablet
restarts into it.
The new system starts with the first-run setup again: your settings and files are not carried over
(the old system is kept aside). Right after the reinstall the installer shows up once more, says
that Omarchy did not finish starting last time, and restarts by itself after 30 seconds: the loader
still counts the start you handed over. The start after that is the new system.

## 9. Android apps

Opt-in, as in the 32-bit release: the image ships Waydroid dormant. `sudo t715-android-setup all`
downloads Waydroid 1.6.3's `waydroid_arm64` images on the tablet — LineageOS 20 (Android 13), the
VANILLA system and the MAINLINE vendor, about 1.1 GB — and sets everything up. Android draws on
the GPU through Panfrost (OpenGL ES 3.1), and both 64-bit (arm64-v8a) and 32-bit (armeabi-v7a)
apps install. An Android tile in the quick settings starts and stops the session.
With Google Play: `sudo t715-android-setup all --gapps`, on a tablet where Android was not set up
yet (the GAPPS system, about 1.3 GB). Once Android has started, `sudo t715-android-setup google-id`
prints the device's ID: register it at https://www.google.com/android/uncertified, then sign in
to the Play Store. On the reference tablet the Play Store works (2026-11-26).

## 10. Sleep and the lock screen

The tablet suspends to RAM a minute after the screen goes dark, on battery only — never on
external power, or while a remote (ssh) login is open, audio plays, a call or the hotspot runs.
Before the sleep the modem's processor and the Wi-Fi/Bluetooth chip are powered down; after the
wake they come back (the Wi-Fi in about 5 s). Wake sources: the Power and Home keys, the cover,
plugging a cable, the RTC alarm. While it sleeps there is no Wi-Fi, no Bluetooth, no call and no
SMS (the modem's processor is off).

Omarchy locks the session before every sleep, and the lock asks for the password or PIN set in the
first-run setup. Until you set one, it is the image's placeholder `changeme`, which has letters:
on the lock screen, switch the number pad to letters. Set a real PIN or password in the setup.
