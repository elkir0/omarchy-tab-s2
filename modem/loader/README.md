# shannon-loader

Independent loader and supervisor for the Shannon SS333 modem (CP) of the Galaxy Tab S2
SM-T715, on the mainline kernel with the ported `modem_v1` + `mipi-lli` drivers (unchanged
userspace ABI). C11, GPL-2.0-or-later, written from `research/modem/research/SYNTHESIS.md`
(D4, rule 1, §2.6-§2.9, §2.13) and `research/modem/research/analysis/loader_spec_v2.md`
(LS2). The specification comes from static analysis of the stock `cbd` and BOOT binaries, with Samsung's public cbd source read as a behavioural reference. No Samsung code was copied.

One long-running process: **preflight** (no hardware side effect) → **boot attempt**
(B1-B17) → **online** (holds `umts_boot0`, `umts_ipc0`, `umts_rfs0`; `READY=1`) →
**supervisor** (silent reset after a CP crash).

## Usage

```
shannon-loader [--dry-run | --stop-after=RUNG] [--attempts=N] [--kmsg] [paths...]
```

| Option | Default |
|---|---|
| `--boot-dev`, `--ipc-dev`, `--rfs-dev` | `/dev/umts_boot0`, `/dev/umts_ipc0`, `/dev/umts_rfs0` |
| `--image` | `/dev/disk/by-partlabel/RADIO` |
| `--lli-control`, `--cp-status` | discovered under `/sys/bus/platform/...` (LS2 F1) |
| `--allow-hw-param` | `/sys/module/sec_modem_v1/parameters/allow_hw` (must read `Y`/`1`) |
| `--nv-mode=copy\|direct` | `copy` (mode A) |
| `--nv`, `--nv-manifest`, `--nv-md5-file` | `/var/lib/shannon/nv/nv_data.bin`, `.../manifest.sha256`, `<nv>.md5` |
| `--nv-md5=warn\|require\|off` | `warn` (log which MD5 form matches, nothing else) |
| `--allow-blank-nv` | off |
| `--battery-capacity`, `--battery-temp`, `--battery-current` | `/sys/class/power_supply/sm5703-fuelgauge/{capacity,temp,current_now}` |
| `--state-file` | `/run/shannon/cp-state` (refused unless under `/run/`) |
| `--attempts` | 1 (maximum 3), per boot cycle |
| `--kmsg` | also log to `/dev/kmsg` as `shannon-loader:` |

Every log line carries a CLOCK_MONOTONIC timestamp, so it can be matched against dmesg.
The log has one line per std_udl word and per ioctl, and one summary line per stage
(frame count, bytes, time). It never contains NV bytes, only sizes and hashes.

## Ladder (`--stop-after`, LS2 §10.6)

Every rung except `online` ends with `MODEM_OFF`. A rung that ends after B7 waits for the
**eFuse settle** first: no `MODEM_OFF` between `cp_status` = 1 and the first of `0xA00D`
received or **10 s** (SYNTHESIS rule 1). That wait ignores SIGTERM. The same wait applies to
every failure after B7.

| Rung | Stops after |
|---|---|
| `preflight` (= `--dry-run`) | F1-F8; no ioctl at all |
| `power` | B1 SET_TX_LINK(LLI), B2 MODEM_ON, B3 BOOT_ON |
| `spi` | B4 DL_START, B5 STATUS, B6 SET_TX_LINK(SPI), B7 BOOT over SPI, B8 `cp_status` = 1 |
| `lli` | B9 SET_TX_LINK(LLI), B10 `lli_control` = `MIPI-LLI 1` (read only) |
| `stage0` | B11 RX drain + `0x900D → 0xA00D` |
| `toc`, `main`, `nv`, `fin` | the matching stage record (`fin` = `0x9F00 → 0xAF00`) |
| `online` | B13-B17, then holds the CP **without** silent reset: a crash means `MODEM_OFF` and exit 6; SIGTERM means a clean stop |

## Exit codes

