# shannond

`shannond` is the userspace daemon for the Shannon SS333 modem of the SM-T715 (Samsung IPC 4.1,
protover 2). It is the only process that opens `/dev/umts_ipc0` (FMT control) and `/dev/umts_rfs0`
(the RFS file and NV service the CP calls). It turns the IPC traffic into an aggregated state, events
and asynchronous commands. Two clients sit on top of it: the ModemManager facade (`shannond/mm/`,
written separately) and the `shannonctl` CLI, which goes through a JSON-lines control socket.

The protocol facts come from `research/modem/research/SYNTHESIS.md` (§2.9 device semantics, §2.11 IPC,
§2.12 RFS, §2.14 data, §2.15 audio, decisions D5 to D9) and from
`research/modem/research/analysis/ipc41_catalogue.md` (message layouts and sizes).

License: GPL-2.0-or-later. The code is new; the structures follow libsamsung-ipc and samsung-ril.
Nothing comes from the Samsung blobs.

**Status:** everything here was tested offline against a fake modem (`tests/fake_modem.py`).
None of it has run on the tablet yet.

## Design choices

- **Python 3.11 or later, standard library only for the core.** Payloads will need fast iteration on
  the device, which argues for Python. Decision D5 had planned C.
- **Event loop:** `shannond/loop.py` defines a small callback interface: `add_reader`, `remove_reader`,
  `call_later` returning a handle with `cancel()`, `call_soon`, `add_signal_handler`, `run` and `stop`.
  There are two implementations:
  - `GLibLoop` is the production loop on the tablet. It uses `GLib.io_add_watch` for file descriptors
    and `GLib.timeout_add` for timers. With it, the python-dbus ModemManager facade
    (`DBusGMainLoop`) runs in the same process.
  - `SelectorLoop` uses only the standard library (`select.poll`). The unit tests run on it on the
    Mac, where `gi` is absent.

  `--loop auto`, the default, picks GLib when PyGObject is importable. The core never imports `gi`.
- **Callback commands, generator sequences.** Every command takes `done(ok, result_or_error)` as its
  last argument. Internally, multi-step sequences (radio on, data up, the call audio order) are
  generators that yield `Op` objects, which are minimal futures (`loop.spawn`). This keeps them
  readable without asyncio and works on both loops.
- **RFS on its own thread, with its own fd and loop** (`RfsService`). Large NV replies and short-write
  retries never stall the FMT side. SYNTHESIS v2 D6 recommends a separate sandboxed process; that form
  exists too (`bin/shannon-rfsd`, run shannond with `--no-rfs`). The thread is the default for now: it
  is the simpler deployment, and the confinement does not depend on the process boundary.

## Layout

| Path | Role |
|---|---|
| `shannond/loop.py` | event loops (GLib and selectors), `Op` future, `spawn` trampoline |
| `shannond/ipc.py` | FMT framing, `FmtChannel` (fd owner), `IpcClient` (mseq, ack matching, timeouts) |
| `shannond/defs.py` | protocol constants and names |
| `shannond/messages.py` | payload encoders and decoders, with sizes checked against the catalogue |
| `shannond/sms_pdu.py` | SMS-SUBMIT encoder, SMS-DELIVER and STATUS-REPORT decoder, concatenation |
| `shannond/rfs.py` | RFS server in observe mode (framing, NV copy, file sandbox), `RfsService` (thread or process), `shannon-rfsd` entry point |
| `shannond/cpstate.py` | parser for the loader's session file `/run/shannon/cp-state` |
| `shannond/core.py` | `ModemCore`: state, events, commands |
| `shannond/netcfg.py` | rmnet configuration (published for an external manager, or applied with iproute2) |
| `shannond/control.py` | control socket server |
| `shannond/daemon.py` | daemon entry point (`python3 -m shannond`) |
| `shannond/ctl.py` | `shannonctl` client |
| `bin/shannond`, `bin/shannonctl`, `bin/shannon-rfsd` | wrappers that work from a checkout or from `/usr/lib/shannond` |
| `../systemd/shannond.service` | systemd unit, not enabled |
| `tests/` | unittest suites and the fake modem |

