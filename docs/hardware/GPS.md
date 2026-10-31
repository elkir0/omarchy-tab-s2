# GPS: from the BCM4752 to GeoClue

Study and results of 2026-10-31, on branch `t715-gps`. No coordinates here, nor any raw NMEA.

Evidence tags, as in [CAMERA.md](CAMERA.md): **[S]** read in source, **[D]** read in the stock
device tree, **[B]** read in a shipped binary, **[I]** deduced, **[U]** not established, **[T]**
seen on the tablet.

## 1. What the chip is

A Broadcom BCM4752 on UART0, separate from the modem and from the BCM4358 (Wi-Fi, Bluetooth)
**[D]**. It is a measurement engine: it tracks satellites and reports raw measurements. The
position is computed on the application processor by Samsung's `gpsd` (Broadcom's GLL, its
`glposeng` and `glmeaseng`) **[B]**. `gpsd` reports chip `4752 / 47520`, build 295783 **[T]**.

| Signal | Pin | Stock settings |
|---|---|---|
| UART0 RTS, CTS | gpd0-3, gpd0-2 | function 2, pull-down **[D]** |
| UART0 TX, RX | gpd0-1, gpd0-0 | function 2, pull-up **[D]** |
| GPS_PWR_EN | gpg2-0 | output, active high, low at boot; low in sleep **[D]** |

`arch/arm/boot/dts/samsung/exynos5433-gts28ltexx-gps.dtsi` enables `&serial_0` with those pins. No
node of ours used gpd0-0 to 3 or gpg2-0 before. There is deliberately no GNSS child under the
UART: serdev would take the tty, and mainline has a binding for the 4751/2/3
(`brcm,bcm4751.yaml`) but no driver.

## 2. Answers to the offline investigation

**a. Is there a free driver?** No position engine exists outside Broadcom's: mainline's binding has
no driver, and every project that got this family working runs the vendor daemon (Yoga-Book-GNSS,
ztOS, omarchy-mobile). The boot protocol is partly documented (`mbicz/bcm4752-init`), the
measurement protocol and the engine are not. Route A is closed.

**b. Where is the position computed?** In `gpsd`, from measurements. A RAM patch goes up at every
start, from inside `gpsd` itself (section 3). Then the link speaks GLME frames, `e0 00 ... e0 01`.

**c. What does `gpsd` depend on?** 13 direct libraries, 48 in the closure, 12.8 MB, all on SYSTEM. It
needs no binder and no property service **[T]**. It does need `/dev/urandom`, and `/sys/power/wake_lock`
to exist (two empty files stand in for it **[T]**). `RILEnabled="false"` and `SensorsEnable="false"`
take away RIL and sensors. `NmeaOutName` makes it create a FIFO and write NMEA there.

**d. Which route first?** B, `gpsd` alone in a minimal bionic tree. It worked on the first real
attempt: routes C and D were not needed.

## 3. The patch goes to RAM only

The frames at start-up, read from a trace of the UART through a pty **[T]**:

| Frame | Meaning |
|---|---|
| `80` x 16 | wake-up |
| `fe 00 fd 21 00 01 33 0e 10 fc` | ping, echoed; nothing else comes out of the chip unasked |
| `ff 00 fd 00 00 fc` | version: `05 00 02 30` |
| `ff 00 fd 1f 94 fc`, `1f 95` | read a register |
| `fe 00 fd 61 16 <u32> fc` | write the register read by `1f 94` |
| `fe <n> fd 61 17 de c0 <addr16> <data> fc` | write `(n+1)*4 - 4` bytes at `addr16` |
| `fe 00 fd 21 18 <addr16> <len16> fc` | checksum of a range, answer `2f 15 <4 bytes>` |
| `fe 00 fd 00 00 55 aa 00 ff fc` | start the patch; GLME frames follow |

The data is 8051 code. 14 frames write 10,992 bytes between 0x7000 and 0x9b0d. Every frame is
found byte for byte in Samsung's `gpsd`, from file offset 0x41a6c0 on.

Nothing of it outlives the power line **[T]**. Three times, with GPS_PWR_EN low for 2 s then high,
and only read-only frames sent:

- the checksums of 0x7000 and 0x8000 and 0x9000 differ from the patched values, and differ
  **from each other at each cycle**, as uninitialised RAM does;
