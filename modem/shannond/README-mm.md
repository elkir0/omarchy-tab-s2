# shannon2mm: the ModemManager facade of shannond

`shannond.mm` exports the shannond `ModemCore` as **ModemManager 1.24** on
the system bus (`org.freedesktop.ModemManager1`). NetworkManager, mmcli,
GNOME Calls, Chatty and other ModemManager clients then work with the
Shannon SS333 unchanged (SYNTHESIS D7). It runs **inside the shannond
process**, on the same GLib main loop, with python-dbus and `DBusGMainLoop`.
ModemManager itself must never run at the same time (see
[Installing](#installing)).

## Entry point

```
shannond --mm [other options]          # GLib loop chosen automatically
```

`shannond/daemon.py` calls `shannond.mm.attach(core, loop)` after it creates
the core and before `loop.run()`. `attach(core, loop, bus="system",
**options)` returns a handle with `.facade` and `.close()`, and raises:

- `shannond.mm.NameTakenError` (a `RuntimeError`) when another process,
  usually ModemManager, already owns the name;
- `RuntimeError` when the loop is not shannond's `GLibLoop`;
- `ImportError` without python-dbus or PyGObject;
- `dbus.exceptions.DBusException` when the system bus is unreachable.

Options (keywords of `attach`, see `model.Options`): `identity`
(`eager` by default, or `on-demand`, `never`), `net_ports` (default: the
`rmnet*` found in `/sys/class/net`, else `rmnet0`), `primary_port`,
`drivers`, `register_timeout`, `command_timeout`, `connect_timeout`,
`sms_timeout`, `terminated_call_ttl`.

For a desktop demo without the modem, run it on the fake core:

```
python3 -m shannond.mm --fake [--bus session] [--locked] [--no-sim] [-v]
```

In demo mode, `SIGUSR1` delivers an SMS, `SIGUSR2` starts an incoming call,
and `SIGHUP` simulates a CP crash followed two seconds later by a recovery.

## Layout

| Module | Role |
|---|---|
| `enums.py` | ModemManager API values and D-Bus error names |
| `spec.py` | property signatures (from the MM 1.24.2 XML), `Variant`, signature checks |
| `convert.py` | pure conversions from the core vocabulary to MM values |
| `model.py` | `Facade`: the object tree and every method, independent of the bus |
| `service.py` | python-dbus glue: exact method/signal signatures, Properties, Introspect, ObjectManager |
| `fake.py` | `FakeCore`, which follows the `ModemCore` contract (tests and demo) |

As in ModemManager, only the modem object appears in the ObjectManager at
`/org/freedesktop/ModemManager1`. The SIM (`/SIM/0`), bearers (`/Bearer/N`),
SMS (`/SMS/N`) and calls (`/Call/N`) are plain exported objects that clients
reach by path.

## What is exported

| Interface | Implemented | Refused or neutral |
|---|---|---|
| Manager | `Version`; `ScanDevices`, `ReportKernelEvent` and `InhibitDevice` succeed and do nothing; `SetLogging` sets the `shannond.mm` log level | |
| Modem | every property; `Enable` → `radio_on`/`radio_off`; `CreateBearer`, `DeleteBearer`, `ListBearers`; `SetPowerState` (LOW → `radio_off`; ON while disabled is a no-op) | `Reset`, `FactoryReset`, `GetCellInfo`, `SetPrimarySimSlot`: Unsupported. `Command`: Unauthorized (there is no AT port). Capabilities, modes and bands accept only their current value |
| Modem.Simple | `Connect` (PIN if given and the SIM is locked, enable, wait for registration, bearer, `data_connect`), `Disconnect` (also removes the bearer, as MM does), `GetStatus` | |
| Modem.Modem3gpp | `Imei`, `RegistrationState`, `OperatorCode`, `OperatorName`, `EnabledFacilityLocks` (SIM once a PIN lock was seen), `PacketServiceState`; `Register("")` | `Scan`, manual `Register`, EPS/5G settings, facility and carrier locks: Unsupported |
| Sim | `SimIdentifier`, `Imsi`, `OperatorIdentifier`, `Active`, type and removability; `SendPin` → `enter_pin` | `SendPuk`, `EnablePin`, `ChangePin`, `SetPreferredNetworks`: Unsupported |
| Modem.Messaging + Sms | `List`, `Create` (text only), `Delete` (→ `delete_sms` for messages stored on the CP side), `Sms.Send` → `send_sms`; signals `Added(path, received)`, `Deleted`; stored messages are loaded once per CP session (`list_sms`); `sms-status-report` sets `DeliveryState` | binary SMS, `Store`, `SetDefaultStorage`: Unsupported |
| Bearer | `Connect`, `Disconnect`, `Interface`, `Connected`, `ConnectionError`, `Ip4Config`, `Ip6Config`, `Properties` (the password is never published) | multiplexing and profiles: Unsupported. `MaxBearers` = `MaxActiveBearers` = 1 |
| Modem.Voice + Call | `CreateCall`, `ListCalls`, `DeleteCall`, `HangupAll`, `HangupAndAccept`; `Call.Start`, `Accept`, `Hangup`, `SendDtmf`; `CallAdded`/`CallDeleted`, `Call.StateChanged`; `AudioFormat` follows the core's `audio` event | hold, transfer, deflect, multiparty and call waiting: Unsupported (the core has no API for them) |
| Modem3gpp.Ussd | **not exported**: the core has no USSD command, and an absent interface is clearer for clients than one whose methods all fail | |
| Location, Time, Signal, CellBroadcast, ProfileManager, Firmware, Sar, Oma | not exported | |

### Modem state

`convert.compute_state` maps the core state to a modem state, checking these
rules in order:

1. CP crashed → FAILED (reason unknown); CP offline → INITIALIZING.
2. SIM absent → FAILED (sim-missing); SIM error → FAILED (sim-error).
3. SIM PIN/PUK lock → LOCKED. PIN2 does not count, as in MM.
4. SIM state unknown → INITIALIZING.
5. Radio not on → DISABLED, or ENABLING/DISABLING while a command runs.
6. Otherwise, from the registration: CONNECTING, CONNECTED, DISCONNECTING,
   REGISTERED (CS or PS home/roaming), SEARCHING, or ENABLED.

`RegistrationState` combines the two domains: a registered PS domain wins,
then a registered CS domain. NetworkManager calls `Enable(true)` as soon as
the modem appears with the WWAN radio switch on. This is normal
ModemManager behaviour: it turns the radio on.

### Identity

The IMEI, IMSI, ICCID, MSISDN and revision come from `core.query_identity()`.
With `identity="eager"`, the facade asks once per CP session as soon as the
SIM state is known, and asks again when the SIM becomes ready (the IMSI
needs an unlocked SIM). `on-demand` asks only when a client reads the modem,
3GPP or SIM properties; `never` leaves them empty. The D-Bus policy
restricts these reads to root and `wheel`.

## Port types: what NetworkManager needs

From NetworkManager 1.58.1 (`src/core/devices/wwan/nm-modem-manager.c`,
`nm-modem-broadband.c`, `nm-device-modem.c`):

- a modem is accepted if it has the `Modem` interface and a **non-empty
  `PrimaryPort`** (`modm_handle_object_added`). Port types are never checked.
  `PrimaryPort` becomes the NM device name and UID, so `nmcli device` shows
  `umts_ipc0  gsm`;
- `Ports` is only used by `owns_port()`: the listed `rmnet*` (type NET) are
  claimed by the modem device, so NetworkManager does not create a separate
  device for them;
- the data interface is `Bearer.Interface`, and it must exist
  (`nm_platform_if_nametoindex`);
- with 3GPP capabilities, NetworkManager waits for a `Sim` object before it
  connects, sends a PIN stored in the connection when `UnlockRequired` =
  SIM-PIN, and needs a state above LOCKED;
- `Ip4Config` with method STATIC needs a valid `address`, takes `prefix`,
  `dns*`, `mtu`, and an optional `gateway` (absent on rmnet). `Ip6Config`
  with method DHCP becomes "auto": NetworkManager takes the interface
  identifier from the link-local address and runs SLAAC.

**Choice:** `Ports = [("umts_ipc0", IGNORED), ("rmnet0".."rmnet3", NET)]`.
QMI would make clients that do look at port types (qmicli front ends,
ModemManager GUIs) open `/dev/umts_ipc0` with a QMI parser. IGNORED is true
(no MM-known protocol runs there) and NetworkManager does not care.

## Data path

`data_connect(apn, ip_type, user, password, done=…, auth=…)` returns the
core `data` dict. The bearer publishes:

- `Interface` = `data.interface`, or `rmnet(cid−1)` (SYNTHESIS §2.14);
- `Ip4Config` = method 2 (STATIC), `address`, `prefix` (32 when missing),
  `gateway` when the network gives one, `dns1..3`, `mtu`;
- `Ip6Config` = method 3 (DHCP), with `address` = `fe80::<IID>` and
  `prefix` 64, where the IID is the low 64 bits of the address the network
  gave (or the core's `iid`), plus `dns1..3` and `mtu`;
- a family without configuration is `{"method": 0}`, as ModemManager
  publishes it (libmm-glib warns on an empty dictionary).

The client's `ip-type` maps to `ipv4`/`ipv6`/`ipv4v6`; NONE and ANY become
`ipv4v6`. `allowed-auth` maps to `none`/`pap`/`chap`/`pap-chap`, and is left
to the core when absent. The facade never configures IP itself:
NetworkManager does it from the bearer (core option `--configure-ip` is for
the case without NetworkManager).

## Installing

1. `dbus/org.freedesktop.ModemManager1.conf` →
   `/usr/share/dbus-1/system.d/`. Only root may own the name; root and
   `wheel` may call methods (this includes reading properties); everyone
   may introspect. If shannond moves to a dedicated user, add that user to
   the owner block.
2. Make sure ModemManager cannot start. NetworkManager, when not under
   systemd, and any client asking for the name trigger **D-Bus activation**
   of ModemManager whenever the name is free (seen in the test container:
   NetworkManager started ModemManager in the gap while the facade
   restarted). On the tablet, keep the `modemmanager` package uninstalled
   (`libmm-glib` alone is fine). If it ever comes in as a dependency, run
   `systemctl mask ModemManager.service dbus-org.freedesktop.ModemManager1.service`.
   Otherwise the facade exits with `NameTakenError`.
3. Start shannond with `--mm` (the systemd unit is WP13). A D-Bus activation
   file `org.freedesktop.ModemManager1.service` with
   `SystemdService=shannond.service` would also let NetworkManager restart
   shannond on demand; that choice belongs to WP13.

## Tests

```
# unit tests (any machine, no bus): conversions, model, contract with core.py, privacy
cd modem/shannond && python3 -m unittest discover -s tests -p 'test_mm*.py'

# integration (disposable root container: dbus-daemon, mmcli, NetworkManager)
docker run -d --name shannon2mm-it --cap-add NET_ADMIN \
    -v "$PWD/modem/shannond:/src:ro" t715-alarm:dev-aarch64 sleep infinity
docker exec shannon2mm-it pacman -Sy --noconfirm --needed \
    modemmanager python-dbus python-gobject networkmanager iproute2
docker exec -e SHANNON2MM_IT=1 -w /src shannon2mm-it \
    python3 -m unittest discover -s tests -p 'test_mm*.py' -v
docker rm -f shannon2mm-it
```

The integration test does the following:

- installs the policy and checks it with `wheel` and non-`wheel` users;
- runs mmcli on every interface;
- compares the live introspection of the ten interfaces with
  `/usr/share/dbus-1/interfaces/org.freedesktop.ModemManager1.*.xml`;
- fails on any libmm-glib type warning;
- checks that a second instance is refused;
- starts NetworkManager, which lists `umts_ipc0 gsm` and activates a gsm
  connection, putting `192.0.2.10/32`, `fe80::1:0:0:a/64` and the default
  route on a dummy `rmnet0`;
- finally runs the real `shannond --mm` against `tests/fake_modem.py`.

mmcli 1.24 has no `--simple-status` option, so `GetStatus` is checked with
`gdbus call`.

## Still to check on the tablet

- The NetworkManager activation on the real `rmnet0` (`ARPHRD_RAWIP`):
  SLAAC from the link-local IID, the MTU taken from `IP_CONFIGURATION`, DNS
  through NetworkManager.
- The SIM PIN prompt through the NetworkManager secret agent, and
  `mmcli -i 0 --pin` from a `wheel` user.
- GNOME Calls and Chatty on Hyprland: incoming call notification,
  `Accept`, DTMF, the end of the call, SMS `Added` and sending. Audio
  routing stays with the core (`audio` event, D8).
- The real `Revision`, ICCID and operator name (`NET_IDENTITY`) once the CP
  sends them.
- Sending an SMS needs `shannond.sms_pdu`, which is not delivered yet.
- Crash recovery with the real CP: the modem goes FAILED and then back to
  DISABLED, and NetworkManager calls `Enable` again.

## Privacy

Log lines carry states, object numbers, counters and lengths, never phone
numbers, SMS text, PINs, passwords or identifiers (enforced by a unit test).
The bearer `Properties` never contain the password. All test values are
fictional: test PLMN 001-01, an all-zero IMEI, +1 555 01xx numbers and
documentation addresses (RFC 5737, RFC 3849).