## Running

```sh
# on the tablet, after the loader has brought the CP to ONLINE
python3 -m shannond                      # or bin/shannond
python3 -m shannond --passive            # gate G12: mandatory replies only
python3 -m shannond --mm                 # also attach the ModemManager facade (needs gi + dbus)
bin/shannonctl status
bin/shannonctl radio on
```

Options:

| Option | Default | Meaning |
|---|---|---|
| `--ipc PATH` / `--rfs PATH` | `/dev/umts_ipc0` / `/dev/umts_rfs0` | device paths; a pty or socket path works for tests (byte streams are reassembled) |
| `--no-rfs` | off | do not open or serve RFS |
| `--passive` | off | answer only `SMS_DEVICE_READY` (SET), `MISC_IPC_LOOPBACK` (CFRM) and RFS. Send nothing else; every command is refused. Gate G12. |
| `--log-payload DIR` | off | also write payload hex dumps to `DIR` (files 0600). These contain identifiers, so keep them in `$T715_PRIVATE/`. |
| `--control PATH` | `/run/shannond/control` | control socket, mode 0660, owned by `root:radio` when run as root |
| `--loop auto\|glib\|selectors` | `auto` | event loop |
| `--mm` | off | `from shannond.mm import attach; attach(core, loop)` after the core is created, before the loop runs. Fails with a clear error if gi or dbus is missing. |
| `--nv-seed PATH` | `/var/lib/shannon/nv/nv_data.bin` | verified NV snapshot, opened read-only. `none` disables the NV verbs. |
| `--efs-lower PATH` | `/var/lib/shannon/efs-root` | read-only lower layer for RFS file verbs, if present |
| `--rfs-upper PATH` | `/run/shannond/rfs` | writable tmpfs layer for RFS file verbs |
| `--configure-ip` | off | configure rmnet with iproute2 (otherwise the configuration is only published) |
| `--route-metric N` | 700 | metric of the rmnet default route. NetworkManager gives Wi-Fi 600, so Wi-Fi stays preferred. |
| `--no-default-route`, `--configure-dns` | off | with `--configure-ip`: add no default route; push DNS to systemd-resolved |
| `--data-state-dir DIR` | `/run/shannond/data` | where `rmnetN.json` is published |
| `--audio-hook CMD` | none | run `CMD open\|close RATE PATH` when call audio must open or close (see Audio) |
| `--audio-path` | `speaker` | `speaker` (0x06), `headphone` (0x07), `handset` (0x01), `headset` (0x02) |
| `--no-mode-sel` | off | do not send `NET_MODE_SEL` SET 0x0B on radio on |
| `--smsc cp\|empty` | `cp` | SMSC for outgoing SMS: ask the CP (`SMS_SVC_CENTER_ADDR` GET, cached) or send an empty SMSC (`00`) |
| `--cp-state PATH` | `/run/shannon/cp-state` | the loader's session file (`session=N state=...`), used by the restart contract. `''` disables it, and the fd is then re-armed with a backoff. |
| `--restore-radio` | off | after a CP restart, send radio on again if it was on. By default shannond only re-syncs with GETs, as v2 D5 specifies. |
| `--rfs-inline` | off | serve RFS on the main loop instead of its own thread (debugging) |

## Protocol behaviour

- **Writes:** the kernel truncates every `write()` on `umts_ipc0` and `umts_rfs0` to the 2048-byte SBD
  uplink slot and returns the short count. It can also fail with `-EBUSY` when 1024 skbs are queued.
  Both channels therefore loop over short writes and retry EINTR, EAGAIN and EBUSY with 10 ms pauses,
  like the stock `IoChannel::Write` (SYNTHESIS v2 §2.9, §2.12, C54). They give up after 5 s.