0 clean stop (SIGTERM, rung reached) · 1 internal error · 2 config · 3 NV refused ·
4 image/TOC invalid (also when MAIN changes between preflight and the CRC frame) ·
5 kernel ABI missing (nodes, sysfs, `allow_hw`) · 6 boot failed after the attempts, or
more than 5 silent resets in 30 min · 7 MAIN rejected twice by the CP (`0xA20F`) ·
8 battery/thermal gate (capacity < 5 % or temperature ≥ 40.0 °C before a power-on).
Code 8 is an addition to LS2 §4.5 for the review's battery rule. The unit does not restart
on codes 2, 3, 4, 5, 7 and 8.

## Safety rules enforced in code

- **BOOT**: read once in preflight into a page-aligned buffer. The CRC32 must be the
  pinned 0x5DB1F04C, and the SHA-256 must be the pinned
  `dd39fae36c2ccfbc28c3562c405962c827b2cf5d66f9e63d3fb90223dd0f94f4` (the slice
  image[0x200..0x2BFC) of the backed-up RADIO). The buffer is then sealed read-only
  (`mprotect`) and locked in RAM (`mlock`). It is checked again before every attempt and
  right before the B7 write. BOOT.size must be ≤ 0xFFFB. MAIN CRC = TOC in preflight, and
  again while streaming: if they differ, the loader aborts before the CRC frame.
- **ioctls**: only an allow-list (ON, OFF, BOOT_ON/OFF/DONE, STATUS, DL_START,
  FW_UPDATE, SET_TX_LINK, GET/CLR_CP_BOOTLOG) is ever sent. The dump, crash and upload
  requests (0x6F32/34/35/36) have no name in `src/`.
- **std_udl words**: every word is checked before it is written. Only AP→CP words with a
  stage 0-3 or FIN are allowed, a CRC frame only for MAIN (never `0x930C`), and FIN only
  as `0x9F00`.
- **sysfs**: `lli_control` and `cp_status` are only read. The ops table has no write
  operation for them, and the unit makes `/sys` read-only.
- **Retries**: every failed attempt ends with `MODEM_OFF` (after the eFuse settle). The
  loader allows `--attempts` (≤ 3) per boot cycle and ≤ 5 silent resets in 30 min, and
  stops after the second MAIN rejection.
- **Power gate**: battery ≥ 5 % and temperature < 40 °C before every CP power-on.
  Capacity, temperature and `current_now` are logged at the start and at the end of every
  attempt (rung).
- **Earlier session**: if `cp_status` is already 1 before B1, the CP is alive from an
  earlier session. The loader waits for the eFuse settle, then sends `MODEM_OFF` before it
  boots again.

## NV policy (LS2 §8, SYNTHESIS D4)

- Mode A (default) reads `/var/lib/shannon/nv/nv_data.bin` with
  `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`. The file must be regular and **exactly** the TOC NV
  size (0x100000). A file that is missing, short, long, a symlink, all 0xFF or all 0x00 is
  refused (`--allow-blank-nv` accepts a blank one, with a loud warning).
- The whole file is read into memory before the first power-on, and its SHA-256 must
  match the manifest. The buffer is then sealed read-only, and stage 3 streams that buffer.
- MD5 (advisory): `nv_data.bin.md5` is compared with MD5(nv) and with
  MD5(nv ‖ `"Samsung_Android_RIL"`). The log says which one matches.
  `--nv-md5=require` makes a mismatch fatal.
- Mode B (`--nv-mode=direct`, default path `/efs/nv_data.bin`) works only on a filesystem
  that `fstatvfs` reports as `ST_RDONLY`. There is no override.
- No code path creates, truncates, pads, renames or deletes an NV/EFS file.

**Manifest format**: the `sha256sum` output format, one line per file,
`<64 hex><space><space|*><name>`. Names are compared by basename. Blank lines and lines
starting with `#` are ignored, and CRLF is accepted. An entry for `nv_data.bin` is
required. An entry for `nv_data.bin.md5` is optional; when present, the `.md5` is trusted
only if its SHA-256 matches. A duplicate name or any malformed line makes the loader
refuse the manifest. To provision it:
`cd /var/lib/shannon/nv && sha256sum nv_data.bin nv_data.bin.md5 > manifest.sha256`.

## Holders, state file and the daemon (SYNTHESIS v2 D5 restart contract)

