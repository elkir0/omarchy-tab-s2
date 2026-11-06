# LINK-PM: letting the SS333 sleep (SYNTHESIS D2, fallback F2)

**Status.** Validated on one tablet without a SIM (section 9): the CP releases
the link and sleeps under `pm_mode=fsm`. The code is the optional series
`kernel/patches/t715-linkpm/` (two patches on `t715-camera-mc`), which is
not in the 1.0 Beta 1 kernel: `lockon` stays the default. The power saved is
not measured yet; calls, SMS and data with a SIM are not tested. D2 is in
`research/modem/research/SYNTHESIS.md`; the measurements are in
`docs/hardware/BATTERY.md` §12; the modem switch that exists in the meantime
is described in `docs/hardware/MODEM.md` §5.4.

## 1. Why

With the screen off, a powered CP costs **155 ± 22 mW**, and it makes no
difference whether its radio is on or off. Its radio adds 28 ± 22 mW
without a SIM. That is a fifth of the screen-off draw. Neither the
interrupt rate nor the CPUs' idle share changes with the CP, so the cost is
the CP's own, plus its link.

**The cause** is the port's link power management, option (c) of D2,
"locked-on". From PHONE_START until `stop_pm`, `start_pm` in
`drivers/misc/modem_v1/link_device_lli.c`:

- holds AP2CP_WAKEUP (gpf5-0) and AP2CP_STATUS (gpf1-2) high;
- holds the wakeup source `lli_ap_wlock`.

The CP is the link master. It may release the MIPI-LLI link only through a
CP-led handshake whose second step is the AP letting go of AP2CP_WAKEUP.
Stock never saw an unmount while the AP held the link (0 of 26, SYNTHESIS
§2.16), and the port never lets go. The link stays mounted, so the CP never
sleeps. D2 accepted this as "higher idle power during bring-up", with F2
(port the stock state machine, `pm_enable = 1`) as the way out "for battery
in phase 2".

**What the tablet shows** (debugfs `ss333/status`, read only, 2026-11-05,
CP online, no SIM, screen off):

| Signal | Reading |
|---|---|
| CP2AP_WAKEUP (gpa3-1) | low: the CP does not want the link |
| AP2CP_WAKEUP | 1, held by the port |
| CP2AP_WAKEUP edges | 4 a minute: about two wake cycles a minute |
| LLI doorbells | 4 a minute |
| CP2AP_STATUS edges | only at CP power changes (28 since boot, over several CP sessions) |

This is the G10 signal of D2: "CP2AP_WAKEUP low with no unmount means the CP
tries to sleep and is refused (power argument for F2)". The CP asks about
twice a minute and is refused every time.

## 2. What stock does

Sources: `kernel_universal5433/drivers/misc/modem_v1/link_device_pm.c` (1095
lines) and `modem_pm.h`; the glue is in `link_device_lli.c`, the LLI side in
`drivers/misc/mipi-lli/exynos-mipi-lli.c` and `mipi-lli.c`. Stock's private
dmesg (SYNTHESIS §2.16) shows it at work on this tablet's CP firmware:

- 26 unmounts in 256 s;
- the link down a median 2.46 s of every 2.83 s;
- links up 0.31-0.97 s.

The FSM, with every transition run under one spinlock (`run_pm_fsm`):