- **Framing:** each FMT frame is a 7-byte header `{u16 len, u8 mseq, u8 aseq, u8 main, u8 sub,
  u8 type}` followed by the payload, written with one `write()` per frame. The AP's `mseq` runs from
  1 to 254 and wraps; `aseq` is always 0. A RESP or GEN is matched to its request through its
  `aseq`.
  - A GET waits for a RESP. A GEN error aborts it (an unimplemented GET is answered by GEN).
  - An EXEC or SET waits for `GEN_PHONE_RES` 80/01. Code 0x8000 means OK; any other code fails the
    command with `GEN code 0x....`.
  - `SMS_SEND_MSG` waits for its RESP, or for the NOTI form; a GEN OK received first is ignored.
  - CFRM and EVENT expect no answer.
- **Default timeouts:** 10 s per request, 60 s for SMS and for data up.
- **Hang-ups:** a 0-byte read on the real device means "idle". On a socket or pty it means EOF.
  `POLLHUP` triggers the `STATUS` ioctl (0x6F27):
  - 7 or 8 means a SIM change, which STATUS consumes. Nothing else happens: SIM presence comes from
    `SEC_PIN_STATUS` NOTIs only.
  - 4 is treated as spurious.
  - Any other value (2, 1 or 0, and also 3, 5 or 6) starts the restart contract below.
- **Restart contract** (SYNTHESIS v2 D5). The loader keeps both fds open across CP restarts and
  publishes `session=N state=...` in `/run/shannon/cp-state`. shannond then:
  1. closes call audio: the hook gets `audio {open: false}` first;
  2. ends calls (`call` events with state `released`, reason `modem restart`) and bearers (`data`
     with `connected: false`), then emits `crash` and sets `cp` to `crashed`, `power` to `off` and the
     SIM, registration and signal fields to unknown;
  3. drains its RX queue until `read` returns nothing;
  4. resets `mseq`, so the next request is 1;
  5. tells the RFS thread to drop its queued requests and handles and re-seed the NV copy, then waits,
     with the reader paused, for a new session in `state=online` in the session file;
  6. discards every frame, including the frames that normally get a mandatory reply, until the next
     `PWR_PHONE_PWR_UP` NOTI;
  7. re-syncs with GETs: `CALL_LIST`, `SEC_PIN_STATUS` (gated on the first PIN NOTI), `NET_REGIST` for
     CS and PS, `NET_SERVING_NETWORK` and `DISP_ICON_INFO`.

  Radio power is not restored unless `--restore-radio` is given. The facade can call `radio_on` again
  once `cp` is `online`. Restarting shannond while the CP is ONLINE sends nothing to the CP.
- **Start-up** (catalogue §10): the CP announces itself with `PWR_PHONE_PWR_UP` N, `PHONE_STATE` N,
  `SEC_PIN_STATUS` N, `SEC_SIM_ICC_TYPE` N and `SMS_DEVICE_READY` N. shannond answers
  `SMS_DEVICE_READY` S and `IPC_LOOPBACK` CFRM (echoing the u16), and sends nothing else until
  `radio_on`.
- **`radio_on`:** sends `PWR_PHONE_STATE` E 0x0202, then in the background `SEC_PIN_STATUS` G (only
  after the first PIN_STATUS NOTI, which is the stock gate), `NET_REGIST` G for CS (2) and PS (3),
  `NET_SERVING_NETWORK` G, `DISP_ICON_INFO` G and `NET_MODE_SEL` S 0x0B. NOTIs keep the state current
  afterwards.
- **SIM:** when the SIM is locked, `SEC_LOCK_INFORMATION` G (9 bytes, PIN1) fetches the retry count.
  shannond never sends a PIN on its own; only `enter_pin` does, and the PIN is never logged or stored.
- **Unknown or undecodable frames** are logged by header and ignored.
- **Emergency calls are refused, hard-coded:** the numbers 112, 911, 15, 17, 18, 115, 119, 999, 000,
  08 and 110 (after stripping separators and a leading `+`), and the call types 0x07 and 0x08.

## Internal Python API (for the ModemManager facade)

