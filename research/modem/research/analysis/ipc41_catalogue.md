# Samsung IPC 4.1 message catalogue for the SM-T715 Shannon SS333 (stock libsec-ril vs libsamsung-ipc)

Scope: the FMT messages a native Linux telephony daemon must send and parse on `/dev/umts_ipc0` to drive the
SS333 CP, established by static analysis of Samsung's `libsec-ril.so` (T715XXU2CRH1) and compared with the free
libsamsung-ipc definitions. RFS (`/dev/umts_rfs0`) is out of scope.

## How to read this note

- **Marks.** **P** = proven: read in decompiled or disassembled code at the cited address, or counted in dmesg headers.
  **I** = inferred: the reasoning is given next to it. Confidence: **H** high, **M** medium, **L** low.
- **Directions and types.** AP→CP: `E`=EXEC 01, `G`=GET 02, `S`=SET 03, `C`=CFRM 04, `V`=EVENT 05. CP→AP: `I`=INDI 01,
  `R`=RESP 02, `N`=NOTI 03. `GEN` = the generic acknowledgement GEN_PHONE_RES 0x80/0x01 RESP.
- **Offsets.** `p0` is the first payload byte, which is frame byte 7 (just after the 7-byte header). All 16- and
  32-bit fields are little-endian: the decompiled code reads them with plain `ushort`/`uint` loads on ARM LE.
- **Addresses.** They are virtual addresses in `libsec-ril.so` (2 640 104 bytes, md5 `9cfbeeef8eab7463e5df6953254aacd7`,
  identical to `dumps/lib/libsec-ril.so`). Every function is `IpcProtocol41::<name>` unless another class is named.
- **libsamsung-ipc.** Struct names come from the clone at `scratchpad/src/libsamsung-ipc` (commit `81a412cb`,
  2023-09-20), `include/*.h`.
- **Match column.** "=" means same size and same field offsets. "prefix" means the libsamsung-ipc struct is a leading
  subset and IPC41 appends fields. "≠" means the layout differs. "new" means libsamsung-ipc has no struct for it.

## Method (static only)

- **Decompilation.** Ghidra 12.1.4 headless decompiled every `IpcProtocol41::`, `IpcProtocol::`, `IpcModem::`,
  `Ipc41PacketBuilder::`, `Ipc41RilDataBuilder::` and `*RespBuilder::` function, plus the call, network, SMS,
  sound, data, power, SIM and misc manager classes and `ModemProxy::`. That is 4 853 decompiled functions, written to
  `scratchpad/ipc41/decomp*/`. The Ghidra project is a scratch copy, so the blob was never written.
- **Gaps.** A few functions that Ghidra did not split were read with rizin (`pd`).
- **Relocations.** The binary uses Android packed relocations (APS2 in `.rel.dyn`). They were decoded with
  `scratchpad/ipc41/aps2.py` to resolve the `IpcProtocol41` vtable (`_ZTV13IpcProtocol41` @0x284238). That resolution
  turns each Rx dispatcher's `switch(sub_cmd)` into concrete handler names (`vt2.py`, `disp.py`).
- **Kernel log.** dmesg was reduced to header fields only: len, seq, ack, main, sub, type
  (`scratchpad/ipc41/tuples.py`). No payload byte was recorded.
- **Not done.** Nothing was executed or emulated, and the tablet was not contacted.

---

## 0. Framing facts that hold for every message

| Fact | Evidence | Mark |
|---|---|---|
| Header `{u16 len; u8 mseq; u8 aseq; u8 main; u8 sub; u8 type}`. `len` includes the 7 header bytes. | Every Tx builder writes `len = 7 + payload` (e.g. `IpcTxModemPowerOff` @0x1d71c8 sends 7 bytes with `len=7`). All 92 `LNK-*` lines in dmesg satisfy link_len − 4 = FMT len. `GetRxData` @0x1dd6e8 switches on byte 4 (main), the group handlers on byte 5 (sub), the parsers on byte 6 (type). | P H |
| Same header as libsamsung-ipc `struct ipc_fmt_header`. | `include/protocol.h:78` | P H |
| AP→CP `mseq` increments per frame and `aseq` = 0. A CP RESP/GEN carries `aseq` = request `mseq`. CP NOTIs carry `aseq` = 0. | dmesg pairing (94 `IOD-*` lines): 43 TX frames = 9 EVENTs + 34 GET/EXEC requests; 34 RX answers, all matched by aseq. | P H |
| GET → RESP with the same main/sub. EXEC/SET → `GEN_PHONE_RES` 80/01 R `{group, index, type, u16 code}`, code 0x8000 = OK. EVENT gets **no** answer. | dmesg: 7× SCREEN_STATUS EVENT and 2× GRIP EVENT unanswered; GPRS_PIN_CTRL EXEC answered by GEN. `IpcRxGeneral` @0x1eb0c4 reads p0 group, p1 index, p2 type, p3..4 code. `IpcProtocol::ConvertGenCmdError` @0x1cbee8 maps 0x8000 → success and 0x80xx/0x81xx/0x84xx/0x85xx/0x90xx → errors. | P H |
| A GET that the CP does not implement is answered by GEN_PHONE_RES instead of RESP. | 8× MISC_MODEM_ACTIVITY_INFO 0a/50 G, each answered by an 80/01 with the matching aseq. | P H |
| The SS333 runs **IpcProtocol41 with ModemProtoVer = 2**. | `ModemFactory::LoadModemConfiguration` @0x1019b4 calls `ModemConfig::Init(idx 0, intf 3, "/dev/umts_ipc0", ModemType 4 (GSM/LTE; 6 if CscFeature_RIL_SupportAllRat, 2 if CDMA), proto 1, protover 2, …)`. `IpcModem::CreateProtocol` @0x1bfc30 maps 0 → IpcProtocol40, 8 → IpcProtocol41Iil, 2 → `IpcProtocol41(2,…)`, else IpcProtocol41. `IpcProtocol::IpcProtocol` @0x1cba30 stores protover at `this+4`. | P H |
| protover 2 changes three behaviours: LTE attach APN is sent (§8); `ConvertPreferredNetTypeToIpc` uses a CDMA-aware table (not used by the Tx path); NET_MODE_SEL fallback = 9. | `IpcTxSetLteAttachProfile` @0x1e2b18 runs only if `this+4 == 2`. | P H |

**Rx dispatch, sub → handler.** These are proven: the handler names come from the vtable slots each group dispatcher
calls.

- **PWR 01:** 01 PwrUp, 03 PwrReset, 07 PwrState.
- **CALL 02:**
  - 02 CallIncoming, 05 Status, 06 List, 07 BurstDtmf, 09 Waiting, 0a LineId, 0b SignalInfo, 0c VoicePrivacy,
    0d CallTime;
  - 0e OtaProgress, 0f DiagnosticOutgoing, 10 EmergencyCbMode, 12 LineControl, 14 Srvcc, 16 EccList, 19 LifeByte,
    33 VoiceRadioBearerHandover.
- **SMS 04:** 01 SendMsg, 02 IncomingMsg, 03 ReadMsg, 04 SaveMsg, 05 DeleteMsg, 06 DeliveryReportMsg, 07 DeviceReady,
  09 StoredMsgCount, 0a Smsc, 0c MemoryStatus, 0d IncomingCBMsg, 0e CBConfig.
- **SEC 05:** 01 PinStatus, 02 PhoneLock, 05 RSIM, 06 Gsim, 07 SimCardType, 08 LockInfo, 09 ImsAuth, 0a PcscPowerUp,
  0b RuimConfig, 0c ICCID, 0d SetSimPower, 0f SimAppInfo.
- **DISP 07:** 01 IconInfo, 06 RssiInfo.
- **NET 08:**
  - 01 PreferredNetworkList, 02 PlmnSelect, 03 ServingNetwork, 04 PlmnList, 05 RegState, 07 BandMode,
    08 ServiceDomain, 0a ModeSelect, 0b AcqOrder, 0c Identity (network name), 0d RoamingPref, 0f Handover;
  - 10 AvoidNetList, 11 CellInfoList, 12 EccRat, 13 CsgSearch, 15 PrefRoamingPlmnList, 17 DomainSpecificRestricted,
    18 AcbInfo, 19 SsacInfo, 1c VoWifiHoThreshold, 20 BandPriority, 21–23 CA, 25 Disable2g, 26 NasTimer,
    30 ExtendedBandMode.
