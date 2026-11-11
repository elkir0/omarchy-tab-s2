# Installing Omarchy on the Samsung Galaxy Tab S2

The install guide for the 1.0 releases, 1.0 Beta 1, then 1.0.1, then 1.0.2,
then 1.0.3, then 1.0.4; the steps name 1.0.4's files. It takes a Samsung
Galaxy Tab S2 8.0 LTE (SM-T715) from stock Android, or from a tablet that
already runs TWRP, to
Omarchy: Hyprland and the Omarchy shell with the omarchy-mobile touch layer,
on a mainline Linux 6.12 kernel, with LTE, calls and SMS. Android stops
booting; its own data stays on the tablet, unused. An unofficial port, not
affiliated with Omarchy, omarchy-mobile or Samsung.

To build everything from source instead of flashing the release, read the
developer guide, [DEPLOY.md](DEPLOY.md).

## Read this first

- **Both install paths blow the tablet's Knox warranty bit for good.** There is
  no way back from that, whatever you do later.
- **Do not rely on this tablet for an emergency call.** The modem software
  refuses emergency numbers, and no emergency call was ever tried under Linux.
  Use a phone ([hardware/MODEM.md](hardware/MODEM.md)).
- **Back up EFS before anything else.** EFS holds your IMEI; it is the one
  partition no tool can rebuild. The TWRP path below does it first.
- **The install writes two partitions only**: BOOT and RECOVERY. Never write
  BOOTLOADER, EFS, m9kefs1-3, RADIO, CDMA-RADIO, PARAM or BOTA: EFS holds your
  IMEI, and the modem's boot code programs eFuses.
- Back up whatever you care about on the Android side. This comes with no
  warranty: you can lose your data and your tablet.
- **Android's own data stays on the tablet**, and the desktop user can read the
  parts that belonged to Android's system user: both have the UID 1000. If that
  matters, wipe Android's data before you copy the image (TWRP: Wipe → Format
  Data, which also empties the internal storage).
- Leave Linux through its own restart (`systemctl reboot` in a terminal), never
  by holding hardware keys down to force one: a forced reset can leave the
  tablet booting the rescue instead of Omarchy.

## 1. What you need

| What | Why |
|---|---|
| A Samsung Galaxy Tab S2 8.0 LTE, model SM-T715, hardware revision 9 or later | the only tablet tested (revision 9); the release's board data covers revisions 9 and up. Other Tab S2 models are not covered |
| Firmware `T715XXU2CRH1` (Android 7.0) | the modem accepts only that exact RADIO image, and the first boot reads the Wi-Fi and Bluetooth files from the tablet's own SYSTEM partition. On any other firmware, flash the stock `T715XXU2CRH1` with Odin first |
| USERDATA as plain ext4, not encrypted | the boot stops with "no ext4 superblock" on an encrypted tablet |
| About 11 GB free on internal storage | the image file (5.3 GiB in 1.0 Beta 1, 1.0.1, 1.0.2, 1.0.3 and 1.0.4), plus the first boot's copy of its contents into the persistent root (4.3 GiB used, plus a 512 MiB margin) |
| A computer with Odin or Heimdall | flashing BOOT and RECOVERY in Download mode |
| The release files, checked | below |

The release files:

| File | What it is |
|---|---|
| `boot.img` | the BOOT image (partition 9): the Linux kernel and initramfs that start Omarchy at power-on |
| `recovery.img` | the RECOVERY image (partition 10): a rescue Linux that boots the image read-only |
| `rootfs-omarchy.img.xz` | the Omarchy root file system, compressed |
| `omarchy-tab-s2-1.0.4-AP.tar.md5` | the Odin package with `boot.img` and `recovery.img`: the "AP" file |
| `omarchy-tab-s2-1.0.4-boot.tar.md5` | the Odin package with `boot.img` only, for a tablet that keeps TWRP in RECOVERY |
| `SHA256SUMS` | the checksum of every file |

## 2. Put the image on the tablet