```python
from shannond.loop import GLibLoop
from shannond.core import ModemCore, CoreConfig
from shannond.rfs import RfsServer

loop = GLibLoop()
core = ModemCore(loop, ipc_path="/dev/umts_ipc0", rfs_path="/dev/umts_rfs0",
                 rfs_server=RfsServer("/var/lib/shannon/nv/nv_data.bin", "/run/shannond/rfs"),
                 passive=False, config=CoreConfig())
unsubscribe = core.subscribe(lambda event, data: ...)
core.start()
loop.run()
```

Constructor keywords: `ipc_fd=` and `rfs_fd=` take already-open descriptors (used by the tests);
`netcfg=` takes a `NetConfig`; `payload_log_dir=` and `audio_hook_cmd=` match the CLI options.
`core.stop()` closes everything.

### `core.state`

`core.state` is a live dict; treat it as read-only. A full copy is emitted as the `state` event every
time it changes, with several updates in one loop turn coalesced into one event.

```python
{
  "cp": "offline" | "online" | "crashed",
  "power": "off" | "lpm" | "on",
  "sim": {"state": "absent" | "locked" | "ready" | "error" | "unknown",
          "pin_retries": int | None, "puk_retries": int | None,
          # extra keys:
          "lock": None | "sim-pin" | "sim-puk" | "blocked" | "sim-pin2" | "ph-net-pin" | ...,
          "icc_type": None | "sim" | "usim" | ...},
  "reg": {"cs": "idle" | "home" | "searching" | "denied" | "unknown" | "roaming",
          "ps": same values,
          "rat": "gsm" | "umts" | "lte" | None,
          "mcc": str | None, "mnc": str | None, "operator": str | None},
  "signal": {"percent": int | None, "rssi_dbm": int | None},
  # extra keys:
  "calls": [{"id", "state", "direction", "number", "type"}],
  "data": None | <the 'data' event dict>,
  "audio": {"open": bool, "rate": 8000 | 16000},
  "passive": bool,
  # only after query_identity():
  "imei", "imsi", "iccid", "own_number", "revision"
}
```

Value mappings:

- **Registration** (catalogue §4): 1 and 8 → idle, 2 → home, 3 → searching, 4 and 9 → denied,
  6 → roaming, 7 and 0x0A (limited service) → idle, anything else → unknown.
- **`rat`:** the access technology of the registered domain (PS first, then CS), else the one from
  SERVING_NETWORK.
- **`signal.percent`:** derived from LTE RSRP when present (−140 to −44 dBm), else from RSSI (as ASU),
  else from the icon bars.

`own_number` is always `None` for now: no IPC message gives the MSISDN without SIM file access.

### Events: `cb(event: str, data: dict)`

Callbacks run synchronously from the loop, and each one receives its own deep copy of the data.

| Event | Data |
|---|---|
| `state` | full copy of `core.state` |
| `sms-received` | `{index, sender, text, timestamp (ISO 8601), pdu_hex}` plus `parts_hex` (the PDUs of a concatenated message) and `encoding`. If decoding fails, `text` and `sender` are `None` and an `error` key is added. |
| `sms-sent` | `{ref, ok, error}` |
| `sms-status-report` | `{ref, status, delivered}` (extra) |
| `call` | `{id, state, number, direction, reason}`, with `state` one of `dialing`, `alerting`, `active`, `held`, `incoming`, `waiting`, `released` and `direction` `in` or `out`. `reason` is set on release. |
| `data` | `{connected: bool, cid, interface, ipv4: {address, prefix, gateway, dns: [...], mtu} \| None, ipv6: {...} \| None}`, plus `reason` when the connection goes down |
| `audio` | `{open: bool, rate: 8000 \| 16000}` plus `fallback`. This is the audio hook; see Audio. |
| `crash` | `{}` |

### Commands

All commands are asynchronous. `done(ok: bool, result_or_error)` comes last and may be omitted. It is
always called later from the loop, never re-entrantly. On failure, `result_or_error` is a string.
Every command except `list_sms`, `delete_sms` and `list_calls` is refused in passive mode with
`"passive mode: command refused"`.