- the four bytes at 0x7fec no longer hold what `gpsd` wrote;
- the register `1f 94` is back to its reset value.

No flash, OTP or fuse operation appears in the boot protocol, and `gpsd`'s strings name none
**[B]**. Its "NvRam" is a block read back from the chip with the RTC at start-up: state kept
while the chip's rail stays up, not storage **[I]**. Whether it survives GPS_PWR_EN low is **[U]**.

## 4. The confinement

`gpsd` has network code: SUPL, `BCMLS2.glpals.com`, and its own downloads of orbit predictions.
ufw lets everything out, so that cannot be what stops it.

- `t715-gps-prepare` writes a `gps.xml` with every such feature off and the server name removed.
- `t715-gpsd.service` has `PrivateNetwork=yes`: the process has its own loopback, no other interface
  that is up, no route, and `connect()` to an outside address gives `ENETUNREACH` **[T]**.
- It runs as user `t715-gps`, in `/var/lib/t715-gps/root`, with no capability **[T]**. Besides the
  pseudo-devices it sees `/dev/ttySAC0` and the power line's value file; `/proc` shows only its own
  process, and `/sys` is empty but for two blank wake lock files.

## 5. The stack

```text
app -> GeoClue -> /run/t715-gps/nmea.sock -> t715-gps-nmea@.service (cat of the FIFO) -> t715-gpsd.service
```

The socket exists only with Location on (`omamobile-gnss on`). GeoClue connecting starts `gpsd`.
When the client leaves, `cat` dies on its next write, within a second; `gpsd` then has nothing
needing it and stops, and `t715-gps-power.service`, needed by nothing else, stops with it and drops
GPS_PWR_EN, after a crash too **[T]**.

`gpsd` writes 0 or 1 to a file (`GpioNStdbyPath`), `/sys/class/sec/gps/GPS_PWR_EN/value` on Android.
The kernel gets `CONFIG_GPIO_SYSFS`, and `t715-gps-power` exports the line for the time `gpsd` runs.

Nothing of Samsung's is in the package: `t715-gps-prepare` copies `gpsd` and its libraries from
this tablet's SYSTEM partition, mounted read-only with no journal replay, the first time.

GeoClue's other sources stay off (`90-t715-gps.conf`), and that is not enough: with `[wifi]
enable=false` it still keeps a GeoIP source, which asked `api.beacondb.net` on the tablet and gave a
position 25 km wide, "GeoIP (ichnaea)" **[T]**. So `geoclue.service.d/t715-gps.conf` gives GeoClue
`PrivateNetwork=yes` as well. It only needs D-Bus and the socket above, both path-based. With Wi-Fi
and LTE connected, nothing outside is reachable from it and no GeoIP position comes **[T]**.

## 6. Results in the sky

Three captures with `t715-gps-capture`, cold each time: `gpsd`'s store erased, time starting at
00:00:00, time uncertainty 4294967295, position uncertainty 9999, `STO,F`, `LTO,-` **[T]**. The first
ran on the test kernel with no network. The second ran on the daily system, LTE connected and
GeoClue confined. The third ran on it after a reboot, with nothing set by hand.

| | First | Second | Third |
|---|---|---|---|
| First fix, 3D from the first frame, no 2D before it | 76 s | 39 s | 51 s |
| Satellites at the first fix, then at most | 4, 9 | 5, 12 | 6, 11 |
| HDOP, worst to best | 4.8 to 0.8 | 3.2 to 0.6 | 4.8 to 2.4 |
| Spread around its own mean, tablet lying still, 95 % | 6.7 m | 5.6 m | 8.1 m |
| Clock minus NMEA time of day | 0.2 to 1.2 s | 0.2 to 1.2 s | 0.2 to 1.2 s |
| `where-am-i` through GeoClue: updates, all from "GPS" frames | 604 | 593 | 586 |
| Farthest client position from the NMEA mean | 11.8 m | 6.5 m | 8.4 m |

C/N0 reached 40 dB-Hz. The receiver went off within a second of the client leaving.

`gpsd`'s date is exactly 1024 weeks behind, 2007-03-17: it was built before the GPS week number
last wrapped. Its time of day is right, and clients get today's date from GeoClue **[T]**. It also
shows the time did come from the sky.

`gpsd` wrote no `gldata.sto` when stopped by the service, so every start is cold **[T]**. Why is
**[U]**: it did under the first test bench, run by hand.
