# Samsung AP-CP IPC protocol and free implementations, as they apply to the Shannon SS333 (SM-T715)

Scope note. "Shannon" below means Samsung's own basebands (SS333 on this tablet; Shannon 335 in the Galaxy S7
"herolte"; Exynos 5123/5300 in Pixel 6/7). "XMM" means the Intel/Infineon XMM6160/XMM6260/XMM6262 basebands of
2010-2013 Samsung phones (Nexus S, Galaxy S2/S3/Note 2, Galaxy Nexus), which the free stack was written for. Facts
are tagged **[confirmed]** (read in source or binary), **[likely]** (strong indirect evidence) or **[speculative]**.

Local evidence method (constraint-compliant). `libsec-ril.so` was never executed. Beyond `strings`, I did static,
read-only disassembly with `rizin` (`pdr`, `pxw`, `ps`, no emulation) of four name-lookup functions to recover the
numeric-index-to-name tables. Their vaddrs are `IpcProtocol41::GetMainCommandName(int)` @0x1e47f8,
`IpcProtocol41::GetSubCommandName(int,int)` @0x1e49bc, `IpcProtocol41::GetCmdTypeName(int)` @0x1e47d8,
`IpcProtocol40::GetMainCommandName` @0x1d1714 and `IpcProtocol40::GetSubCommandName` @0x1d1860. The
resolver follows the Thumb `ldr rX,[lit]; add rX,pc` string loads under each `tbb`/`tbh` switch case, and the
pointer arrays indexed by `sub_cmd-1`. Limits: a few cases per group were not resolved, mainly indexes 01/02 of the
inner switches. Groups PWR, SVC, SAT, CFG, IMEI, SAP, FACTORY, OMADM, RFS, IMS and EMBMS use a code shape the script
did not decode. Where a name comes from `strings` order rather than the switch, I say so. libsamsung-ipc and
samsung-ril were cloned as source from git.replicant.us into a scratch directory, and only read.

---

## Q1. libsamsung-ipc and samsung-ril: repository, history, devices, protocol definitions, RFS, maintenance; is the FMT header our `sipc_fmt_hdr`?

### Takeaway
libsamsung-ipc (GPL-2.0+, Replicant) is a small C library. It holds the FMT/RFS framing helpers, the XMM-era message
catalogue (groups 0x01-0x12, RFS 0x42, GEN 0x80) and per-device transport/boot code. Its `ipc_fmt_header` is
byte-for-byte our `sipc_fmt_hdr`, and its xmm626 "kernel_smdk4412" transport uses exactly our device names and
`_IO('o',…)` ioctl numbers. One device file already targets a Shannon phone: herolte, the Galaxy S7, added 2020-09-29.
That file proves the userspace framing works on a modem_v1/SIPC5 kernel. But its boot path does not match the SS333's
DL_START+FW_UPDATE+write() path. Development is in maintenance mode: the last libsamsung-ipc commit is from
2023-09-20 and the last samsung-ril commit from 2024-10-08.

### Cited Findings
**Repository and history**
- Upstream git is `https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc.git`. Maintainer: Denis "GNUtoo"
  Carikli. Status: "Maintained". Mailing list: replicant@osuosl.org. **[confirmed]**
  — [MAINTAINERS](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/MAINTAINERS)
- History: 814 commits from 2011-01-17 (initial commit by Joerie de Gram) to 2023-09-20 (last commit, by Carikli). Top
  authors: Carikli 319, Simon Busch 190, Paul Kocialkowski 176+58 ("PaulK"), Joerie de Gram 34, Alexander Tarasikov 21.
  No commit since 2024-01-01 on master as of the clone (2026-10-29). Release tags are named `replicant-6.0-0004-*`.
  **[confirmed]** — [git log](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/log/)