| Method | Result |
|---|---|
| `radio_on(done)` / `radio_off(done)` | `{power}` |
| `enter_pin(pin, done)` | `{}`. Never called automatically. |
| `enter_puk(puk, new_pin, done)` | `{}` (extra) |
| `pin_status(done)` | the `sim` dict, after `SEC_PIN_STATUS` G and `SEC_LOCK_INFORMATION` G |
| `send_sms(number, text, done, request_status_report=False)` | `{ref, refs, parts}`. GSM 7-bit or UCS2, concatenated automatically. |
| `list_sms(done)` / `delete_sms(index, done)` | list of `sms-received` dicts / `{index}`. Storage is in memory only. |
| `dial(number, done)` | `{id}`, once the CP reports the call. Refuses emergency numbers and types. |
| `answer(id, done)` / `hangup(id, done)` | `{id}`. `hangup` sends `CALL_RELEASE`, or `SS_MANAGE_CALL` type 3 when several calls exist. |
| `send_dtmf(id, digits, done)` | `{id, digits}` via `CALL_CONT_DTMF` start/stop |
| `list_calls(done)` | the `calls` list (extra) |
| `data_connect(apn, ip_type, user, password, done, auth=None, cid=1)` | the `data` event dict |
| `data_disconnect(done)` | `{connected: False, cid}` |
| `query_identity(done)` | `{imei, imsi, iccid, own_number, revision}`, also stored in `state`; never logged |
| `raw(main, sub, type, payload_bytes, done)` | `{ok, gen_code, main, sub, type, payload_hex}` (debugging) |
| `refresh(done)`, `scan_networks(done)`, `set_audio_path(path, done)`, `set_mic_mute(mute, done)` | extras |

After a `crash` event, commands fail with `modem crashed` until `state.cp` is `online` again, which
happens after the next `PWR_PHONE_PWR_UP`; see the restart contract.

Details:

- **`data_connect`:** `ip_type` is `ipv4`, `ipv6` or `ipv4v6`. `auth` defaults to `chap` when
  credentials are given, else `none`.
- **`refresh`** re-runs the queries `radio_on` makes.
- **`scan_networks`** returns `[{status, plmn, rat}]`.

`core.network_time` holds the last NITZ (`{time, tz_minutes, dst}`). `core.stats()` returns frame
counters, mandatory-reply counts and RFS statistics.

## Control socket API (`/run/shannond/control`)

The socket speaks JSON lines: one request per line, one reply per line. Requests may be pipelined;
the `id` is echoed.

```json
{"id": 1, "cmd": "status", "args": {"stats": true}, "identifiers": false}
{"id": 1, "ok": true, "result": {...}}
{"id": 2, "ok": false, "error": "emergency calls are refused by shannond: use a certified phone"}
```

Without `"identifiers": true`, results are redacted:

- operator code and name, IMEI, IMSI, ICCID, IP addresses, DNS and gateway become `"<redacted>"`;
- numbers are masked as `+CC*******NN`;
- SMS text becomes `"<N chars>"`.

| cmd | args | maps to |
|---|---|---|
| `ping` | — | `{version}` |
| `status` | `stats?` | `core.state` (and `core.stats()`) |
| `radio` | `on: bool` | `radio_on` / `radio_off` |
| `refresh`, `pin-status` | — | `refresh`, `pin_status` |
| `pin-enter` | `pin` | `enter_pin` |
| `puk-enter` | `puk, pin` | `enter_puk` |
| `sms-send` | `number, text, status_report?` | `send_sms` |
| `sms-list` / `sms-delete` | — / `index` | `list_sms` / `delete_sms` |
| `call-dial` | `number` | `dial` |
| `call-answer` / `call-hangup` | `id?` | `answer` / `hangup` |
| `call-list` | — | `list_calls` |
| `call-dtmf` | `id, digits` | `send_dtmf` |
| `audio-path` / `mic-mute` | `path` / `mute` | `set_audio_path` / `set_mic_mute` |
| `data-up` | `apn, ip_type?, user?, password?, auth?, cid?` | `data_connect` |
| `data-down` | — | `data_disconnect` |
| `identity` | — | `query_identity` |
| `networks-scan` | — | `scan_networks` |
| `raw` | `main, sub, type, hex` | `raw` |
| `log-level` | `level, logger?` | sets a logger level (`shannond`, `shannond.ipc.frames`, `shannond.rfs`, ...) |
| `subscribe` | — | streams `{"event": name, "data": {...}}` lines on this connection, starting with `state` |