- **SND 09:** 02 Mute, 08 RingbackTone, 09 ClockCtrl, 0a WbAmrReport.
- **MISC 0A:**
  - 01 MobileEquipVersion, 02 Imsi, 03 SerialNumber, 04 KeyCodeNotify, 05 TimeInfo, 08 PhoneDebug, 23 IpcLoopback,
    2d DeviceCapa, 2f CaProperty;
  - 41 CpPosition, 42 GripSensorInfo, 46 SendCpFeature, 4a ManufactureSalesCode, 4c CpNwData, 50 ModemActivityInfo,
    51 CpInfoForAtc, 52 Cltcp;
  - plus CDMA, IMS and timer subs.
- **SS 0C:** 01 CallWaiting, 02 Cli, 03 Barring, 05 Forward, 06 Info, 08 Ussd.
- **GPRS 0D:** 03 PsState, 04 PdpContext, 09 IpConfiguration, 0c HsdpaStatus, 0f DunPinControl, 10 CallStatus,
  16 EpdgStatus, 18 PcoStatus, 19 LteCaStatus, 1a BackoffTimer, 1c TrafficChannel.
- **SAT 0E:** 01 ProfileDownload, 02 Envelope, 03 ProactiveCmd, 08 Refresh, 09 EventList, 0a CallControlResult.
- **GEN 80:** `IpcRxGeneral`.

---

## 1. Power

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| PWR_PHONE_PWR_UP 01/01 | CP→AP N | not parsed; triggers "modem powered" (PowerInfo 2) | index only | = (no data) | `IpcRxPwrUp` @0x1d726c (disasm) | P H |
| PWR_PHONE_PWR_OFF 01/02 | AP→CP E | none | index only | = | `IpcTxModemPowerOff` @0x1d71c8 | P H |
| PWR_PHONE_STATE 01/07 (radio on/off) | AP→CP **E** | p0..1 = u16 state: **0x0202 normal (radio on)**, **0x0001 LPM (airplane/off)** | `ipc_pwr_phone_state_request_data {u16 state}`, REQUEST_NORMAL 0x0202 / LPM 0x0001 | = | `IpcTxRadioPower` @0x1f64e8: RadioPowerState 1 → bytes 01 00, 2 → 02 02 | P H |
| PWR_PHONE_STATE 01/07 | AP→CP E | p0..1 = 03 00 ("slave phone off", dual-standby only) | — | new | `IpcTxSlavePhoneOff` @0x1f6560 | P H |
| PWR_PHONE_STATE 01/07 | CP→AP N | p0 = state: 1 → LPM (radio off), 2/3/4 → normal (radio on). Only NOTI is parsed. | `ipc_pwr_phone_state_response_data {state}` LPM 1 / NORMAL 2 | = (3, 4 new) | `IpcRxPwrState` @0x1f65f8, table @0x26bc7c = [1,2,2,2] | P H |
| PWR_PHONE_RESET 01/03 | CP→AP N or R | p0 reset type (1 → 0, 2 → 1, else 2), p1 cause (0..5, else 6) | index only | new struct | `IpcRxPwrReset` @0x1f65b4 | P M (meaning of values I) |
| Phone/modem reset (AP-initiated) | — | No IPC41 Tx exists for PWR_PHONE_RESET. `IpcTxResetModemRadio` sends 0x22/0x0A S (QMI_HIDDENMENU, Qualcomm only). Shannon reset goes through the kernel (`IOCTL_MODEM_RESET`/`FORCE_CRASH_EXIT`, cf. bring-up §2.2). | — | — | `IpcTxResetModemRadio` @0x1ebedc → `Ipc41PacketBuilder::BuildIpcModemRadioReset` @0x200e48 | P H (absence I M) |

## 2. Identity

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| MISC_ME_VERSION 0A/01 | AP→CP G | p0 = 0xFF (field mask "all") | `ipc_misc_me_version_request_data {magic}` (setup sets 0xFF) | = | `BuildIpcMiscMobileEquipmentVersion` @0x200a58 | P H |
| MISC_ME_VERSION 0A/01 | CP→AP R | p0 = mask. p1..32 SW version (mask 0x01), p33..64 HW version (0x02), p65..96 cal date (0x04), p97..128 misc/product (0x08), p129.. field (0x10). p146 = PRL count, then 3×17-byte entries (0x20). p198 = ERI count, then 3×17-byte entries (0x40). p250.. (0x80). | `{unknown, sw[32], hw[32], cal_date[32], misc[32]}` = 129 B | prefix | `Ipc41RilDataBuilder::BuildRilDataMiscMobileEquipmentVersion` @0x200a9c | P H |
| MISC_ME_IMSI 0A/02 | AP→CP G / CP→AP R | Request: none. Response: p0 = length (≤15), p1.. ASCII digits. | `ipc_misc_me_imsi_header {length}` + digits | = | `IpcTxGetImsi` @0x1eb244, `IpcRxMiscImsi` @0x1ee500 | P H |
| MISC_ME_SN 0A/03 (IMEI, serial, …) | AP→CP G | p0 = SN type: 0x01 IMEI, 0x02..0x07 other identities (DeviceInfoType 4→2, 8→3, 0x10→4, 0x20→5, 0x40→6, 0x80→7) | `ipc_misc_me_sn_request_data {type}`; SERIAL_NUM 0x01 is used for IMEI by samsung-ril `misc.c:207` | = | `BuildIpcMiscMobileEquipmentSerialNumber` @0x200820 | P H (type names beyond 0x01 I) |
| MISC_ME_SN 0A/03 | CP→AP R | p0 type, p1 length (≤32), p2.. data. Types 2/7/3 carry binary date bytes, which the AP formats. | `ipc_misc_me_sn_response_data {type, length, data[32]}` | = | `BuildRilDataMiscMobileEquipmentSerialNumber` @0x200900 | P H |
| SEC_SIM_ICCID 05/0C | CP→AP N | p0 = length, p1.. ICCID | — | new | `IpcRxNotiICCID` (accesses p0, p1..) | P M |

IMEISV: no separate message was found; samsung-ril derives it from the same ME_SN exchange (I, M).

