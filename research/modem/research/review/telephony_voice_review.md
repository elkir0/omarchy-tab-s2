# Telephony and voice review of SYNTHESIS.md (D5-D9, §2.11-§2.15, §6.4, §7, §8)

Date 2026-10-29. Reviewer role: adversarial telephony specialist (ModemManager/oFono, Samsung IPC,
ALSA/ASoC voice). Scope: everything above "CP online". Nothing touched the tablet; no Samsung
binary was executed; no EFS/NV content was opened; no identifier is written below.

**Method.** Claims were re-checked at their source: the decompiled builders (header bytes, frame sizes,
offsets), two short static `rizin` reads of the stock blobs (`libsecril-client.so` path map at
0x33cc, `libsec-ril.so` `IoChannel::Write` at 0xe1f78), the 3.10 `modem_v1` sources
(`src/kernel_universal5433/drivers/misc/modem_v1/`, board pdata DT), mainline 6.12
(`src/linux-6.12/`), the deployed image (`image/out/rootfs-omarchy.MANIFEST`,
`image/rootfs/*.sh`, the UCM overlay, `image/pkg/omamobile-*`), and the web (Arch Linux ARM
package pages, WirePlumber, GNOME Calls, Chatty and omarchy-mobile sources). Tags: **[P]**
proven at the cited place, **[I]** inferred, **[U]** unknown. Severities: **blocker** (the
plan as written cannot pass the gate or causes damage), **major** (wrong result, rework or a
real safety/privacy hole), **minor** (precision, cost, wording).

## 0. Verdict summary

| Decision | Verdict | One line |
|---|---|---|
| D5 daemon strategy | **agree with changes** | Native IPC 4.1 first is right and the catalogue sizes hold at the builders; add the daemon/loader contract for CP restarts and name the omarchy-mobile precedent. |
| D6 RFS server | **agree with changes** | Sandbox/observe policy is right; make it a separate hardened process and fix the reply framing (the kernel cuts every write at the 2 KiB SBD slot; a short-write loop is mandatory). |
| D7 desktop + data | **agree with changes** | MM-API impersonation is the right architecture; do not write `shannon2mm` from scratch: adapt omarchy-mobile's `omamobile-mmd` (MIT, already MM-1.24.2-conformant and tested against mmcli/Calls/Chatty), whose shell is already in our image. |
| D8 voice | **agree with changes** | Kernel/UCM design is sound; the desktop half fails as written (image ships WirePlumber 0.5.13, GNOME Calls hard-depends on callaudiod); move clock-plan rates to the kernel and gate the pins on "verb applied + CP clock". |
| D9 (daemon part) | **agree with changes** | Add secret redaction in every log mode, a PIN retry guard, an SMS persist-before-ack rule, an emergency-call policy, and the network-sunset horizon. |

Top three changes (details §6): (1) reuse `omamobile-mmd` + re-enable the shell's cellular
icon as the first deliverable, data before SMS; (2) RFS server as a separate sandboxed process
with a short-write loop and chunk-aware mocks; (3) rewrite G12-G21 with a crash/restart
contract, a WirePlumber ≥ 0.5.15 prerequisite, a CallAudio shim and an explicit emergency
policy.

---

## 1. Decision-by-decision review

### D5. Telephony daemon strategy: agree with changes

What holds (verified, [P]):

- Frame sizes and offsets in §2.11 match the decompiled IPC 4.1 builders: CALL_OUTGOING is a
  99-byte frame (92 B payload, TON 0x21/0x11, number clamp 82, p91 byte; `IpcTxCallOriginate`
  0x1ddab4); PDP_CONTEXT is a 0x70-byte frame (105 B: action p0, cid p1, u32 flags p2..p5, user
  p6, password p38, auth p102, reason p104; 0x1e2684); SND_AUDIO_PATH is a 9-byte SET frame
  (2 B payload; 0x1f9614); SND_CLOCK_CTRL is an 8-byte EXEC frame (0x1f9864); the CLOCK NOTI
  parser accepts type 3 only and maps p0 1..7 through a table (0x1f9c6c); the rmnet rule binds
  interface n to DataCall id n+1 in the single-SIM branch (0x176348).
- The A1 rejection reasoning stands (writable uid-1001 `/efs`, NV regeneration, property store,
  N910C crash precedent).

Changes:

- **D5-1 (major) Missing precedent on the same desktop.** omarchy-mobile (Omarchy + Hyprland
  on Arch Linux ARM, Pixel 7 Pro) runs exactly the D5/D7 architecture: `omamobile-sitd` is the
  only process that talks to the modem; `omamobile-mmd` (Python, PyGObject Gio, MIT) owns
  `org.freedesktop.ModemManager1`, serves MM 1.24.2's API from sitd's socket, and passed a
  43-check offline conformance run with mmcli, GNOME Calls 51.1 and Chatty 0.8.9 plus an
  on-device NetworkManager check (`modem-research-scratch-20261030/web/cheetah_modem_plan.md`
  §"T0/T1", lines 2336-2430; `packages/omamobile-mmd/` on GitHub, ~1.8 kLOC lib + ~2 kLOC tests).
  KD Q2 mentions the project but D5/D7 never use it. Our image already repackages two
  omarchy-mobile packages (`image/pkg/omamobile-omarchy/PKGBUILD:25-47`,
  `image/pkg/omamobile-shell/PKGBUILD`). The protocol under it (SIT) differs; the MM layer does not.
