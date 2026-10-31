# Samsung RIL runtime, session start and RFS service (SM-T715, T715XXU2CRH1)

Static, read-only analysis of the stock Android 7.0 RIL stack of the SM-T715 ("Samsung RIL v3.0"):
`/system/bin/rild`, `lib/libril.so`, `lib/librilutils.so`, `lib/libsec-ril.so`,
`lib/libsecril-client.so`, `lib/libaudio-ril.so`, plus the stock ramdisk rc files. Purpose: decide
between (a) running stock bionic `rild` + `libsec-ril.so` in a minimal Android chroot on the mainline
6.12 ARM32 kernel and (b) writing a native libsamsung-ipc based daemon. Section 5 is the RFS server
specification a native daemon must implement.

Nothing was executed or emulated. No EFS, `nv_data` or modem-filesystem content was opened. No
identifier appears below.

## 0. Method and conventions

- Tools: `rz-bin` (DT_NEEDED, imports, exports, `.rel.plt`), `rizin -b 16` linear Thumb-2
  disassembly of `.text`, `/usr/bin/objdump -p` (program headers), and small Python scripts that
  resolve `ldr rX,[pc,#lit]; add rX,pc` string loads, track constant arguments up to each
  `bl/blx`, map PLT stubs to symbols (`.rel.plt` order), and decode Android packed relocations (APS2)
  for `GLOB_DAT`/`RELATIVE` slots that rizin does not show. The scripts, raw listings and per-function
  dumps are in the session scratchpad (`.../scratchpad/ril-runtime/`), not in the repository.
- libsec-ril exports about 9300 symbols (C++ mangled), so most function names below are the vendor's
  own (`Nv::ProcessOpenFile()` etc.), not guesses.
- **Addresses are ELF virtual addresses.**
  - `libsec-ril.so`: first `PT_LOAD` at VA 0xa000. File offset = VA − 0xa000 (code/rodata),
    VA − 0xb000 (`.data.rel.ro`/`.got`/`.data`, from VA 0x27bc10). `.text` 0xde8e0–0x21f350.
  - `libril.so`: file offset = VA (RX), VA − 0x1000 (RW, from 0x16510).
  - `rild`: `main` = 0x1154 (from the `__libc_init` structure at 0x5f10), `switchUser` = 0x1044.
- Tags: **[P]** proven (address, or `file:line`), **[I]** inferred (reasoning given).
- Earlier notes reused: `SS333_LLI_BRINGUP.md` §2, §5; `CBD_RE.md` §5–§9; web notes
  `android_ril_reuse.md`, `samsung_ipc_free_rils.md`.

## 1. Key findings

1. **RFS on `/dev/umts_rfs0` uses libsamsung-ipc's 6-byte header**, not an FMT header:
   `{u32 length (whole frame incl. header); u8 cmd; u8 id}`. Commands 0x01–0x17, with names matching
   the `RFS_*` table that `IpcProtocol41` uses only for logging. FMT messages with main group 0x15
   (`RFS_CMD`) are ignored (`IpcProtocol41::IpcRxRfs` is a stub returning 0). **[P]** (§5).
2. **The CP's file system lives at `/efs/root/`.** Paths starting with `Audio_OEM`, `Audio_IFX`,
   `CP_AUDIO_SLSI` or `RF_NVM` are served from `/system/etc/`; `err*` and `/data/log*` go to
   `/data/log/`; any `..` component is rejected. NV items are byte windows into `/efs/nv_data.bin`.
   File handles given to the CP are raw AP file descriptors. **[P]** (§5.3).
3. **`ril.cbd.rfs_check_done=1` is written by libsec-ril** (`Modem::Init`, 0x10d0fe) right after
   `Nv::Init()` returns 0, **before** the CP is online. `Nv::Init` validates `/efs/nv_data.bin` with
   an internal 16-bit checksum (header at file offset 0x80000) and with
   `MD5(file ‖ "Samsung_Android_RIL")` against `/efs/nv_data.bin.md5`. On failure it restores from
   `/efs/.nv_data.bak` or `.nv_core.bak`, and **as a last resort regenerates `nv_data.bin` from the
   default NV inside the RADIO partition (`/dev/mbin0`)**. cbd only waits up to 5 s for the property.
   **[P]** (§3.2).