## 3. SIM

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| SEC_PIN_STATUS 05/01 (card status) | CP→AP N, then R to G | p0 status: 0x00–0x0B lock states, 0x80 absent, 0x81 card error, 0x83 PB/init done, plus new 0x84/0x88/0x89/0x8A/0x8B. p1 = facility lock (0..6). | `ipc_sec_pin_status_response_data {status, facility_lock}` | prefix (0x09–0x0B and 0x84–0x8B new) | `IpcRxSecPinStatus` @0x1f7668 | P H |
| SEC_PIN_STATUS 05/01 | AP→CP G | none. **Gated:** libsec-ril refuses the GET until a first PIN_STATUS NOTI has arrived (flag `SimCache+0x21`). | — | = | `IpcTxGetPinStatus` @0x1f6680 | P H |
| SEC_PIN_STATUS 05/01 (verify PIN/PUK) | AP→CP S → GEN | 19 B: p0 PIN type (PIN1 0x03, PIN2 0x09, third type 0x01), p1 len1, p2 len2, p3..10 pin1[8], p11..18 pin2[8]. PUK: two strings; samsung-ril puts new PIN in pin1 and PUK in pin2. | `ipc_sec_pin_status_request_data` (19 B) | = | `IpcTxSetPinStatus` @0x1f6868, `IpcModem::EnterSimPuk` @0x1c0c1c passes both strings | P H (PUK field order I M) |
| SEC_PHONE_LOCK 05/02 (facility lock query) | AP→CP G / CP→AP R | Request: p0 facility. Response: p0 facility (0x80.. remapped), p1 active. | `ipc_sec_phone_lock_request_get_data`, `…_response_data` | = | `IpcTxGetPhoneLock` @0x1f692c, `IpcRxSecPhoneLock` @0x1f7eac | P H |
| SEC_PHONE_LOCK 05/02 (set) | AP→CP S → GEN | 42 B: p0 facility, p1 active, p2 pw_len, p3..41 pw[39] | `ipc_sec_phone_lock_request_set_data` (42 B) | = | `IpcTxSetPhoneLock` @0x1f6984. Facility map `FUN_001f6800` = identity for 1..11, then 0x80..0x84, 0x88, 0x89. | P H |
| SEC_CHANGE_LOCKING_PW 05/03 (change PIN) | AP→CP S → GEN | 81 B: p0 facility, p1 old_len, p2 new_len, p3..41 old[39], p42..80 new[39]. **Facility = PIN type code** (PIN1 0x03, PIN2 **0x09**). | `ipc_sec_change_locking_pw_data` (81 B); samsung-ril sends SC 0x03 / **FD 0x04** for PIN2 | = size, ≠ PIN2 code | `IpcTxSetChangeLockPwd` @0x1f7c7c | P H |
| SEC_RSIM_ACCESS 05/05 (SIM I/O) | AP→CP **G** (for reads and updates alike) | 37 B header + data: p0 command (B0/B2/C0/D6/DC/F2…), p1 app selector (3 = SIM; else from the AID's app type: [3,0,4,2,1], default 6), p2 aid_len, p3..18 AID[16], p19..20 u16 file_id, p21 path_len in u16 units, p22..33 path[6×u16], p34 P1, p35 P2, p36 P3, p37.. data | `ipc_sec_rsim_access_request_header {cmd, u16 file_id, p1, p2, p3}` (6 B) + data | **≠** | `IpcTxGetRsimWithAid` @0x1f6a34 (frame len = 0x2c + data) | P H |
| SEC_RSIM_ACCESS 05/05 | CP→AP R | p0 SW1, p1 SW2, p2 len, p3.. data. A USIM FCP (0x62) is converted to a SIM-style GET RESPONSE by the AP. | `ipc_sec_rsim_access_response_header {sw1, sw2, length}` | = | `IpcRxSecRSIM` @0x1d805c (shared with IPC40) | P H |
| SEC_SIM_ICC_TYPE 05/07 | CP→AP N/R | p0 card type 1..4 (1 SIM, 2 USIM, 3/4 RUIM/other) | `ipc_sec_sim_icc_type_data {type}` | = | `IpcRxSecSimCardType` @0x1f7f44 | P H (3/4 names I) |
| SEC_LOCK_INFORMATION 05/08 (retries) | AP→CP G | **9 B**: p0 = caller value, p1 lock type, p2..8 = 0 | `ipc_sec_lock_information_request_data {magic=1, type}` (2 B) | ≠ (size) | `IpcTxGetSimLockInfo` @0x1f6760 | P H (use of p2..8 unknown) |
| SEC_LOCK_INFORMATION 05/08 | CP→AP R | p0 num, p1 lock type, p2 key state (0..6), p3 retry count | `ipc_sec_lock_information_response_data` | = | `IpcRxSecLockInfo` @0x1f7e38 | P H |
| SEC_SIMAPPS_INFO 05/0F | AP→CP G / CP→AP R | Request: none. Response: p0 n_apps, then 24-B records: {app type (0 USIM, 1 ISIM, 2 CSIM, 3 SIM, 4 RUIM), aid_len, aid[16], pin1 state, pin2 state, 4 retry counters} | — | new | `IpcTxGetSimAppsInfo` @0x1f670c, `IpcRxSecSimAppInfo` @0x1f7958, app table @0x26de30 = [2,5,4,1,3,0,0] (RIL app types) | P H |
| SEC_SIM_POWER 05/0D | AP→CP S | p0 on/off | — | new | `IpcTxSetSimPower` @0x1f7d40 | P H |
| SEC_ATR_INFO 05/0A | AP→CP G | none | — | new | `IpcTxGetAtr` @0x1f6de4 | P H |

## 4. Network

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| NET_REGIST 08/05 | AP→CP G | p0 act = 0xFF, p1 domain = **0x02 CS (voice) / 0x03 PS (data)** | `ipc_net_regist_request_data {act, domain}` | = | `IpcTxNetGetVoiceRegState` @0x1f126c, `…DataRegState` @0x1f12f4 | P H |
| NET_REGIST 08/05 | CP→AP R/N | **19 B**: p0 act, p1 domain (1 → 0, 2 → 2, 3 → 1), p2 reg status, p3 edge, p4..5 LAC, p6..9 cell id, p10 reject cause, **p11..12 TAC, p13 VoLTE support, p14 IMS-emergency support, p15 bool, p16..17 physical cell id, p18 flag** | `ipc_net_regist_response_data` = 11 B (act … fail_cause) | prefix | `IpcRxNetRegState` @0x1f30cc. Log format @0x26361c: "VolteSupport %d ImsEmergencySupport %d TAC %d PhysicalCellId %d". dmesg: 19 B. | P H |
| NET_SERVING_NETWORK 08/03 (operator) | AP→CP G / CP→AP R/N | **26 B**: p0 ?, p1 reg status, p2 act, p3..8 PLMN ASCII ('#' pad for 5 digits), p9..10 LAC, p11..17 ?, p18 SSAC voice factor, p19..20 voice time, p21 video factor, p22..23 video time, p24..25 ?. A second operator block follows if the frame is > 0x21 B. | `ipc_net_serving_network_data {unknown[3], plmn[6], u16 lac}` = 11 B | prefix | `IpcTxNetGetOperator` @0x1f137c, `IpcRxNetServingNetwork` @0x1f3b84. dmesg: 26 B. | P H (p11..17 unknown) |
| NET_IDENTITY 08/0C (operator names) | CP→AP N | Layout chosen by frame length. New layout (≥0x46): p1 flags (bit0 short name, bit1 full name), p3 short len, p4 coding (0 8-bit, 1 GSM7 packed, 2 UCS2), p5.. short name, p38 full len, p39 coding, p40.. full name, p104..109 PLMN. Old layout: short at p3/p4/p5, full at p22/p23/p24, PLMN at p56..61. | — | new | `IpcRxNetIdentity` @0x1f48bc | P M |
| DISP_RSSI_INFO 07/06 (signal) | CP→AP N | **9 B**: p0 RSSI as −dBm (ASU = (0x71−x)>>1, clamp 0..31), p1 alt bars, p2 BER, p3 LTE SS, p4 RSRP (−dBm, 0 = n/a), p5 RSRQ, p6..7 s16 RSSNR+200, p8 CQI (0xFF n/a). RESP adds p12..17 three s16 (WCDMA/TD). A 23-B CDMA variant also exists. | `ipc_disp_rssi_info_data {rssi}` | prefix | `IpcRxDispRssiInfo` @0x1e6290. dmesg: 9 B. | P H |
| DISP_RSSI_INFO 07/06 | AP→CP G / S | G: p0 = 1 byte. S: p0..2 = 3 bytes (threshold/report config). | — | new | `IpcTxDispGetRssiNoti` @0x1e6200, `IpcTxDispSetRssiNoti` @0x1e6160 | P H (field meaning I) |
| DISP_ICON_INFO 07/01 | AP→CP G | p0 = 0x01 (RSSI flag) | `ipc_disp_icon_info_request_data {flags}` | = | `IpcTxDispGetIconInformation` @0x1e60dc | P H |
| DISP_ICON_INFO 07/01 | CP→AP R/N | **10 B**: p0 flags, p1 bars (0..3/4 → ASU table), p2 hdr_rssi, p3 battery, p4 LTE SS, p5 RSRP, p6 RSRQ, p7..8 RSSNR+200, p9 CQI (if frame ≥ 17 B). If frame = 19 B: p10..11 u16 level. | `ipc_disp_icon_info_response_data` (4 B) | prefix | `IpcRxDispIconInfo` @0x1e64dc. dmesg: 10 B. | P H |
| NET_PLMN_SEL 08/02 | AP→CP G / CP→AP R | Response: p0 mode (2 auto, 3 manual, 4 auto, 5/6 manual-variants) | `ipc_net_plmn_sel_response_data` | = | `IpcTxNetGetNetSelectionMode` @0x1f15dc, `IpcRxNetPlmnSelect` @0x1f43bc, table [0,1,0,2,3] | P H |
| NET_PLMN_SEL 08/02 (select) | AP→CP S → GEN | 8 B: p0 mode (2 auto, 5 alternative auto, 3 manual), p1..6 PLMN ASCII (6th = '#' if 5 digits), p7 act (0xFF for auto) | `ipc_net_plmn_sel_request_data` (8 B) | = | `IpcTxNetSetNetSelectionAuto` @0x1f1664, `…Manual` @0x1f1728 | P H |
| NET_PLMN_LIST 08/04 (scan) | AP→CP G (start), **S with no payload = cancel** | none | index only | = (cancel new) | `IpcTxNetGetAvailableNetworks` @0x1f17f8, `IpcTxNetCancelAvailableNetworks` @0x1f1880 | P H |
| NET_PLMN_LIST 08/04 | CP→AP R | p0 count, then 10-B entries: {status 1..4, plmn[6], **act**, 2 B ?} | `ipc_net_plmn_list_entry {status, plmn[6], type, unknown[2]}` | = size; byte 7 is the RAT, not a "type" | `IpcRxNetPlmnList` @0x1f43f0 | P H |
| NET_MODE_SEL 08/0A (preferred network type) | AP→CP G / S | S: p0 = **RAT bitmask**: bit0 GSM, bit1 WCDMA, bit2 CDMA/EVDO, bit3 LTE, bit4 TD-SCDMA. Android type → mask: 0/3 → 0x03, 1 → 0x01, 2 → 0x02, 9 → 0x0B, 11 → 0x08, 12 → 0x0A, default → 0x0F. | `ipc_net_mode_sel_data {mode_sel}` with enumerated values 1 GSM+UMTS, 2 GSM, 3 UMTS | **≠ (values)** | `IpcTxNetSetPreferredNetType` @0x1f14bc → `ConvertPreferredNetTypeToIpcWithBitmask` @0x1f1404 | P H |
| NET_MODE_SEL 08/0A | CP→AP R | p0 = bitmask (reverse map; 0x03 → 0, 0x0B → 9, 0x08 → 11, 0x0A → 12, 0x0F → 10) | same | ≠ | `IpcRxNetModeSelect` @0x1f433c → `ConvertIpcToPreferredNetTypeWithBitmask` @0x1f42d0 | P H |
| NET_CELL_INFO 08/11 | AP→CP G | none | — | new | `IpcTxNetCellInfoList` @0x1f2838 | P H |
| NET_CELL_INFO 08/11 | CP→AP R/N | p0 n_gsm, p1 n_cdma, p2 n_lte, p3 n_wcdma (0xFF = 0). frame len must equal 11 + 13·g + 20·c + 27·l + 17·w. Records from p4: GSM 13 B {reg, mcc[3], mnc[3] ('#' pad), u16 lac, u16 cid, ss, ber}; CDMA 20 B; LTE 27 B {reg, mcc[3], mnc[3], u32 ci, u32 pci, u16 tac, ss, rsrp, rsrq, s16 rssnr, cqi, u32 ta}; WCDMA 17 B {reg, mcc[3], mnc[3], u16 lac, u32 cid, u16 psc, ss, ber} | — | new | `IpcRxNetCellInfoList` @0x1f5144 | P H |

**RAT ("act") values, common to REGIST, SERVING, PLMN_LIST and PLMN_SEL** (P H; `ConvertNetRatToIpc` @0x1f1710, table
@0x26dd10, plus the switches in the Rx parsers): 0x01 GSM, 0x02 GPRS, 0x03 EDGE, 0x04 UMTS, 0x05 UMTS (Rx only),
0x11 IS95A, 0x12 IS95B, 0x13 1xRTT, 0x14/0x15 EVDO-0, 0x16–0x18 EVDO-A, 0x19 eHRPD, **0x21 LTE**, 0x22 TD-SCDMA,
0x30 IWLAN, 0xFF any.

libsamsung-ipc defines only 0x00–0x04 and 0xFF, and its 0x00 "GSM" is unknown in IPC41. The HSPA variants are not
encoded in the RAT byte (they map to 0). They come from GPRS_HSDPA_STATUS 0D/0C (I M).

**Registration status values** (P H): 01/08 not registered, 02 home, 03 searching, **04/09 denied**, 06 roaming, 07/0A
emergency-only/limited, other values unknown. libsamsung-ipc names 04 "EMERGENCY" and 05 "UNKNOWN"; IPC41 treats 04 as
denied.

## 5. Calls

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| CALL_OUTGOING 02/01 (dial) | AP→CP E → GEN | **92 B**: p0..1 u16 call type, p2 CLIR (0 default, 1 hide, 2 show), p3 number length (≤82), p4 TON (0x21 national/unknown, **0x11 international** when the number starts with '+'), p5..90 number[86], **p91 extra int from caller**. Variant: 94 B, adds p92..93 = {1, len−1}. | `ipc_call_outgoing_data {unknown, type, identity, number_length, prefix, number[86]}` = 91 B; prefix NONE is 0x00 there | prefix (+1 B, TON 0x21) | `IpcTxCallOriginate` @0x1ddab4 (99-B frame) and @0x1ddbdc (101-B frame) | P H (p91 meaning I L) |
| Call type u16 (OUTGOING, STATUS, LIST) | — | Read as LE u16 = (type << 8) \| subtype, so p1 = type: 0x01 voice, 0x03 video, **0x07 emergency**, 0x08 another emergency variant (likely IMS/video, I); 0x05xx = IMS variants. Voice call = bytes 00 01; CS emergency = 00 07. | {unknown, type}, VOICE 0x01, DATA 0x03 | = for voice | `ConvertCallTypeToIpc` @0x1dda98, table @0x26d9b0. `CallManager::IsEmergencyCall` @0x124fd6: CallType 12/13/15 → 0x0700/0x0702/0x0801. | P H |
| CALL_INCOMING 02/02 | CP→AP N | not parsed; libsec-ril just signals "call state changed" and re-reads CALL_LIST | `ipc_call_incoming_data {unknown, type, id, line}` | unverified | `IpcRxCallIncoming` @0x1ced90 (disasm) | P H (layout not checked) |
| CALL_ANSWER 02/04 | AP→CP E → GEN | none | index only | = | `IpcTxCallAnswer` @0x1de10c | P H |
| CALL_RELEASE 02/03 (hang up current) | AP→CP E → GEN | none. Used by RIL HANGUP when only one call exists. | index only | = | `IpcTxCallRelease` @0x1de2b8, `CallManager::DoHangup` @0x12b054 | P H |
| SS_MANAGE_CALL 0C/07 (hold, swap, conference, release by id) | AP→CP **S** → GEN | **85 B**: p0 type, p1 call id (+1 if NeedCallIdPlusMinus), p2 number length, p3..84 number[82]. Types: 1 release held/waiting (CHLD=0, UDUB), 2 release active + accept (CHLD=1), **3 release one id (CHLD=1x)**, 4 swap/hold-accept (CHLD=2), 5 split (CHLD=2x), 6 conference (CHLD=3), 7 ECT (CHLD=4, optional number). | none | new | `IpcTxCallSetManageCall` @0x1de340; types from `CallManager::DoHangupWaitOrBg` @0x12b3e0, `…FgResumeBg` @0x12b2a0, `…SwitchWaitOrHoldAndActive` @0x12b508, `DoConference` @0x12b5b0, `DoSeparateConnection` @0x12b73c, `DoExplicitCallTransfer` @0x12b690, `DoHangup` | P H |
| CALL_HOLD 02/13 | AP→CP E | none | — | new | `IpcTxHoldCall` @0x1ded38 | P H (use vs MANAGE_CALL I) |
| CALL_LIST 02/06 | AP→CP G / CP→AP R | p0 count, then per call: u16 call type, id, term (1 = MO), status (1 active … 6 waiting), mpty, num_len, TON/NPI (&0x70 == 0x10 → international), number. Optional trailing fields only when CSC features are on: DualPhoneNumber, ShowRedirectCallNumber (len+number each), WaitingToneBySignalInfo (2 B), SupportTwoPhoneService (1 B). | `ipc_call_list_entry` (8 B) + number | = (if CSC extras absent) | `IpcRxCallList` @0x1df850; feature strings at the literals 0x1dfdd4/0x1dfe2c/0x1dfe08/0x1dfe18 | P H (extras absent on XXU2 I M) |
| CALL_STATUS 02/05 | CP→AP N | p0..1 call type, p2 id, p3 status (1 dialing, 2 ignoring, 3 connected, 4 released, 5 connecting), p4 cause type, p5 end cause | `ipc_call_status_data` (6 B) | = | `IpcRxCallStatus` @0x1df55c (cause via `GetReleaseCause` @0x1df2cc) | P H |
| CALL_BURST_DTMF 02/07 | AP→CP E | **84 B**: p0 tone type (1 or 2), p1 length (≤82), p2..83 digits | `{count}` + `{status, tone}`×n | **≠** | `IpcTxCallSendBurstDtmf` @0x1de46c | P H |
| CALL_CONT_DTMF 02/08 | AP→CP S | 2 B: start {0x01, digit}, stop {0x02, 0x00} | `ipc_call_cont_dtmf_data {status, tone}` | = | `IpcTxCallStartContDtmf` @0x1de578, `…StopContDtmf` @0x1de610 | P H |
| SS_WAITING 0C/01 (call waiting) | AP→CP G / S | G: p0 class. S: p0 class, p1 mode (table [4,3,3,1,2]). Class: voice 0x11, data 0x12, fax 0x13, SMS 0x16, all-tele 0x10, data-sync 0x24, data-async 0x25, packet 0x99, … | none | new | `IpcTxSsGetCallWaiting` @0x1fa110, `IpcTxSsSetCallWaiting` @0x1f9fe8 | P H |
| CALL_ECC_STATUS 02/17 (emergency call status) | AP→CP S | p0 E911 status, p1 RAT | — | new | `IpcTxCallSetEmergencyCallStatus` @0x1debf0 | P M (optional for CS) |

**Emergency call.** A CS emergency call is an ordinary CALL_OUTGOING with call type p1 = 0x07 (P). The CP also sends
an ECC list (CALL_ECCLIST 02/16 N, `IpcRxCallEccList`), which was not decoded.

## 6. SMS

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| SMS_SEND_MSG 04/01 | AP→CP E | p0 format (0x02 = 3GPP), p1 msg_type (**0x01 more-to-send**, 0x02 single), p2 domain (ConvertDomainToIPC: 0 → 0x02, 1 → 0x03, 2 → 0x00, 3 → 0x01), p3 length, p4.. SMSC+TPDU | `ipc_sms_send_msg_request_header {type, msg_type, unknown, length}` | = | `IpcTxSendSms` @0x1f85b0, `ConvertDomainToIPC` @0x1f83f4 | P H (p2 meaning I) |
| SMS_SEND_MSG 04/01 | CP→AP R/N | p0 format (1 = 3GPP2, 2 = 3GPP). 3GPP: p1..2 u16 ack/result, p3 msg ref, p4 pdu length, p5.. RP-ACK/ERROR TPDU. | `ipc_sms_send_msg_response_data {type, u16 ack, id, unknown}` | prefix (p4 = length) | `IpcRxSendMsg` @0x1f9170 (`GetSmsResult` @0x1f8370) | P H |
| SMS_INCOMING_MSG 04/02 | CP→AP N | p0 format (1 CDMA, 2 GSM), p1 type (1 = deliver, 2 = status report), p2..3 u16 SIM index, p4 msg id (for the ack), p5 length, p6.. SMSC+TPDU | `ipc_sms_incoming_msg_header {msg_type, type, u16 sim_index, id, length}` | = (byte 0 named differently) | `IpcRxIncomingMsg` @0x1f8f5c | P H |
| SMS_DELIVER_REPORT 04/06 (ack) | AP→CP E | 5 B: p0 format (2), p1..2 u16 ack (0 OK; 0x8080 memory full, 0x8016, 0x8081, 0x806F unspecified), p3 msg id, p4 = 0. With PDU: p4 = pdu length, p5.. pdu. | `ipc_sms_deliver_report_request_data` (5 B) | = (+ PDU form) | `IpcTxDeliveryReport` @0x1f8680, `…WithPdu` @0x1f8858 | P H |
| SMS_DELIVER_REPORT 04/06 | CP→AP R | p0..1 u16 ack | `ipc_sms_deliver_report_response_data` | = | `IpcRxDeliveryReportMsg` @0x1f8dfc | P H |
| SMS_SVC_CENTER_ADDR 04/0A (SMSC) | AP→CP G / S; CP→AP R | G: none. S: **12 B fixed**, SMSC bytes copied raw and zero-padded. R: whole payload = SMSC (parsed by `SmsCenter`). | `ipc_sms_svc_center_addr_header {length}` + data | likely = (I) | `IpcTxGetSmscAddress` @0x1f8960, `IpcTxSetSmscAddress` @0x1d8734, `IpcRxSmsc` @0x1f8e84 | P M |
| SMS_SAVE_MSG 04/04 (write to SIM) | AP→CP E | p0 storage, p1..2 u16 index (RIL index−1; 0xFFFF = any), p3 status (RIL+1), p4 length, p5.. pdu | `ipc_sms_save_msg_request_header` (5 B) | = | `IpcTxWriteSmsToSim` @0x1f8410 | P H |
| SMS_DEL_MSG 04/05 | AP→CP E | p0 storage, p1..2 u16 index−1 | `ipc_sms_del_msg_request_data` | = | `IpcTxDeleteMsg` @0x1d8604 | P H |
| SMS_READ_MSG 04/03, SMS_STORED_MSG_COUNT 04/09 | AP→CP G | READ: {storage, u16 index−1}. COUNT: {storage}. | — | new | `IpcTxGetReadMsg` @0x1d86d0, `IpcTxGetStoredMsgCount` @0x1d87f4 | P H |
| SMS_DEVICE_READY 04/07 | CP→AP N, then AP→CP **S** | none either way. The NOTI drives `SmsManager::OnDeviceReady`, which queues the SET. | index only | = | `IpcRxDeviceReady` @0x1d8d64, `IpcTxSetDeviceReady` @0x1d87a0 (disasm), `SmsManager::OnDeviceReady` @0x134ad4 | P H |
| SMS_MEM_STATUS 04/0C | AP→CP S / CP→AP N | S: p0 = 1 (memory available) or 2 (full). N: p0 = 2 (GSM), p1 = 1 available or 2 full. | — | new | `IpcTxSetMemStatus` @0x1d8850 (disasm), `IpcRxMemoryStatus` @0x1f92cc | P H (1/2 meaning I M) |

"More to send": libsec-ril encodes it in p1 = 0x01. LineageOS SlteRIL avoids RIL's EXPECT_MORE request, but the IPC
encoding exists (P).

## 7. USSD / SS

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| SS_USSD 0C/08 (send) | AP→CP E | **fixed 185 B, zero-padded**: p0 type (1 = new request, 2 = reply to a network request), p1 DCS (0x0F), p2 length, p3.. data (GSM 7-bit packed, ≤182) | `ipc_ss_ussd_header {state, dcs, length}` + data | prefix (fixed size) | `IpcTxSsSendUssd` @0x1fa7f0; pre-encoded form `IpcTxSsSendEncodedUssd` @0x1fa908 (p0 = 1, p1 = caller DCS) | P H |
| SS_USSD 0C/08 (cancel) | AP→CP E | 185 B with p0 = 0x03, rest zero | — | new use | `IpcTxSsCancelUssd` @0x1fa768 | P H |
| SS_USSD 0C/08 (receive) | CP→AP N | p0 state (1 no action, 2 action required, 3 terminated, 4 other client, 5 not supported, 6 timeout), p1 DCS, p2 length, p3.. data | `ipc_ss_ussd_header`, same state values | = | `IpcRxSsUssd` @0x1fb5b8 | P H |

## 8. Data (PDP, LTE bearer, rmnet)

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| GPRS_DEFINE_PDP_CONTEXT 0D/01 | AP→CP S → GEN | **127 B**: p0 enable (1), p1 cid, p2 PDP type (**0x02 IP, 0x05 IPv6, 0x06 IPv4v6, 0x04 PPP**), p3..102 APN[100], p103 0, p104..119 static IPv6, p120..123 static IPv4, p124..125 0, p126 flag (set from the PDP type when a bool argument is set) | `ipc_gprs_define_pdp_context_data {enable, cid, magic=0x02, apn[124]}` = 127 B | = size (APN tail must stay zero) | `IpcTxDefinePdpContext` @0x1e259c, PDP table @0x26bc3c = [2,5,6,4] | P H (DataProtocol order IP/IPV6/IPV4V6/PPP I M) |
| GPRS_PDP_CONTEXT 0D/04 (activate/deactivate) | AP→CP S → GEN | **105 B**: p0 action (1 activate, 0 deactivate, 2..6 other), p1 cid, **p2 flags** (bit0 user, bit1 password, bit4 auth type present), p3..5 0, p6..37 user[32], p38..69 password[32], p70..101 0, p102 auth type (none 0, PAP 1, CHAP 2, PAP/CHAP → 1), p103 0, p104 deactivation reason (table, action 0) | `ipc_gprs_pdp_context_request_set_data` = 103 B, **magic1[2] = 0x13 at p4**, magic2 = 1 at p102 | **≠** (size +2; flags at p2, not p4) | `IpcTxSetPdpContext` @0x1e2684, tables @0x26bc4c, @0x26dab0 | P H |
| GPRS_PDP_CONTEXT 0D/04 | AP→CP G / CP→AP R | R: p0 count, then {cid, state}: state 0x01 active, 0x0A/0x0B two other states, else inactive | `…_request_get_data {active_count, {cid, active}×3}` | = | `IpcTxGetPdpContext` @0x1d06ac, `IpcRxPdpContext` @0x1e3bd0 | P H |
| GPRS_IP_CONFIGURATION 0D/09 | CP→AP N | p0 cid, **p1..2 u16 flags** (0x0001 IPv4, 0x0040 IPv6, 0x2000 MTU, 0x4000 extra), p3..6 IPv4, p7..10 DNS1, p11..14 DNS2, p15..22 not read (gateway/mask in libsamsung-ipc), p23..34 3× IPv4 **P-CSCF**, p35..50 IPv6 addr, p51..98 3× IPv6 P-CSCF, p99..114 IPv6 DNS1, p115..130 IPv6 DNS2, p152..155 u32 **MTU**, p156 byte | `ipc_gprs_ip_configuration_data` 27 B {cid, field_flag, fail_cause, ip, dns1, dns2, gw, mask, unk} | prefix up to p14 (field_flag+fail_cause = u16 flags), then extended | `IpcRxIpConfiguration` @0x1e36b4. P-CSCF naming from the strings "ril.pcscfv4.%s%d.0..2" / "ril.pcscfv6…". | P H |
| GPRS_IP_CONFIGURATION 0D/09 | AP→CP S | 17 B: p0 cid, p1..16 IPv6 address/IID | none | new | `IpcTxIpv6Configuration` @0x1e2cc0 | P H (purpose I) |
| GPRS_CALL_STATUS 0D/10 (data call state) | CP→AP N | p0 cid, p1 status (0x01 up, 0x0A/0x0B other states, else down), p2 fail cause, p3 bool, p4 byte, p5..8 u32 (e.g. retry timer), p9 byte if frame > 16 B | `ipc_gprs_call_status_data {cid, status, fail_cause, external}` | prefix | `IpcRxGprsCallStatus` @0x1e3858 | P H |
| GPRS_PS 0D/03 (attach/detach) | AP→CP S | 3 B: attach {0x01, 0, 0}; detach {0x00, bool, reason 1..4} | `ipc_gprs_ps_data {cid, attached}` (the response struct) | ≠ | `IpcTxPsAttach` @0x1e27f4 | P H |
| GPRS_PS 0D/03 | CP→AP N/R | p0 attached (==1), p1 flag (==0), p2 cause 1..7 | `ipc_gprs_ps_data` | ≠ | `IpcRxGprsPsState` @0x1e3d10 | P H |
| GPRS_LTE_ATTACH_APN_INFO 0D/14 (LTE default bearer) | AP→CP S | **194 B**: p0..126 as DEFINE_PDP_CONTEXT, then p127..158 user[32], p159..190 password[32], p191 auth type, p192 roaming PDP type, p193 roaming flag. Sent only when protover = 2, which is the SS333 case. | none | new | `IpcTxSetLteAttachProfile` @0x1e2b18 | P H |
| GPRS_MOBILE_DATA_STATUS 0D/1D | AP→CP S | {enabled, roaming-enabled} | none | new | `IpcTxSetMobileDataSetting` @0x1d0834 | P H |
| GPRS_LTE_CA_STATUS 0D/19 | CP→AP N | p0 CA active, p1 aggregated bandwidth. If frame = 15 B (8-B payload): p3 byte (stored), p4 count 0..3, p5..p7 per-carrier values. | none | new | `IpcRxLteCaStatus` @0x1e4388. dmesg: 2 B. | P H |
| GPRS_PIN_CTRL 0D/0F (DUN V.24 lines) | AP→CP E / CP→AP N | 2 B: p0 line code (DataSignalLine 1 → 4, 2 → 7, 3 → 1, 4 → 6, 5 → 8, 6 → 9, else 0x0A), p1 on/off | index only | new struct | `IpcTxDunPinCtrl` @0x1d07a0 (disasm), `IpcRxDunPinControl` @0x1e3ccc | P H |

**rmnet mapping** (P H for the rule, I M for the prefix value). `GsmDataCallManager::CreateDataCallList` @0x176348
builds interfaces `"%s%d" % (Feature::mGsmNetInterfacePrefix, n)` for n = 0..4 and binds each to **cid = n + 1**. An
interface that does not exist is skipped. So cid 1 → rmnet0, …, cid 4 → rmnet3. The prefix is very probably "rmnet",
since that string is in `.rodata`. The DT has only rmnet0–3 (SIPC ch 10–13), so cids 1–4 are usable.

**Sequence used by libsec-ril** (I M, from the message set; per-step callers not traced):
1. LTE: send ATTACH_APN_INFO first.
2. DEFINE_PDP_CONTEXT S (cid, APN, type).
3. PDP_CONTEXT S (action 1, auth).
4. GEN_PHONE_RES.
5. Wait for the CALL_STATUS N (status 1) and IP_CONFIGURATION N.
6. Configure rmnet(cid−1) as raw IP.
7. Teardown: PDP_CONTEXT S with action 0.

## 9. Sound (voice calls)

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| SND_AUDIO_PATH_CTRL 09/03 | AP→CP S | **2 B**: p0 path, p1 extra (from the OEM request; 0 or an audio-HAL member) | `ipc_snd_audio_path_ctrl_data {path}` (1 B) | prefix (+1 B) | `IpcTxSndSetAudioPath` @0x1f9614. Bytes passed unchanged from the Multiclient OEM payload: `SoundManager::DoSetAudioPath` @0x130650 → `IpcModem::SetAudioPath` @0x1c460c → vtable 0x31c. | P H |
| **This build's path values** | — | Stock `libsecril-client.so` maps its enum (input value → IPC byte): 0 → **0x01 handset**, 1 → 0x02 headset, **2 → 0x06 speaker**, 3 → 0x04 BT, 4 → 0x05 stereo BT, **5 → 0x07 headphone**, 6 → 0x08 BT NR-off, 7 → 0x09 mic1, 8 → 0x0A mic2, 9 → 0x0B BT-WB, 10 → 0x0C BT-WB NR-off, 11..13 → 0x0D..0x0F; 0x17/0x18/0x27..0x2B/0x32..0x35 pass through; 0x1E..0x24 → 0x1F, 0x20, 0x24, 0x22, 0x23, 0x25, 0x26; 0x25/0x26 → 0x09/0x0A; any other value → 0x01. | IPC_SND_AUDIO_PATH_* HANDSET 1, HEADSET 2, BT 4, SPEAKER **6**, HEADPHONE **7**, BT_NO_NR **8** | = (libsamsung-ipc values are the right ones) | `libsecril-client.so` SetCallAudioPath @0x327c → map @0x33cc (tbb table decoded). The OEM header is {08 05 00 06 path extra}. | P H (enum names I M, from AOSP order) |
| SND_SPKR_VOLUME_CTRL 09/01 | AP→CP S | p0 type (0x01 voice, 0x11 speaker, 0x31 headset, 0x41 BT), p1 level | `ipc_snd_spkr_volume_ctrl_data` | = | `IpcTxSndSetVolume` @0x1f9580 | P H |
| SND_MIC_MUTE_CTRL 09/02 | AP→CP S / G; CP→AP R | S: p0 mute (0..5). G: none. R: p0 1..5. | `ipc_snd_mic_mute_ctrl_data {mute}` | = | `IpcTxSndSetMute` @0x1f93d8, `IpcTxSndGetMute` @0x1f9470, `IpcRxSndMute` @0x1f9bf4 | P H |
| SND_CLOCK_CTRL 09/09 | AP→CP **E** | p0 condition: 0 stop, 1 start. libsec-ril turns 2 into 0. A STOP arriving during an active call is answered locally and **not sent**. | `ipc_snd_clock_ctrl_data {sync}`, samsung-ril uses EXEC | = | `IpcTxSndSetClockCtrl` @0x1f9864, `SoundManager::DoOemSetClockCtrl` @0x1307b4 | P H |
| SND_CLOCK_CTRL 09/09 | **CP→AP N** | p0 1..7 → table [1,0,3,0,5,0,7] (odd = clock on, even = off); raised to the audio HAL as RIL_UNSOL_SNDMGR_CLOCK_CTRL | none | new | `IpcRxSndClockCtrl` @0x1f9c6c, table @0x26de70 | P H (on/off reading I M) |
| SND_WB_AMR_RPT 09/0A | CP→AP N; AP→CP G | N/R: p0 = 1..8 codec/rate report (0 = NB) → RIL_UNSOL_SNDMGR_WB_AMR_REPORT. G: none. | index only ("WB_AMR_STATUS") | new struct | `IpcRxSndWbAmrReport` @0x1f9c44, `IpcTxSndGetWbAmr` @0x1f9a48 | P H (value meanings I) |
| SND_LOOPBACK_CTRL 09/05 | AP→CP S | 1 or 2 raw bytes from the OEM request (path/on-off) | index only | new struct | `IpcTxSndSetLoopbackCtrl` @0x1f9738 | P H (semantics I) |
| SND_TWO_MIC_SOL_CTRL 09/0B, SND_AUDIO_MODE_CTRL 09/0D, SND_CLOCK_MODE_CTRL 09/0E | AP→CP S | 2 B, 2 B and 1 B raw OEM values | — | new | `IpcTxSndSetTwoMicCtrl` @0x1f98f4, `…AudioMode` @0x1f9ad0, `…ClockMode` @0x1f9b64 | P H (semantics I) |

**Consequence for the WM1814/AIF2 work.** Two findings change the plan:

- **Speaker path is 0x06, not 0x07.** This firmware's stock audio stack sends speaker = 0x06 and headphone = 0x07,
  the libsamsung-ipc values. The LineageOS `SAMSUNG_NEXT_GEN_MODEM` table (speaker 0x07, headphone 0x08) is **not**
  what stock uses.
- **The CP reports its own PCM clock state** with SND_CLOCK_CTRL NOTI. A daemon can sequence FLL2/AIF2 on that event
  instead of guessing.

## 10. Misc, time, periodic and start-up

| Message | Dir / type | Payload (IPC41) | libsamsung-ipc | Match | Evidence | Mark |
|---|---|---|---|---|---|---|
| MISC_TIME_INFO 0A/05 (NITZ) | CP→AP N | **18 B**: p0 type/valid (only 1, 2, 5 accepted), p1 DST-valid, p2 year (yy, < 37), p3 mon, p4 day, p5 h, p6 m, p7 s, p8 tz (signed quarter-hours), p9 DST, p10 ?, **p11 new byte (0/1)**, **p12..17 PLMN** | `ipc_misc_time_info_data` 17 B, plmn at p11 | **≠ (PLMN shifted +1)** | `IpcRxMiscTimeInfo` @0x1ee6a4 | P H |
| MISC_TIME_INFO 0A/05 | AP→CP G / S | G: none. S: 11 B, p0 = 3, p1 = 0, then RTC date and time (field order as NOTI) | — | — | `IpcTxGetTimeInfo` @0x1ebad0, `IpcTxSetTimeInfo` @0x1eb578 | P H (G); S layout I L (decompiler lost stores) |
| MISC_SCREEN_STATUS 0A/0F | AP→CP **V** (no answer) | p0 = 1 screen on / 0 off | none (IPC40 used 0x0D) | new | `IpcTxSetScreenState` @0x1ef6dc. dmesg: 1 B, 7×, unanswered. | P H |
| MISC_GRIP_SENSOR_STATUS 0A/10 | AP→CP V | 4 B u32 state | none | new | `IpcTxMiscEventGripSensorStatus` @0x1ed478. dmesg: 4 B. | P H |
| MISC_MODEM_ACTIVITY_INFO 0A/50 | AP→CP G | none; this CP answers with GEN_PHONE_RES (unsupported) | none | new | `IpcTxGetActivityInfo` @0x1ee158; dmesg aseq pairing | P H |
| MISC_IPC_LOOPBACK 0A/23 | CP→AP (any type), AP→CP **C** | Rx: p0..1 u16 → AP echoes it in CFRM `{u16}` | none | new | `IpcRxMiscIpcLoopback` @0x1eedda → `IpcTxMiscCfrmIPCLoopbackTest` @0x1eedec | P H |
| SAT 0E/0D (SAT_SIM_INITIATE_MESSAGE) | AP→CP V | none | not defined (SAT stops at 0x0C) | new | `IpcTxSimInitMessage` @0x1fc0c0 | P H (name I M, from the `strings` list) |

**Start-up and "required" traffic.**

- **Proven gates and replies.**
  - The CP announces itself with PWR_PHONE_PWR_UP N, followed by PWR_PHONE_STATE N, SEC_PIN_STATUS N,
    SEC_SIM_ICC_TYPE N and SMS_DEVICE_READY N.
  - The AP must not GET SEC_PIN_STATUS before the first PIN_STATUS NOTI (gate at `IpcTxGetPinStatus`).
  - The AP must answer SMS_DEVICE_READY with SMS_DEVICE_READY S.
  - The AP must answer MISC_IPC_LOOPBACK with a CFRM.
- **Inferred minimal bring-up order** (I M):
  1. PWR_PHONE_STATE E 0x0202 (radio on).
  2. NET_REGIST G for CS and for PS.
  3. NET_SERVING_NETWORK G.
  4. DISP_ICON_INFO G.
  5. SEC_PIN_STATUS / SEC_SIMAPPS_INFO G.
  6. NET_MODE_SEL S.
  7. LTE ATTACH_APN_INFO S.
- **Periodic.** The CP sends DISP_RSSI_INFO and ICON_INFO NOTIs on its own. Everything periodic in the stock log is
  AP-initiated and optional: screen and grip events, cell-info polling, modem-activity GETs. The only periodic need
  found is cell-info polling if the UI wants it. The RFS NV service on umts_rfs0 is required at CP boot; see bring-up
  §5.

---

## 11. (a) dmesg header check: frame length vs libsamsung-ipc payload size

All 19 distinct tuples (94 `IOD-*` + 92 `LNK-*` lines; header bytes only) are consistent with the libsec-ril builders and parsers
above. Against libsamsung-ipc:

| Tuple (main/sub/type, dir) | Count | Payload len | libsamsung-ipc struct (size) | Verdict |
|---|---|---|---|---|
| 07/01/02 TX (ICON GET) | 3 | 1 | icon_info_request (1) | = |
| 07/01/02 RX, 07/01/03 RX (ICON R/N) | 3 + 4 | 10 | icon_info_response (4) | IPC41 longer (+6 LTE bytes) |
| 07/06/03 RX (RSSI N) | 4 | 9 | rssi_info_data (1) | longer (+8) |
| 08/02/02 TX / RX (PLMN_SEL) | 3 / 3 | 0 / 1 | — / plmn_sel_response (1) | = |
| 08/03/02 TX / RX (SERVING) | 3 / 3 | 0 / 26 | — / serving_network_data (11) | longer (+15) |
| 08/05/02 TX / RX (REGIST) | 6 / 6 | 2 / 19 | regist_request (2) / regist_response (11) | = / longer (+8) |
| 08/11/02 TX / RX (CELL_INFO) | 10 / 10 | 0 / 548 | none | new |
| 0a/0f/05 TX (SCREEN EVENT) | 7 | 1 | none | new |
| 0a/10/05 TX (GRIP EVENT) | 2 | 4 | none | new |
| 0a/50/02 TX (MODEM_ACTIVITY GET) | 8 | 0 | none | new; answered by GEN |
| 0d/0f/01 TX / 0d/0f/03 RX (PIN_CTRL) | 1 / 1 | 2 / 2 | none (index only) | new struct |
| 0d/19/03 RX (LTE_CA N) | 8 | 2 | none | new |
| 80/01/02 RX (GEN_PHONE_RES) | 9 | 5 | gen_phone_res_data (5) | = |

Every RX frame that libsamsung-ipc knows (except GEN and PLMN_SEL) is **longer** in IPC41. In each case the libsec-ril
parser shows the libsamsung-ipc struct is a correct prefix (§4). A libsamsung-ipc parser that checks
`size >= sizeof(struct)` keeps working. One that checks `size == sizeof` would reject these frames (I M; libsamsung-ipc
mostly checks `<`).

## 12. (b) Reuse classification of libsamsung-ipc codecs

**Reusable unchanged.** The layout is identical, or a prefix that the decoder reads safely. All are P H unless noted.

- PWR: PHONE_STATE request and response; PWR_UP, PWR_OFF.
- MISC: ME_VERSION request and response (prefix); ME_IMSI; ME_SN.
- SEC: PIN_STATUS request (19 B) and response (prefix); PHONE_LOCK get, set and response; RSIM_ACCESS response;
  SIM_ICC_TYPE; LOCK_INFORMATION response.
- NET:
  - REGIST request; REGIST response (prefix);
  - SERVING_NETWORK (prefix: unknown[1] = status, unknown[2] = RAT);
  - PLMN_SEL request and response; PLMN_LIST entries (rename `type` → act).
- DISP: ICON_INFO request and response (prefix); RSSI_INFO (prefix, byte 0 is −dBm).
- CALL:
  - OUTGOING (91 + 1 trailing byte: the CP takes a 92-B payload, so append one zero; use TON 0x21/0x11, not 0x00);
  - ANSWER, RELEASE (no data); STATUS; LIST entry (8 B + number); CONT_DTMF.
- SMS: SEND_MSG request header; SEND_MSG response (prefix); INCOMING_MSG header; SAVE_MSG; DEL_MSG; DELIVER_REPORT
  request and response; SVC_CENTER_ADDR response.
- SS: USSD receive header. USSD send works if padded to 185 B (I M: the CP may also accept shorter).
- SND: SPKR_VOLUME_CTRL; MIC_MUTE_CTRL; CLOCK_CTRL (EXEC).
- GPRS:
  - DEFINE_PDP_CONTEXT (127 B; keep the APN ≤ 99 bytes so the tail stays zero; magic 0x02 = IP);
  - PDP_CONTEXT GET response;
  - IP_CONFIGURATION (prefix for IPv4 address and DNS only);
  - CALL_STATUS (prefix).
- GEN: PHONE_RES.

**Needs an IPC 4.1 variant or a fix** (P H):

- SEC_RSIM_ACCESS request: new 37-B header with AID and path.
- SEC_LOCK_INFORMATION request: 9 B.
- SEC_CHANGE_LOCKING_PW: PIN2 facility 0x09, not FD 0x04.
- NET_MODE_SEL: bitmask values instead of enumerated values.
- MISC_TIME_INFO: PLMN at p12.
- SND_AUDIO_PATH_CTRL: 2-byte payload.
- CALL_BURST_DTMF: {type, len, digits[82]}.
- GPRS_PDP_CONTEXT SET: 105 B, auth flags at p2.
- GPRS_PS: attach/detach request {attach, flag, reason} and a different response.
- GPRS_IP_CONFIGURATION: full layout with IPv6, P-CSCF and MTU, needed for IPv4v6.
- NET_REGIST response: TAC and PCI for LTE.

**Entirely new, no libsamsung-ipc definition** (P H):

- NET: CELL_INFO 08/11; IDENTITY 08/0C names; PLMN_LIST cancel (S).
- DISP: RSSI_INFO G/S config.
- SS: MANAGE_CALL 0C/07; WAITING 0C/01.
- CALL: HOLD 02/13; ECC_STATUS 02/17; ECCLIST 02/16.
- SMS: READ_MSG / STORED_MSG_COUNT requests; MEM_STATUS 04/0C.
- SEC: SIMAPPS_INFO 05/0F; SIM_POWER 05/0D; ICCID 05/0C; ATR 05/0A.
- GPRS: LTE_ATTACH_APN_INFO 0D/14; MOBILE_DATA_STATUS 0D/1D; LTE_CA_STATUS 0D/19; PIN_CTRL payload;
  IPv6 IP_CONFIGURATION S.
- SND: CLOCK_CTRL NOTI; WB_AMR report; LOOPBACK, TWO_MIC, AUDIO_MODE, CLOCK_MODE.
- MISC: SCREEN_STATUS 0A/0F; GRIP 0A/10; MODEM_ACTIVITY 0A/50; IPC_LOOPBACK 0A/23 CFRM.
- PWR: PHONE_RESET payload.
- SAT: 0E/0D.

## 13. What remains unknown

- **Unknown fields.**
  - NET_SERVING_NETWORK p0, p11..17, p24..25.
  - NET_REGIST p15, p18.
  - CALL_OUTGOING p91.
  - GPRS_CALL_STATUS p3..8 meaning.
  - IP_CONFIGURATION p15..22 and the 0x4000 byte.
  - CLOCK_CTRL NOTI and WB_AMR value semantics.
  - TIME_INFO SET exact layout.
- **CALL_INCOMING payload.** libsec-ril never parses it, so the libsamsung-ipc struct is unverified.
- **Fixed sizes.** Whether the CP accepts shorter-than-stock frames: USSD 185 B fixed, DEFINE_PDP 127 B,
  PDP_CONTEXT 105 B. A daemon should send the stock sizes.
- **CSC-feature trailing fields in CALL_LIST** (dual number, redirect, waiting tone, two-phone). They are assumed
  absent on T715XXU2 but this is not checked.
- **Enum names on the AP side.** These are inferred from code order and AOSP names: the stock audio-HAL path enum,
  libsec-ril's CallType, DataProtocol, DeviceInfoType and PinType 3.
- **Not looked at.** SAT/STK, CB SMS, SS barring/forwarding/CLIR, IMS/VoLTE (group 0x16), EMBMS. RFS lives on a
  separate channel.
- **GEN_PHONE_RES error codes.** The 0x81xx/0x84xx/0x85xx → RIL error mapping is located (`ConvertGenCmdError`
  @0x1cbee8) but not tabulated.

Working files stay outside the repository.