On Linux the server also checks `SO_PEERCRED`: it accepts root, its own uid, or a member of the
`radio` group.

### shannonctl

```text
shannonctl [--socket PATH] status [--stats] [--identifiers]
shannonctl radio on|off
shannonctl pin-status | pin-enter | puk-enter          (PIN and PUK are read from the terminal, never from argv)
shannonctl sms send NUMBER TEXT [--status-report] | sms list [--show] | sms delete INDEX
shannonctl call dial NUMBER | call answer [ID] | call hangup [ID] | call list [--show] | call dtmf ID DIGITS
shannonctl data up APN [--ip-type ipv4|ipv6|ipv4v6] [--user U] [--password-stdin] [--auth none|pap|chap] | data down
shannonctl identity [--show] | networks | audio-path PATH | mic-mute on|off
shannonctl raw MAIN SUB TYPE [HEX]                     (for example: raw 0x0a 0x50 2)
shannonctl log-level debug|info|warning|error [--logger NAME]
shannonctl monitor [--identifiers]                     (event stream)
```

`SHANNOND_SOCKET` overrides the default socket path. The exit status is 0 on success, 1 when the
command fails and 2 when the daemon cannot be reached.

## RFS: observe mode (SYNTHESIS D6, phase 1)

- **Framing:** a 6-byte header `{u32 length (whole frame), u8 cmd, u8 id}`. Frames up to 0x80000
  bytes are reassembled across reads; a frame that is too large or has an invalid header is dropped.
  The reply goes out in one `write()` with the same `cmd` and the `id` echoed. Commands 0x0D to 0x10
  and 0x12 get no reply, as on stock.
- **NV verbs** (0x01, 0x02, 0x15, 0x16, 0x17) work on an in-memory copy of the snapshot. The snapshot
  is opened `O_RDONLY | O_NOFOLLOW`; the copy is re-seeded at daemon start, after a crash, and when a
  new `PWR_PHONE_PWR_UP` arrives without a hang-up.
  - Writes are acknowledged, kept in memory and discarded at the next re-seed.
  - `NV_RESTORE` re-seeds the copy.
  - Without a snapshot, the NV verbs reply `confirm = 0`.
  - Windows are limited to the snapshot size: the copy never grows.
  - The last 256 `(cmd, offset, length)` writes are kept for `status --stats`; this is the purpose of
    observe mode. The largest `NV_READ_ITEM` and `READ_FILE` sizes the CP asks for are recorded too
    (`max_nv_read`, `max_read_file`, unknown U22).
- **Replies** are written with the same short-write loop as FMT, so a 0x80000-byte NV reply leaves in
  2048-byte pieces.
- **File verbs** (0x03 to 0x0C, 0x11, 0x13, 0x14) map paths as follows:
  - a path starting with `err` or `/data/log` goes to `upper/log/`, which survives CP restarts;
  - `Audio_OEM`, `Audio_IFX`, `CP_AUDIO_SLSI` and `RF_NVM` names get ENOENT;
  - everything else goes to `upper/efs/` over the read-only lower layer. A write copies the file up;
    an unlink of a lower-only file leaves a whiteout.
  - `upper/efs/` is wiped at every CP boot.