- postmarketOS packages it as "libsamsung-ipc 6.0.0004" (pkg-config `samsung-ipc` 0.7.0, GPL-2.0-or-later) for
  armv7/aarch64/x86. **[confirmed]** — [pkgs.postmarketos.org](https://pkgs.postmarketos.org/package/master/postmarketos/armhf/libsamsung-ipc)
- A pmaports MR "upgrade and add runtime device overrides" exists, which helps with broken device detection.
  **[confirmed, title only]** — [pmaports MR 3456](https://gitlab.com/postmarketOS/pmaports/-/merge_requests/3456)
- An older GPLv3+ fork lived at github.com/morphis/libsamsung-ipc (Simon Busch). **[confirmed, from wiki snippet]**
  — [Replicant wiki Samsung-RIL](https://redmine.replicant.us/projects/replicant/wiki/Samsung-RIL?version=40)
- The Replicant redmine wiki is now behind an Anubis bot wall: my fetches of the Libsamsung-ipc, SamsungIpcDissector
  and SamsungGalaxyBackdoor pages returned "Access Denied". Only search snippets were usable.

**Devices and modems in the tree** (from `samsung-ipc/devices/*` and their includes) **[confirmed]** —
[devices/](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/devices)

| device dir | phone | modem module used |
|---|---|---|
| aries, crespo | Galaxy S / Tab P1000, Nexus S | `modems/xmm616` (XMM6160) |
| galaxys2, i9300, n5100, n7100 | GT-I9100, GT-I9300, Note 8.0, Note 2 | `xmm626` + `xmm626_hsic` + `xmm626_kernel_smdk4412` |
| maguro, piranha | Galaxy Nexus, Galaxy Tab 2 | `xmm626` + `xmm626_mipi` + `xmm626_kernel_smdk4412` |
| **herolte** | **Galaxy S7 (Exynos 8890, Shannon 335)** | `xmm626` + `xmm626_kernel_smdk4412` + `xmm626_modem_prj.h`; own boot code |

**Protocol definitions (`include/protocol.h`)** **[confirmed]** —
[protocol.h](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/include/protocol.h)
- Request types (`:31-35`): EXEC 0x01, GET 0x02, SET 0x03, CFRM 0x04, EVENT 0x05. Response types (`:38-40`): INDI 0x01,
  RESP 0x02, NOTI 0x03.
- Groups (`:46-64`): PWR 0x01, CALL 0x02, SMS 0x04, SEC 0x05, PB 0x06, DISP 0x07, NET 0x08, SND 0x09, MISC 0x0A,
  SVC 0x0B, SS 0x0C, GPRS 0x0D, SAT 0x0E, CFG 0x0F, IMEI 0x10, GPS 0x11, SAP 0x12, RFS 0x42, GEN 0x80. The library has
  no FACTORY group. `IPC_COMMAND(g,i) = (g<<8)|i`.
- `struct ipc_fmt_header { u16 length; u8 mseq; u8 aseq; u8 group; u8 index; u8 type; } __packed` (`:78`).
  `struct ipc_rfs_header { u32 length; u8 index; u8 id; } __packed` (`:87`).
- `length` includes the 7-byte header: `header->length = message->size + sizeof(struct ipc_fmt_header)`.
  — [ipc_utils.c:301](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/ipc_utils.c)
- Message indexes defined, 16-bit codes, all [confirmed] from `include/*.h`:
  - **PWR**: 0101 PHONE_PWR_UP, 0102 PHONE_PWR_OFF, 0103 PHONE_RESET, 0104 BATT_STATUS, 0105 BATT_TYPE, 0106 BATT_COMP,
    0107 PHONE_STATE.
  - **CALL**: 0201 OUTGOING … 020A LINE_ID (10 messages).
  - **SMS**: 0401 SEND_MSG … 0411 PARAM.
  - **SEC**: 0501 PIN_STATUS … 0509 IMS_AUTH.
  - **PB**: 0601-0605.
  - **DISP**: 0701 ICON_INFO, 0702 HOMEZONE_INFO, 0706 RSSI_INFO.
  - **NET**: 0801 PREF_PLMN … 080D PREFERRED_NETWORK_INFO.
  - **SND**: 0901 SPKR_VOLUME_CTRL, 0902 MIC_MUTE_CTRL, 0903 AUDIO_PATH_CTRL, 0904 AUDIO_SOURCE_CTRL, 0905 LOOPBACK_CTRL,
    0906 VOICE_RECORDING_CTRL, 0907 VIDEO_CALL_CTRL, 0908 RINGBACK_TONE_CTRL, 0909 CLOCK_CTRL, 090A WB_AMR_STATUS.
  - **MISC**: 0A01 ME_VERSION, 0A02 ME_IMSI, 0A03 ME_SN, 0A05 TIME_INFO, 0A0C DEBUG_LEVEL.
  - **SVC**: 0B01-0B09.
  - **SS**: 0C01-0C0A.
  - **GPRS**: 0D01 DEFINE_PDP_CONTEXT … 0D11 PORT_LIST, including 0D0F PIN_CTRL.
  - **SAT**: 0E01-0E0C.
  - **IMEI**: 1001-1002.
  - **RFS**: 4201 NV_READ_ITEM, 4202 NV_WRITE_ITEM.
  - **GEN**: 8001 PHONE_RES.
  - [include/](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/include)

**RFS handling** **[confirmed]**
- libsamsung-ipc implements only NV_READ_ITEM/NV_WRITE_ITEM as `{offset,length}` windows into `/efs/nv_data.bin`
  (size 0x200000, secret "Samsung_Android_RIL", plus md5 and backup paths). It has no generic file verbs.
  — [rfs.h:29-63](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/include/rfs.h),
  [xmm626.h:42-48](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/modems/xmm626/xmm626.h)
- RFS frames on `umts_rfs0` use the 6-byte `ipc_rfs_header`, not the FMT header.
  — [xmm626_kernel_smdk4412.c:340-424](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/modems/xmm626/xmm626_kernel_smdk4412.c)
- In 2014 Replicant reported that the proprietary RIL's RFS lets the modem do remote file I/O on phone storage. It
  judged NV read/write legitimate and the other RFS messages unjustified ("Samsung Galaxy back-door").
  — [Boing Boing 2014-03-13](https://boingboing.net/2014/03/13/samsung-galaxy-back-door-allow.html/amp),
  [Replicant wiki SamsungGalaxyBackdoor](https://redmine.replicant.us/projects/replicant/wiki/SamsungGalaxyBackdoor)
  (wiki not fetchable)

**xmm626 "kernel_smdk4412" transport = our kernel ABI** **[confirmed]**
- Device paths (`xmm626_kernel_smdk4412.h:23-34`): `/dev/umts_boot0`, `/dev/umts_boot1`, `/dev/umts_ipc0`,
  `/dev/umts_rfs0`, `/dev/link_pm`. GPRS ifaces `rmnet` ×3.
- ioctls (`xmm626_modem_prj.h:40-63`): MODEM_ON `_IO('o',0x19)`, OFF 0x20, RESET 0x21, BOOT_ON 0x22, BOOT_OFF 0x23,
  START 0x24, PROTOCOL_SUSPEND/RESUME 0x25/0x26, STATUS 0x27, DL_START 0x28, FW_UPDATE 0x29, NET_SUSPEND 0x30,
  `IOCTL_DPRAM_SEND_BOOT` 0x40.
  — [xmm626_modem_prj.h](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/modems/xmm626/xmm626_modem_prj.h)
- Our board has the same numbers: 0x6F19-0x6F29; 0x6F40 is `IOCTL_MODEM_XMIT_BOOT`, which returns NULL/-EINVAL on
  SS333. — `research/modem/SS333_LLI_BRINGUP.md:225-254`
- `fmt_send` writes `ipc_fmt_header` + data only, so the kernel adds the link framing. This is what our modem_v1
  `misc_write` expects: it builds the SIPC5 link header itself (`SS333_LLI_BRINGUP.md:286-292, 556-566`).
  — [xmm626_kernel_smdk4412.c:188-233](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/modems/xmm626/xmm626_kernel_smdk4412.c)

**herolte, the only Shannon device in libsamsung-ipc** **[confirmed]** —
[herolte.c](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/tree/samsung-ipc/devices/herolte/herolte.c),
[commit 56ff641](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/commit/?id=56ff64110d57570454a4a308419190cae74b133e)
- Author: Tony Garnock-Jones, 2020-09-29, rebased by GNUtoo. The commit message says it was possible to boot the modem
  and "probably possible" to exchange messages. Only an earlier version of the patch was tested on hardware.
- Boot sequence:
  1. Read the TOC from the RADIO partition (`/dev/disk/by-partlabel/RADIO` for pmOS, or the LineageOS by-name path).
  2. `IOCTL_MODEM_RESET`.
  3. `IOCTL_SECURITY_REQ = _IO('o',0x53)` with `{mode=2 (insecure), size_boot, size_main, 0}`.
  4. Upload BOOT, MAIN and NV in 62 KiB chunks ("just what cbd uses") through `IOCTL_DPRAM_SEND_BOOT` (0x6F40), using
     `{binary,size,m_offset,b_offset,mode,len}`.
  5. `IOCTL_SECURITY_REQ` again in secure mode (mode 0).
  6. Power on and boot_power on, then `IOCTL_MODEM_DL_START`.
  7. 4-byte handshake on umts_boot0: write 0x900d, expect 0xa00d; write 0x9f00, expect 0xaf00.
  8. boot_power off.
  - Source lines: `herolte.c:57-59, 133, 295, 313-359`.
- The code comment states the modem_v1 `rild_ready()` gate: FMT and RFS must both be open (`herolte.c:388-397`). That
  is the same gate as ours (`SS333_LLI_BRINGUP.md:284-285`).
- `gprs_activate` and `gprs_deactivate` are TODO placeholders (`herolte.c:524, 535`), so data was not implemented. The
  FMT and RFS ops reuse the xmm626_kernel_smdk4412 ones.

**samsung-ril (libsamsung-ril)** **[confirmed]** —
[repo](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ril)
- 228 commits, 2011-10-26 to 2024-10-08 (last commit: "scripts: guix.scm: switch from OpenSSL to LibreSSL").
- It moved to `hardware/replicant/libsamsung-ril` in 2020 ("Replicant is the upstream"). — [Replicant wiki](https://redmine.replicant.us/projects/replicant/wiki/Libsamsung-ril/43)
- RIL requests implemented (from `samsung-ril.c` dispatch):
  - **Calls**: DIAL, ANSWER, HANGUP, HANGUP_WAITING_OR_BACKGROUND, HANGUP_FOREGROUND_RESUME_BACKGROUND,
    GET_CURRENT_CALLS, LAST_CALL_FAIL_CAUSE, DTMF, DTMF_START, DTMF_STOP, SET_MUTE.
  - **SIM**: GET_SIM_STATUS, ENTER/CHANGE_SIM_PIN(2), ENTER_SIM_PUK(2), QUERY/SET_FACILITY_LOCK, SIM_IO.
  - **Identity and power**: GET_IMEI, GET_IMEISV, GET_IMSI, BASEBAND_VERSION, RADIO_POWER, SCREEN_STATE, OEM_HOOK_RAW.
  - **Network**: OPERATOR, SIGNAL_STRENGTH, VOICE/DATA/GPRS_REGISTRATION_STATE, QUERY_AVAILABLE_NETWORKS,
    QUERY_NETWORK_SELECTION_MODE, SET_NETWORK_SELECTION_AUTOMATIC/MANUAL, GET/SET_PREFERRED_NETWORK_TYPE.
  - **SMS**: SEND_SMS(_EXPECT_MORE), SMS_ACKNOWLEDGE, WRITE_SMS_TO_SIM, DELETE_SMS_ON_SIM.
  - **USSD**: SEND_USSD, CANCEL_USSD.
  - **Data**: SETUP_DATA_CALL, DEACTIVATE_DATA_CALL, DATA_CALL_LIST, LAST_DATA_CALL_FAIL_CAUSE.
- Unsolicited messages: RADIO_STATE_CHANGED, CALL_STATE_CHANGED, CALL_RING, NEW_SMS(+STATUS_REPORT),
  NETWORK_STATE_CHANGED, SIGNAL_STRENGTH, NITZ, ON_USSD, SIM_STATUS_CHANGED, DATA_CALL_LIST_CHANGED.
- Audio is not a RIL request. It goes through the SRS socket (`srs.c`: SRS_SND_SET_CALL_VOLUME, _AUDIO_PATH,
  _CLOCK_SYNC, SET_MIC_MUTE). `sound.c` sends SND_SPKR_VOLUME_CTRL SET (`:78`), SND_MIC_MUTE_CTRL SET (`:103`), SND_AUDIO_PATH_CTRL SET (`:154`) and
  SND_CLOCK_CTRL EXEC (`:175`).
  — [sound.c](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ril/tree/sound.c)

### Inferences
- **FMT header**: identical in size, field order and packing to `sipc_fmt_hdr {u16 len; u8 msg_seq, ack_seq,
  main_cmd, sub_cmd, cmd_type}`, which the bring-up doc reads at `modem_prj.h:165-172` (`SS333_LLI_BRINGUP.md:271-273`).
  **[confirmed]** Length semantics (header included) should also match. **[likely]** This needs checking against one
  captured frame: header length versus SIPC5 link length minus link header.
- **Transport**: herolte runs on a modem_v1 kernel with SIPC5 link framing. So libsamsung-ipc does not need any
  SIPC5-aware code: the kernel strips and adds the link header on `/dev/umts_ipc0`. **[likely]**, not proven on
  herolte hardware.
- **Boot**: herolte's boot path does not match ours. It uses `IOCTL_DPRAM_SEND_BOOT` (0x6F40, which is
  `XMIT_BOOT` = -EINVAL on SS333) and `IOCTL_SECURITY_REQ` 0x6F53, absent from our ioctl table. An SM-T715 device file
  would need its own boot function (our cbd replacement) and could reuse the xmm626_kernel_smdk4412 FMT, RFS, poll and
  read/write code unchanged. **[likely]**
- **RFS**: libsamsung-ipc's NV-window RFS model, and its absence of RFS file verbs, is the main functional gap for
  Shannon. Its handling is in Q7. **[likely]**

### Gaps
- Whether anyone ran herolte libsamsung-ipc end-to-end (calls, SMS) on hardware after 2020. postmarketOS wiki pages
  were behind Anubis; no report found.
- I did not open the full Replicant wiki device-status tables (Anubis).

---

## Q2. Shannon-era IPC versus XMM "IPC v4": SIPC5, new groups, dissectors and papers, SIT

### Takeaway
On Shannon the message layer is the same Samsung FMT protocol (7-byte header, group/index/type), extended. libsec-ril
carries two protocol classes, `IpcProtocol40` and `IpcProtocol41`. The SM-T715's own traffic matches IPC 4.1 index
assignments that do not exist in IPC 4.0. IPC 4.1 adds about 20 main groups (CDMA_DATA, FACTORY, OMADM, RFS_CMD 0x15,
IMS, EMBMS, DOMESTIC, PCSC, PROSE, MCPTT, JPN, QMIIMS, IIL…) and grows NET/GPRS/MISC/CALL with LTE, IMS and CA
messages. SIPC5 is a kernel link-layer change (the framing sits below the FMT header), not a message-layer change.
No public, maintained Wireshark dissector or paper documents Shannon AP-CP IPC payloads. Nothing found on "SIT".

### Cited Findings
- libsec-ril.so (SM-T715 stock 7.0) defines vtables `IpcProtocol` (base), `IpcProtocol40`, `IpcProtocol41` and
  `IpcProtocol41Iil`. It logs `"IpcProtocol40::%s is not implemented in IPC40"` and
  `"IpcModem::%s msg->mObj=%p, modem type=%d MainCmd=%d SubCmd=%d CmdType=%d"`. **[confirmed]**
  — `strings` on `dumps/lib/libsec-ril.so`
- IPC41 main-command table, recovered from `IpcProtocol41::GetMainCommandName` @0x1e47f8. **[confirmed]**
  - Groups shared with libsamsung-ipc: 0x01 PWR, 0x02 CALL, 0x04 SMS, 0x05 SEC, 0x06 PB, 0x07 DISP, 0x08 NET, 0x09 SND,
    0x0A MISC, 0x0B SVC, 0x0C SS, 0x0D GPRS, 0x0E SAT, 0x0F CFG, 0x10 IMEI, 0x11 GPS, 0x12 SAP.
  - Groups new in IPC41: 0x03 CDMA_DATA, 0x13 FACTORY, 0x14 OMADM, **0x15 RFS_CMD**, 0x16 IMS, 0x17 EMBMS,
    0x18 MMS_PROVISION, 0x1F MODEMTEST, 0x20 DOMESTIC, 0x21 PCSC, 0x22 QMI_HIDDENMENU, 0x23 SMARTAS, 0x24 PROSE,
    0x25 MCPTT, 0x26 OES, 0x30 JPN, 0x40 QMIIMS, 0x70 IIL (handled outside the switch), 0x80 GEN.
  - Everything else is `MAIN_CMD_UNDEFINED`.
- IPC40 main table (@0x1d1714): the same groups 0x01-0x17, 0x20 and 0x30. It lacks 0x18 and 0x1F-0x26, 0x40 and 0x70.
  **[confirmed]**
- Request types in IPC41 (`GetCmdTypeName` @0x1e47d8, a 5-entry pointer table): "EXEC", "GET", "SET", "CFRM", "EVENT",
  else "UNDEFINED". These are the same names as libsamsung-ipc's 0x01-0x05. **[confirmed]**
- IPC40 and IPC41 differ in sub-index assignment. **[confirmed]**
  - MISC: IPC40 maps 0x0A PDA_BOOT_COMPLETE, 0x0B FACTORY_RESET_COMPLETE, 0x0D SCREEN_STATUS. IPC41 maps 0x0A ALARM_INFO,
    0x0B PUBLIC_MODE, 0x0C RESERVED, 0x0D DEVICE_POSITION, 0x0E VTCALL_CONNECTION_STATUS, 0x0F SCREEN_STATUS,
    0x10 GRIP_SENSOR_STATUS.
  - NET: IPC40 maps 0x0F AVOID_SYS, 0x10 HANDOVER. IPC41 swaps them (0x0F HANDOVER, 0x10 AVOID_SYS) and adds 0x11
    CELL_INFO.
- Stock-Android frames on this tablet, reported by the project notes from `dumps/dmesg.txt` (I did not re-read it):
  - TX MISC/0x0F/EVENT ×7 and MISC/0x50/GET ×8.
  - TX and RX NET/0x11/GET+RESP ×10.
  - RX GPRS/0x19/NOTI ×8.
  - All these indexes resolve only in the IPC41 table (MISC_SCREEN_STATUS, MISC_MODEM_ACTIVITY_INFO, NET_CELL_INFO,
    GPRS_LTE_CA_STATUS), not in IPC40.
- Samsung-IPC Wireshark dissector: Denis Carikli (Replicant) asked wireshark-dev in Feb 2022 how to design it. The code
  was in a Replicant Wireshark fork, and there is no evidence of upstreaming. **[confirmed for 2022; status unknown]**
  — [wireshark-dev 2022-02](https://www.wireshark.org/lists/wireshark-dev/202202/msg00029.html),
  [seclists](https://seclists.org/wireshark/2022/Feb/28),
  [Replicant wiki SamsungIpcDissector](https://redmine.replicant.us/projects/replicant/wiki/SamsungIpcDissector)
  (Anubis-blocked; per the search snippet it shows annotated hex dumps of length/seq/group/index/type with names such as
  PWR_PHONE_PWR_UP).
- Shannon firmware emulation research (Hernandez & Muench, hardwear.io 2020, which became FirmWire) targets ShannonOS
  on ARMv7-R for over-the-air fuzzing. In what I found it does not document the AP-CP FMT message set.
  — [paper PDF](https://hernan.de/research/papers/hardwear-io-20-hernandez-muench-emulating-samsungs-baseband.pdf)
- BaseMirror (2024, arXiv 2409.00475) reverse-engineers baseband commands out of Android vendor RILs and reports 873
  baseband commands undisclosed to the public. I could not read the paper's Samsung-specific details: the fetch was
  refused by a tool safeguard. **[confirmed abstract-level only]** — [arXiv HTML](https://arxiv.org/html/2409.00475v1)
- Pixel 6/7 use Samsung Shannon/Exynos modems (g5123b = Exynos 5123; Exynos 5300 on Pixel 7). Project Zero reported
  critical Exynos modem bugs in March 2023. **[confirmed]**
  — [Notebookcheck](https://www.notebookcheck.net/Leaked-Google-Pixel-6-and-Pixel-6-Pro-service-manuals-emerge-with-references-to-a-Samsung-Exynos-5123-modem.571134.0.html),
  [9to5google 2023-03-16](https://9to5google.com/2023/03/16/google-exynos-modem-vulnerabilities/)

### Inferences
- The SS333 on this tablet speaks **IPC 4.1**. **[likely]** Basis: the dmesg indexes only resolve in IPC41. Treat
  libsamsung-ipc's tables as an IPC 4.0-or-older subset. Where both define an index, names agree (Q3), but payload
  layouts of LTE-era messages, for example NET_REGIST and GPRS_IP_CONFIGURATION, may have grown.
- "SIPC5 instead of HDLC" changes nothing for userspace. On the XMM HSIC/MIPI kernels the kernel also did the link
  framing. libsamsung-ipc always writes only the 7-byte FMT header and data, so the same code serves both. **[likely]**
- IIL (0x70) plus the `IpcProtocol41Iil` class is probably the RIL to Samsung-IMS-stack interface ("IMS Interface
  Layer"). Its strings include IPC_IIL_IMS_CALL_STATE_NOTI, IPC_IIL_ISIM_LOADED and IPC_IIL_SIP_SUSPEND. VoLTE is out
  of scope for a first native RIL. **[speculative]**

### Gaps
- No public document of Shannon "SIT" or of the Pixel RIL's AP-CP protocol was found. My searches for "SIT", "sitril"
  and "libsitril" returned only Replicant pages and Pixel-modem news. Whether SIT is a successor of IPC 4.1 is unknown.
- No source was found that names "IPC v4.0/4.1" as Samsung's official version labels beyond the class names.
- The dissector fork's location and status after 2022 are unknown.

---

## Q3. libsec-ril.so `strings` and decoded tables versus libsamsung-ipc; naming of the observed SM-T715 frames

### Takeaway
Every index that libsamsung-ipc defines and that I could resolve in IPC41 carries the same name. One exception: SND
0x0A is "WB_AMR_STATUS" in libsamsung-ipc and "WB_AMR_RPT" in libsec-ril. IPC41 adds several hundred messages. The 21
header tuples seen on the tablet all resolve. 4 of the 12 distinct commands are missing from libsamsung-ipc:
NET 0x11 CELL_INFO, GPRS 0x19 LTE_CA_STATUS, and MISC 0x0F, 0x10 and 0x50 (3 of the 4 are MISC). None is needed to
place calls or SMS.

### Cited Findings
Decoded IPC41 sub-command tables. All are **[confirmed]** by static disassembly of `IpcProtocol41::GetSubCommandName`
@0x1e49bc in `dumps/lib/libsec-ril.so`. "=" means same index and name as libsamsung-ipc. Indexes 01/02 of
switch-based groups were not resolved; for them the `strings` order and libsamsung-ipc agree on CALL OUTGOING/INCOMING,
NET PREF_PLMN/PLMN_SEL, MISC ME_VERSION/ME_IMSI and SS WAITING/CLI (**[likely]**).
- **CALL 0x02**: 03-0A "=" (RELEASE, ANSWER, STATUS, LIST, BURST_DTMF, CONT_DTMF, WAITING, LINE_ID). New: 0B SIGNAL,
  0C VOICE_PRIVACY, 0D CALL_TIME_COUNT, 0E OTA_PROGRESS, 0F DIAG_OUTGOING, 10 E911_CB_MODE, 11 FLASH_INFO, 12 LINE_CTRL,
  13 HOLD, 14 SRVCC, 15 ALERT_CONTROL, 16 ECCLIST, 17 ECC_STATUS, 18 BLOCK_STATUS, 19 DATA_CALL_BYTE_COUNTER, 30 MODIFY,
  33 VOICE_RADIO_BEARER_HANDOVER.
- **CDMA_DATA 0x03** (new group): 01 SERVICE_CFG … 15 CALL_STATUS_IPBASED (21 entries).
- **SMS 0x04**: 01-11 "=". New: 12 STATUS, 13 CBS_CBMI_CFG, 14 CBS_ACTIVATION, 15 IPC_SMS_RP_SMMA.
- **SEC 0x05**: 01-09 "=" (08 spelled LOCK_INFOMATION). New: 0A ATR_INFO, 0B RUIM_CONFIG, 0C SIM_ICCID, 0D SIM_POWER,
  0E IMS_SUPP_AUTH_TYPES, 0F SIMAPPS_INFO.
- **PB 0x06**: 01-05 "=".
- **DISP 0x07**: 01 ICON_INFO "=", 02 HOMEZONE_INFO "=", 06 RSSI_INFO "=". New: 03 PHONE_FATAL_INFO, 04 EXT_ROAM_INFO,
  05 USER_INDICATION.
- **NET 0x08**: 03-0D "=" (SERVING_NETWORK, PLMN_LIST, REGIST, SUBSCRIBER_NUM, BAND_SEL, SERVICE_DOMAIN_CONFIG,
  POWERON_ATTACH, MODE_SEL, ACQ_ORDER, IDENTITY, PREFERRED_NETWORK_INFO). New: 0E HYBRID_MODE, 0F HANDOVER, 10 AVOID_SYS,
  **11 CELL_INFO**, 12 ECC_RAT, 13 CSG_SEARCH, 15 PREFERRED_ROAMING_PLMN_LIST, 16 DUAL_STANDBY_PREF,
  17 DOMAIN_SPECIFIC_RESTRICTED, 18 ACB_INFO, 19 SSAC_INFO, 1C VOWIFI_HO_THRESHOLD, 20 LTE_BAND_PRIORITY, 21 LTE_ROAMING,
  22 CA, 23 AUTONOMOUS_GAP, 24 EPDG_HO_THRESHOLD, 25 DISABLE_2G, 26 NAS_TIMER, 30 EXTEND_BAND_MODE.
- **SND 0x09**: 01-09 "=". 0A is SND_WB_AMR_RPT (libsamsung-ipc: WB_AMR_STATUS). New: 0B TWO_MIC_SOL_CTRL,
  0C DHA_SOL_CTRL, 0D AUDIO_MODE_CTRL, 0E CLOCK_MODE_CTRL.
- **MISC 0x0A**: 03 ME_SN "=", 05 TIME_INFO "=". **Conflict**: 0C is MISC_RESERVED in IPC41 but DEBUG_LEVEL in
  libsamsung-ipc. New:
  - 04 KEY_EVENT_PROCESS, 06 NAM_INFO, 07 VCALL_CHANNEL_ID, 08 PHONE_DEBUG, 09 FUS, 0A ALARM_INFO, 0B PUBLIC_MODE,
    0D DEVICE_POSITION, 0E VTCALL_CONNECTION_STATUS, **0F SCREEN_STATUS**, **10 GRIP_SENSOR_STATUS**, 11 PREPAY_MODE,
    12 TBSR_CDMA, 13 MODEM_INTERFACE_MODE, 14 MODEM_UART_MODE, 15 T_MPSR_VALUE, 16-17 OMADM, 18 ENS_STATE, 19 1XADV_INFO,
    1A SMS_FORMAT, 1B SMS_OVER_IP_INFO, 1C HOME_DOMAIN_NAME, 1D-1E timers, 1F UART_AUTO, 20-22 IMS test/SIP port/FQDN,
    **23 IPC_LOOPBACK**, 24 LTE_TIMER, 25 PA_THERMISTER, 26 LOGGING_TIME_INFO, 27 DUALSTANDBY_CALL_STATUS,
    28 SILENT_LOGGING_CONTROL, 29 GPIODVS_DATA, **2A AT_CMD_FWD**, 2B-2C SIMLOCK, 2D DEVICE_CAPA, 2F CA_PROPERTY,
    30 T3402_TIMER, 31 POA_DELETE_GUTI, 40 BIP_INFO, 41 CP_POSITION, 42 GRIP_SENSOR_INFO, 43 AP_GPS_POSITION,
    44 LCD_MIPI_CONTROL, 45 CLM_TT_CMD, 46 SEND_CP_FEATURE, 47 ECHOLOCATE_MENU_STATUS, 48 CP_SPD_STATUS,
    49 SSDS_ONEHW_SIM_SLOT_COUNT, 4A MANUFACTURE_SALES_CODE, 4B SHARED_MEM_CMD_SAVE_FULL_MEMORY, 4C CP_NW_DATA,
    **50 MODEM_ACTIVITY_INFO**, 51 CP_INFO_FOR_ATC, 52 CLTCP.
- **SS 0x0C**: 03-0A "=". New: 0B UUS.
- **GPRS 0x0D**: 03-11 "=" (PS … PORT_LIST, including **0F PIN_CTRL**). New: 12 LTE_QOS_PROFILE,
  13 NW_INITIATED_PDN_DISCONNECT, 14 LTE_ATTACH_APN_INFO, 15 EPDG_HANDOVER, 16 EPDG_STATUS, 17 FD_INFORMATION,
  18 OPERATOR_RESERVED_PCO, **19 LTE_CA_STATUS**, 1A BACKOFF_TIMER, 1B SET_APN_INFO, 1C TRAFFIC_CHANNEL_STATUS,
  1D MOBILE_DATA_STATUS, 21 IMS_TEST_MODE, 22 SET_ALWAYS_ON_PDN.
- **GPS 0x11**: 03 FIX_REQ … 0D PD_EVENT, 11-15 XTRA_*, 21-2A control-plane AGPS (EXT_RADIO_SIG … IPC_GPS_CONTROL_PLANE),
  30 GANSS_MEASURE_POSITION. libsamsung-ipc has no GPS messages.
- **DOMESTIC 0x20, MCPTT 0x25, QMIIMS 0x40**: Korean-carrier, mission-critical-PTT and QMI-hidden-menu messages. These
  are irrelevant to this tablet.
- From `strings` only (indexes not decoded):
  - **PWR**: PHONE_PWR_UP, PHONE_PWR_OFF, PHONE_RESET, BATT_STATUS, BATT_TYPE, BATT_COMP, PHONE_STATE. These are the same
    7 as libsamsung-ipc, in the same string order.
  - **IMS**: CHANNEL, CODEC, REGI, PDN, RTP_MEDIA, SIP_INFO_ACB …
  - **SVC**: ENTER, END, PRO_KEYCODE, SCREEN_CFG, DISPLAY_SCREEN, CHANGE_SVC_MODE, DEVICE_TEST, DEBUG_DUMP_MESSAGE,
    DEBUG_STRING_MESSAGE, plus LTE_SCAN_FILE, FAKE_CELL_INFO, CALL_DROP_LOG_INFO, BIG_DATA_INFO, CP_LOGGING.
  - **SAT**: 0x01-0x0C names identical to libsamsung-ipc.
  - **FACTORY, CFG, IMEI, SAP**: name lists in `strings`.
  - **RFS**: OPEN/CLOSE/READ/WRITE/GET/PUT_FILE, GET_FILE_INFO, GET_HANDLE_INFO, LSEEK, FTRUNCATE, CREATE, RENAME,
    UNLINK, MAKE/OPEN/READ/CLOSE/REMOVE_DIR, NV_READ_ITEM, NV_WRITE_ITEM, NV_WRITE_ALL_ITEM, NV_RESTORE,
    NV_BUFFER_MESSAGE.
- The IpcProtocol41 transmit and receive method set is large. **[confirmed]**
  - Examples: `IpcTxCallOriginate`, `IpcTxSendSms`, `IpcTxDefinePdpContext`, `IpcTxSetPdpContext`, `IpcTxPsAttach`,
    `IpcTxSndSetAudioPath`, `IpcTxSndSetClockCtrl`, `IpcTxSndSetVolume`, `IpcTxSndSetMute`, `IpcTxNetGetVoiceRegState`,
    `IpcTxNetCellInfoList`, `IpcTxRadioPower`, `IpcTxRawIpc`.
  - Receive handlers: `IpcRxCall*`, `IpcRxNet*`, `IpcRxGprs*`, `IpcRxRfs`, `IpcRxSnd*`.
  - These come from exported mangled C++ symbols (`_ZN13IpcProtocol41…`), so the method names are reliable.

**Names of the SM-T715 header tuples (direction, main/sub/type)** — tuples as relayed by the project notes from
`dumps/dmesg.txt`; names from the IPC41 tables above and from libsamsung-ipc `protocol.h` types:

| Tuple | Name (IPC41) | In libsamsung-ipc? | Confidence |
|---|---|---|---|
| RX 07/01/02 ×3, TX 07/01/02 ×3 | DISP_ICON_INFO — RESP / GET | yes, 0x0701 | confirmed |
| RX 07/01/03 ×4 | DISP_ICON_INFO — NOTI | yes | confirmed |
| RX 07/06/03 ×4 | DISP_RSSI_INFO — NOTI | yes, 0x0706 | confirmed |
| TX/RX 08/02/02 ×3 | NET_PLMN_SEL — GET / RESP | yes, 0x0802 | likely (index 02 from libsamsung-ipc + strings order; IPC41 switch case 02 not decoded) |
| TX/RX 08/03/02 ×3 | NET_SERVING_NETWORK — GET / RESP | yes, 0x0803 | confirmed |
| TX/RX 08/05/02 ×6 | NET_REGIST — GET / RESP | yes, 0x0805 | confirmed |
| TX/RX 08/11/02 ×10 | **NET_CELL_INFO** — GET / RESP | **no** (IPC41-only) | confirmed |
| TX 0a/0f/05 ×7 | **MISC_SCREEN_STATUS** — EVENT | **no** (IPC40 puts it at 0x0D) | confirmed |
| TX 0a/10/05 ×2 | **MISC_GRIP_SENSOR_STATUS** — EVENT | **no** | confirmed |
| TX 0a/50/02 ×8 | **MISC_MODEM_ACTIVITY_INFO** — GET | **no** | confirmed |
| TX 0d/0f/01 ×1, RX 0d/0f/03 ×1 | GPRS_PIN_CTRL — EXEC / NOTI | yes, 0x0D0F (no payload struct in libsamsung-ipc) | confirmed |
| RX 0d/19/03 ×8 | **GPRS_LTE_CA_STATUS** — NOTI | **no** | confirmed |
| RX 80/01/02 ×9 | GEN_PHONE_RES — RESP | yes, 0x8001 | confirmed |

### Inferences
- The 9 GEN_PHONE_RES match libsamsung-ipc's convention that EXEC, SET and EVENT requests are acknowledged by
  GEN_PHONE_RES rather than by a RESP. On the tablet, 7 SCREEN_STATUS events, 2 GRIP_SENSOR_STATUS events and 1
  PIN_CTRL exec make 10 non-GET requests, against 9 GEN_PHONE_RES. The 8 MODEM_ACTIVITY_INFO GETs got no RESP in the
  tuple list. **[speculative]** Pairing by `aseq` would settle it.
- GPRS_PIN_CTRL is the DUN virtual-V.24 control message. libsec-ril has `DoGprsExecDunPinCtrl`, `DoGprsDisconnectDun`
  and `IpcTxDunPinCtrl`. Its exchange at boot suggests that the CP's DUN port (umts_router, ch 25) is live by default.
  **[likely]** (see Q6)
- The decoded tables are enough to write a dissector and a name table for a new RIL. Message payload structs are not
  recoverable from name tables. They need libsamsung-ipc's structs (XMM era) checked against observed payload lengths,
  or deeper RE of the `IpcRx*`/`IpcTx*` methods. **[likely]**

### Gaps
- Indexes not decoded: 01/02 of switch groups; PWR, SVC, SAT, CFG, IMEI, SAP, FACTORY, OMADM, RFS(0x15), IMS, EMBMS
  and GEN sub-tables. These are reachable with the same method by handling the other code shapes.
- Payload-length comparison (header byte only) between the dmesg frames and libsamsung-ipc structs for NET_REGIST,
  NET_SERVING_NETWORK and DISP_ICON_INFO. This has not been done yet and is the cheapest test of payload compatibility.

---

## Q4. Older free stacks: FSO fsogsmd "samsung", SHR, oFono samsungipc (2011-2012); what worked, where the code is

### Takeaway
libsamsung-ipc was co-developed in 2011-2013 with freesmartphone.org. Simon Busch maintained Vala bindings for
fsogsmd's `modem_samsung` plugin. That plugin lived in FSO's "cornucopia" tree and targeted the XMM616 Nexus S /
Galaxy S. It is dead with FSO. The oFono "samsungipc" driver was never merged upstream (licensing). A forward-port
exists in xc-racer99's oFono fork (branch `1.30-samsungipc`), "minimally tested" on a Galaxy S 4G (XMM6160). No
Shannon device was ever driven by FSO or oFono.

### Cited Findings
- Simon Busch's libsamsung-ipc commits run 2011-08-24 to 2013-06-23. Many concern the Vala API, for example "Add a lot
  more enums and structs to the vala api description" (2011-10-17) and "vapi: … support vala-0.14" (2011-11-25).
  Carikli committed "Fix VAPI's ipc_net_{regist_setup,plmn_sel_setup} renames for fsogsmd" on 2012-09-30.
  **[confirmed]** — [libsamsung-ipc log](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ipc/log/)
- PaulK: "Added SIM IO table (from FSO)…", 2011-10-29. **[confirmed]** — same log
- The Replicant wiki lists the Cornucopia fsogsmd `modem_samsung` plugin as an upper-layer user of libsamsung-ipc.
  **[confirmed via search snippet]** — [Replicant wiki Libsamsung-ipc](https://redmine.replicant.us/projects/replicant/wiki/Libsamsung-ipc/9/annotate)
- OpenEmbedded recipes existed for libsamsung-ipc 0.2.0 from the freesmartphone.org download server. **[confirmed]**
  — [OE layer index](https://layers.openembedded.org/layerindex/recipe/55579)
- Replicant's wiki says there are out-of-tree patches adding libsamsung-ipc support to oFono. **[confirmed]** —
  [Replicant libsamsung-ipc wiki](https://redmine.replicant.us/projects/libsamsung-ipc/wiki)
- postmarketOS wiki (per search snippet): the old oFono patches "don't seem like they were merged due to licensing
  issues which have now been resolved". They were forward-ported at github.com/xc-racer99/ofono and
  github.com/xc-racer99/libsamsung-ipc. **[confirmed via snippet; page Anubis-blocked]** —
  [pmOS wiki Samsung_Modem](https://wiki.postmarketos.org/wiki/Samsung_Modem)
- The xc-racer99/ofono About text: "ofono with libsamsung-ipc support … Minimally tested with modified libsamsung-ipc and
  SGS4G", branch `1.30-samsungipc`, "Rebased frequently". **[confirmed]** — [GitHub](https://github.com/xc-racer99/ofono)
- Upstream oFono's own `plugins/samsung.c` is a different, AT-based "Samsung modem driver" for USB data cards.
  **[confirmed]** — [ofono plugins/samsung.c](https://kernel.googlesource.com/pub/scm/network/ofono/ofono/+/dbbbebf92d786b089508b70f87532613a3f76a03/plugins/samsung.c)

### Inferences
- The likely licensing issue: libsamsung-ipc was GPLv3+ at the time (morphis fork). Today's GPL-2.0-or-later licence is
  compatible with oFono's GPLv2. **[speculative]**, consistent with "now resolved".
- The xc-racer99 oFono driver is the most complete existing non-Android consumer of libsamsung-ipc. It is XMM6160-tested
  only, and its rebase status after 1.30 is unknown. **[likely]**

### Gaps
- Exact Cornucopia path, last commit date and feature status of fsogsmd `modem_samsung`. git.freesmartphone.org was not
  reached.
- SHR: no source found linking SHR specifically to Samsung IPC beyond FSO.
- The 2011-2012 oFono mailing-list thread about samsungipc was not located on lore.kernel.org.

---

## Q5. ModemManager and oFono today; what a non-AT/QMI/MBIM protocol needs; bridge options

### Takeaway
ModemManager has no Samsung-IPC support: its port model knows AT, QCDM, QMI and MBIM (plus net/GPS/audio), and its
"samsung" plugin is AT-based. The existing bridge is **samsungipcd** (sleirsgoevy, GPL-2.0+, packaged in postmarketOS).
It emulates an AT modem over ptys on top of libsamsung-ipc. ModemManager is told to manage those ptys through udev
rules. Since v0.3.0 it routes IP traffic over native rmnet0 instead of PPP. This is the shortest path to an
MM/GNOME-Calls-compatible stack.

### Cited Findings
- ModemManager does not detect modems by itself. It reacts to udev port events. Plugins register subsystems (tty,
  usbmisc, net, wwan, qrtr), and the probe types are decided per port type. Port hint tags cover AT (primary/secondary/
  GPS-control/PPP), QCDM, GPS, AUDIO, QMI and MBIM. **[confirmed]** —
  [modemmanager.org port detection](https://modemmanager.org/docs/modemmanager/port-and-device-detection/)
- samsungipcd: "AT modem emulation via libsamsung-ipc", GPL-2.0-or-later, upstream gitlab.com/sleirsgoevy/samsungipcd
  (project created 2022-09-18, 39 commits, 7 tags). **[confirmed]** —
  [pkgs.postmarketos.org](https://pkgs.postmarketos.org/package/master/postmarketos/armv7/samsungipcd),
  [GitLab](https://gitlab.com/sleirsgoevy/samsungipcd)
- The original aport added udev rules tagging `ttywc`/`ttywd` so that ModemManager manages them, plus an OpenRC
  service running samsungipcd on `/dev/ptywc` and `/dev/ptywd`. **[confirmed via search summary]**
  — [pmaports commit (MR 3460)](https://ayakael.net/forge/pmaports/commit/ad454e784dd8d80b0b0f6f85c84083753d593def)
- v0.3.0 "adds a PPP bypass, so that traffic can flow through the native interface (rmnet0) directly". Depends: ppp,
  networkmanager-ppp. **[confirmed via search summary]**
  — [pmaports commit 9984529a](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/commit/9984529af7cbbc876f1bcac4375584f8a91a7d48)

### Inferences
- **Option A, shortest.** Add an `sm-t715` device to libsamsung-ipc: our boot routine plus the existing
  xmm626_kernel_smdk4412 transport. Then run samsungipcd, so that ModemManager uses its generic AT plugin. Main risks:
  - IPC 4.1 payload deltas for NET, GPRS and SMS.
  - RFS file verbs that libsamsung-ipc lacks.
  - Voice audio: samsungipcd's handling of SND_AUDIO_PATH/CLOCK_CTRL is unknown.
  - **[likely]** on feasibility, **[speculative]** on effort.
- **Option B.** xc-racer99 oFono samsungipc, used with ofono-based UIs. Less used today; MM is the default in Phosh and
  pmOS. **[likely]**
- **Option C.** A native MM plugin would need a new port type, a protocol library in the style of libqmi/libmbim, and
  plugin probing. Months of work, no precedent. **[likely]**
- A QMI or MBIM emulator is possible in principle but would have to translate full LTE semantics. It is strictly harder
  than AT emulation. **[speculative]**

### Gaps
- samsungipcd's README was not readable: GitLab rendered no content to the fetcher. Its supported AT set (calls?
  SMS? USSD? audio?) and tested devices are unknown. The tested devices are likely XMM ones (S2/S3/Note 2), which pmOS
  ships libsamsung-ipc for.
- No evidence that samsungipcd was ever run on a Shannon device.

---

## Q6. Does a Shannon CP accept AT commands directly? (umts_router, umts_csd, umts_atc*, AT over IPC)

### Takeaway
No public source shows ModemManager or any Linux tool driving a Shannon CP with native AT commands, and no `umts_atc*`
node exists on this board. There are two real leads.
1. **MISC_AT_CMD_FWD (0x0A2A)**, an IPC message that carries AT strings to the CP. libsec-ril has
   `DoOemAtCmdForwardResult`, and Samsung's AP-side `at_distributor` runs on this tablet.
2. **umts_router** (SIPC ch 25, "BT_DUN", app "Data Router"). It is the CP's DUN serial port with virtual V.24 signals
   (GPRS_PIN_CTRL) and is very probably a 27.007 AT interpreter for dial-up.

Both are untested here and worth a single, safe experiment.

### Cited Findings
- Our DT has no `umts_atc*` node. The 13 iodevs are umts_ipc0, umts_rfs0, umts_csd (ch 1 CS_VT_DATA), umts_router
  (ch 25 BT_DUN, app "Data Router"), umts_dm0 (ch 28 CPLOG1, DIAG), ipc_loopback0, rmnet0-3, multipdp, umts_boot0 and
  umts_ramdump0. **[confirmed]** — `SS333_LLI_BRINGUP.md:129-143`
- IPC41 defines MISC 0x2A `MISC_AT_CMD_FWD` and 0x51 `IPC_MISC_CP_INFO_FOR_ATC`. libsec-ril strings include
  `DoOemAtCmdForwardResult`, `"%s() : DoOemAtCmdForwardResult FAIL"` and a test-app path `…/saveApnByAtCmd`.
  **[confirmed]** — decoded table above; `strings` libsec-ril.so
- The tablet's init starts `service at_distributor /system/bin/at_distributor` ("AT Distributor for factory test",
  root, groups radio misc log). **[confirmed]** — `src/device_gts2-common/ramdisk/init.universal5433.rc:656-660`
- Tian et al., USENIX Security 2018, on the Samsung S8+:
  - USB AT goes `/dev/ttyGS0` → `ddexe` ("Data Distributor") → UNIX socket → `at_distributor`, which "either handles
    them itself or dispatches them".
  - Daemons involved: ddexe, at_distributor, smdexe, port-bridge.
  - Hayes/GSM commands such as ATD are delivered to the baseband by the RIL.
  - A ship-mode whitelist (`ro.product_ship`) limits commands.
  - All Samsung and LG phones tested exposed a USB modem (ACM) interface by default.
  - **[confirmed]** — [sec18-tian.pdf §2.3, §4.2.4](https://www.usenix.org/system/files/conference/usenixsecurity18/sec18-tian.pdf)
- AT commands are listed as a Shannon attack surface in a baseband-exploitation course (Artenstein). **[confirmed,
  course listing only]** — [Ringzer0](https://ringzer0.training/practical-baseband-exploitation)
- libsec-ril: `DoGprsExecDunPinCtrl`, `DoGprsDisconnectDun`, `IpcTxDunPinCtrl`. GPRS_PIN_CTRL (0x0D0F) was exchanged on
  the tablet at boot (Q3 table). **[confirmed]**
- Negative results: no web source for "umts_router" with AT, ddexe/drexe and DUN; no ModemManager report or issue for
  a Shannon/Exynos internal modem; the libsec-ril strings contain no "umts_router" and no "/dev/umts_atc". The only
  related ModemManager item is a 2017 thread about a USB Samsung GT-B3730 stick. **[confirmed negative]** —
  [MM-devel 2017-08](https://lists.freedesktop.org/archives/modemmanager-devel/2017-August/005603.html)

### Inferences
- The S8+ data path (ddexe/at_distributor → RIL → CP) suggests that on Samsung Exynos devices the CP's AT interpreter
  is reached through IPC (MISC_AT_CMD_FWD) for most commands. DUN dial-up is bridged raw from USB/BT to umts_router,
  hence the router node's "Data Router" app tag and the PIN_CTRL signalling. **[likely]**
- Experiment, for after CP boot under Linux: open `/dev/umts_router`, write `AT\r`, `ATI\r` and `AT+CGMR\r`, read with
  a timeout. Possibly first send GPRS_PIN_CTRL EXEC (DTR on) on the FMT channel, mirroring the boot-time exchange seen
  on stock. If it answers, ModemManager's generic AT plugin could control registration, SMS and PS data via ATD*99# on
  that port, with no IPC code. Voice and SMS over IMS are not expected there. **[speculative]**
- MISC_AT_CMD_FWD needs its payload format, which is unknown. It can be recovered by RE of `DoOemAtCmdForwardResult`
  and its sender, which would give a generic "AT over IPC" tunnel. **[speculative]**
- `umts_csd` (ch 1, CS_VT_DATA, group loop_radio) is the circuit-switched video-telephony data pipe, not an AT port.
  **[likely]**

### Gaps
- Whether umts_router speaks AT by default, or only after a DUN-enable IPC message (for example MISC_MODEM_INTERFACE_MODE
  0x0A13 or UART_MODE 0x0A14). Untested and undocumented.
- The MISC_AT_CMD_FWD payload layout and its whitelist. The at_distributor binary was not examined; it is not among
  the files I was allowed to read.

---

## Q7. What libsec-ril does beyond FMT: RFS, PDP via multipdp/rmnet, libsecril-client "Multiclient" audio, and the SND messages behind it

### Takeaway
libsec-ril runs at least three services on top of the FMT channel.
- **RFS file server** on umts_rfs0: full file and directory verbs plus NV items, needed because the CP keeps its
  NV/EFS on the AP.
- **PDP control**: GPRS DEFINE_PDP_CONTEXT/PDP_CONTEXT/IP_CONFIGURATION over FMT, with IP on rmnet0-3. multipdp is only
  a flow-control/wakeup node.
- **"Multiclient" socket server**: the audio HAL's `libsecril-client` sends OEM_HOOK_RAW sound commands, which become
  IPC SND messages.

samsung-ril implements the same audio path through its SRS socket.

### Cited Findings
- **libsecril-client (LineageOS 18.1 hardware/samsung, Apache-2.0)**. **[confirmed]**
  - Connects to abstract socket `"Multiclient"`, or `"VND_Multiclient"` on vendor builds, with `…2` for SIM 2 and
    `"QMulticlient"` for Qualcomm (`secril-client.cpp:39-45, 368, 432, 496`).
  - Each call is a Parcel `{RIL_REQUEST_OEM_HOOK_RAW, token, bytes}` (`:1112-1113`). Payload: `{0x08 OEM_FUNC_SOUND,
    sub, len_hi=0, len_lo, args…}` (`:70-83, 649-654`).
  - Calls and their OEM sub-commands:
    - SetCallVolume → `OEM_SND_SET_VOLUME_CTRL 0x03`, `{type, level}`. Types are 0x01 voice, 0x11 speaker, 0x31 headset,
      0x41 BT (`:85-88`).
    - SetCallAudioPath → `0x05`, `{path, extraVolume}`. Paths: earpiece 01, headset 02, HFK 03/06, BT 04, stereo-BT 05,
      speaker 06/07, headphone 07/08 … (two numbering variants, `:91-115, 699-705`).
    - SetCallClockSync → `0x0A`, `{condition}` (`:746-750`).
    - SetMute → `0x0B` (`:875-879`); GetMute → `0x0C`.
    - SetVideoCallClockSync → `0x07`; SetCallRecord → `0x09`; SetLoopbackTest → `0x08`; SetTwoMicControl → `0x0D`;
      SetDhaSolution → `0x0E`.
  - — `src/hardware_samsung-18.1/ril/libsecril-client/secril-client.cpp`, API in `secril-client.h:244-290`
  - The device trees ship it: `device_gts2-common/device-common.mk:44-45` and `device_gts28ltexx/device.mk:30-31`.
- libsec-ril contains `"Multiclient"`, `"Multiclient socket open error: %s."` and IPC SND senders `IpcTxSndSetVolume`,
  `IpcTxSndSetAudioPath`, `IpcTxSndSetClockCtrl`, `IpcTxSndSetMute`, `IpcTxSndSetLoopbackCtrl`,
  `IpcTxSndSetVoiceRecordingCtrl`, `IpcTxSndSetVideoCallCtrl`, `IpcTxSndSetTwoMicCtrl`, `IpcTxSndSetDhaCtrl`,
  `IpcTxSndSetAudioMode`, `IpcTxSndSetClockMode`. **[confirmed]** — `strings` libsec-ril.so
- SND index map in IPC41: 01 SPKR_VOLUME_CTRL, 02 MIC_MUTE_CTRL, 03 AUDIO_PATH_CTRL, 05 LOOPBACK_CTRL,
  06 VOICE_RECORDING_CTRL, 07 VIDEO_CALL_CTRL, 09 CLOCK_CTRL, 0B TWO_MIC_SOL_CTRL, 0C DHA_SOL_CTRL, 0D AUDIO_MODE_CTRL,
  0E CLOCK_MODE_CTRL. **[confirmed]** — decoded table (Q3)
- The free equivalent, samsung-ril `sound.c`, sends: SND_SPKR_VOLUME_CTRL SET (`:78`), SND_MIC_MUTE_CTRL SET
  (`:103,133`), SND_AUDIO_PATH_CTRL SET (`:154`), SND_CLOCK_CTRL EXEC (`:175`). **[confirmed]** —
  [sound.c](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ril/tree/sound.c)
- **RFS in libsec-ril** **[confirmed]**:
  - Classes `Nv::ProcessRfsPacket`, `Nv::SendRfsMessage`, `Nv::CheckRfsDirectory`, `IpcModem::ProcessRfsMessageReceived`,
    `Modem::Create/Open/CloseRfsIoChannel`, `ModemConfig::HasRfsInterface`.
  - Config log `"Modem config #%d: rfsIfName[%s], nvHeader[%s], modemDev[%s], nvSize[%d], nvDir[%s] nvOffSet[%d]"`.
  - Paths such as `/efs/imei/mps_code.dat`, `/efs/factory.prop`, `/efs/cpk/redata.bin`.
- **PDP** **[confirmed]**:
  - libsec-ril has `IpcTxDefinePdpContext`, `IpcTxSetPdpContext`, `IpcTxIpv6Configuration`, `IpcTxPsAttach`,
    `IpcRxIpConfiguration`, `IpcRxPdpContext` and `IpcRxGprsCallStatus`, and opens `/dev/tun` and
    `/sys/devices/virtual/misc/multipdp/waketime`.
  - rmnet0-3 are SIPC ch 10-13 with `NO_LINK_HEADER` (bare IP), and multipdp is a dummy node used for
    PROTOCOL_SUSPEND/RESUME. — `SS333_LLI_BRINGUP.md:606-617`
  - samsung-ril data.c uses GPRS DEFINE_PDP_CONTEXT, PDP_CONTEXT, IP_CONFIGURATION, CALL_STATUS and PS, plus
    `gprs_get_iface` and `gprs_activate`. — [data.c](https://git.replicant.us/replicant/hardware_replicant_libsamsung-ril/tree/data.c)

### Inferences
- Mapping chain for voice routing, from audio HAL to IPC SND (sub-command and message per call). **[likely]**: names
  and indexes are confirmed, the one-to-one call path inside libsec-ril is not traced.

  | libsecril-client call | OEM sub | IPC41 message |
  |---|---|---|
  | SetCallVolume | 0x03 | SND 0x01 SPKR_VOLUME_CTRL |
  | SetMute | 0x0B | SND 0x02 MIC_MUTE_CTRL |
  | SetCallAudioPath | 0x05 | SND 0x03 AUDIO_PATH_CTRL |
  | SetLoopbackTest | 0x08 | SND 0x05 LOOPBACK_CTRL |
  | SetCallRecord | 0x09 | SND 0x06 VOICE_RECORDING_CTRL |
  | SetVideoCallClockSync | 0x07 | SND 0x07 VIDEO_CALL_CTRL |
  | SetCallClockSync | 0x0A | SND 0x09 CLOCK_CTRL |
  | SetTwoMicControl | 0x0D | SND 0x0B TWO_MIC_SOL_CTRL |
  | SetDhaSolution | 0x0E | SND 0x0C DHA_SOL_CTRL |

- A native Linux RIL must therefore send SND_AUDIO_PATH_CTRL and SND_CLOCK_CTRL when a call starts, so that the CP
  drives the AIF2 PCM clock towards the WM1814 (see `SS333_LLI_BRINGUP.md` §6). That is exactly what samsung-ril's
  SRS path does, so the code exists. **[likely]**
- RFS is the biggest delta from libsamsung-ipc. Two unknowns:
  - Whether the SS333 CP actually issues file verbs (OPEN/READ/WRITE_FILE) at runtime, or only NV items. If it issues
    file verbs, a Linux RFS server needs the libsec-ril verb indexes and request layouts, which are not yet decoded.
  - Whether RFS on ch 245 uses libsamsung-ipc's 6-byte `ipc_rfs_header` (herolte, a Shannon device, assumes so) or the
    FMT header with main 0x15 RFS_CMD.
  - **[speculative]** on both counts.
  - Mitigation: a logging RFS server that answers NV read/write from a copy of nv_data.bin and logs every unknown
    verb. Must never touch the real EFS partitions.

### Gaps
- RFS verb numeric indexes (main 0x15 sub-table) and payload layouts.
- Whether `RFS_CMD` 0x15 is used on the FMT channel at all.
- The exact libsec-ril code path from the Multiclient OEM_HOOK_RAW handler to `IpcTxSnd*`.

---

## Q8. DIAG: SCAT (fgsect/scat) on Samsung Shannon SDM, via umts_dm0

### Takeaway
SCAT parses Samsung "SDM" diagnostic streams (`-t sec`, autodetecting the Samsung baseband type since 1.2.0) from USB
or from `.sdm` dump files and emits GSMTAP. Starting a USB session needs a Samsung "start magic" that the project
deliberately does not publish. Nothing documents using SCAT on an on-device `/dev/umts_dm0` node. In principle that node
(ch 28 CPLOG1, with a `dm_state` sysfs knob) is the same SDM byte stream, so a small reader that pipes umts_dm0 into
SCAT's file or stdin parser is plausible.

### Cited Findings
- README: `scat -t sec -u -a 001:010 -i 2` (USB) and `scat -t sec -d test.sdm` (dump).
  - "Samsung devices require a correct magic number to be supplied to start the diagnostic session through USB" (Issue
    #27). The project's chat rules say `--start-magic` "should not be discussed in the public".
  - SCAT ≥1.2.0 autodetects the Samsung baseband type; `-m` is needed only for raw SDM without the start response.
  - Credits GSMK for the SDM parser.
  - **[confirmed]** — [github.com/fgsect/scat](https://github.com/fgsect/scat)
- On the tablet, `umts_dm0` is SIPC ch 28 (CPLOG1), RAW misc, app "DIAG". init gives radio/system access to
  `/sys/devices/virtual/misc/umts_dm0/dm_state`. **[confirmed]** — `SS333_LLI_BRINGUP.md:135`;
  `src/device_gts28ltexx/rootdir/etc/init.baseband.rc:36-37`
- libsec-ril references `SVC_CP_LOGGING`, `MISC_SILENT_LOGGING_CONTROL` (0x0A28) and `IpcTxSilentLoggingControl`, the
  IPC-side switch for CP logging. **[confirmed]** — strings and decoded table

### Inferences
- With the CP booted under Linux, enabling `dm_state`, then possibly sending MISC_SILENT_LOGGING_CONTROL and SCAT's
  SDM start sequence on umts_dm0, should yield an SDM stream that SCAT can parse. That would give layer-3 (NAS/RRC)
  visibility while debugging registration. **[speculative]**
- SDM start magic: per SCAT's policy it is not public. Recovering it from the stock CP-logging app or from silent-logging
  binaries is possible, but sits outside this research's constraints. **[speculative]**

### Gaps
- No report found of SCAT used with an on-device umts_dm0 or on an SS333 (2015-era Shannon) specifically. Which SDM
  protocol generation SS333 speaks is unknown.
- What `dm_state` values mean. They are kernel-defined; check `modem_io_device.c` in our kernel source next.
