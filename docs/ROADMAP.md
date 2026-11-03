# Roadmap

Where the port stands and what comes next. The dated working journals behind it are not
published (`docs/journal/README.md`); what they established is in `docs/hardware/`,
`docs/image/` and `docs/DEPLOY.md`.

## State on 2026-11-03

In the daily kernel and the image since 0.9.3, tested on one tablet:

- **CPU frequency**: the A53s scale from 400 MHz to 1.2 GHz under schedutil, at this chip's own
  voltages, with stock's thermal thresholds; the A57s stay at the 1.2 GHz they always ran
  (`docs/hardware/CPUFREQ.md` section 9, `kernel/patches/t715-cpufreq`). A 2-hour soak with the
  modem online and four clean reboots passed before it went daily.
- **Power with the screen off**: 2.26 W down to 1.48 W, from the lock screen's blanking and Wi-Fi
  power saving (`docs/hardware/BATTERY.md` section 9). The gain from the A53 levels at idle is
  small, 60-90 mW.
- **Rear camera focus**: the DW9807 focus motor (`kernel/patches/t715-camera-af`), driven by
  `t715-photo`.
- **Shell**: omamobile-shell 0.2.94 with the tablet's patches rebased; hyprgraphics 0.6.0 for
  Hyprland 0.57 (`docs/image/PACKAGES.md`).
- **Auto-rotation** on from the first boot; the Rotation tile still turns it off
  (`docs/image/ROTATION.md`).
- **Claude Code**: `t715-claude-code`, an installer for it, patched for this tablet. The image
  carries no Anthropic binary and no token; the owner of the tablet installs and signs in
  (`docs/DEPLOY.md` 11.10).
- **Shutdown diagnostics**: a system-shutdown hook lists the processes that outlive the last
  SIGKILL, and `t715-pstore-shutdown` keeps that list from pstore at the next boot, to catch
  NetworkManager's rare slow stop (once in 40 reboots).
- **Build options**: the image's language, time zone and first keyboard layout
  (`tools/build-rootfs --locale --timezone --keyboard`; en_US.UTF-8, UTC and US QWERTY by
  default).

## Next

1. **Suspend.** Every sleep target is masked and the kernel offers s2idle only, so the tablet
   cannot sleep while the modem runs. The next levers on the screen-off draw, from the study in
   `research/cpuidle/FINDINGS.md`: take the A57 cluster offline while the screen is off, then
   give the A57s stock's body bias and EMA (decision D7 in `docs/hardware/CPUFREQ.md`), which
   would also give them levels to fall back to when hot. They have none today: a full load on
   all eight cores reaches 99 °C in 90 s.
2. **GPU frequency scaling**, after the CPU (`docs/hardware/GPU.md`).
3. **Cameras**: a live preview and a photo app on libcamera's software ISP, in progress.
4. **NetworkManager at shutdown**: read what the shutdown hooks catch, then fix the wait.

The modem stack does not change for now: the test tablet has no SIM.