After `BOOT_OFF` returns (B14), the loader opens `umts_ipc0` then `umts_rfs0`
(`O_RDWR|O_NONBLOCK`). The second open sends `INIT_END` (late path). The loader **never
reads** these fds and keeps them across silent resets, so on a CP restart the
`PHONE_START` handler sends `INIT_END` itself. The loader never opens them between
`DL_START` and the return of `BOOT_OFF`. The telephony daemon opens its own fds to the
same nodes once the state reads `online`.

The loader writes `/run/shannon/cp-state` atomically (temporary file in the same
directory, then `rename`). This is the only file it ever writes, and the path must be
under `/run/`:

```
session=<N> state=<booting|online|crashed|offline>
```

`N` goes up by one at every CP power-on. It continues from the existing file across
loader restarts within one AP boot. A typical sequence:
`offline → booting → online → crashed → offline → booting(N+1) → online`. `READY=1` is
sent once, at the first `online`. Later restarts send only `STATUS=` messages.

## Build and tests

```
make docker-test     # = docker run ... t715-kbuild make test   (arm64, gcc 14)
make docker-cross    # = docker run ... t715-alarm:dev-armv7h make cross CROSS_CC=gcc
```

`make cross` builds `build/shannon-loader-armv7`, a static ARMv7-A hard-float binary
(VFP register arguments, glibc). `make test` (Linux only) runs:

- known-answer vectors for CRC32, SHA-256 and MD5, plus a cross-check of the fixture
  manifests and MD5 files against `sha256sum`/`md5sum`;
- positive controls proving that the `nv_guard.so` LD_PRELOAD interposer stops every
  write, create, truncate, rename or unlink on NV/EFS paths, every write-open of
  `lli_control`/`cp_status`, and the forbidden ioctls (exit 86);
- the level-1 suite under that interposer, and again under ASan + UBSan. The suite uses a
  C mock of `umts_boot0` (LS2 §10.2 state machine, CP side of std_udl) with a virtual
  clock. It covers:
  - the golden transcript on the stock geometry (synthetic contents with forged stock
    CRCs: MAIN 0x21271A0, 16 975 frames, last 0x1A0, CRC 0x1E71169C, NV 512 frames,
    17 497 stage-engine writes, 12 reads, 3 FW_UPDATE) and the byte vectors of §2.7/§2.8;
  - every rung, the full fault matrix of LS2 §10.5, the NV policy, the supervisor, the
    eFuse settle, the power gate and the state file;
  - mock tripwires (forbidden ioctls, stage ≥ 4, `0x930C`, a wrong SPI payload, two SPI
    writes per power-on, a first holder open inside the download window, `MODEM_OFF`
    inside the eFuse window), each proven able to fire;
- black-box runs of the real binary with real Linux ops on synthetic files.
  `shannon-loader-testpin` differs only by its BOOT SHA-256 pin, and the production binary
  is shown to refuse the synthetic BOOT;
- static safety checks: no forbidden constant or file-modifying call in `src/`, exactly
  four write-capable `open()` calls (boot node, holders, `/dev/kmsg`, `/run` state file),
  and no 0x6f32/34/35/36 immediate in the objects (`objdump`).

To run the golden transcript on the real RADIO image (read in place, production pins):
`docker run ... -v <radio.img>:/radio.img:ro -e SL_REAL_RADIO=/radio.img t715-kbuild
build/aarch64/test_loader <fixtures> real_radio`.

## Not done

- LS2 level 2 (CUSE black-box bench) and level 3 (ring vectors fed to the ported
  kernel code), i.e. O4. What is missing:
  - a CUSE `/dev/umts_boot0` (unrestricted ioctls), with two dummy holder nodes and sysfs
    files in a temp dir;
  - a CP model behind it, which can reuse the logic of `tests/mock.c`;
  - a Linux host or VM with `/dev/cuse` (Docker Desktop does not expose it).

  The loader needs no change for this: all paths are options.
- RAM dump (LS2 §9.4): not implemented, on purpose.
- The systemd unit `modem/systemd/shannon-loader.service` is not enabled anywhere. Enable
  it only after gate G11.