The image has to sit on the tablet's internal storage as a plain file, under
`linux/`: `Internal storage/linux/rootfs-omarchy.img` from Android, which TWRP
calls `/data/media/0/linux/rootfs-omarchy.img`.

1. On the computer, decompress the image and give it its checksum sidecar:

   ```bash
   xz -dk rootfs-omarchy.img.xz
   grep '  rootfs-omarchy.img$' SHA256SUMS > rootfs-omarchy.img.sha256
   shasum -a 256 -c SHA256SUMS
   ```

   The sidecar is one `sha256sum`-format line. On the first boot the tablet
   checks its own copy of the image against it before setting itself up, and a
   damaged copy is refused without changing anything.

   On Linux, `sha256sum -c SHA256SUMS` checks the files the same way. On
   Windows, where Odin runs:

   - unpack the image with 7-Zip;
   - check each file against its line in `SHA256SUMS`: in PowerShell,
     `Get-FileHash <file>` prints its SHA-256;
   - make the sidecar: copy the `rootfs-omarchy.img` line of `SHA256SUMS`
     into a new file named `rootfs-omarchy.img.sha256` with Notepad (check
     that it did not add `.txt`), or use the `grep` line above in WSL or Git
     Bash. From 1.0.1 the first boot reads a sidecar written on Windows: CR LF
     line endings, a byte order mark, the hash in upper case as `Get-FileHash`
     prints it. 1.0 Beta 1's images refuse such a file and say "The image
     file is damaged (bad checksum)": for Beta 1, make it in WSL or Git Bash.
     The sidecar is optional:
     without it, the first boot copies the image without a check, so compare
     the sizes instead (3.).

2. Copy **both** files, `rootfs-omarchy.img` and `rootfs-omarchy.img.sha256`,
   into `linux/` on the internal storage, in any of these ways:

   - from an **exFAT microSD card**, with the tablet's own file manager:
     Android's, or TWRP's File Manager. The card must be exFAT (or another
     file system without FAT32's 4 GiB file limit, which the raw image is
     over), and it is only a ferry: the image still goes to the internal
     storage, not the card. From 1.0.2, Linux reads the card too
     ([hardware/SDCARD.md](hardware/SDCARD.md)): once Omarchy runs, the
     card mounts as storage;
   - over **MTP**, with the tablet plugged into the computer (not yet tested
     end to end);
   - with **adb**, over Wi-Fi (Android drops big files over USB):

     ```bash
     adb shell mkdir -p /sdcard/linux
     adb tcpip 5555
     adb connect <tablet-ip>:5555
     adb -s <tablet-ip>:5555 push rootfs-omarchy.img /sdcard/linux/rootfs-omarchy.img
     adb -s <tablet-ip>:5555 push rootfs-omarchy.img.sha256 /sdcard/linux/rootfs-omarchy.img.sha256
     adb -s <tablet-ip>:5555 shell 'sync; sleep 45; sync'
     ```

3. Check that the size of the image on the tablet matches your local file
   before going on.
4. Optional: to log in over SSH later, also copy your public key as
   `linux/authorized_keys` (for example `~/.ssh/id_ed25519.pub`). The image has
   no key, so without one SSH stays closed; the first boot installs it for root
   and for `alarm`.

## 3. Path A: from stock Android

**Not yet tested end to end.** The reference tablet this ROM was built on had
already given Android up, so the Odin and Heimdall steps below were never run
against a stock tablet. You would be among the first to do it: expect rough
edges, and report them.

1. On the tablet, turn on Developer options, USB debugging and OEM unlocking,
   and back up what you care about. If your firmware is not `T715XXU2CRH1`,
   flash the stock one with Odin first (see "What you need").
2. Reboot into **Download mode**: with the tablet off, hold
   **Power + Volume down + Home** until the warning screen, then press
   **Volume up** to continue. With adb, `adb reboot download` does the same.
3. Flash, with either tool:
   - **Odin**: put `omarchy-tab-s2-1.0.4-AP.tar.md5` in the AP slot and
     start;
   - **Heimdall**: `heimdall flash --BOOT boot.img --RECOVERY recovery.img`.