- **Confinement:**
  - Each path is split on `/`, and any `..` component is refused (EACCES), as are control
    characters.
  - Each component is opened relative to a directory fd with `O_NOFOLLOW` (and `O_DIRECTORY` for
    intermediate components), so a symlink is never followed, whether in the lower or the upper
    layer.
  - CP open flags (ARM Linux values) are translated: only the access mode, `O_CREAT`, `O_EXCL`,
    `O_TRUNC` and `O_APPEND` are honoured.
  - Handles are small integers numbered from 3, at most 64 open, all dropped at every CP restart.
  - Caps: 1024-byte path, depth 16, 255-byte components, 8 MiB per file, 32 MiB in total. Reads are
    clamped to 0x40000 bytes.
  - errno values are sent as Linux numbers.
  - Nothing is ever written outside the upper directory: never `/efs`, never a block device.
- **Logging:** each request logs `{cmd, id, offset, length, path}`, never content.

## Data

`data_connect` follows SYNTHESIS §2.14:

1. `GPRS_LTE_ATTACH_APN_INFO` S (194 B, protover 2). A GEN error here is only a warning.
2. `GPRS_DEFINE_PDP_CONTEXT` S (127 B).
3. `GPRS_PDP_CONTEXT` S activate (105 B).
4. Wait for `GPRS_CALL_STATUS` N up and `GPRS_IP_CONFIGURATION` N (in either order).
5. Configure `rmnet(cid−1)`.

If activation fails after the activate request, shannond sends a deactivate. A `CALL_STATUS` down
while connected emits `data` with `connected: false`.

- **Default mode (`external`):** writes `/run/shannond/data/rmnetN.json` and emits the event. Nothing
  else is touched; NetworkManager or the facade configures the interface.
- **MTU:** `min(IP_CONFIGURATION MTU, 1500)`, or 1500 when the CP gives none. rmnet uplink slots are
  2048 bytes and longer skbs are truncated.
- **`--configure-ip`:** runs `ip link set up`, sets the MTU, flushes and adds `ADDR/32`, and adds
  `ip route replace default dev rmnetN metric 700`. With `--configure-dns` it also runs
  `resolvectl dns`. Wi-Fi is never touched.

The IPv6 address from `IP_CONFIGURATION` is passed through as given, with prefix 64. SLAAC is left to
the network manager, as D7 says.

## Audio (SYNTHESIS D8, IPC side only)

1. When a call reaches dialing, alerting or active (or is answered), shannond sends
   `SND_AUDIO_PATH_CTRL` S `{path, 0}`, `SND_SPKR_VOLUME_CTRL` S `{0x11 or 0x31, 4}`,
   `SND_TWO_MIC_SOL_CTRL` S `{0, 0}` and `SND_MIC_MUTE_CTRL` S `{0}`.
2. A `SND_CLOCK_CTRL` N with an odd value (CP clock on) emits `audio {open: true, rate}`. This is
   where the hook switches the `Modem RX/TX` pins on.
3. If no clock NOTI arrives 3 s after `CALL_STATUS` connected, shannond sends `SND_CLOCK_CTRL` E `{1}`
   once and opens with `fallback: true`.
4. A `SND_WB_AMR_RPT` change while audio is open emits a new `audio {open: true, rate: 16000}`. The
   hook does pins off, then the rate, then pins on.
5. When the last call is released, shannond emits `audio {open: false}` first (pins off), then sends
   `SND_CLOCK_CTRL` E `{0}`. A clock NOTI with an even value also closes.

The hook is any `subscribe` callback on the `audio` event, or `--audio-hook CMD`. The command is run
synchronously with a 5 s timeout, so the ordering above holds. It receives
`CMD open|close RATE PATH` and the environment variables `SHANNON_AUDIO_OPEN`, `SHANNON_AUDIO_RATE`
and `SHANNON_AUDIO_PATH`.

## Privacy

- **Default logs** contain only:
  - IPC header tuples (`shannond.ipc.frames` at INFO);
  - RFS `{cmd, id, offset, length, path}`;
  - state transitions;
  - numbers masked as `+CC*******NN`, and message lengths (never SMS text).