| State | Event | Next, and what is done |
|---|---|---|
| CP_BOOTING (`start_pm`, PHONE_START; both AP2CP lines high, wake lock) | CP2AP_WAKEUP HIGH | ACTIVE, AP2CP_WAKEUP high |
| ACTIVE | CP2AP_WAKEUP LOW | AP_FREE, `cp_free` work in `cp_hold_time` (100 ms) |
| AP_FREE | CP_HOLD_TIMEOUT, CP2AP_WAKEUP still low and no TX reference (`ref_cnt` 0) | CP_FREE, **AP2CP_WAKEUP low** |
| AP_FREE | CP_HOLD_TIMEOUT otherwise, CP2AP_WAKEUP HIGH, or a hold request | ACTIVE, AP2CP_WAKEUP high |
| CP_FREE | CP2AP_STATUS LOW | UNMOUNTING, watchdog 500 ms for LINK_UNMOUNTED |
| CP_FREE | CP2AP_WAKEUP HIGH / hold request | ACTIVE / ACTIVATING (watchdog 500 ms for CP2AP_WAKEUP HIGH) |
| UNMOUNTING | LINK_UNMOUNTED (LLI `unmount_cb`) | UNMOUNTED, AP2CP_STATUS low, wake lock released; or HOLDING if a hold was asked |
| UNMOUNTED | CP2AP_WAKEUP HIGH | RESETTING: `ld->reload` (LLI soft reset), AP2CP_WAKEUP high, watchdog 500 ms for LINK_RESET |
| UNMOUNTED | hold request (AP TX) | HOLDING: AP2CP_WAKEUP high, watchdog 500 ms for CP2AP_WAKEUP HIGH |
| HOLDING | CP2AP_WAKEUP HIGH | RESETTING (as above) |
| RESETTING | LINK_RESET (LLI `reset_cb`, at SW_RESET_DONE) | MOUNTING: AP2CP_STATUS high, watchdog 500 ms for LINK_MOUNTED |
| MOUNTING | LINK_MOUNTED (LLI `mount_cb`) or CP2AP_STATUS HIGH | ACTIVE, TX waiters woken |
| any wait | its watchdog, after re-reading the GPIOs | WDOG_TIMEOUT, CP_FAIL or AP_FAIL: `pm_fail_cb` (MDM_CRASH_PM_FAIL) or `pm_cp_fail_cb` (MDM_CRASH_PM_CP_FAIL) |
| ACTIVE, AP_FREE | CP2AP_STATUS LOW | CP_FAIL |

How the AP side takes part:

- **Sending.** TX calls `forbid_cp_sleep` → `request_hold` (a CP_HOLD_REQUEST)
  and waits until `link_active()`, which is true in LOCKED_ON, ACTIVE and
  AP_FREE. It then calls `permit_cp_sleep`.
- **LLI callbacks.** The LLI driver calls `reset_cb` at SW_RESET_DONE,
  `mount_cb` from the mount thread and `unmount_cb` at UNMOUNT_DONE. It does
  not re-arm itself when an `unmount_cb` exists.
- **System sleep.** `suspend_cb` and `resume_cb` come from the LLI driver's
  `dev_pm_ops`.

## 3. Design

### 3.1 Scope

**F2 is the stock state machine, with its semantics unchanged**, behind a
`pm_mode` parameter:

- **`lockon`** stays the default, and its code path stays what runs today.
- **`fsm`** must be asked for.

The CP firmware's side of the handshake is fixed, and stock's timings are
known to work with this firmware on this tablet, so a rewrite would add
protocol risk for no gain.

F2 is runtime power only:

- `modem_suspend()` still refuses system sleep while the CP runs (-EBUSY);
- `mc->power_wlock` is still held while the CP is powered;
- so deep sleep with the modem on stays out of scope. That would be a later
  F2b: the LLI driver's system sleep callbacks, the FSM's SUSPENDED state,
  and the wake masks of `research/suspend`.

### 3.2 `pm_mode`, chosen at run time

`pm_mode` becomes writable (0644) but only while the CP is OFFLINE: a set
callback refuses any other state with `-EBUSY`. It is read once, at
`start_pm` (PHONE_START).

- A module loaded in lockon can be switched to fsm between two CP sessions,
  with no reload. The modules cannot be reloaded anyway: both are
  `[permanent]`, with no `module_exit`.
- A reboot always comes back in lockon. A hang under fsm therefore cannot
  repeat at boot: a risky new path is opt-in at run time, never on at
  boot.

### 3.3 The modem_v1 side

- **`link_device_pm.c` and `modem_pm.h`, ported to 6.12.** The FSM table,
  CP_HOLD_TIME (100 ms, `cp_hold_time` parameter) and the 500 ms watchdogs
  are copied as they are. The API conversions:

| 3.10 | 6.12 port |
|---|---|
| `gpio_get_value(int)` / `gpio_set_value` | `mif_gpio_get_value(desc)` / `mif_gpio_set_value(desc)`; the writes stay gated by `allow_hw` |
| `mif_add_timer(t, expire, fn, data)` | `timer_setup()` once, then the port's `mif_add_timer(t, expire)`; `from_timer()` in the bark |
| `alloc_workqueue(.., WQ_NON_REENTRANT \| WQ_UNBOUND \| WQ_HIGHPRI, 1)` | `WQ_UNBOUND \| WQ_HIGHPRI`, max_active 1 (every workqueue is non-reentrant since 3.7) |
| `wake_lock` | the port's `modem_wakelock.h` (a wakeup source) |
| `static const char const *` | `static const char * const` |
| `pr_info` at every transition | `pr_debug`, compiled out on `#6` (no `CONFIG_DYNAMIC_DEBUG`); counters in debugfs `ss333/status`; only failures at `pr_err`. The LLI driver's routine reset, mount and unmount lines go to `pr_debug` as well while the FSM runs |
| `panic()` on AP_FAIL under `CONFIG_SEC_MODEM_DEBUG` | none: AP_FAIL goes to the CP fail handler, as stock without that option |

- **`struct link_device` gets its `struct modem_link_pm pm` back** (the
  unifdef of patch 0007 removed it). The FSM's GPIO fields become
  `struct gpio_desc *`.
- **The glue in `link_device_lli.c` dispatches on the mode chosen at
  `start_pm`:**
  - lockon keeps today's `start_pm`, `stop_pm`, `forbid_cp_sleep` and
    `permit_cp_sleep`, word for word;
  - fsm uses stock's: `pm->start(pm, PM_EVENT_CP_BOOTING)`, `pm->stop`,
    `forbid_cp_sleep` with `request_hold`, `check_link_status` with
    `pm->link_active`;
  - `pm_fail_cb` and `pm_cp_fail_cb` raise MDM_CRASH_PM_FAIL and
    MDM_CRASH_PM_CP_FAIL. The port already handles both with
    `ss333_force_crash_exit()`, which is atomic-safe, then CRASH_EXIT and the
    loader's silent reset (rule 17).
- **The CP2AP interrupts stay the port's.**
  - They are edge-both, requested disabled at `allow_hw` 0→1, enabled by
    `ss333_on` / `start_monitor` and disabled first in `stop_pm`, with the
    storm guard.
  - In fsm mode the handler reads the line's level and gives it to the FSM
    as a HIGH or LOW event, so stock's level flipping (`irq_set_irq_type()`
    from inside the handler) is not needed.
  - The FSM's `start` does not enable them again; the port's lifecycle owns
    them.