4. After a Download-mode flash the bootloader may start RECOVERY first. That
   quick boot is the rescue: Omarchy runs from the image read-only, nothing is
   set up and nothing is written. Reboot once (`systemctl reboot` in the foot
   terminal) to boot BOOT, which does the setup.
5. Continue with the first boot (5.).

## 4. Path B: from TWRP

**Not yet tested end to end** either; the reference tablet last ran TWRP
before this ROM existed. TWRP's official `gts28ltexx` builds are the ones that
work on this tablet.

1. In TWRP, **back up EFS first**, then Boot, Modem, m9kefs1-3 and System, to
   the microSD. USB does not work under TWRP on this tablet, so the card is
   the only way the backup leaves the tablet. Keep that backup: it is the only
   way back if EFS is ever damaged.
2. Copy `rootfs-omarchy.img` and `rootfs-omarchy.img.sha256` from the microSD
   into `/data/media/0/linux/` with TWRP's File Manager, creating the `linux`
   directory if it is not there.
3. **Install → Install Image**, and flash `boot.img` to the **Boot** partition.
4. Either keep TWRP in Recovery, or install `recovery.img` there instead: then
   RECOVERY is the rescue Linux rather than TWRP. Keep TWRP, and only `boot.img`
   ever needs flashing again — that is what the
   `omarchy-tab-s2-1.0.4-boot.tar.md5` package is for.
5. Reboot, and continue with the first boot.

## 5. The first boot

- The screen shows **"Setting up Omarchy (first boot)"** and a percentage about
  every ten seconds. This takes a few minutes (3 min 17 s for 1.0 Beta 1,
  3 min 16 s for 1.0.1, 3 min 12 s for 1.0.2, 3 min 31 s for 1.0.3, @SEED@ for
  1.0.4, on the reference tablet): the tablet is copying the image into a
  persistent root on the internal storage. Leave it alone.
- The same boot takes the Wi-Fi and Bluetooth files from the tablet's own
  Android SYSTEM partition, read-only, and the system then makes the cameras'
  tables from the tablet's own camera firmware, also on SYSTEM.
- If something fails, the screen says why, in plain words, and either waits
  (hold Power + Volume down to restart) or reboots by itself.
- Then Omarchy starts, and the session logs you in by itself as the user
  `alarm`.

## 6. Getting started

- **Touch:** tap or pull down the top bar for quick settings; swipe up from the
  home pill for home, up and hold for recent apps; a swipe in from the left or
  right edge is Back. Power, short: screen off and on. Power held: the system
  menu. Left alone, the screen goes off after two minutes; the **Stay awake**
  tile (under "Add tiles" in quick settings) holds that: on, the screen stays
  on until Power or the cover turns it off. The **Battery saver** tile keeps
  the four fast cores (the A57s) off and caps the CPU clock — and the GPU's,
  on kernels that scale it — until the tile goes back off.
- **Set a PIN at once.** Until then the user `alarm` has the password `alarm`
  and `sudo` asks for nothing: anyone with the tablet has full control. Hold
  Power for the system menu, choose the PIN row, give the current password
  (`alarm`) and your PIN. That turns on the screen lock, and `sudo` asks for
  the password from then on.
- **Wi-Fi:** the quick-settings Wi-Fi tile. WPA2 only — the firmware has no
  WPA3, and a WPA3-only network cannot be joined.
- **Mobile data:** the modem's NV data is copied once from EFS, read-only, on
  the first boot; it holds the tablet's identity and never leaves it. Open
  **Réseau mobile** in the app drawer and set your operator's APN. The **Modem**
  tile in quick settings switches the modem off — for a tablet without a SIM, or
  to save the battery; off, it takes no calls, no SMS and no data (and the
  Mobile data tile says "Modem off").
