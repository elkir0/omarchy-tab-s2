# T715 arm64 image: what is on this system

An Arch Linux ARM **aarch64** system for the Samsung Galaxy Tab S2 8.0 LTE
(SM-T715, Exynos 5433), built in Docker on the Mac by
`arm64/rootfs/build.sh`. It has **not been tested on the tablet**
at the time of its build (2026-11-24): it was checked only in its own
container on the Mac (the smoke check below). The full story, the kernel
requirements and what is unverified:
`arm64/docs/ROOTFS.md`.

* Which image this is: `/usr/share/t715-arm64/IMAGE`.
* What is inside: `/usr/share/t715-arm64/MANIFEST.image`.
* The smoke check, to run again here: `/usr/lib/t715-arm64/smoke-check`.

## The user and the placeholders (change them)

* The user is `alarm` (uid 1000, in wheel: sudo without a password until a
  PIN is set), as on the owner's armv7h tablet; SDDM logs it into Omarchy
  (`/etc/sddm.conf.d/autologin.conf`, `omarchy.desktop`). Its password is the
  build's PLACEHOLDER, `changeme` (not ALARM's `alarm`; build.sh `--password`
  gives another). Change it (`passwd`, or System > PIN: `omamobile-set-pin`).
* root is locked; ssh accepts keys only. Without a key nobody can log in
  over ssh: rebuild with `build.sh --ssh-pubkey FILE`.
* The Wi-Fi NVRAM and the Bluetooth patch RAM are not in the image. They come
  from the tablet's own SYSTEM partition at the first boot
  (`t715-vendor-firmware.service`), or were staged by the owner.
  `/usr/share/t715-arm64/VENDOR-FILES-MISSING` says which are missing.

## The watchdog and the boot mark (the loader's design)

The loader arms the SoC watchdog before it starts the kernel and the kernel
never feeds it (`s3c2410_wdt.tmr_atboot=1 watchdog.handle_boot_enabled=0`).

* `t715-watchdog-keeper.service` feeds the watchdog every 5 s from early in
  the boot (before `basic.target`). It is the only thing that does. If it
  dies it is restarted within a second. It never starts a watchdog the kernel
  left stopped.
* `t715-kboot-mark.service` writes `KBOOT: up` into the kernel log (mirrored
  into S-Boot's RAM ring by the console) once `sshd.service` and
  `usb-rndis.service` are active (it requires both, and the keeper): the
  owner can reach the system. At the next boot the loader reads it: no mark
  means the attempt failed, and it hands back to S-Boot for that one boot. No
  mark without a watchdog device in the kernel, nor if the keeper cannot run:
  a marked boot that is then reset for lack of feeding would be retried for
  ever.

## Bring-up knobs (kernel command line)

* `t715.kbootmark=0`: the mark never runs. Every next boot goes back to the
  arm32 system, whatever this one did.
* `t715.return=MIN`: `t715-return.timer` (enabled at each boot by
  `/etc/systemd/system-generators/t715-return-generator`, only with the
  knob) reboots the tablet MIN minutes (1 to 1440; anything else: 10) after
  the boot, unless `/run/t715-stay` exists then: `touch /run/t715-stay` keeps
  this boot. With `t715.kbootmark=0` that reboot lands in the arm32 system.
  Without the knob nothing happens.

To look at a broken boot without being reset: boot the kernel **without**
`s3c2410_wdt.tmr_atboot=1` (the driver then stops the watchdog at its probe),
or, from an emergency shell in time: `systemctl start t715-watchdog-keeper`.
To stop the watchdog on a running system, for a test:
`systemctl kill -s USR1 t715-watchdog-keeper`.

## Getting in over USB

`usb-rndis.service` brings up a CDC-ECM gadget: the tablet is
`172.16.42.1`, the Mac gets `172.16.42.2`-`10` by DHCP. It needs the kernel's
USB gadget support (configfs, the Exynos USB 3.0 DRD controller):
`journalctl -u usb-rndis` if it fails. In the Omarchy image the firewall lets
nothing in but ssh (22) and DHCP (67), on that cable only.

## Not here yet (their kernel side is not on arm64)

Suspend, the modem, the cameras, GPS, Waydroid, the Wi-Fi and power guards
that the armv7h image has: see the build's documentation.