4. **libsec-ril does not boot the CP.** `DoModemBoot()` = `WaitForOnline()`: it polls
   `IOCTL_MODEM_STATUS` (0x6f27) on `/dev/umts_boot0` until `STATE_ONLINE` (4), then opens
   `/dev/umts_ipc0` and `/dev/umts_rfs0` (which satisfies the kernel's `rild_ready`). Request
   processing stays disabled until the CP sends `PWR_PHONE_PWR_UP` (FMT main 0x01, sub 0x01, type
   NOTI). Recovery is "exit and let init restart everything": `DoModemSilentReset()` is `exit(0)`,
   and the rc file restarts `cpboot-daemon` whenever `ril-daemon` restarts. **[P]** (§6).
5. **Running stock rild on 6.12 needs no binder, ashmem or `/dev/alarm`.** The real requirements are
   a bionic `/system`, a working property area plus `property_service`, init-style inherited sockets
   `ANDROID_SOCKET_rild` and `ANDROID_SOCKET_rild-debug` (missing → `exit(-1)`), the modem device
   nodes, a writable `/efs` owned by uid 1001, and a supervisor that copies the Android lifecycle.
   Two traps: stock libril **exits rild when the RIL client disconnects**, and rild's event-loop
   error path does `kill(0, SIGKILL)` (whole process group). **[P]** (§2, §7).

Also notable: the audio "Multiclient" socket accepts a peer only if its `argv[0]` and app-id match
a 30-entry whitelist (for example `/system/bin/audioserver` with uid 1041, `com.sec.phone` with uid
1001, `system_server` with uid 1000). **[P]** (§2.4).

## 2. Q1: dependencies, Android services, sockets, credentials

### 2.1 DT_NEEDED [P] (`rz-bin -l`)

| Binary | DT_NEEDED |
|---|---|
| `bin/rild` | liblog, libcutils, libril, libdl, libc++, libc, libm |
| `lib/libril.so` | liblog, libutils, libbinder, libcutils, libhardware_legacy, librilutils, **libsecnativefeature**, libc++, libdl, libc, libm |
| `lib/librilutils.so` | libc++, libdl, libc, libm |
| `lib/libsec-ril.so` | libcutils, libril, libnetutils, libsqlite, libhardware_legacy, libcrypto, librilutils, libxml2, **libsecnativefeature**, **libfloatingfeature**, libc++, libdl, libprotobuf-cpp-full, libc, libm |
| `lib/libsecril-client.so` | libcutils, libhardware_legacy, libc++, libdl, libc, libm |
| `lib/libaudio-ril.so` | liblog, libcutils, libutils, libc, libsecril-client, libc++, libdl, libm |
| `lib/hw/audio.primary.universal5433.so` | … libsecril-client, libaudio-ril, libsecnativefeature, libtinyalsa, Samsung pre/post-processing libs … |

All these libraries exist in the stock `/system/lib` listing (`dumps/system_listing.txt`, lines
424–840), but only the RIL ones were extracted into the private blob directory. Their transitive
closure (libutils → libbacktrace/libunwind/libbase, libxml2/libsqlite → libicuuc/libz, …) is
**[I]** and must be computed from a full `/system` image.

### 2.2 Imports that imply Android services [P] (`rz-bin -i`)

- **Properties**: `property_get`/`property_set` (libcutils) in rild, libril, libsec-ril,
  libsecril-client. No binary imports `__system_property_*` directly. libsec-ril wraps them in
  `ReadProperty*`/`WriteProperty*` (0xe1740–0xe1c38). The slot-indexed variants store
  comma-separated per-SIM lists, and `WriteProperty(key, slot, value)` writes from a detached
  pthread (0xe1854).
- **Binder**: libril imports only `android::Parcel` methods, `String16` and
  `android::elapsedRealtime()`. There is no `ProcessState`, `IPCThreadState`, `IServiceManager` or
  `BpBinder` import in any of the four RIL binaries, so libbinder is needed only as a library and
  `/dev/binder` is never opened **[P]** for the imports; **[I]** that libbinder's static initialisers
  do not open the driver (Android 7 opens it lazily in `ProcessState::self()`).
- **ashmem**: no import and no string in rild, libril, libsec-ril or libsecril-client.
- **Logging**: `__android_log_buf_print` (liblog). The Android 7 liblog transport (`/dev/socket/logdw`)
  is **[I]** (liblog not in the blobs).
- **Wake locks**: `acquire_wake_lock`/`release_wake_lock` (libhardware_legacy). Names: libril
  `"radio-interface"` (libril 0x63e2); libsec-ril `"ril-rfs"` (RFS frames, 0x10a182),
  `"ril-imei"`, `"ImeiProcess"`, `"ril-factory"`, `"ril-fd"`, `"Ril-Am"`. That libhardware_legacy
  writes `/sys/power/wake_lock` and `/sys/power/wake_unlock` is **[I]** (AOSP N source; library not
  inspected).
- **`/dev/alarm`**: `ElapsedRealTime()` (0xe1024) opens `/dev/alarm` and issues
  `ANDROID_ALARM_GET_TIME(ELAPSED_REALTIME)` (0x40086134). If that fails it falls back to
  `clock_gettime(CLOCK_BOOTTIME)`, then `CLOCK_MONOTONIC` (0xe1080–0xe1096). `SetRtc()`
  (0x40086105) is reached only from factory paths (`ConfigManager::RilFacoryReset`,
  `FactoryManager::SetFactoryTimeRTC`). No shim is needed **[P]**.
- **Netlink/net**: `NetlinkUtilsRunnable` (NETLINK_ROUTE) and `UeventUtilsRunnable`
  (NETLINK_KOBJECT_UEVENT; only consumer `MiscManager::OnSvnetUevent`, matching `MAILBOX=cp_reset`,
  `cp_exit` and `hsic_disconnected`. The 3.10 `modem_v1` driver emits no such uevent, so it is
  irrelevant here **[P]** for libsec-ril, **[I]** for the kernel based on grep). libsec-ril
  configures the data interfaces itself with ioctls (`SIOCSIFADDR`, `SIOCSIFFLAGS`, `SIOCADDRT`,
  `SIOCDELRT`, `SIOCSIFMTU`, `SIOCSIFTXQLEN`, bridge ioctls) in `IntfConf`/`IntfConfV6`, called from
  `Interface::BringUp(DataLink*, bool)`. It writes `/proc/sys/net/ipv6/conf/%s/*` and the properties
  `net.%s.dns%d` and `net.temp.mtu`. **There is no netd, `ndc` or iptables usage** (no such string
  in libsec-ril) **[P]**.
- **External processes**: `system()` only in `SecRil::SetEnableUnsolResponse` (a qmuxd check, so
  Qualcomm only) and in `IpcRxServiceModeCPLogging`. `popen("ps -C qmuxd")`. `Am::Execute` (0x10f810)
  first sends the `am` command line to the RIL client as unsolicited 11002 (0x2afa), and also has a
  `fork/vfork` + `execv("/system/bin/sh", …)` + `waitpid` path. `LogManager`/`GetLog` fork `logcat`
  and kernel-log readers (debug only) **[P]**.
- **Others**: `SecNativeFeature::get*` and `SemFloatingFeature::getInteger` (CSC/floating
  features), sqlite3 (telephony provider DBs), libxml2 (`/system/omc/SW_Configuration.xml`,
  `customer.xml`, `cp.xml`), OpenSSL `MD5_*` (NV check), `AES_*` + `RAND_bytes` (SIM data
  encryption files in `/data/misc/radio`), protobuf/nanopb (SAP, PLMN delta), `getpwuid_r` and
  `multiuser_get_app_id` (peer checks) **[P]**.

### 2.3 Sockets [P]

| Socket | Created by | How | Evidence |
|---|---|---|---|
| `rild` (`rild2..4` for `-c 2..4`) | init, inherited | libril reads `ANDROID_SOCKET_<name>`, `strtol`, `listen(fd,4)`. **Missing → "Failed to get socket", `exit(-1)`** | libril 0x4de4–0x4e78; default name at libril VA 0x17004, `rild2..4` at 0x13480; suffix chosen in rild main 0x128c–0x130e |
| `rild-debug` | init, inherited | same; **missing → `exit(-1)`** | libril 0x480e–0x48fc |
| `sap_uim_socket1` | init, inherited | `RilSocket::socketInit`; failure only logged | libril 0xc89c–0xc90c |
| `Multiclient` (`Multiclient2` for RilIndex>0) | libsec-ril | `socket_local_server(name, ABSTRACT, SOCK_STREAM)` in `OemClientReceiver::Start` (0xe4fbc), after `SecRil::Init` | 0xe4ff2, 0xe50ce |
| `IPCDEBUG_UNIX_SOCKET` | libsec-ril | abstract; only if `IsShipBuild()` is false and log level ≥ 2 (`Modem::Init` 0x10d042–0x10d074) | 0x101c68 |
| imsd / epdgd UNIX channels | libsec-ril | `SockUnixIoChannel` (abstract), only for the CSC IMS/EPDG modem types 8/0x40 | table at 0x27c5e8 |
| TCP listener port 7777 | libsec-ril | `OemClientReceiver::OpenServerSocket()` (0xe5118) builds `AF_INET` port 0x1e61; **no caller found** in the linear scan, so treat as unused **[I]** | 0xe513e |

Abstract sockets are scoped by network namespace, so `Multiclient` clients (audio HAL replacement)
must share rild's netns **[I]** (Linux semantics).

### 2.4 Credentials and peer checks [P]

- The stock rc starts rild as **root** (`init.rilchip.rc:7-14`: `user root`, `group radio cache inet
  misc audio sdcard_r sdcard_rw log vpn system readproc`, `onrestart restart cpboot-daemon`). rild
  then drops privileges itself (`switchUser` 0x1044): `prctl(PR_SET_KEEPCAPS,1)`,
  `setresuid(1001,1001,1001)`, `capset(v3)` with effective = permitted = **CAP_CHOWN,
  CAP_DAC_READ_SEARCH, CAP_NET_ADMIN, CAP_NET_RAW, CAP_SYS_ADMIN** (word 0 = 0x00203005) and
  **CAP_BLOCK_SUSPEND** (word 1 = 0x10). This runs before `dlopen(libsec-ril)` (0x15c0), so all of
  libsec-ril runs as uid 1001 with the rc's gids. `ro.debuggable=1` adds `PR_SET_DUMPABLE`.
- libril accepts a client on `rild` only if `getpwuid(SO_PEERCRED.uid)->pw_name` is `"radio"`
  (`"bluetooth"` for SAP) (strings libril 0x10e88, 0x13bab, 0x13bd0; `getpwuid` at 0x6e70).
  Bionic resolves 1001 → "radio" from its built-in table **[I]**.
- `Multiclient` accept (`OemClientReceiver::Accept` 0xe5204): `SO_PEERCRED`, then reads
  `/proc/<pid>/cmdline` and compares `argv[0]` with the `allowedProcess` table (VA 0x28f044, 30
  entries of `{u32 appId, u32 -1, char* name}`). The peer's `multiuser_get_app_id(uid)` must equal
  `appId` unless `appId == -1`. Entries include `1041 /system/bin/audioserver`,
  `1000 /system/bin/smdexe`, `1021 /system/bin/gpsd`, `1001 /system/bin/at_distributor`,
  `1001 com.sec.phone`, `1000 system_server`, `1002 com.android.bluetooth`, and `-1` for
  `com.expway.embmsserver` and `com.jio.emiddleware`.
- `CheckRfsDirectory` `chown`s CP directories to 1001:1000 (0x109fda) and
  `SimManager::GenerateKeyIvFile` `chown`s key files to 1001 (needs CAP_CHOWN).

### 2.5 Process-lifecycle behaviour that a non-Android supervisor must reproduce [P]

| Event | Behaviour | Address |
|---|---|---|
| RIL client closes its socket or a read error | libril logs "RIL Restart for Phone Died.", clears `gsm.sim.operator.numeric`, calls the vendor `onCancel` slot, then **`exit(0)`** | libril 0x4c36–0x4cc2 |
| libril event loop fails | `kill(0, SIGKILL)` (whole process group) | libril 0x4578–0x457c |
| CP crash seen (`IOCTL_MODEM_STATUS` ≠ ONLINE on the IPC fd) | `DevIoctlIoChannel::Read` notifies registrant 0x54 → `MiscManager::OnModemStateChanged` → `SecRil::ResetModem` → `ModemBoot::SilentReset` → **`DoModemSilentReset()` = `exit(0)`** | 0xe20f2, 0x14e324, 0x1017ac, 0x1bf9e8 |
| NV restore impossible ("Can't access to NV 2. reset") | `exit(0)` | 0x108c54 |
| rild exits | init restarts `ril-daemon` and, through `onrestart`, `cpboot-daemon` (CP reboot) | `init.rilchip.rc:14` |
| `persist.sys.cpboot=disable` | init stops both daemons | `init.rilchip.rc:25-27`, `init.baseband.rc:30-31` |
| `ril.cbd.modechan=0/2` | init restarts `ril-daemon` (ITP mode) | `init.universal5433.rc:641-645` |

## 3. Q2: Android properties

### 3.1 rild, libril and the client libraries [P]

- **rild main**: reads `rild.libpath`, `rild.libpath2`, `rild.libargs`, `ro.debuggable`,
  `ro.multisim.simslotcount`, `init.svc.ril-daemon1`; writes `ctl.stop`/`ctl.start` =
  `ril-daemon1` (only when multi-SIM). It also reads `/proc/cmdline` for `android.qemud=` and
  `android.ril=` (emulator paths). `-l <lib>` overrides `rild.libpath`, and `-c N` selects socket
  suffix N (0x1154–0x17a0).
- **libril**: writes `gsm.version.ril-impl` (from `getVersion`, else "unavailable") and clears
  `gsm.sim.operator.numeric` on exit; reads `ro.debuggable`.
- **libsecril-client**: `ro.csc.sales_code`. **libaudio-ril**: `persist.radio.multisim.config`
  (`dsds`/`dsda`/`tsts`).

### 3.2 `ril.cbd.rfs_check_done` and the NV validity check [P]

- **Writer**: `Modem::Init(ModemProxy*, ModemConfig*)` (0x10d00c). When the modem config has an RFS
  interface it creates the RFS `IoChannel`, `new Nv(this)`, then `Nv::Init(NvConfig*)` (0x10d0f0).
  If that returns 0 it calls `WriteProperty("ril.cbd.rfs_check_done", "1")` (0x10d0fe). The RFS
  channel is set up whatever the result. This runs inside `ModemFactory::Init()` from
  `SecRil::Init()`, i.e. **before** `WaitForOnline()`. libsec-ril never reads the property back.
  `ril.cbd.boot_done` does not appear in any RIL binary. The reader is cbd (`CBD_RE.md` §6 step 1–2:
  50 × 100 ms wait, then it continues with "TIMEOUT").
- **NV configuration** (`ModemFactory::LoadModemConfiguration` 0x101c38–0x101c7a,
  `ModemConfig::Init` 0x101518): iftype 3 (`DevIoctlIoChannel`), ifname `/dev/umts_ipc0`, proto 1,
  protover 2 (IPC 4.1), dbg `IPCDEBUG_UNIX_SOCKET`, rfsIfName `/dev/umts_rfs0`, nvHeader `nv`,
  modemDev `/dev/mbin0`, nvSize 0x100000, nvDir `/efs`, nvOffset 0xa00000. `Nv::InitNvOffset`
  (0x106c0c) then reads the first 0x1000 bytes (TOC) of `/dev/mbin0` and replaces offset and size
  with the TOC row named `NV` (it also looks for `OFFSET` and `logelfs.zip`).
- **Paths** built by `Nv::Init` (0x106580). `Nv::CheckEfsMountMode` (0x106878) parses
  `/proc/mounts`: mountpoint `/efs*` rw → 2, ro → 1; `/fac*` rw → 4, ro → 3; none → 0. In modes
  0/1/2 everything is under `nvDir` = `/efs`:
  `/efs/nv_data.bin`, `/efs/nv_data.bin.md5`, `/efs/.nv_data.bak`, `/efs/.nv_data.bak.md5`,
  `/efs/.nv_core.bak` (+`.md5`; `/cpefs/` if a "secure EFS" is mounted), `/efs/.nv_state`,
  `/efs/nv.log`. Modes 3/4 move the primary or backup to `/factory` and `/data/radio` (not used on
  this device **[I]**).
- **What Nv::Init checks**, in order:
  1. `LoadNvChecksumState` (0x106f04): `chmod 0700` on the state and md5 files, reads `%2d` from
     `.nv_state` (MD5 checking on/off; state 2 → `BackupNvData`).
  2. If the modem type ≠ 2 (CDMA), `CheckNvDataChecksum` (0x107170) → `CheckNvDataCheck(0)`
     (0x109648): opens `nv_data.bin` read-only, `ReadHeader` at **file offset 0x80000** (write count,
     item count, data size), `CalChecksum` (16-bit sum), `CompareCheckSum` against the stored word.
     If that fails it tries `.nv_data.bak` and restores it by copy (`RestoreNvDataFromBackup`). Both
     bad → return −1 → **property not set**.
  3. `CheckNvDataValidity` (0x1072e0): `IsNvDataSizeValid` (`stat` size ≥ TOC NV size) and
     `GetChecksumValidityWith(0)`: `ComputeChecksum` (0x10887c) = **MD5 over the whole file
     followed by the 19-byte string `Samsung_Android_RIL`**, as 32 lowercase hex, compared with
     `%32s` read from `nv_data.bin.md5`. MD5 disabled by state → valid. Mismatch, missing md5 or
     compute error → "Nv data tainted! Restoring..." → `RestoreNvData()` (0x108b6c).
  4. `RestoreNvData`: back up from `.nv_data.bak`, else `.nv_core.bak`, else
     **`CreateDefaultNvData`** (0x109170): `open(nv_data.bin, O_RDWR|O_CREAT|O_TRUNC|O_SYNC, 0700)`,
     fill with 0xff, copy the default NV from `/dev/mbin0` at the TOC `NV` offset, `fsync`, then
     `UpdateChecksumFile` (writes `nv_data.bin.md5`, mode 0700).
- So "RFS check done" means "the AP-side NV file is present, its size and internal checksum are
  valid and its MD5(+secret) matches, possibly after restore or regeneration". It is the same
  scheme as libsamsung-ipc's `ipc_nv_data_check` (same secret). **Operational risk [I]**: running
  libsec-ril against an `/efs` whose md5 or backup files are missing makes it rewrite
  `nv_data.bin`, possibly from RADIO defaults (calibration and NV identity lost). Run it first
  against a copy, and keep the original EFS image.

### 3.3 Properties used by libsec-ril [P] (240 literal keys resolved at the call sites of the property wrappers and of `property_get`/`set`)

R = read, W = written. Built names: `net.%s.dns%d`, `ril.pco.%s`, `ril.pcscfv4|6.%s%d.N`,
`ril.ecclist_net%d`, `ril.clatd.v4-%s`.

- **ro.\***: `ro.board.platform` R, `ro.boot.cp_debug_level` R, `ro.build.PDA` R,
  `ro.build.characteristics` R, `ro.build.date.utc` R, `ro.build.fingerprint` R, `ro.build.id` R,
  `ro.build.type` R, `ro.build.version.release` R, `ro.cdma.home.operator.numeric` R,
  `ro.csc.country_code` R, `ro.csc.countryiso_code` R, `ro.csc.omcnw_code` R, `ro.csc.sales_code` R,
  `ro.debug_level` R (default "0x494d"), `ro.debuggable` R, `ro.factory.factory_binary` R,
  `ro.multisim.simslotcount` R, `ro.product.device` R, `ro.product.model` R, `ro.product.name` R,
  `ro.radio.noril` R, `ro.ril.PESN` W, `ro.ril.svdo` R, `ro.ril.svlte1x` R,
  `ro.telephony.default_network` R, `ro.use_data_netmgrd` R.
- **persist.\***: `persist.ims.gcfmode` R, `persist.log.seclevel` R,
  `persist.radio.dataprefer.slotId` R, `persist.radio.enable.stubDebug` R,
  `persist.radio.forced_succ_ack` W, `persist.radio.initphone-type` R, `persist.radio.ipclog` R,
  `persist.radio.last.phonetype` R, `persist.radio.latest-modeltype` RW,
  `persist.radio.model_type` R, `persist.radio.multisim.config` R,
  `persist.radio.multisim.stackid` R, `persist.radio.ondemand` RW,
  `persist.radio.override_pse911` R, `persist.radio.override_psvoice` R,
  `persist.radio.pcovalue` R, `persist.radio.plmnname` W, `persist.radio.roaming_iptype` R,
  `persist.radio.rplmn` R, `persist.radio.setnwkmode` R, `persist.radio.silent-reset` RW,
  `persist.radio.snapshot_enabled` R, `persist.radio.snapshot_timer` R,
  `persist.radio.ss.fallback` R, `persist.radio.ss.policy` R, `persist.radio.ss.voiceclass_2` RW,
  `persist.radio.tdscdma_present` R, `persist.radio.ussd.policy` R, `persist.ril.ims.*` (6 keys) RW,
  `persist.ril.interfaceconf.failed` W, `persist.ril.modem.board` W, `persist.sys.e911` R,
  `persist.sys.e911.gcf` R, `persist.sys.members.logging` RW, `persist.sys.omcnw_path` R,
  `persist.sys.softsim.status` R, `persist.sys.ut` R.
- **gsm.\***: `gsm.STK_SETUP_MENU`, `gsm.STK_SETUP_MENU2`, `gsm.UTK_SETUP_MENU` RW,
  `gsm.current.phone-type` R, `gsm.default.channel` W, `gsm.operator.alpha|isroaming|numeric` R,
  `gsm.sim.acc` R, `gsm.sim.cdmaoperator.numeric` RW, `gsm.sim.gsmoperator.numeric` W,
  `gsm.sim.imsRegiEvent` R, `gsm.sim.operator.alpha` R, `gsm.sim.operator.gid` RW,
  `gsm.sim.operator.numeric` RW, `gsm.sim.sixmode` R, `gsm.sim.sixmode.slave` W, `gsm.sim.state` R,
  `gsm.sim.temp.operator.numeric` W, `gsm.sim.unkownready` W.
- **ril.\*** (134 keys, mostly RIL-private state): `ril.cbd.rfs_check_done` W, `ril.RildInit` RW,
  `ril.rildreset` RW, `ril.modemstate` W, `ril.radiostate` W, `ril.deviceOffRes` RW,
  `ril.restart.netmgrd` W, `ril.debug_modemfactory` W, `ril.ICC_TYPE`, `ril.IsCSIM`, `ril.simtype`,
  `ril.Simpower`, `ril.Simreset`, `ril.pin_mode`, `ril.initPB` (SIM state); `ril.sw_ver`/`hw_ver`/
  `model_id`/`product_code`/`serialnumber`/`barcode`/`manufacturedate`/`rfcal_date` (W, filled from
  CP data, identity-bearing); `ril.currentplmn`, `ril.lteband`, `ril.ltenetworktype`,
  `ril.signal.param`, `ril.voice.rat`, `ril.timezoneID`, `ril.sib16.last.*` (network);
  `ril.data.intfprefix`, `ril.dds.*`, `ril.epdg.*`, `ril.ims.*`, `ril.volte.911call` (data/IMS);
  plus about 90 more of the same kind (the full list is in the scratch file `props_by_key.txt`).
- **Others**: `sys.default.data.phoneid` R, `sys.deviceOffReq` R, `sys.ims.is_volte_active` R,
  `sys.powerctl` W, `vold.decrypt` R, `net.temp.mtu` R, `net.tether.always` W,
  `telephony.lteOnCdmaDevice` R, `radio.sim.acc` RW, `dev.silentlog.on` R.

Behaviour-relevant reads [P]: `ro.radio.noril` ("yes" → `OnRadioPowerUp` skips init, 0x10fc94),
`sys.deviceOffReq` (=1 → no wakeboot, no silent reset), `ro.build.type` + `ro.factory.factory_binary`
(factory/user mode), `vold.decrypt` (`trigger_restart_min_framework` → CP-config path),
`ro.use_data_netmgrd`, `persist.radio.silent-reset`. Many W keys are read back later
(`ril.RildInit`, `ril.ICC_TYPE`, `ril.Simreset`, `persist.radio.silent-reset`, …), so a property
store that **accepts writes** is needed for faithful behaviour **[I]**.

CSC and floating features (not properties, but configuration): `CscFeature_RIL_ConfigGlobalModuleType`,
`CscFeature_RIL_ConfigRilVersion`, `CscFeature_RIL_SupportImsService`, `CscFeature_RIL_SupportEpdg`,
`CscFeature_RIL_SupportAllRat`, `CscFeature_Common_AutoConfigurationType`, and others, all read
through libsecnativefeature. **The RIL version reported to libril is
`CscFeature_RIL_ConfigRilVersion`, or 8 if that feature is ≤ 0** (`RIL_Init` 0xe35ee–0xe360a
overwrites the static 12) **[P]**. Where libsecnativefeature reads its XML (`/system/csc/…`) is **[I]**.

## 4. Q3: files and devices

All [P] (call sites in libsec-ril unless noted). "Need" = must exist for basic voice/SMS/data on a
non-Android system **[I]**.

| Path | Use (flags) | Need |
|---|---|---|
| `/dev/umts_ipc0` | FMT channel, `open(O_RDWR)`, 50 × 500 ms retries (`IoChannel::Open` 0xe1d88); `IOCTL_MODEM_STATUS` before each read (`DevIoctlIoChannel::Read` 0xe20dc); `IOCTL_MODEM_FORCE_CRASH_EXIT` 0x6f34 in `DoModemCrash` | **yes** |
| `/dev/umts_rfs0` | RFS channel, same open; read and write | **yes** |
| `/dev/umts_boot0` | `open(O_RDWR)` + `IOCTL_MODEM_STATUS` polling only (`WaitForOnline` 0x1bf814); never written | **yes** |
| `/dev/mbin0` | read-only: 4 KiB TOC (`InitNvOffset`), default NV (`CreateDefaultNvData`) | yes (fallback config otherwise) |
| `/efs/nv_data.bin` | `O_RDWR\|O_SYNC` (0x101002) per NV request (`OpenNVFile` 0x109bc8, 10 × 300 ms); created 0700 if needed | **yes** |
| `/efs/nv_data.bin.md5`, `/efs/.nv_data.bak(.md5)`, `/efs/.nv_core.bak(.md5)`, `/efs/.nv_state`, `/efs/nv.log` | NV integrity, backup, state, log (RW) | yes |
| `/efs/root/**` | CP files through RFS (RW, `mkdir -p` 0775, `chown 1001:1000`) | yes (CP-driven) |
| `/efs/imei/mps_code.dat` (w+), `/efs/imei/omcnw_code.dat`, `/efs/imei/replace_code.dat`, `/efs/imei/` (mkdir 0755), `/efs/factory.prop` (O_RDWR\|O_CREAT), `/efs/FactoryApp/factorymode`, `/efs/sec_efs/block_ipv6`, `/efs/cpk/redata.bin`, `/efs/redata.bin`, `/efs/cert.cp`, `/efs/hdcp13.bin` | IMEI preconfig, sales code, factory mode | partly (missing → defaults **[I]**) |
| `/proc/mounts` | EFS mount mode | yes |
| `/proc/<pid>/cmdline` | Multiclient peer check | yes (audio) |
| `/data/misc/radio/` (stock `init.rc:539`: 0775 system radio) | key and IV files `dakl`, `mgzc` (0x101042, chmod 0640, chown 1001), encrypted SIM caches (`cicd`, `kmem`, …), `.data_usage_*`, `.ipv6_*`, `mccbanddb`, `rel11nw`, `ctc4g` | yes (writable) |
| `data/misc/radio/fingerprint`, `data/misc/radio/ramdumpmode.txt`, `data/system/users/0/settings_global.xml`, `…/settings_system.xml`, `sdcard/SDET_PLMN/input/MNCMCC.txt` | **relative paths**, so they resolve against the CWD | CWD must be `/` |
| `/data/user_de/0/com.android.providers.telephony/databases/telephony.db`, `nwk_info.db`, `opname*.db`, `shared_prefs/…preferred-apn.xml`; `/data/user_de/0/com.android.phone/shared_prefs/fdormancy…xml`; `/data/user_de/0/com.sec.epdg/databases/*.db` | APN, sub-id, fast-dormancy and ePDG settings (sqlite/xml, read) | optional (absence → defaults **[I]**) |
| `/system/etc/Audio_OEM*`, `Audio_IFX*`, `CP_AUDIO_SLSI*`, `RF_NVM*` | served to the CP through RFS (read) | yes if the CP asks **[I]** |
| `/system/etc/plmn_delta*.bin` (`wb` in `PlmnProtobufWrapper::FlushDelta`), `/system/etc/plmn_se13.bin`, `/system/omc/SW_Configuration.xml`, `/system/csc/sales_code.dat`, `%s/customer.xml`, `%s/cp.xml` | network-name DBs, CSC/OMC | optional |
| `/sys/devices/virtual/misc/multipdp/waketime` | `w`, fast dormancy wake time | optional |
| `/sys/class/sec/slot_switch/slot_sel` (r), `/sys/class/sec/sec_key/hall_irq_ctrl` (w), `/sys/class/lcd/panel/mipi_switch` (w), `/sys/block/mmcblk0/device/{cid,name}` (r) | misc, factory | no |
| `/dev/tun` (O_RDWR, `TUNSETIFF`) | ePDG (Wi-Fi calling) only | no |
| `/dev/alarm` | elapsed time; fallback exists | no |
| `/dev/knox_kap`, `/dev/block/param` | warranty bit, factory | no |
| `/dev/esoc-0`, `/dev/modem_br`, `/dev/qmi_dump`, `/dev/smd0`, `/dev/ramdump_memshare`, `/sys/module/rmnet_usb/…`, `/sys/module/mhi/…`, `/tombstones/mdm/mdm_err.log` | Qualcomm or other-modem paths | no |
| `/data/log/**`, `/sdcard/log/**`, `/proc/kmsg`, `/proc/uptime` | debug logs, CP crash logs, tcpdump (libpcap is linked in) | no |
| `/dev/socket/*` | none opened by libsec-ril; libril only uses inherited fds | see §7 |

## 5. Q4: RFS service specification (`/dev/umts_rfs0`, SIPC ch 245)

### 5.1 Transport and framing [P]

- `IpcModem::Start` (0x1bfd30) opens the IPC, debug and RFS channels and adds them to one
  `IoChannelReader` select loop. RFS reads go to `IpcModem::ProcessRfsMessageReceived` (0x1c0110) →
  `Nv::ProcessRfsPacket(buf, len)` (0x10a128).
- Frame header (offsets within the payload the kernel delivers, without the SIPC5 link header):
  `+0 u32 length` (whole frame, header included, little-endian), `+4 u8 cmd`, `+5 u8 id`;
  parameters start at `+6` and are unaligned (`ldr.w` from odd offsets in every handler).
  This is byte-identical to libsamsung-ipc's `struct ipc_rfs_header {u32 length; u8 index; u8 id;}`
  (`include/protocol.h:87-91`; `ipc_rfs_header_setup` sets `length = size + 6`).
- **Reassembly**: on the first chunk `ProcessRfsPacket` takes `length` from `+0`. If it exceeds
  0x80000 it logs "too big RFS frame" and drops the frame. It allocates `length` bytes and appends
  further `read()` chunks until `length` bytes are in ("full RFS frame received (%d packets / %d
  bytes)"), then calls `ProcessRfsMessage()`. The wake lock `ril-rfs` is held meanwhile.
- **Dispatch** (`Nv::ProcessRfsMessage` 0x10a328): `cmd = buf[4]`; `tbb` table at 0x10a370
  (cmd − 1, 23 entries). Each handler re-checks its own cmd byte.
- **Replies** go out as one `write()` on the RFS fd (`Nv::SendRfsMessage` → `Modem::SendRfsMessage`
  → `IoChannel::Write` 0xe1f78, retrying on EINTR/EAGAIN with 10 ms sleeps). They carry the same 6-byte header with
  `length` = total, `cmd` = request cmd and **`id` = the request's id echoed**.
- Unhandled cmds (0x0d, 0x0e, 0x0f, 0x10, 0x12) return −1 and **send no reply**.

### 5.2 Command table [P]

Names come from the `IpcProtocol41` RFS sub-name pointer array at VA 0x285330, indexed by
`cmd − 1` and used by `GetSubCommandName` at 0x1e4e62. Handlers come from the dispatch table, with
veneers resolved through `.rel.plt`. "ret/errno" replies are 14 bytes:
`hdr(6) | i32 ret @6 | u32 errno @0xa` (errno 0 on success).

| cmd | Name | Handler | Request (after the 6-byte header) | Reply |
|---|---|---|---|---|
| 0x01 | RFS_NV_READ_ITEM | `Nv::ProcessNVRead` 0x10a910 | `u32 offset @6, u32 size @0xa` (≤ 0x80000) | 15 + n: `u8 confirm(1=ok) @6, u32 offset @7, u32 n @0xb, data @0xf` |
| 0x02 | RFS_NV_WRITE_ITEM | `Nv::ProcessNvWrite` 0x10a568 (or `ProcessNvBuffering` 0x10a48c in buffer mode) | `u32 offset @6, u32 size @0xa, data @0xe` | 15: `confirm @6, offset @7, written @0xb` |
| 0x03 | RFS_READ_FILE | `ProcessReadFile` 0x10bbc8 | `i32 fd @6, u32 size @0xa` (≤ 0x80000) | 14 + n: `u32 n @6 (0 on error/EOF), u32 errno @0xa (set when n < 1), data @0xe`; the copied payload and the `n` field are clamped to 0x40000 while `length` uses the unclamped n (0x10bcd4–0x10bd22) |
| 0x04 | RFS_WRITE_FILE | `ProcessWriteFile` 0x10ad00 | `i32 fd @6, u32 size @0xa, data @0xe` | ret = bytes written / −1, errno |
| 0x05 | RFS_LSEEK_FILE | `ProcessLseekFile` 0x10b604 | `i32 fd @6, i32 offset @0xa, u32 whence @0xe` | 18: `u32 0 @6, i32 result @0xa, u32 errno @0xe` |
| 0x06 | RFS_CLOSE_FILE | `ProcessCloseFile` 0x10ae94 | `i32 fd @6` | ret/errno |
| 0x07 | RFS_PUT_FILE | `ProcessPutFile` 0x10b764 | `u32 flags @6, u32 pathlen @0xa, path @0xe (0x400 field), u32 len @0x40e, data @0x412` | 18: `0 @6, i32 written/−1 @0xa, errno @0xe` |
| 0x08 | RFS_GET_FILE | `ProcessGetFile` 0x10b9bc | `u32 pathlen @6, path @0xa (0x400 field), u32 size @0x40a` | 14 + n: `u32 n @6, errno @0xa, data @0xe` |
| 0x09 | RFS_RENAME_FILE | `ProcessRenameFile` 0x10bd7c | `u32 oldlen @6, old @0xa (0x400 field), u32 newlen @0x40a, new @0x40e` | ret/errno |
| 0x0a | RFS_GET_FILE_INFO | `ProcessGetFileInfo` 0x10c148 | `u32 pathlen @6, path @0xa` | 32 bytes, see below |
| 0x0b | RFS_UNLINK_FILE | `ProcessDeleteFile` 0x10b46c | `u32 pathlen @6, path @0xa` | ret/errno |
| 0x0c | RFS_MAKE_DIR | `ProcessMakeDirectory` 0x10ab64 | `u32 pathlen @6, path @0xa` | ret/errno |
| 0x0d–0x10 | REMOVE_DIR, OPEN_DIR, READ_DIR, CLOSE_DIR | — | — | **none** |
| 0x11 | RFS_OPEN_FILE | `ProcessOpenFile` 0x10afec | `u32 flags @6, u32 pathlen @0xa, path @0xe` (≤ 0x400) | `i32 fd @6, errno @0xa` |
| 0x12 | RFS_FTRUNCATE_FILE | — | — | **none** |
| 0x13 | RFS_GET_HANDLE_INFO | `ProcessGetFileInfoByHandle` 0x10bf24 | `i32 fd @6` | 32 bytes (`fstat`) |
| 0x14 | RFS_CREATE_FILE | `ProcessCreateFile` 0x10b304 | `u32 pathlen @6, path @0xa` | `creat(path, 0775)` → fd/errno |
| 0x15 | RFS_NV_WRITE_ALL_ITEM | `ProcessNVWriteAll` 0x10c378 | `u32 offset @6, u32 size @0xa, data @0xe` | 13: `confirm @6, u32 offset @7, u16 written @0xb` |
| 0x16 | RFS_NV_BUFFER_MESSAGE | `ProcessNVBufferStartEnd` 0x10c774 | `u8 mode @6 (1 = start, 0 = end), u32 offset @7, u32 size @0xb` | 13: `confirm @6, …` |
| 0x17 | RFS_NV_RESTORE | `ProcessNVRestore` 0x10cb80 | — | ret/errno (`RestoreNvData`) |

GET_FILE_INFO / GET_HANDLE_INFO reply (32 bytes, 0x10c238–0x10c2e6): `i32 ret @6`, `u16 type @0xa`
(1 = directory, 2 = other), `u32 size @0xc` (low 32 bits of `st_size`), 6 bytes of `st_ctime`
broken down `@0x10` (year − 2000 as `tm_year + 0x9c` truncated to 8 bits, month 1–12, mday, hour,
min, sec), 6 bytes of `st_mtime` `@0x16`, `u32 errno @0x1c`. Times are `localtime_r`, so they depend
on the AP time zone.

### 5.3 Path handling (`Nv::MakeRfsDirectoryName` 0x109c54) [P]

1. The path is copied (≤ 0x414 bytes) and split on `/`. **Any component equal to `..` → "wrong
   path"**, NULL is returned and the reply carries fd/ret −1.
2. Starts with `err` or `/data/log` → `"/data/log/" + path`.
3. Starts with `Audio_OEM`, `Audio_IFX`, `CP_AUDIO_SLSI` or `RF_NVM` → `"/system/etc/" + path`.
4. Anything else → `"/efs/root/" + path` (`"%s/%s/%s"` with `nvDir`, `"root"`, path).

The containing directory is created by `CheckRfsDirectory(dir, 0775)` (0x109e3c): `mkdir` per
component, `chmod 0775` under err/`/data/log`, then `chown(dir, 1001, 1000)`.
`ProcessOpenFile`/`PutFile` call `open(path, cp_flags | O_SYNC(0x101000), 0775)`. The CP's flags are
passed through unchanged, as ARM Linux `O_*` values **[I]** that this is the CP's convention. Paths
containing `err` or `/data/log` are `chmod 0775`. `ProcessGetFile` opens read-only. After every
successful open `Nv::SetIoBoost` tries `FS_IOC_GETFLAGS`/`FS_IOC_SETFLAGS` (Samsung "IO boost"
flag). Failure is only logged, and the call is skipped for `/system/etc`.

### 5.4 NV semantics and what persists to /efs [P]

- NV read and write use `lseek(offset)` + `read`/`write` on `/efs/nv_data.bin` (opened
  `O_RDWR|O_SYNC` per request, then `fsync`, `close`), sizes clamped to 0x80000.
- Before each **NV_WRITE_ITEM** and **NV_WRITE_ALL** the MD5 is re-checked; if "tainted",
  `RestoreNvData()` runs first. After the write, **`UpdateChecksumFile(nv_data.bin)` rewrites
  `nv_data.bin.md5`** (0x10a796), under a mutex at `Nv+0x1bc`.
- Writes at offset **0x180014** (logged as "Write IMEI Number…") or **0x181469** ("Write Network lock
  info…") trigger `BackupNvData()` (0x10a7b0–0x10a808), which refreshes `.nv_data.bak` and the core
  backup. These offsets imply an NV file larger than 1.5 MiB; libsamsung-ipc assumes 0x200000. This
  conflicts with the 0x100000 TOC size in `CBD_RE.md` §5 (open question §9).
- **NV_BUFFER_MESSAGE start** (mode 1): reads `[offset, offset+size)` of the file into a heap buffer
  and enters buffer mode (`Nv+0x1b0` = 1). NV_WRITE_ITEM is then applied to the buffer and answered
  at once. **End** (mode 0): one `lseek`/`write`/`fsync` of the buffer, free, then
  `UpdateChecksumFile`.
- The file verbs persist anything the CP chooses under `/efs/root/` (and `/data/log` for crash
  logs). Which files the SS333 CP actually creates is decided CP-side (§9).

### 5.5 Minimum RFS server for a native daemon [I]

Implement the 6-byte header with id echo and reassembly up to 0x80000; cmds 0x01, 0x02, 0x15, 0x16,
0x17 against a 0x200000 `nv_data.bin` with md5 maintenance; the file verbs 0x03–0x0c, 0x11, 0x13,
0x14 with the §5.3 path mapping rooted at `/efs/root` (or an equivalent directory); no reply for
0x0d–0x10 and 0x12. Log every request for the first runs. libsamsung-ipc covers only 0x01 and 0x02
(as 0x4201/0x4202).

## 6. Q5: session start and interaction with cbd / umts_boot0

### 6.1 Order of events [P]

1. `rild main` → `switchUser` → `dlopen` → `RIL_Init` (0xe346c). `RIL_Init` reads the RilIndex (`-c`),
   `ro.multisim.simslotcount` and CSC features, sets the interface prefix (`rmnet`), then calls
   `env->RequestTimedCallback(LazyRilInit, env, {0 s, 100 ms})` (0xe3630–0xe363a, callback from GOT
   `LazyRilInit`, delay at 0x26bcac) and returns `s_callbacks`. rild then calls `RIL_register`
   (sockets) and `RIL_register_socket` (SAP).
2. 100 ms later, **on libril's event-loop thread**, `LazyRilInit` → `SecRilProxy::Init` →
   `SecRil::Init` (0xe5e2c):
   `ModemFactory::WakeBootModem` (`ModemBoot::WakeBoot` only sets `mWakebootDone`) →
   `InitReqQueueList` → `ModemFactory::Init` (`LoadModemConfiguration`, `InitModemProxies` →
   `Modem::Init` → `Nv::Init` → **`ril.cbd.rfs_check_done=1`**) → `StartModelTypeChanger` →
   `RegisterDefaultHandlers` → `ReqRouter`/`EventScheduler`/`ReqDispatcher::Start` →
   `ModemFactory::BootModem`.
3. `BootModem` → `ModemBoot::Boot` → `DoModemBoot()` = **`WaitForOnline()`** (0x1bf814): up to 10
   rounds of {`open("/dev/umts_boot0", O_RDWR)`; up to 91 × `ioctl(0x6f27)` every 200 ms until it
   returns 4 (`STATE_ONLINE`); 3 = BOOTING is only logged}. Timeout → −110. It never writes to
   umts_boot0; cbd does the whole download.
4. `StartAllModems` → `IpcModem::Start`: opens `/dev/umts_ipc0`, then (debug), then
   `/dev/umts_rfs0`. Opening both FMT and RFS is what makes the kernel send `IOSM_A2C_INIT_END`
   (`SS333_LLI_BRINGUP.md` §2.4) **[P]** (kernel source).
5. `SecRilProxy::Init` then starts the `Multiclient` server, calls `SendModemCrashReason`
   (`/dev/esoc-0`, Qualcomm; fails harmlessly **[I]**) and writes `ril.RildInit=1`.
6. **Nothing is sent on the FMT channel on this path.** No IoChannel write occurs in the functions
   listed above **[P]**, though the whole call graph was not exhaustively checked **[I]**.
   `ReqDispatcher` is constructed with processing disabled (`strb 0, [this+0xc]` at 0xea17a), so
   client requests are queued.
7. CP → AP `PWR_PHONE_PWR_UP`: `IpcProtocol41::IpcRxPower` (0x1f6644) routes sub 1 → `IpcRxPwrUp`
   (0x1d726c), which requires `type == 3` (NOTI, byte 6 of the 7-byte FMT header) and builds
   `PowerInfo(2)`. `PowerManager::OnRadioPowerUp` (0x10fbbc) notifies the power state (RIL
   radio-state change), calls **`ReqRouter::EnableProcessing(true)`** ("Online booting, need to
   enable processing"), and unless `ro.radio.noril=yes` pushes internal request 0x3f3 and runs
   `ImeiManager::setCpConfigOnFirstBoot`/`setPreconfigOnFirstBoot` (CSC-dependent CP feature
   config). Sub 3 → `IpcRxPwrReset`, sub 7 → `IpcRxPwrState`.
8. After that the session is driven by RIL requests. Example on the wire: `IpcTxRadioPower`
   (0x1f64e8) sends 9 bytes `{len=9, mseq, aseq, main=0x01 PWR, sub=0x07 PHONE_STATE, type=0x01
   EXEC, data}`, with data `01 00` for state 1 and `02 02` for state 2. These are libsamsung-ipc's
   `PHONE_STATE_REQUEST_LPM` / `NORMAL` values.

### 6.2 Consequences [I]

- Because `LazyRilInit` blocks the libril event loop inside `WaitForOnline`, the `rild` socket is
  not serviced until the CP is online (up to about 3 min of retries). A client should tolerate a
  late `RIL_UNSOL_RIL_CONNECTED`.
- With a independent loader instead of cbd: start rild (or the native daemon) early enough for
  cbd-equivalent NV handling. The native loader need not wait for `rfs_check_done`; it can run the
  same MD5 check itself. It must make `IOCTL_MODEM_STATUS` reach 4. It must reboot the CP
  whenever rild exits (stock `onrestart`).
- Crash handling: the CP crash is noticed through `IOCTL_MODEM_STATUS` on the next IPC read
  (`misc_poll` returns POLLHUP in crash states). libsec-ril then exits, and cbd (or its replacement)
  does the dump and reboot. `DoModemCrash()` (0x1bf9fc: `open(umts_ipc0)` +
  `IOCTL_MODEM_FORCE_CRASH_EXIT`) is reached only from `MiscManager::DoForceCpCrash` (OEM request).

## 7. Q6: minimum environment for stock rild + libsec-ril on mainline 6.12

| # | Shim / requirement | Evidence | Status |
|---|---|---|---|
| 1 | Bionic userland at Android paths: `/system/bin/linker`, `/system/bin/rild`, `/system/lib/*` (closure of §2.1, incl. libsecnativefeature, libfloatingfeature, libxml2, libsqlite, libcrypto, libprotobuf-cpp-full, libnetutils, libhardware_legacy, libbinder, libutils, libcutils, liblog, libc++) | DT_NEEDED, `.interp` = `/system/bin/linker` | [P] list, [I] closure |
| 2 | Property area + `property_service` socket accepting `set` (seed rild.libpath, ro.radio.noril=no, ro.multisim.simslotcount=1, ro.build.type=user, ro.factory.factory_binary, ro.csc.sales_code, ro.product.*, ro.build.PDA, ro.debug_level, ro.telephony.default_network=9, persist.radio.multisim.config, …) | 240 keys, read-backs §3.3 | [P] need; [I] mechanism (Android 7 bionic maps `/dev/__properties__`, writes over `/dev/socket/property_service`, per `android_ril_reuse.md` Q1) |
| 3 | Launcher that creates `rild` and `rild-debug` (and optionally `sap_uim_socket1`) UNIX stream sockets, exports `ANDROID_SOCKET_<name>=<fd>`, starts rild as **root** with gid `radio` + groups (cache, inet, misc, audio, sdcard_r/rw, log, vpn, system, readproc), CWD `/`, in **its own process group** (`setsid`) | §2.3, §2.4, §2.5 | [P] |
| 4 | Supervisor reproducing Android lifecycle: restart rild on exit and **reboot the CP each time** (`onrestart restart cpboot-daemon`); keep the RIL client connected (EOS → exit) | §2.5 | [P] |
| 5 | Device nodes with radio access: `/dev/umts_ipc0`, `/dev/umts_rfs0`, `/dev/umts_boot0` (O_RDWR + ioctl 0x6f27/0x6f34; stock ueventd `0660 system radio`), `/dev/mbin0` → RADIO partition (readable by radio) | §4, `ueventd.universal5433.rc:119-122`, `init.baseband.rc:3` | [P] |
| 6 | `/efs` mounted RW, contents owned by uid 1001 (rild has no CAP_DAC_OVERRIDE) incl. `nv_data.bin` + md5 + backups; `/efs/root` creatable | §3.2, §5.3 | [P] need; [I] ownership |
| 7 | `/data/misc/radio` (0775 system:radio), `/data` tree writable; `/proc` (mounts, pid cmdline), `/sys` | §4 | [P] |
| 8 | Same network namespace as the host (rmnet0..3 netdevs, ioctls on them, `/proc/sys/net/ipv6/conf/*` writable, NETLINK_ROUTE; abstract `Multiclient` visible to audio clients) | §2.2 | [P] use, [I] netns choice |
| 9 | Kernel: modem_v1 port (§2 of the bring-up dossier), `CONFIG_PM_WAKELOCKS` for `/sys/power/wake_lock` (else wake locks fail, harmless **[I]**), Unix sockets, capabilities, `CLOCK_BOOTTIME`. **Not needed**: binder/binderfs, ashmem, `/dev/alarm`, `CONFIG_ANDROID_PARANOID_NETWORK`, SELinux | §2.2 | [P] (absence of use) |
| 10 | Logging sink: logd-compatible `/dev/socket/logdw`, or accept lost logs | liblog import | [I] |
| 11 | cbd (or replacement) running concurrently: performs the CP boot; optional `ril.cbd.rfs_check_done` handshake | §3.2, `CBD_RE.md` §6 | [P] |
| 12 | Optional: libsecnativefeature/floating-feature XMLs (CSC features change RIL version, IMS/EPDG configs, model type); telephony provider DBs/xml; `/system/etc` CP audio/RF files served via RFS | §3.3, §4 | [I] |

Not required [P]: `servicemanager`, binder, ashmem, SurfaceFlinger or other framework services,
netd, iptables. The Android framework itself is not required, but some features expect it (`am`
broadcasts are sent as unsolicited 11002 to the RIL client; SIM-lock and IMEI dialogs).

### 7.1 Route (a) vs (b) in one line each [I]

- **(a) Chroot**: feasible with items 1–11. Main risks: NV auto-restore or regeneration, the RIL
  version depending on CSC features (8 without them), libril exiting on client disconnect, and
  Samsung parcel extensions for the client (`android_ril_reuse.md` Q4).
- **(b) Native**: needs a cbd replacement plus FMT (IPC 4.1) and the RFS server of §5. The
  NV/MD5/backup logic of §3.2 must be re-implemented to keep `/efs` consistent with what a later
  stock firmware expects.

## 8. Verification hooks for the first live run (no tablet contact in this analysis)

- `strace -f -e trace=open,openat,ioctl,read,write -p <rild>` limited to `/dev/umts_rfs0` frames:
  check that cmd bytes and lengths match §5.2 and list the paths the SS333 CP actually uses.
- Run the first session against a **copy** of `/efs`, then diff the file list and sizes only
  (not contents).

## 9. Open questions

1. Which RFS verbs and files the SS333 CP actually uses at runtime (CP-side; check via §8).
2. NV file size: libsec-ril validates against the TOC `NV` row size and special-cases offsets
   0x180014/0x181469, while `CBD_RE.md` §5 reads the TOC NV size as 0x100000. Settle it with the
   size (only) of `/efs/nv_data.bin` or a re-check of the TOC.
3. Exact semantics of `.nv_state` values (only 2 → "MD5 S:2" was traced) and of the 0x80000 NV
   header checksum algorithm (`CalChecksum` 0x1093a8, not transcribed).
4. Which XML and CSC files libsecnativefeature/libfloatingfeature read, and their values on this
   firmware (decides the RIL version and the IMS/EPDG configs). Libraries not inspected.
5. Behaviour of Android 7 liblog, libcutils properties and libhardware_legacy without their
   services (inferred from AOSP, not from the device's libraries).
6. Internal request 0x3f3 pushed on PWR_UP and the exact first FMT TX after PWR_UP (needs a trace
   or deeper call-graph work through the request tables).
7. The `RIL_Init` → `LazyRilInit` blocking of the libril event loop: confirm on a live run that the
   `rild` socket stays silent until the CP is online.