- **Coding agents:** Pi, the terminal coding agent, is preinstalled — drawer
  entry "Pi". Sign in on the tablet with `/login` or a provider API key, never
  with a Claude Pro or Max subscription: Anthropic's terms keep those
  credentials to its own apps. Claude Code is not preinstalled. The drawer's
  "Claude Code installer" is an unofficial, opt-in installer (about 250 MB
  downloaded, capped at 2.1.270 on this 32-bit tablet) that explains itself and
  asks before doing anything.

## 7. Going back to Android

Flash the stock `T715XXU2CRH1` firmware with Odin — the ROM's own files stay
in internal storage, unused, until you delete them — or restore the full TWRP
backup (with TWRP back in RECOVERY, or kept there all along). If Android then
misbehaves, a factory reset from its own recovery starts its data over. The
Knox warranty bit stays tripped either way.

## 8. When something goes wrong

- **Download mode** is the way back in: with the tablet off or restarting, hold
  **Power + Volume down + Home** until the warning screen, then press
  **Volume up**. Odin and Heimdall both work from there; flashing the release
  again (3.) puts a working BOOT and RECOVERY back.
- **The rescue in RECOVERY** boots the image read-only: no setup, no copy, and
  nothing you do there survives a reboot. After a Download-mode flash the
  bootloader may start it first — that is normal, reboot once (`systemctl
  reboot` there goes back to BOOT). From a running tablet,
  `sudo t715-reboot-to recovery` goes there on purpose.
- **A failed first boot** says why on the screen. "The image file is damaged
  (bad checksum)" means the copy onto the tablet went wrong: copy both files
  again, the sidecar made as in 2. On 1.0 Beta 1's images it also means the
  sidecar has Windows line endings, which those images refuse (2.); from
  1.0.1 a sidecar written on Windows is accepted. "Not enough free space"
  means what it says: free about the
  amount it names and restart. Until then the tablet runs from the image, and
  changes are lost at each reboot.
- **A frozen tablet:** hold Power + Volume down for about ten seconds to force
  a restart. If it then loops on the rescue, enter Download mode and flash
  again.

## 9. What has not been run yet

Honesty about the testing, so you know where the surprises will be:

- the install from a stock tablet with Odin (path A) is not yet tested end to
  end;
- the TWRP path (B) is not yet tested end to end;
- copying the image over MTP is not yet tested end to end;
- one tablet ran this ROM, and no install by anyone else has been reported yet.

<!-- TESTED: the supervisor writes this paragraph -->

On that tablet, 1.0.3's published image was unpacked from its `.xz`, checked,
and installed from RECOVERY with its own persistent root next to the owner's,
then checked: the first boot and its copy, a second boot, the rescue, the
session, the Wi-Fi and its recovery service, the microSD card, Bluetooth, the
pointer settings in place, the Battery saver, the modem's switch, the speaker
and microphone devices (`CHANGELOG.md`).

For 1.0.2, the published image went through the same first boot on that
tablet, next to the owner's system, and was checked there: the first boot and
its copy, a second boot, the rescue, the session, the microSD card and its
tile, Bluetooth, the pointer settings in place, the Battery saver, the modem's
switch, Wi-Fi scanning, the speaker and microphone devices (`CHANGELOG.md`).

For 1.0.1, the published image went through the same first boot on that
tablet, next to the owner's system, and was checked there: the first boot and
its copy, a second boot, the rescue, the session, both cameras and the Camera
app, the Battery saver, the modem's switch, Wi-Fi scanning, Bluetooth, Pi and
the Claude Code installer (`CHANGELOG.md`).

For 1.0 Beta 1, a first build was installed fresh from RECOVERY on that tablet,
with its own persistent root next to the owner's, and checked: the first boot
and its copy, a second boot, the rescue, the session, both cameras, the
modem's switch, Wi-Fi scanning, Bluetooth, Pi and the Claude Code installer.
The published image was then booted read-only and checked again
(`CHANGELOG.md`). Everything here comes from the repository's own
documentation; the developer guide ([DEPLOY.md](DEPLOY.md))
has the full story, including building from source.