- **D5-2 (major) No daemon/loader contract for CP restarts.** The loader holds `umts_ipc0`/
  `umts_rfs0` for life and reboots the CP with them held (LS2 §7.2 #2-#3, §9.3). Consequences the
  daemon must handle, none of which is in D5/D7/G12b:
  - the per-device RX queue is purged only when the open count reaches 0
    (`modem_io_device.c:1011-1012`), and nothing purges it on CRASH_EXIT
    (`io_dev_modem_state_changed`, `:925-950`): stale FMT/RFS frames of the dead session survive
    into the next one, and stale RESP `aseq` values can match new `mseq` values;
  - `poll` on `umts_ipc0` returns POLLHUP both for crash states and for a pending SIM change
    (`:1040-1061`); only `IOCTL_MODEM_STATUS` tells them apart, and whichever process (loader or
    daemon) calls it first consumes the SIM event (§2.9);
  - writes return `-EPERM` while not ONLINE (`:1341-1345`).
  Required rule: on POLLHUP the daemon calls STATUS; on 2/1/0 it (1) turns `Modem RX/TX Switch`
  off, (2) ends calls and bearers on D-Bus (§4.6), (3) drains both RX queues until `read` returns
  0, (4) resets its `mseq`, (5) waits for the loader's READY (sd_notify STATUS or a socket), and
  (6) discards everything before the next PWR_PHONE_PWR_UP NOTI. SIM presence is taken from
  SEC_PIN_STATUS NOTIs, never from STATUS 7/8.
- **D5-3 (minor) samsungipcd rationale.** "Drags PPP" (D7) contradicts FR Q5: samsungipcd ≥ 0.3.0
  bypasses PPP and routes on `rmnet0` (still needs `ppp`/NM-ppp packages). The rejection still
  holds for other reasons: SIM unlocking, hold/multiparty, USSD and call volume are unimplemented
  (LV §1), and every IPC 4.1 delta (§12 of IPC) would have to be patched into libsamsung-ipc.
- **D5-4 (minor) A1 oracle.** Add: run it in its own network namespace with `rmnet0-3` moved in
  (libsec-ril configures addresses and routes itself with CAP_NET_ADMIN, RR §2.2/§2.4); the `/efs`
  copy's `nv_data.bin` must be byte-identical to the loader's snapshot (the CP's RAM copy came from
  that snapshot at stage 3).
- **D5-5 (minor) AT probe output** (`ATI`, `AT+CGMR`) can contain equipment identifiers on some
  stacks: store the transcript only under `$T715_PRIVATE/`, report "answered/silent".

### D6. RFS server: agree with changes

The observe/sandbox policy (tmpfs NV copy re-seeded per CP boot, overlay for `efs/root`, no real
EFS, request log without content) is correct and is the right reading of RR §3.2/§5.

- **D6-1 (major) Separate process, not a thread in `shannond`.** G10 needs the RFS server before
  any FMT daemon exists (G10 "no daemon except RFS observe server"), so it is a standalone
  program anyway. It parses CP-controlled lengths and paths and touches the file system, which is
  exactly what deserves its own sandbox: dedicated user, `ProtectSystem=strict`,
  `ReadWritePaths=/run/shannon/rfs`, `PrivateNetwork=yes`, `NoNewPrivileges=yes`,
  `SystemCallFilter=@system-service`, NV snapshot passed with `LoadCredential=` (read-only, no
  access to `/var/lib/shannon/nv`), and a check at start that its copy's SHA-256 equals the
  loader manifest. A crash of the FMT daemon then never stalls RFS and vice versa.
- **D6-2 (major) Reply framing is not "one write()".** The kernel truncates every IPC-channel skb
  to the SBD uplink slot size and returns the short count: `xmit_ipc_to_rb()` does
  `skb->len = min(skb->len, rb->buff_size)` (`link_device_memory_main.c:301`, SBD path chosen at
  `:725-750`), `misc_write` returns `ret - headroom - tailroom` (`modem_io_device.c:1414`), and the
  board's slots are 2048 B for `umts_rfs0` UL and 4096 B for `umts_ipc0` UL
  (`arch/arm/boot/dts/modem-ss333-pdata.dtsi:38,51`). Stock `IoChannel::Write` loops over short
  writes, retrying EINTR/EAGAIN with 10 ms sleeps (libsec-ril 0xe1f78-0xe2004, static read).
  So stock NV_READ replies of up to 0x80000 B leave as ~2 KiB chunks. Requirements: (a) the
  server writes each reply with the same short-write loop (and retries `-EBUSY`, which the kernel
  returns when 1024 skbs are queued, `link_device_memory.h:205`); (b) the kernel port must **not**
  "fix" this silent truncation into an error (it is the stock chunking mechanism); (c) the O5
  mocks and the CUSE harness must emulate the truncation, or the tests prove nothing. How the CP
  reassembles chunks whose SIPC5 header still announces the full length is [U] (new unknown U22):
  log the largest NV_READ/READ_FILE size the CP requests at G10.
- **D6-3 (minor) Handle and range hygiene.** Hand out handles from 3 upward (stock gave real fds,
  never 0-2; a CP that treats 0 as failure is plausible [I]), cap open handles (e.g. 64), drop all
  handles at every CP restart; refuse NV windows beyond the snapshot size (stock `lseek`+`write`
  would grow the file; offsets 0x180014/0x181469 are outside 1 MiB); clamp READ_FILE consistently
  (stock clamps data and `n` to 0x40000 but computes `length` from the unclamped `n`, RR §5.2);
  return GET_FILE_INFO times in UTC.
- **D6-4 (minor) Language.** A C parser of untrusted CP input needs ASan/UBSan fuzzing in O5 (the
  plan only fuzzes path confinement). A memory-safe language (Python, matching `omamobile-mmd`,
  or Rust) removes the class; C is only required for the loader (rescue contexts, D4).

### D7. Desktop integration and data: agree with changes

The architecture (own daemon + MM D-Bus impersonation, raw-IP rmnet, NM configures IP, MM
masked) is the right one: Arch has no oFono; MM cannot see a misc node; a native MM plugin is
an upstream project. The implementation plan should change:

- **D7-1 (major) Adapt `omamobile-mmd` instead of writing `shannon2mm`.** It already: exports
  Manager/ObjectManager, Modem, Modem3gpp, Simple, Location, Messaging, Signal, Voice, Sim,
  Bearer, Sms, Call with signatures checked against MM 1.24.2's introspection XML; answers
  `Get/GetAll/Introspect` from the XML through Gio; ships polkit actions and a bus policy; models
  "no SIM" as MM does (FAILED/sim-missing, `Voice.EmergencyOnly`); has a container conformance
  suite; and found a real trap (listing `org.freedesktop.DBus.*` interfaces in
  `GetManagedObjects` crashes GNOME Calls). Replace its `sitd_link.py` (5.6 KB) with a
  `shannond` link, or make `shannond` speak a compatible subset of sitd's socket protocol.
  Library choice follows: python-gobject 3.58.1 is on ALARM armv7h; `python-dbus-next` is
  0.2.3 (ALARM `any`, upstream dormant since 2021) and hand-written signatures are where
  ofono2mm needed fixes (LV §1). libmm-glib also exports the server skeletons
  (`mm_gdbus_*_skeleton_new`) if a C façade is ever preferred.
- **D7-2 (major) The image already has the consumer; the first deliverable is not SMS.** The
  deployed `omamobile-shell` bar shows a cellular icon from `omamobile-cell-watch` and a call chip
  from omatel's agent, and its quick settings had a "Mobile data" tile; the tablet patches turned
  both off because no modem exists (`image/pkg/omamobile-shell/0004-tablet-quiet-pollers.patch`,
  `0001-tablet-quick-settings-tiles.patch:24`). `omamobile-cell-watch` needs only
  ObjectManager (`GetManagedObjects`, `InterfacesAdded/Removed`), `NameOwnerChanged`, Modem
  `State`/`StateFailedReason`/`SignalQuality`/`AccessTechnologies` and Modem3gpp
  `RegistrationState` with `PropertiesChanged` (upstream script, read 2026-10-29). That is the
  smallest visible deliverable (§3.3).
- **D7-3 (minor, factual) The network manager is established.** The image runs NetworkManager
  1.58.1 (`image/out/rootfs-omarchy.MANIFEST:44`; `image/rootfs/configure-system.sh:128-132`).
  Drop systemd-networkd from D7 and G17.
- **D7-4 (major) Client contract details the façade must honour** (§3.2): GNOME Calls and
  WirePlumber follow call state through the `Call.StateChanged(iiu)` signal, not
  `PropertiesChanged`; Chatty and the shell follow `PropertiesChanged`. Emit both on every change.
  WirePlumber's module has no handler for object removal, name-owner loss or `CallDeleted` of an
  active call (§4.6): a call must always reach TERMINATED through `StateChanged` before it is
  deleted, and the modem object path must stay stable across CP restarts.
- **D7-5 (minor) Packaging.** `libmm-glib` is a separate package (Calls, Chatty, NM depend on it
  only); `mmcli` lives in `modemmanager`, which `omamobile-mmd` declares as a conflict. Keep mmcli
  for the offline container; on the tablet use a libmm-glib Python probe (omarchy-mobile's
  `test/libmm-status.py` practice). No D-Bus activation file for the façade; its own bus policy
  must let its service user own the name.
- **D7-6 (minor) SMS needs more than the catalogue.** MM clients expect assembled text: the façade
  (or `shannond`) must decode/encode GSM 7-bit (with national shift tables) and UCS-2, reassemble
  and split concatenated SMS (UDH IEI 0x00/0x08; send non-final parts with `msg_type` 0x01),
  surface status reports, expose WAP push as `Sms.Data` (mmsd-tng rule), and persist received
  messages until a client deletes them (§4.3). None of this is in WP9/WP10.
- **D7-7 (minor) MTU.** `rmnet` UL slots are 2048 B (`modem-ss333-pdata.dtsi:116`) and the same
  silent truncation applies: the bearer MTU must be `min(IP_CONFIGURATION MTU, 1500)`.

### D8. Voice: agree with changes

The kernel half (wm8998 patch, c2c "baseband" link, FLL2 REFCLK MCLK1 + SYNC AIF2BCLK, refcount,
pins off at boot) is well argued and consistent with VA and mainline sources. Verified:
`gts28_wm1814.c` starts MCLK1 and FLL1 on BIAS_OFF→STANDBY (`gts28_set_bias_level`), so FLL2's
reference exists before the c2c PRE_PMU; the stock path map is the one C27 adopts (static read
of `libsecril-client.so` 0x33cc: index = input − 1; 0 → 0x01, 1 → 0x02, **2 → 0x06**, 3 → 0x04,
4 → 0x05, **5 → 0x07**, 6 → 0x08, 7..12 → 0x09..0x0E; out of range → 0x01).

- **D8-1 (blocker for G21 as written) WirePlumber version.** The image ships WirePlumber 0.5.13
  (`MANIFEST:38`; ALARM armv7h `wireplumber 0.5.13-1`, built 2026-01-01). The fix "voice call
  profile selection no longer skips profiles with `unknown` availability" is in 0.5.15 (NEWS).
  Our Voice Call profile has no jack controls, so its availability is `unknown`: with 0.5.13 the
  hook never selects it. Options: build ≥ 0.5.15 for armv7h in `image/pkg/` (the project already
  builds packages); or ship an override of `device/find-voice-call-profile.lua` with the 0.5.15
  logic in a script directory WirePlumber searches before `/usr/share` ([I]: verify the lookup
  order offline); or let `shannond` select the profile itself (`wpctl set-profile`) as a fallback.
- **D8-2 (major) Put the constant clock-plan rates in the kernel, not UCM.** `ASYNC Sample Rate 2
  = 48 kHz`, `ASRC RATE 2 = ASYNCCLK rate 2`, `ISRC2 FSH = ASYNCCLK rate 2`, `ISRC2 FSL = ASYNCCLK
  rate` never change for voice and do not affect AIF1. Writing them once in `late_probe` (the VA
  "stop-gap" writes, kept even with the codec patch) removes three hazards: the race between
  WirePlumber applying the verb and `shannond` turning the pins on (pins first → ASRC PRE_PMU with
  reset rates, `wm8998.c:55-90`, DAPM enables anyway); WirePlumber re-running the verb mid-call
  (rates rewritten while powered); and the UCM ordering constraint. UCM keeps only routing,
  volumes and pin switches. Also pin AIF1 to 48 kHz while in the Voice Call verb
  (`PlaybackRate 48000`/`CaptureRate 48000` on its devices): `SAMPLE_RATE_1` is shared with the
  ASRC sync side.
- **D8-3 (major) Pin gating and teardown order.** Turn `Modem RX/TX Switch` on only when all of:
  CP clock-on NOTI seen, `Modem Rate` set, and the Voice Call verb applied (check a routing
  control such as `ISRC2INT1 Input == AIF2RX1` via ALSA control events). Turn them off (i) on a
  clock-off NOTI (hold may stop BCLK, [U]), (ii) at once on POLLHUP/CRASH_EXIT, (iii) on CALL_STATUS
  released **before** the façade emits `StateChanged → TERMINATED`, so WirePlumber's verb switch
  never races the link. Then `CLOCK_CTRL E {0}` after the last call (stock never sends STOP during
  an active call, IPC §9).
- **D8-4 (major) callaudiod and mute.** `gnome-calls 51.1` hard-depends on `callaudiod` (ALARM
  package dependencies) and uses it for the speaker and mute buttons; G21 disables callaudiod.
  Mute through PipeWire is software-only and never reaches AIF2 (VA §5.2). Provide a small
  `org.mobian_project.CallAudio`-compatible service from `shannond` (methods `SelectMode`,
  `EnableSpeaker`, `MuteMic`, and their state properties [I: check callaudiod's interface XML]):
  `MuteMic` → `SND_MIC_MUTE_CTRL`; `EnableSpeaker` → UCM device switch + matching
  `SND_AUDIO_PATH_CTRL`/`SPKR_VOLUME_CTRL`; `SelectMode` → no-op (WirePlumber switches profiles).
  Mask the real callaudiod.
- **D8-5 (minor) What the path byte does.** On this board the physical output is chosen by the
  codec routing (UCM), not by the CP; AIF2 carries the same PCM whatever the byte. The byte selects
  the CP's processing set (gain table, AEC/NS tuning). G20's "wrong output → path byte" diagnostic
  cannot fire; the observable is echo/level quality (C27 "audible output" is not evidence).
- **D8-6 (minor) Missing call-flow items.** SND 09/08 RingbackTone NOTI (CP asks the AP to play
  local ringback when the network gives none): map to MM `RINGING_OUT` and a local tone on AIF1, or
  ignore deliberately. CALL_STATUS has no "alerting" value (1 dialing, 2 ignoring, 3 connected,
  4 released, 5 connecting): write the explicit mapping to MM states (DIALING, RINGING_OUT?,
  ACTIVE, TERMINATED; RINGING_IN/WAITING/HELD from CALL_LIST status). MT calls (CALL_INCOMING N
  → CALL_LIST G → RINGING_IN → ANSWER) have no gate (§5).
- **D8-7 (minor) Phase-1 mic.** Stock speakerphone uses the sub mic (VA §1.4); with path 0x06 the
  CP's AEC is tuned for that geometry. Expect echo with the main mic; keep phase 2 close behind.

### D9 (daemon part): agree with changes

- **D9-1 (major) Secrets never reach any log, in any mode.** `--log-payload` as written would
  record PINs, PUKs and APN passwords. A per-message redaction table is needed for SEC_PIN_STATUS
  S (p3..p18), SEC_CHANGE_LOCKING_PW (p3..p80), SEC_PHONE_LOCK S (p3..p41), GPRS_PDP_CONTEXT S
  (p6..p69), GPRS_LTE_ATTACH_APN_INFO (p127..p190), SMS bodies and numbers. Kernel side: the stock
  default `dflags` has the FMT bit set (`modem_utils.c:69-71`), which makes `log_ipc_pkt` hex-dump
  the first 16 bytes of every FMT frame at the link layer (`:309-331`, through `pr_debug` and the
  `mif_log` tracepoint in this source; the stock dmesg did carry per-frame IOD/LNK lines, IPC §0).
  For a PIN-verify frame those 16 bytes include the first PIN digits. `dflags = 0` (D9) must be the
  compiled default and the parameter should not be writable by group (stock mode
  `S_IWUSR|S_IWGRP`).
- **D9-2 (major) PIN handling.** The daemon never stores a PIN; it refuses automatic (unattended)
  PIN submission when the retry counter (SEC_LOCK_INFORMATION) is below its maximum, so a wrong PIN
  saved in an NM profile cannot walk the SIM into PUK. Bring-up gates G14-G18 use a test SIM with
  the PIN lock disabled (omarchy-mobile's T2 precondition).
- **D9-3 (major) SMS persistence before acknowledgement** (§4.3).
- **D9-4 (minor) Identifier exposure on D-Bus.** Calls derives the country from `Sim.Imsi` (or
  Location LAC/CI), Chatty from `Sim.Imsi`. omarchy-mobile leaves IMEI, IMSI and ICCID empty.
  Decide explicitly: either empty (clients lose number normalisation) or MCC+MNC only through
  `Sim.OperatorIdentifier`; keep `Modem.Location` sources disabled (no cell IDs on the bus).
- **D9-5 (minor) Node permissions.** Separate groups for `umts_ipc0` (daemon) and `umts_rfs0`
  (RFS server); `IOCTL_MIF_LOG_DUMP` injects 512 KiB of log buffer as frames into the calling
  node's RX queue (`modem_utils.c:103-125`): restrict it to root on `umts_boot0` or remove it.
- **D9-6 (minor) Metadata.** Header tuples with timestamps still reveal call/SMS timing: keep the
  daemon journal volatile or rate-limited summaries by default.

---

## 2. Errors, unsupported claims, inconsistencies

| # | Sev | Location | Statement in SYNTHESIS | Correct statement | Evidence |
|---|---|---|---|---|---|
| E1 | major | §2.12 "Replies" row; D6 | replies are one `write()` | one logical reply written with a short-write loop; the kernel cuts it into ≤ 2048-B SBD frames on `umts_rfs0` (4096 B on `umts_ipc0`); `-EBUSY` possible; CP reassembly of such chunks [U] | `link_device_memory_main.c:301`, `modem_io_device.c:1414`, `modem-ss333-pdata.dtsi:38,51`; libsec-ril 0xe1f78-0xe2004 |
| E2 | major | G21; D8 | "WirePlumber ≥ 0.5.15" as a given | image and ALARM armv7h ship 0.5.13; unknown-availability profiles are skipped before 0.5.15 | `MANIFEST:38`; ALARM package page; WirePlumber NEWS 0.5.15 |
| E3 | major | G21; D8 | "callaudiod disabled" | gnome-calls 51.1 depends on callaudiod and uses it for speaker/mute; disabling it breaks those buttons; mute must reach the CP | ALARM `gnome-calls` deps; VA §5.2 |
| E4 | major | G12 success evidence | five NOTIs PWR_UP, PHONE_STATE, PIN_STATUS, ICC_TYPE, DEVICE_READY expected | only PWR_UP NOTI is proven to gate processing (RR §6.1 #7); the other four are inferred from handlers; none of the five appears in the stock dmesg tuples | IPC §11 table (groups 07/08/0a/0d/80 only); RR §6.1 |
| E5 | minor | §2.11 "Start-up" row marked **P** | announcement sequence proven | replies (DEVICE_READY S, LOOPBACK CFRM) and the PIN GET gate are P (code); the order and presence of the CP announcements are I | IPC §10 (its own "Proven gates and replies" vs code-only evidence) |
| E6 | minor | D7 | network manager "must be checked" | NetworkManager 1.58.1 (wpa_supplicant backend) | `MANIFEST:44`; `configure-system.sh:128-132` |
| E7 | minor | D7 rationale; §3 | samsungipcd "drags PPP" | ≥ 0.3.0 has a PPP bypass on `rmnet0`; sources disagree (add contradiction C46: LV §1 vs FR Q5) | FR Q5; LV §1 |
| E8 | minor | G20 diagnostic; C27 | wrong output → path byte 0x06/0x07 vs 0x07/0x08; confirm with "audible output" | the path byte changes CP processing only; output is codec routing; evidence = GEN 0x8000 + echo/level comparison | VA §1.3 (routes), §2 (AIF2 single PCM) |
| E9 | minor | VA §0 item 6, §6.2, §6.3 row 1 | IPC SND numbering unproven; path 0x07/0x08 | superseded by IPC §9 and C27/C28; §9 of SYNTHESIS lists patches for the original dossier only: add VA | C27, C28 |
| E10 | minor | §1 first paragraph | every layer up to a voice call specified with proven evidence on both sides | above ONLINE several items are I/U: CALL_INCOMING layout, CLOCK/WB semantics, FLL2 REFCLK+SYNC behaviour, AIF2 slot use, CP reassembly of chunked RFS, network acceptance | IPC §13; VA §8 |
| E11 | minor | §1 outlook (SMS, voice rows) | conditional probabilities without a horizon | CS voice (CSFB) and probably SMS over SGs depend on the operator's 2G/3G core; the plan has no IMS/VoLTE path. | web, §Sources |
| E12 | minor | §2.14, D7 | MTU 1500 / MTU from IP_CONFIGURATION | clamp to ≤ 1500: rmnet UL slot 2048 B, larger skbs are silently truncated | `modem-ss333-pdata.dtsi:116`; `link_device_memory_main.c:301` |
| E13 | minor | G15 | "our ack accepted" | not observable as such; use DELIVER_REPORT R `ack == 0` and no redelivery of the same message within 10 min | IPC §6 |
| E14 | minor | §7 WP14 | targeted RE list | add CALL_ECCLIST 02/16 N (emergency numbers), SND 09/08 RingbackTone, SMS_MEM_STATUS policy and INCOMING storage index meaning, SAT profile download / proactive-command minimum, INDI types that need a CFRM | IPC §0 (CFRM), §5, §6, §13 |
| E15 | minor | §7 WP10 | 6-10 d from scratch | 2-4 d adapting `omamobile-mmd` + its tests [I] | D7-1 |
| E16 | minor | §2.9 "File semantics" | `read` "one frame per call (remainder pushed back)" | correct, and it implies: read with a buffer ≥ the largest frame (≥ 64 KiB for RFS) and only after POLLIN, since every empty read logs "NO data in RXQ" | `modem_io_device.c:1425-1451` |

Contradiction-log entries in scope that hold: C26 (resolution right; keep the observe log), C27
(path map verified at 0x33cc, but see E8), C28, C29, C38, C39 (add the horizon of E11), C40, C41,
C44.

---

## 3. Feasibility and cost

### 3.1 Architecture options for this desktop

| Option | New code | Conformance risk | Crash isolation | Fits the image | Verdict |
|---|---|---|---|---|---|
| SYNTHESIS: C `shannond` + new Python `shannon2mm` (dbus-next) over a private socket | IPC core + RFS + full MM façade + socket API | high (hand-written signatures, no tests yet) | good | partial (ignores the shell's MM consumers) | change |
| **Recommended**: `shannond` (IPC 4.1, SND/ALSA, CallAudio shim) + adapted `omamobile-mmd` + separate RFS server | IPC core + RFS + link adapter | low (XML-checked API, existing container suite) | best (3 processes, loader holds fds) | direct: shell icon, tile, call chip, omatel | **adopt** |
| Single daemon (IPC + MM API in one process) | less glue | depends on API layer | a façade bug kills IPC state | same | acceptable if written in Python with PyGObject; loses `omamobile-mmd` drop-in reuse |
| samsungipcd + real MM generic AT | libsamsung-ipc device file + IPC 4.1 patches + RFS server | low on D-Bus, high on AT gaps | good | good | reject: no SIM unlock, no hold/USSD/volume, AT emulation loses PDU/IPv6 detail |
| oFono driver + ofono2mm | C oFono atoms + packaging oFono for ALARM | medium | good | poor | reject (Arch has no oFono, three layers) |

Language: the CP-facing parsers (`shannond`, RFS) gain more from memory safety than from C;
Python is adequate for FMT traffic (tens of frames per second) and matches the façade.

### 3.2 Minimal ModemManager subset the chosen clients use

From the client sources (read 2026-10-29) unless marked [I].

| Consumer | Interfaces and members actually used |
|---|---|
| `omamobile-cell-watch` (bar icon, in our image) | ObjectManager `GetManagedObjects`, `InterfacesAdded/Removed`; `NameOwnerChanged`; Modem `State`, `StateFailedReason`, `SignalQuality`, `AccessTechnologies`; Modem3gpp `RegistrationState`; `PropertiesChanged` |
| NetworkManager 1.58 [I: LV §2, §5 and omarchy-mobile T1] | Modem `State`, `StateFailedReason`, `UnlockRequired`, `PrimaryPort`, `Device`, `DeviceIdentifier`, `Drivers`, `Plugin`, `CurrentCapabilities`, `Sim`, `Bearers`, `Enable()`; Modem3gpp `RegistrationState`, `OperatorCode`, `OperatorName`; Simple `Connect`/`Disconnect`; Bearer `Interface`, `Connected`, `Ip4Config`, `Ip6Config` (incl. MTU); Sim `SendPin`, `OperatorIdentifier` |
| Chatty 0.8.9 | Manager object manager (`object/interface-added/removed`), name watch; Modem `State` (`notify`), `OwnNumbers`, `Sim`; Sim `Imsi`; Messaging `List`, `Create`, `Delete`, `Added`; Sms `Send`, `State` (`notify`), `PduType`, `Number`, `Text`, `Timestamp`, `MessageReference`, `DeliveryState` |
| GNOME Calls 51.1 | Modem `OwnNumbers`, `Model`, `Manufacturer`, `Device`, `PrimaryPort`, `DeviceIdentifier`, `Plugin`, `Sim`; Voice `CreateCall`, `DeleteCall`, `ListCalls`, `CallWaitingQuery/Setup` (Unsupported is fine), `CallAdded/Deleted`; Call `Number`, `State`, `StateReason`, `Direction`, `Start`, `Accept`, `Hangup`, `SendDtmf`, **`StateChanged` signal**; Sim `Imsi`, `EmergencyNumbers`; optional Ussd, Location 3GPP |
| WirePlumber modem module | object manager on `/org/freedesktop/ModemManager1` (object-added only); Voice `ListCalls`, `CallAdded/Deleted`; Call cached `State` once, then **`StateChanged`** only; active = DIALING, RINGING_OUT, ACTIVE |

So the first useful façade is ~8 Modem/3gpp properties; NM data adds Simple + Bearer + Sim;
Messaging/Sms and Voice/Call follow. Everything else returns `Error.Core.Unsupported`.

### 3.3 Smallest deliverables with visible value (recommended order)

1. **Cellular icon in the bar** (registration + signal): `shannond` radio on, NET_REGIST, ICON/RSSI
   NOTIs; façade subset of the first row above; flip `cellWatch` on in the tablet `shell.json`.
   Visible, low risk, no subscriber data leaves the daemon.
2. **Mobile data in NetworkManager**: PDP + RAWIP rmnet + Simple/Bearer; restore the quick-settings
   "Mobile data" tile (patch 0001). For an LTE tablet this is the main value of the modem.
3. **SMS** in omatel's Messages or Chatty, after the spool and the PDU codec exist (§4.3).
4. **Voice signalling** (MO and MT) in the Phone app or GNOME Calls.
5. **Call audio**.

SYNTHESIS orders SMS (G15) before the façade (G16) and data (G17). A raw SMS smoke test can stay
as an IPC check, but data before SMS gives the owner value sooner and avoids the SMS-loss hazard
while the spool does not exist.

### 3.4 Effort deltas (judgement)

WP10: 6-10 d → 2-4 d (adaptation). New: SMS codec + spool 2-3 d; CallAudio shim 1 d; WirePlumber
≥ 0.5.15 armv7h package or override 0.5-1 d; shell patch revert 0.5 d; fake-CP harness (CUSE
`umts_ipc0`/`umts_rfs0` with truncation and POLLHUP semantics) 2-3 d, mostly reusing WP7.

---

## 4. Safety and privacy

1. **RFS sandbox and NV** (D6 + D6-1/2/3): agree; add a separate hardened process, snapshot-hash
   equality with the loader, no growth beyond the snapshot, handle reset per CP boot. Phase-2
   persistence stays manual and owner-approved, as written.
2. **Stock rild/libsec-ril** (rule 5): agree; add own network namespace and identical NV copy
   (D5-4).
3. **Logging** (D9-1, D9-6): redaction table applies in every mode, including `--log-payload`;
   compiled `dflags = 0`; the IPC logger ioctl restricted (D9-5).
4. **SIM PIN** (D9-2): never stored, never logged, no unattended submission below max retries,
   test SIM with PIN lock off for bring-up.
5. **SMS loss.** Until the spool exists, a received SMS acknowledged with `ack = 0` and dropped is
   lost forever (the network deletes it). Rule: persist (spool 0600 under the daemon's state dir)
   **before** DELIVER_REPORT `ack = 0`; when persistence is impossible, answer "memory capacity
   exceeded" (catalogue 0x8080) and set SMS_MEM_STATUS full so the SMSC retries later. Spool
   entries are deleted when a client deletes the message.
6. **Emergency calls.** CS emergency is CALL_OUTGOING with type p1 = 0x07 (IPC §5); the CP's
   own ECC handling is [U]; the ECC list NOTI is not decoded; with a 2G/3G sunset and no IMS the
   tablet loses emergency calling altogether. Policy to state in §5: (a) never test with a real
   emergency number; (b) until G18/G18b pass and ECC handling exists, the façade refuses emergency
   numbers at `CreateCall` with a clear error (omarchy-mobile's choice) so nobody waits on a call
   that cannot connect; (c) afterwards best effort with type 0x07 and `Voice.EmergencyOnly` when the
   SIM is absent or locked; (d) README: this tablet is not an emergency phone. Owner decision
   between (b) and earlier best effort.
7. **CP crash mid-call** (D5-2, D8-3, D7-4): pins off immediately; every call gets
   `StateChanged(→ TERMINATED, reason)` then `CallDeleted`; bearers `Connected = false`; modem
   object kept at the same path with State FAILED/DISABLED until the next PWR_UP; RX queues
   drained; no RFS handle survives. Never restart the façade (bus name loss) during a call: neither
   WirePlumber nor Calls recovers its active-call count from that.
8. **Network horizon** (E11): record the operator's sunset dates before investing in G18+.

---

## 5. Plan gates (§6.4) and offline tests

### 5.1 Gate corrections and additions

| Gate | Change |
|---|---|
| O5 | add: encoder golden vectors for every TX message from a machine-readable catalogue (sizes 92/105/127/194/85/19/9/185/2/1 B); decoders against dmesg tuple lengths (REGIST 19, SERVING 26, ICON 10, RSSI 9, GEN 5, CELL_INFO 548); RFS with SBD truncation and `-EBUSY` emulation; ASan/UBSan fuzz of RFS framing |
| **O8 (new)** fake-CP scenarios | CUSE `umts_ipc0`/`umts_rfs0` with the real misc semantics (100 ms empty read, one frame per read with push-back, POLLHUP on crash and SIM change, `-EPERM` when not ONLINE, STATUS 7/8 consumption, stale queue across a reset); replay the stock header sequence (94 IOD lines: `mseq/aseq` pairing, unanswered EVENTs, GEN for unsupported GET) with synthetic payloads; scripts for MO/MT call, multipart SMS in/out, PDP up/down, CLOCK/WB NOTIs, CP crash mid-call |
| **O9 (new)** D-Bus conformance | private system bus + façade + fake `shannond`: mmcli, libmm-glib, Calls and Chatty under Xvfb (omarchy-mobile's suite), NM against a dummy netdev named `rmnet0` in a netns; a WirePlumber-contract test (object manager + `ListCalls` + `StateChanged`) that fails if a call is deleted while active |
| O6 | add level 1b (every `cset` name/value exists in mainline) as a blocking check; Voice Call devices carry 48 kHz rates; rate controls absent from UCM once D8-2 is applied |
| G12 | evidence: PWR_UP NOTI; one GET round trip (DISP_ICON_INFO G → 10-B RESP); replies to DEVICE_READY/LOOPBACK if they arrive; RFS server answering; no "NO data in RXQ" flood |
| G12b | add daemon assertions: pins off, stale queue drained, `mseq` reset, façade (once present) keeps the modem path and terminates calls; RFS handles dropped |
| **G12c (new)** daemon restart | kill and restart `shannond` while ONLINE and idle: no CP state change (fds held by the loader), state re-synced by GETs (PIN, REGIST, CALL_LIST) |
| G14 | test SIM, PIN lock off; record CS and PS registration separately (SMS/CSFB vs data); NET_MODE_SEL GET before any SET |
| **G16a (new, before data)** bar icon | façade subset 1; `cellWatch` on; icon shows bars and RAT |
| G17 → before SMS | data through NM (`nmcli` gsm connection), MTU clamp, teardown, CP crash during data (NM sees `Connected = false`) |
| G15 → after G17 | spool and NACK policy in place first; evidence per E13 |
| G18 | add MM state mapping check (DIALING → ACTIVE → TERMINATED via `StateChanged`) |
| **G18b (new)** MT call | incoming call, reject, answer, missed call; CALL_INCOMING → CALL_LIST path |
| G19 | run with rate controls already set by the kernel (D8-2) |
| G20 | remove the path-byte "wrong output" diagnostic (E8); add hold (clock-off NOTI → pins off) |
| G21 | prerequisites: WirePlumber ≥ 0.5.15 behaviour (package or override), CallAudio shim, callaudiod masked; evidence adds: CP crash mid-call returns the profile to HiFi without restarting WirePlumber |

### 5.2 Order of features

Registration/signal → data → SMS → voice signalling (MO, MT) → call audio. Voice audio can be
prepared offline in parallel (O6, G19 dry run) because it does not depend on the network.

---

## 6. Most important changes, as replacement text

### 6.1 Replace D7's Decision cell

> **(1), built on omarchy-mobile's bridge.** `shannond` owns `umts_ipc0` (IPC 4.1), the codec's
> `Modem RX/TX Switch` and `Modem Rate`, and a CallAudio-compatible D-Bus service; it never owns
> `umts_rfs0` (see D6). The MM façade is `omamobile-mmd` (MIT, Python/PyGObject Gio, MM 1.24.2
> API checked against MM's XML), packaged for armv7h like `omamobile-shell`, with its
> `sitd_link.py` replaced by a `shannond` link. ModemManager's daemon is not installed
> (`libmm-glib` only); no D-Bus activation file. Delivery order: (a) Manager/ObjectManager,
> Modem, Modem3gpp for the shell's cellular icon (`cellWatch`); (b) Sim, Simple, Bearer for
> NetworkManager 1.58 (the image's network manager) with the "Mobile data" tile restored;
> (c) Messaging/Sms with GSM 7-bit/UCS-2, concatenation and a persist-before-ack spool; (d)
> Voice/Call; (e) Ussd. Every property change emits `PropertiesChanged`; Modem and Call state
> changes also emit `StateChanged`. A call always reaches TERMINATED by `StateChanged` before
> `CallDeleted`; the modem object path is stable across CP restarts; the façade is never restarted
> during a call. Data: rmnet `ARPHRD_RAWIP`; bearer `Interface = rmnet(cid−1)`, `Ip4Config`
> STATIC (address /32, DNS, MTU = min(network MTU, 1500)), `Ip6Config` DHCP with the network IID
> link-local; NM configures IP. Offline gate O9 runs omarchy-mobile's conformance suite (mmcli,
> libmm-glib, GNOME Calls, Chatty) plus NM against a dummy `rmnet0` and a WirePlumber-contract
> test. AT on `umts_router` stays a fallback if G13 answers and the IPC route stalls.

### 6.2 Replace D6's Decision cell (first sentences) and §2.12 "Replies" row

> **Phase 1 (G10-G18): (c) "observe" mode in a separate process `shannon-rfsd`** (memory-safe
> language or fuzzed C), started by the loader's READY, as its own user with `ProtectSystem=strict`,
> `PrivateNetwork=yes`, `NoNewPrivileges=yes`, `ReadWritePaths=/run/shannon/rfs` and the NV
> snapshot passed by `LoadCredential=`; it refuses to start unless the snapshot's SHA-256 equals
> the loader manifest. It speaks the 6-byte protocol (§2.12) with reassembly ≤ 0x80000, id echo,
> no reply for 0x0D-0x10 and 0x12, handles numbered from 3 (cap 64, all dropped at every CP
> restart), NV windows limited to the snapshot size, and writes every reply with a short-write
> loop that retries EINTR, EAGAIN and EBUSY.

> | Replies | one logical reply per request, same header, `cmd` echoed, **`id` echoed**; ret/errno replies 14 B `{hdr, i32 ret @6, u32 errno @0xA}`. The kernel truncates each `write()` to the SBD uplink slot (2048 B on `umts_rfs0`, 4096 B on `umts_ipc0`, `modem-ss333-pdata.dtsi:38,51`; `link_device_memory_main.c:301`) and returns the short count; stock `IoChannel::Write` loops until done (libsec-ril 0xe1f78). The port must keep this behaviour; mocks must emulate it; CP-side reassembly of the chunks is U22 | RR §5.1-5.2; SYN | P (AP side), U (CP side) |

### 6.3 Replace D8's "Daemon ordering" sentence

> **Daemon ordering**: the ISRC2/ASRC/ASYNC clock-plan rates are written once by the machine
> driver's `late_probe` and never by UCM. On call DIALING (MO) or answer (MT): `AUDIO_PATH_CTRL` S
> {0x06 speaker or 0x07 headphone, 0x00}, `SPKR_VOLUME_CTRL` S {0x11 or 0x31, fixed level},
> `TWO_MIC_SOL_CTRL` S {0, 0}, `MIC_MUTE_CTRL` S {0}. `Modem RX/TX Switch` go on only when the CP
> clock-on NOTI has arrived, `Modem Rate` matches the last WB report, and the Voice Call verb is
> applied (ALSA control check); they go off at once on a clock-off NOTI, on POLLHUP/CRASH_EXIT, and
> on CALL_STATUS released **before** the call's `StateChanged → TERMINATED` is emitted; after the
> last call `CLOCK_CTRL` E {0}. Fallback if no clock NOTI within 3 s of connected: `CLOCK_CTRL` E
> {1} once. Mute and speaker come from a CallAudio-compatible service in `shannond`
> (`MuteMic` → `MIC_MUTE_CTRL`); callaudiod is masked. Profile switching needs WirePlumber ≥ 0.5.15
> behaviour (the image has 0.5.13): package it or override `find-voice-call-profile.lua`; fallback
> `wpctl set-profile` from `shannond`. The path byte selects CP processing, not the output.

### 6.4 Replace §6.4 rows G12-G17 ordering (summary text for the section intro)

> Order: G12 (FMT/RFS traffic) → G12b (crash path, daemon assertions) → G12c (daemon restart) →
> G13 (AT probe) → G14 (radio, test SIM with PIN lock off, CS and PS registration) → G16a (bar
> cellular icon through the façade) → G17 (data through NetworkManager) → G15 (SMS, only with the
> spool and NACK policy) → G16 (Messaging in a client) → G18/G18b (MO and MT voice signalling) →
> G19-G21 (audio). Offline gates O8 (fake-CP scenarios with real misc semantics) and O9 (D-Bus
> conformance) precede G12 and G16a respectively.

### 6.5 Add to §5 safety rules

> | 22 | **Secrets never logged**: PIN/PUK, APN passwords, SMS bodies and numbers are redacted in every log mode, including `--log-payload`; `dflags = 0` is the compiled default | stock `dflags` hex-dumps the first 16 bytes of each FMT frame | A | D9 |
> | 23 | **No unattended PIN submission** below the SIM's maximum retry count; bring-up uses a test SIM with the PIN lock off | PUK lock | S | D9 |
> | 24 | **Persist before acknowledging an SMS**; otherwise answer memory-full | messages are deleted by the network once acknowledged | A | §4.3 |
> | 25 | **Never test with a real emergency number**; emergency numbers are refused at `CreateCall` until the emergency gate passes; the tablet is not an emergency phone (no IMS; CS ends with the operator's 2G/3G sunset) | safety, law | A | §4.6 |

And to §8: U22 CP reassembly of chunked RFS replies; U23 LTE default-bearer cid and whether
PDP_CONTEXT activate is needed after attach; U24 SMS routing (AP vs SIM storage, MEM_STATUS);
U25 INDI types that require a CFRM and minimal SAT handling; U26 CP clock behaviour on hold and
swap; U27 operator 2G/3G sunset dates and SMS-over-SGs availability after them.

---

## 7. Checked and found correct

IPC header, types, sequencing and GEN rules (§2.11 rows 1-5); NET_REGIST domains; PHONE_STATE
values (0x0001 bytes `01 00`, 0x0202 bytes `02 02`); NET_MODE_SEL bitmask 0x0B; SMS SEND/INCOMING/
DELIVER_REPORT layouts; call sizes (92, 85 B) and emergency type 0x07 (p1); DEFINE_PDP 127 B,
PDP_CONTEXT 105 B, LTE_ATTACH 194 B, IP_CONFIGURATION offsets as catalogued; cid n ↔ rmnet(n−1)
(AP-side rule; CP routing I); `ARPHRD_RAWIP` = 519 and mainline IPv6 autoconf accepts it
(`addrconf.c:3500-3512`); RFS header, command table and path mapping (RR §5); NV facts in §2.13;
SND numbering (C28), path map (C27, re-read at 0x33cc), 2-byte path payload (C29), CLOCK_CTRL EXEC
and NOTI table; AIF2 format and FLL2 plan in §2.15; mainline gaps in wm8998 (VA §3); WirePlumber
active states (DIALING, RINGING_OUT, ACTIVE); ALARM armv7h availability: modemmanager/libmm-glib
1.24.2-2, networkmanager 1.58.1-2, gnome-calls 51.1-1, chatty 0.8.9-9, python-gobject 3.58.1-1,
python-dasbus 1.7-5, python-dbus-next 0.2.3-8, wireplumber 0.5.13-1 (too old, E2).

## Sources (web, read 2026-10-29)

- Arch Linux ARM package pages: [modemmanager](https://archlinuxarm.org/packages/armv7h/modemmanager),
  [libmm-glib](https://archlinuxarm.org/packages/armv7h/libmm-glib),
  [wireplumber](https://archlinuxarm.org/packages/armv7h/wireplumber),
  [networkmanager](https://archlinuxarm.org/packages/armv7h/networkmanager),
  [gnome-calls](https://archlinuxarm.org/packages/armv7h/gnome-calls),
  [chatty](https://archlinuxarm.org/packages/armv7h/chatty),
  [python-gobject](https://archlinuxarm.org/packages/armv7h/python-gobject),
  [python-dasbus](https://archlinuxarm.org/packages/armv7h/python-dasbus),
  [python-dbus-next](https://archlinuxarm.org/packages/armv7h/python-dbus-next)
- WirePlumber: [NEWS](https://raw.githubusercontent.com/PipeWire/wireplumber/master/NEWS.rst),
  [module-modem-manager.c](https://raw.githubusercontent.com/PipeWire/wireplumber/master/modules/module-modem-manager.c),
  [wireplumber.conf](https://raw.githubusercontent.com/PipeWire/wireplumber/master/src/config/wireplumber.conf)
- GNOME Calls MM provider: [calls-mm-origin.c](https://raw.githubusercontent.com/GNOME/calls/main/plugins/provider/mm/calls-mm-origin.c),
  [calls-mm-call.c](https://raw.githubusercontent.com/GNOME/calls/main/plugins/provider/mm/calls-mm-call.c)
- Chatty: [chatty-mm-account.c](https://gitlab.gnome.org/World/Chatty/-/raw/main/src/mm/chatty-mm-account.c)
- libmm-glib skeletons: [MmGdbusModemSkeleton](https://www.freedesktop.org/software/ModemManager/doc/latest/libmm-glib/MmGdbusModemSkeleton.html)
- omarchy-mobile: [repository (MIT)](https://github.com/derekross/omarchy-mobile),
  [packages/omamobile-mmd](https://github.com/derekross/omarchy-mobile/tree/main/packages/omamobile-mmd),
  [omamobile-cell-watch](https://raw.githubusercontent.com/derekross/omarchy-mobile/main/packages/omamobile-shell/bin/omamobile-cell-watch),
  [omatel PKGBUILD](https://raw.githubusercontent.com/derekross/omarchy-mobile/main/packages/omatel/PKGBUILD)