- **Four additions of the port**, where stock's FSM can wait forever
  (found by an independent review of the code, 2026-11-05):
  - **ACTIVATING → UNMOUNTING arms the UNMOUNTING watchdog**, as
    CP_FREE → UNMOUNTING does. Stock armed none there, so a lost unmount
    left the FSM in UNMOUNTING for good, and the next `stop_pm_wdog()`
    logged an "illegal state" on a normal path.
  - **A send that waits 5 s for the link ends the CP session**
    (MDM_CRASH_PM_FAIL). This covers what no FSM watchdog sees: a mount
    that fails (no DL credits) after CP2AP_STATUS has already taken
    MOUNTING to ACTIVE, and an unmount the FSM did not ask for (no re-arm
    under fsm). Stock's SBD path had no limit.
  - **A CP2AP storm** stops the IRQs and, in fsm, raises MDM_CRASH_PM_FAIL.
    If the IRQs are not live at PHONE_START (a storm during the CP's boot),
    that session stays in lockon.
  - **The fail handlers act only on a CP that is ONLINE, or BOOTING**
    between PHONE_START and BOOT_DONE. While OFFLINE a power-off is under
    way: `__ss333_off` sets OFFLINE, then waits up to 3 s before `ld->off`
    stops the FSM, and a crash there would arm `crash_ack_timer` on a CP
    being switched off. In CRASH_EXIT the crash path already runs.
- **`stop_pm` in fsm mode**, in this order:
  1. the CP2AP IRQs are disabled (the port's order, review D2-b);
  2. `pm->active` goes false under the FSM lock;
  3. the watchdog timer and the `cp_free` work are cancelled with the
     non-sync calls, since `stop_pm` can run in atomic context from
     `ss333_force_crash_exit`;
  4. both AP2CP lines go low, the wake lock is released.

  A late timer, work or LLI callback then finds `!active` and only lowers
  AP2CP_WAKEUP, a write gated by `allow_hw`.

### 3.4 The LLI side

- **The interface comes back.** `struct link_pm_svc` and
  `mipi_lli_get_pm_svc()` return in `include/linux/mipi-lli.h` and
  `mipi-lli.c`, with stock's `lock_link` / `unlock_link`: the
  UNMOUNTED↔WAITFORMOUNT marks.
- **The callbacks are called where stock calls them, after the port's gates:**
  - `reset_cb` at SW_RESET_DONE, after `exynos_lli_check_remap()`. If the
    remap readback fails, the mount is refused at HIBERN8_EXIT as today, and
    the MOUNTING watchdog ends the session (rule 12: an interlock refusal
    ends the session);
  - `mount_cb` in the mount thread, after DL credits and the AFC save, and
    only on success;
  - `unmount_cb` at UNMOUNT_DONE. Only when an owner is registered (fsm)
    does the driver not re-arm; otherwise (lockon) it re-arms as today.
- **The port's protections all stay:** the `allow_hw` gate on every register
  write, the LLI interrupt storm guard, the rate limit on the soft reset of
  RESET_ON_ERROR_SENT, and the remap interlock recomputed at every
  SW_RESET_DONE.
- **Not wired:** `suspend_cb` and `resume_cb` (no system sleep callbacks in
  the port, see 3.1), and `error_cb` (stock calls it only for an SS300).
- **AFC across remounts is unchanged.** The mount thread saves the AFC code
  at the first mount with DL credits (`afc_valid`); every later `cmn_init`
  writes the saved code instead of running the AFC, as stock does ("afc on
  only booting time"). A remount every few seconds is therefore stock's case.

### 3.5 Observability

`ss333/status` gains:

- the mode;
- the FSM's state;
- counts of unmounts, remounts, hold requests, watchdog barks and fails;
- the time since the last state change.

This is how the G10 counters of D2 become readable per test.

## 4. Failure modes, and what catches each

| Failure | Caught by | Ends in |
|---|---|---|
| A CP2AP edge missed (two edges before the handler) | the handler reads the level; every watchdog re-reads both CP2AP lines before it declares a failure (stock); the CP raises CP2AP_WAKEUP and keeps it until it has the link | a missed LOW leaves the link up until the next LOW; a missed HIGH is covered by the HOLDING/ACTIVATING watchdogs |
| No SW_RESET_DONE after a reload | RESETTING watchdog, 500 ms | AP_FAIL → `pm_cp_fail_cb` → CRASH_EXIT → silent reset |
| Remap readback wrong | the mount is refused at HIBERN8_EXIT (unchanged) | MOUNTING watchdog → WDOG_TIMEOUT → fail handler |
| No MOUNT_DONE | MOUNTING watchdog | WDOG_TIMEOUT → fail handler |
| No DL credits ("Mount failed") after CP2AP_STATUS already rose (MOUNTING → ACTIVE, stock) | the port's send stall limit: a send waiting 5 s for the link | MDM_CRASH_PM_FAIL → silent reset |
| An unmount the FSM did not ask for (ACTIVE); no re-arm under fsm | the send stall limit, at the next send | MDM_CRASH_PM_FAIL → silent reset |
| No unmount after CP2AP_STATUS low | UNMOUNTING watchdog, armed from CP_FREE (stock) and from ACTIVATING (port) | WDOG_TIMEOUT → fail handler |
| The CP lowers CP2AP_STATUS while ACTIVE or AP_FREE | stock's transition | CP_FAIL → `pm_cp_fail_cb` |
| An oscillating or stuck CP2AP line | the port's storm guard (> 1000 edges/s), plus MDM_CRASH_PM_FAIL in fsm; before PHONE_START, the session stays in lockon | silent reset; the IRQs are re-armed at the next `start_monitor` |
| An LLI interrupt storm | the LLI driver's guard (IRQ disabled until the next reset) | the next watchdog → fail handler |
| More than 5 silent resets in 30 min | the loader's supervisor | exit 6: the modem stays off until `systemctl restart shannon-loader` or a boot |
| MODEM_OFF or a crash during any state | `stop_pm`'s order (3.3); `!active` makes every late event a no-op; the fail handlers do nothing while the CP is OFFLINE (the 3 s of `__ss333_off` before `ld->off`) or crashed | the CP off, the lines low |
| TX while unmounted | `forbid_cp_sleep` → HOLDING; the SBD timer retries every `TX_PERIOD_MS` until `link_active()` | a missing answer within 500 ms → WDOG_TIMEOUT → fail handler; any other wait over 5 s → the send stall limit |
| `allow_hw` 0 during a test | refused unless OFFLINE (unchanged) | — |
| A remount costs latency on the first packet after an idle | not a failure; measured in test L5 | — |

What it does not catch at once: a CP that accepts the handshake and then
stalls without any line moving, while nothing is sent. The next send meets
the 5 s stall limit; shannond's periodic GETs send often enough for that.
The IPC layer's own timeouts ("no answer" after 10 s) see it too, as they
would today.

## 5. Expected saving (inferred, not measured)

- **Today:** 155 ± 22 mW for a CP that is held awake.
- **Stock's duty cycle:** the link down a median 87 % of the time
  (2.46 s of 2.83 s), on a tablet in use with a SIM. Here, idle and without
  a SIM, the CP asks to let go only about twice a minute, so it should stay
  unmounted longer.
- **The CP's sleep floor is unknown.** A cellular modem idle on a network
  typically draws ten to twenty milliwatts, which would leave about 20 to
  40 mW instead of 155: **100 to 135 mW saved**. Only the first measurement
  (L4) will say.
- **The AP's cost per cycle** is a soft reset, a few interrupts and the
  mount thread (a 1 ms delay and the credit wait). At a few cycles a minute
  it is negligible.

Calls, SMS and data would stay as they are today. Each AP send after an
idle pays one remount; stock's links lasted 0.3-1 s, and how long a remount
takes has not been measured.

## 6. Test plan (the owner present, every step)

The two modem modules are `[permanent]` and cannot be swapped at run time,
so the plan avoids both a partition write and a change to the root:

1. `t715-modem-power off`: the CP off, and `shannon-modem-prepare` disabled
   at boot.
2. Reboot: no modem module is loaded.
3. Load the test modules from `/var/tmp/linkpm/` by hand.

**Rollback is `t715-modem-power on` and a reboot, which loads the installed
modules again.** A hang during a test ends in a watchdog reset into BOOT,
which boots with no modem at all, since prepare is still disabled. Nothing
can loop.

**Gates for every step:**
- battery at 30 % or more, battery temperature under 45 °C;
- `power-windows.sh`-style logging at 5 s;
- dmesg scanned with the "Kernel command line" filter.

**Stop at once on any of:** PM WDOG, CP_FAIL, AP_FAIL, "mount refused", a
storm guard, a silent reset, a kernel warning. Then go back to the rollback.

| Step | What | Passes when |
|---|---|---|
| **L0** (Mac) | Build both modules from `t715-linkpm` on `#6`'s tree and `.config` (`out/mainline-power-wifi/.config`; no MODVERSIONS, no module signing). Check that `modinfo` shows vermagic `6.12.114 SMP preempt mod_unload ARMv7 p2v8`, that nothing outside the two modules changed, and that the build has no warning | builds clean; the lockon path is word for word today's (diff review) |
| **L1** lockon on the new code | Steps 1-3 above, with `image/tests/ondevice/linkpm.sh load` (`check` first): `modprobe spi_s3c64xx`, `insmod exynos5433-mipi-lli.ko`, `insmod sec_modem_v1.ko`, `allow_hw` 1 on both, then `shannon-loader` and `shannond` started | ONLINE in about 10 s, `shannonctl status` answers, `ss333/status` reads as today (AP2CP_WAKEUP 1, mode lockon). Then the CP off |
| **L2** fsm, 10 min, screen on | `linkpm.sh mode fsm` (the CP off, `pm_mode` written, the CP on), then `linkpm.sh watch 600`: `shannonctl status` every 10 s (each is a send, so a hold and a remount), the kernel's failure lines, the CP's state | at least 20 unmount/remount cycles, 0 failures, every GET answered within 2 s, no CRASH_EXIT in the loader's journal |
| **L3** fsm soak | 60 min with the screen off and a 30 s sampler; then 10 cycles of `t715-modem-power off` / `on` (each in a different FSM state) | 0 failures; ONLINE after each power-on |
| **L4** power | `power-windows.sh` with new actions `modem_lockon` and `modem_fsm` (CP off, `pm_mode` written, CP on): nine 5-min windows CP fsm / CP lockon / CP off | the fit gives the CP's cost under fsm; it goes into `BATTERY.md` |
| **L5** (needs a SIM) | an incoming call while unmounted, SMS both ways, mobile data (latency of the first ping after an idle, throughput), call audio | rings as today; nothing lost |
| **L6** | crash recovery under fsm: `modem/tools/cp-force-crash.py --yes` (test only) | silent reset, ONLINE, the FSM back in CP_BOOTING at PHONE_START |

**Afterwards (the owner's decision):**
- the modules go into a daily kernel (`#7`), lockon still the default;
- once L5 has passed, fsm can become the default.

The modem switch of `MODEM.md` §5.4 stays either way.

## 7. Certain, inferred, open

**Certain**
- read in the code: the port's locked-on PM and the stock FSM;
- measured on the tablet: the CP's 155 mW, the CP's refused release
  requests, the modules' `[permanent]` state, their vermagic, that the
  installed modules are `#6`'s, and that the kernel has no MODVERSIONS and no
  module signing;
- copied from the dossier: stock's duty cycle on this tablet (SYNTHESIS
  §2.16).

**Inferred**
- that the CP sleeps once unmounted, and the size of the saving;
- that stock's FSM timings, ported unchanged, suit this firmware under
  mainline. Stock ran them with this firmware, but under 3.10.

**Open**
- the CP's sleep floor;
- the remount latency;
- the behaviour with a SIM, network traffic and calls (L5);
- system sleep with the modem on (F2b).

## 8. Code

**Where.**
- `kernel/patches/t715-linkpm/`, two patches. They were written on
  `t715-power` (kernel `#6`) and apply unchanged on `t715-camera-mc`, the
  release kernel's tip (`kernel/README.md`). Built there with the release's
  fixed identity, the zImage and the DTB are the 1.0 Beta 1 release's, byte
  for byte, and only `sec_modem_v1.ko` and `exynos5433-mipi-lli.ko` differ,
  with the same vermagic; the replay (below) passes on that code too.
- Only `drivers/misc/modem_v1/`, `drivers/misc/mipi-lli/` and
  `include/linux/mipi-lli.h` change, so the two modules stay loadable into
  a running kernel of the same build.

| File | Change |
|---|---|
| `modem_v1/link_device_pm.c`, `link_device_pm.h` (new, 1 059 lines) | the 3.10 state machine, ported (3.3) |
| `modem_v1/link_device_lli.c` | `pm_mode` writable while the CP is OFFLINE; the dispatch on the mode; the CP2AP IRQs feeding the FSM; the send stall limit; the lockon fallback; the fail handlers |
| `modem_v1/link_device_memory.h`, `modem_utils.h`, `modem_ctrl_ss333.c`, `Makefile` | the FSM in `mem_link_device`; its lines in `ss333/status` |
| `mipi-lli/exynos-mipi-lli.c`, `mipi-lli.c`, `include/linux/mipi-lli.h` | `struct link_pm_svc` and `mipi_lli_get_pm_svc()` back; the reset, mount and unmount callbacks while active; quiet routine lines under fsm |

**Build.**
- The command, from the repository root, with the series applied to
  `src/linux-6.12`:
  `KBUILD_VOLUME=t715-kbuild-out-linkpm KBUILD_OUT_DIR=$PWD/out/mainline-linkpm KBUILD_SKIP_ARM64=1 bash kernel/kbuild-mainline.sh --fragment gts28ltexx_cpufreq.config`,
  which is `#6`'s configuration.
- Exit 0, no compiler warning.
- The `.config` is identical to `out/mainline-power-wifi/.config` (`#6`), and
  so are the built-in symbols: `System.map`, names and types, no difference.
- 78 of the 80 modules are byte-identical to `#6`'s. The two that differ:

| Module | sha256 | Size |
|---|---|---|
| `sec_modem_v1.ko` | `892cf8156f23a7c1…` | 157 984 bytes |
| `exynos5433-mipi-lli.ko` | `56428e75911a67c4…` | 44 528 bytes |

  Both have vermagic `6.12.114 SMP preempt mod_unload ARMv7 p2v8`, the same
  as the modules installed on the tablet (which are `#6`'s: same sha256).
  `out/mainline-linkpm/modules/` holds them with `SHA256SUMS`.

**The state machine, replayed off the device** (step L0):
`research/modem/linkpm/run.sh` compiles the branch's `link_device_pm.c` in
userspace on the stand-ins of `linkpm/stubs/` and drives it through:
- stock's handshake: three release, sleep and wake cycles;
- a send while unmounted, a send during the hold time, hold requests in
  UNMOUNTING and CP_FREE;
- the ACTIVATING paths;
- every watchdog, a lost edge, a stop in each of eight states with late
  events after it, a hold request before ONLINE.

**331 checks, 0 failures.**

**Review.** An independent review of the diff against stock found no defect
on the lockon path and six in fsm. All six are fixed:
1. hangs no watchdog saw, now covered by the UNMOUNTING watchdog from
   ACTIVATING and by the send stall limit;
2. a storm before PHONE_START left a session deaf (lockon fallback);
3. `++mnt_ok` sat inside a `pr_debug` that is compiled out;
4. a false "illegal state" error on a normal path;
5. a fail handler during `__ss333_off`'s wait;
6. a fail handler on an already crashed CP.

Items 5 and 6 are handled by acting only on a CP that is ONLINE or BOOTING.

**On the tablet:** `image/tests/ondevice/linkpm.sh` (section 6); section 9
has the runs.

## 9. On the tablet (2026-11-05, the owner present)

**Set-up.**
- Kernel `#6` from BOOT.
- `t715-modem-power off`, then a reboot, which booted with no modem module
  loaded.
- `image/tests/ondevice/linkpm.sh load lockon` loaded the two test modules
  from `/var/tmp/linkpm/` (sha256 checked); nothing installed.
- The tablet was on USB with the battery at 97-98 %; no SIM.

**L1, lockon on the new code.**
- The CP was ONLINE at the first try.
- `ss333/status` showed AP2CP_WAKEUP and AP2CP_STATUS at 1 ("PM locked
  on"), one good mount, the AFC code saved.
- `shannonctl` answered once shannond was up, and no kernel failure line
  appeared.
- **Same as today.**

**L2, fsm.**
- `linkpm.sh mode fsm`: CP off, `pm_mode` written, CP ONLINE again;
  "PM state machine started (CP_BOOTING)".
- Within 20 s: 9 cycles ACTIVE → AP_FREE → CP_FREE, **AP2CP_WAKEUP released
  for the first time**, but no unmount yet (the CP was busy after its boot).
- Two quiet minutes later, **the CP unmounts the link on its own and
  remounts it on its own wake**:
  - UNMOUNTING → UNMOUNTED → RESETTING → MOUNTING → ACTIVE;
  - about one cycle every 35 s;
  - at rest, **all four lines are at 0** and the FSM's wake lock is
    released.
- **The 10-minute watch** (`shannonctl status` every 10 s): 61 of 61
  answered, median 769 ms, at most 889 ms; 0 failures, 0 watchdog barks,
  no kernel failure line.
  - `status` answers from shannond's cache, so it sends nothing to the CP.
- **The AP's own wakes** (`linkpm.sh sends 20 30`):
  - `shannonctl refresh`, which sends real IPC GETs, every 30 s, each time
    to an unmounted link;
  - **19 of 20 went through HOLDING** (the AP wakes the CP; the twentieth
    met a wake of the CP's);
  - all 20 were answered;
  - 75 unmount/remount cycles and 77 good mounts in all, 0 failed mounts,
    0 barks, 0 fails.
- **Every cold refresh took about 10.8 s.** That is shannond's known
  NET_REGIST quirk (`docs/hardware/MODEM.md` §9): the CS and PS reads sent
  together are both answered with one `aseq`, and the other waits 10 s.
  - The journal has one "NET_REGIST: no answer" per refresh (20 of 20).
  - A refresh on a link just used took 730 ms.
  - Under fsm, both reads queue while the link wakes and leave in one
    burst, so the quirk hits every cold refresh; under lockon it hit only
    sometimes.
  - Not a link failure, but a shannond fix to make: send the PS read
    after the CS answer, or match the answers by domain.

**L3, the soak.**
- 30 minutes with the screen off and a sample a minute, on the first
  modules: the link was unmounted at every sample, 26 good mounts, every
  round trip answered.
- **Before the soak, one session ended on a watchdog** (one in about a
  hundred cycles):
  - the log read "PM WDOG timeout {LINK_UNMOUNTED@UNMOUNTING}";
  - the lines read {1:0:0:0}, CP2AP_WAKEUP already high again;
  - `ss333_force_crash_exit`, CRASH_EXIT, the loader's silent reset 1/5,
    ONLINE 13 s later. The recovery worked as designed.
- **The cause: an ordering race stock's FSM does not handle.**
  - The LLI driver's UNMOUNT_DONE was handled before the CP2AP_STATUS low
    edge. The FSM, still in CP_FREE, dropped the unmount (stock), then
    entered UNMOUNTING on the edge and waited for an event that had already
    come.
- **The fix, in `link_device_pm.c`:** an unmount in CP_FREE or ACTIVATING
  takes the FSM down as UNMOUNTING's does, through the new `link_down()`:
  UNMOUNTED, or HOLDING when a send waits. It is counted as "early
  unmounts" in `ss333/status`.
  - The replay has the race's sequence: 361 checks, 0 failures.
  - The rebuilt `sec_modem_v1.ko` is `896e6c358ca3`; `exynos5433-mipi-lli.ko`
    is unchanged.
- **The 10 power cycles ran once only:** a variable clash in `linkpm.sh`,
  since fixed.
- **The modules being permanent, the fix needed a second reboot.**

**With the fix**, from a fresh boot, the series ran again: 20 of 20 sends
woke an unmounted link from the AP side (HOLDING), then 30 minutes of soak
and 10 CP power-offs in UNMOUNTED, CP_FREE and ACTIVE, without a watchdog or
a failure. Afterwards `t715-modem-power on` and a reboot brought the
installed modules back.

**Left:** L4, the power saved; L5, a SIM (calls, SMS, data, call audio); L6,
crash recovery under fsm. Then the owner's decision on the default.