- **Never logged:** IMEI, IMSI, ICCID, operator code and name, LAC, TAC, cell id, PINs and payloads.
- **`--log-payload DIR`** is required for payload hex dumps.
- **Tests:** all fixtures are fictional:
  - PLMN 00101;
  - numbers in the Ofcom and ARCEP ranges reserved for fiction (+447700900xxx, +336399800xx);
  - TEST-NET addresses (192.0.2.x, 2001:db8::);
  - a zero IMEI.

## Tests (offline, against mocks)

```sh
python3 -m unittest discover -s modem/shannond/tests
```

| Suite | What it covers |
|---|---|
| `test_messages.py` | encoders and decoders against the catalogue sizes and offsets (§1 to §11), truncation, random lengths, emergency refusal |
| `test_sms_pdu.py` | SMS PDU known vectors, 7-bit packing, UCS2, concatenation, decoding, truncation |
| `test_rfs.py` | RFS framing and reassembly, id echo, verbs without a reply, NV observe semantics (no growth, U22 sizes), file verbs, overlay, caps, handles from 3 (at most 64), symlinks, `..`, and a fuzz of path confinement over every path verb |
| `test_core_fake_modem.py` | the catalogue §10 boot against the fake modem, mandatory replies, `--passive` sending nothing else, radio on, SIM lock and retries, SMS send and receive, calls with the audio order and the clock fallback, data up and down, the MTU clamp, the restart contract, SIM-change hang-ups, identity, the privacy of logs, and the kernel's 2048-byte write truncation and EBUSY (emulated by `fake_modem.SbdWriter`: a 0x80000-byte NV reply goes out in pieces) |
| `test_control.py` | control socket, redaction, subscription, and the real daemon process against the fake modem on ptys with `shannonctl status` |
| `test_loop.py` | the common loop contract on `SelectorLoop`, and on `GLibLoop` when `gi` is installed |

**These tests run on a fake modem.** They prove that shannond does what the catalogue describes. They
do not prove that the real CP behaves that way.

To run the GLib backend locally: the image `t715-phosh-test:aarch64` has Python 3.14 and gi 3.58.

```sh
docker run --rm --network none -v "$PWD/modem/shannond:/src:ro" t715-phosh-test:aarch64 \
  sh -c 'cd /src && python3 -m unittest discover -s tests'
```

## Known unknowns and assumptions

- **`SMS_SEND_MSG` p2 (domain):** shannond sends 0x02, the stock RIL's mapping for its default
  domain. The catalogue marks the meaning as inferred (I).
- **`NET_REGIST` domain values:** only 2 (CS) and 3 (PS) are used; any other value is ignored and
  logged.
- **`CALL_INCOMING` payload:** never parsed by the stock RIL. shannond reads the call id at p2 when it
  is present, then asks for `CALL_LIST`.
- **`SND_WB_AMR_RPT` and `SND_CLOCK_CTRL` N value meanings:** inferred. Non-zero WB means 16 kHz;
  odd means clock on.
- **`SEC_LOCK_INFORMATION` p0:** shannond sends 0x01, the libsamsung-ipc magic. Only PIN1 retries
  are queried.
- **RFS reply layouts the notes leave open:** NV_BUFFER_MESSAGE (13 B `{confirm, u32 offset,
  u16 size}`), OPEN and CREATE (`{fd, errno}`) and WRITE (`{ret, errno}`). READ_FILE is clamped
  consistently at 0x40000, instead of reproducing the stock length mismatch.
- **Service user:** the daemon runs as root with group `radio` in the unit. Moving it to a dedicated
  `radio` user (D9) is still open.
- **RFS form:** the RFS server runs as a thread with its own fd and loop. The separate sandboxed
  process from v2 D6 is available as `bin/shannon-rfsd`, but it has no systemd unit here: only
  `modem/systemd/shannond.service` was in scope.
- **Unexpected STATUS values on hang-up:** besides 2, 1 and 0, the values 3, 5 and 6 (BOOTING,
  NV_REBUILDING, LOADER_DONE) also start the restart contract, because the CP cannot be used then.
