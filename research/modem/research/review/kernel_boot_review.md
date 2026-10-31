# Review: kernel, link, boot and safety side of `SYNTHESIS.md`

Adversarial review, 2026-10-29. Static only: the tablet was not contacted, no
Samsung binary was executed, no EFS/`nv_data`/`m9kefs` content was opened, and the stock
dmesg was used for LLI/link-PM lines and timestamps only.

**Scope.** D1, D2, D3, D4, D9; fact sheet §2.1-§2.3, §2.9, §2.16; contradiction rows C01-C05,
C09-C10, C14-C15, C25, C33-C35, C42-C43, C45; safety rules §5; gates O1-O7 and G0-G12 (§6);
dossier corrections §9.1-§9.4.

**Roots.** `S` = `research/modem/research/SYNTHESIS.md` (line numbers of today's file).
`K/` = `src/kernel_universal5433/`. `ML/` = `src/linux-6.12/` at `ed71dc803`.
`BL` = `docs/hardware/boot-logs/boot1-2026-10-28.txt` (our mainline boot log).
`DM` = `dumps/dmesg.txt` (stock, LLI/PM lines only). `CFG` = `out/mainline/.config`.
KP, LS2, RI, KD as in S §0.

**Severity.** **blocker**: fix before the first W gate. **major**: fix before the gate it
affects. **minor**: correctness, wording or evidence quality.

---

## 0. Verdicts

| Decision | Verdict | In one line |
|---|---|---|
| D1 kernel architecture | **agree with changes** | Lift-and-shift into an in-tree series is right. Fix `allow_hw` run-time semantics, the LLI probe's real side effects, the M-PHY AFC state, add kernel tripwires, and replace the overlay argument. |
| D2 LLI power management | **agree with changes** | Locked-on is supported by the FSM code and by DM. F1 is under-specified (it skips the AP2CP_STATUS handshake). CP2AP IRQs must be disabled before CP power-off. |
| D3 shared memory | **agree with changes** | Static no-map 0xde000000 is the best and also the safest base. Add a per-boot remap/mount interlock, detection of a failed reservation, a no-map tail up to the end of DRAM, and fix the "Device ≈ strongly-ordered" argument. |
| D4 loader | **agree with changes** | C, one process and NV Mode A are right. Pin BOOT in memory and add a kernel CRC tripwire, an eFuse settle window, NV provisioning from the raw backup, single attempts until the AFC fix, and keep the unit disabled until G11. |
| D9 privacy | **agree with changes** | `dflags = 0` is verified to silence payload dumps. Add modes for DIAG/AT/ramdump nodes, treat debugfs `mem_dump` as payload, cover journald/pstore, and keep the SIM out until G14. |

---

## 1. Decisions

### D1. Kernel architecture: agree with changes

Verified at source: the in-tree side-series model exists (`kernel/patches/t715-g3d-abb/`,
`kernel/kbuild-mainline.sh:13-17,84-96` `--fragment`); `# CONFIG_SPI is not set`,
`CONFIG_PL330_DMA=m`, `CONFIG_DEVMEM=y`, no `STRICT_DEVMEM`, `CONFIG_LOCALVERSION_AUTO=y`
(CFG); the upstream clock ID collision (`ML/include/dt-bindings/clock/exynos5433.h:198-199`);
`exynos_get_pmu_regmap_by_phandle()` exported and no 5433 `pmu_data`
(`ML/drivers/soc/samsung/exynos-pmu.c:256-257,297-329`); the syscon regmap is spinlocked,
so a PMU write from hard IRQ is legal (`ML/drivers/base/regmap/regmap-mmio.c:398`
`.fast_io = true`; this upgrades KP's "inferred" to proven). The panic/BUG sites listed in KP
exist (`K/drivers/misc/modem_v1/modem_io_device.c:1254`, `modem_main.c:223`,
`link_device_memory_main.c:467,747`, `link_device_pm.c:364`).

| # | Sev | Finding | Required change |
|---|---|---|---|
| D1-a | **major** | `allow_hw` is "root-writable at run time", but GPIOs are requested `GPIOD_ASIS` when it is 0 (S:476). A descriptor obtained ASIS keeps the pin's direction, and `gpiod_set_value()` only writes DAT. After a 0→1 flip, `MODEM_ON` would toggle DAT on lines that may still be inputs: the CP gets no power, or partial power. G3 and G4 flip the parameter at run time. | Give the parameter a `set` callback. On 0→1 with state OFFLINE, perform the stock probe-state transition: `gpiod_direction_output(…, 0)` on CP_ON, then CP_RESET (stock order, `K/…/modem_main.c:294,307`; again `modem_ctrl_ss333.c:550-551`), then PDA_ACTIVE, AP_DUMP_INT, AP2CP_STATUS, AP2CP_WAKEUP, IPC_INT2CP; log the pin registers. Refuse 1→0 unless the state is OFFLINE. |
| D1-b | **major** | "With 0: … every GPIO/LLI/SPI side effect returns -EPERM" (S:476) is false for the LLI module. The platform core applies `assigned-clocks` (the mux parents, and `div_aclk_cpif_200` → 100 MHz) **before** probe (`ML/drivers/base/platform.c:1367`). KP's probe then enables the gates and writes `DME_LLI_INTR_ENABLE`/`STATUS` (KP §2.2 step 7). The pinctrl default state is applied before probe too (`ML/drivers/base/dd.c:694`). G2 is therefore the first CMU_CPIF/LLI hardware access, not G3. | Say so in D1 and split G2 (§4, G2a/b/c). Request IRQ 184 with `IRQF_NO_AUTOEN` as well (KP does this only for 185). |
| D1-c | **blocker** | **M-PHY AFC state** (not in any analysis). 3.10 runs AFC only in the first `cmn_init` after boot (`static bool is_first`, `K/drivers/misc/mipi-lli/exynos-mipi-lli-mphy.c:55,79-88`). It saves the AFC code only at the first `MOUNT_DONE` (`exynos-mipi-lli.c:841,853-858`). Any second `exynos_lli_setting()` before a mount therefore writes AFC override = 1 with code `afc_val` = 0 (the field is zero-initialised, `exynos-mipi-lli-mphy.h:231`). The plan triggers exactly this: G3's soft reset consumes the "first" AFC; G4's `MODEM_ON` (`ld->reset`) runs the second `cmn_init` with code 0, so G5/G6 would fail as "M-PHY/clock" problems. Loader retries within one boot (D4: 3 per start) are not independent trials either: after a failed mount, every retry runs with a different PHY setup. | Port: replace both statics by `phy->afc_valid`; take the AFC branch while `!afc_valid`; set `afc_valid` and `afc_val` only at a `MOUNT_DONE` that obtained DL credits. Until that fix is proven on the bench, reboot between G3 and G4 and between failed mount attempts (`--attempts=1`). Add it to O8 (unit test of the branch sequence reset → reset → mount → reset). |
| D1-d | **major** | No kernel-side guard for the two irreversible or invisible failures: a wrong BOOT on SPI (eFuses), and a CP mount without a valid remap (AP memory). | (i) SPI link tripwire: while the TX link is SPI, accept exactly one write per `MODEM_ON`, of exactly 0x29FC payload bytes with CRC32 = `boot_crc` (module parameter, default 0x5DB1F04C); anything else → `-EPERM` + `dev_err`. (ii) Remap/mount interlock (D3-a). Both are cheap and catch loader bugs and operator errors. |
| D1-e | minor | The rationale "DT overlays cannot add phandles to our base DTB (no `__symbols__`)" (S:478) is weak: we compile the DTB, so `-@` would add `__symbols__`, and ztOS applied an overlay at module load (KD Q2). | The decisive reasons are: (1) a `reserved-memory` region must be in the boot DTB, because memory handed to the page allocator cannot be reserved later; (2) the CMU_CPIF clocks are `CLK_OF_DECLARE` built-ins (`ML/drivers/clk/samsung/clk-exynos5433.c:910-915`); (3) mainline has no userspace overlay loader. |
| D1-f | minor | "`lli_control` … store accepts only `0` unless `lli_debug_cmds=1`" (S:475). Store `0` calls `debug_info` → `exynos_lli_reg_dump`, which reads `lli_debug_clk_info[]`, statically mapped 5430 CMU VAs (`exynos-mipi-lli.c:141-151`, `.h:254-263`). D1 drops those tables, so `0` points to code that no longer exists. Nothing (cbd v1, the loader) ever writes the file. | Make `lli_control` 0444 with no store. Put debug commands, if needed, in debugfs under `allow_hw`. Rule 8 then becomes structural. |
| D1-g | minor | "Modules allow `make M=` iteration without reflashing BOOT" (S:478). With `CONFIG_LOCALVERSION_AUTO=y` every commit or dirty tree changes the release string, so a rebuilt `.ko` no longer matches the BOOT kernel's vermagic. The initramfs also replaces `lib/modules/<rel>` when BOOT's module tarball changes (`boot/initramfs/init:845-873`). | Rule: build module-only fixes with `make M=` in the **same O= tree** that built the BOOT kernel (its `utsrelease.h` is frozen); install them under `/lib/modules/<rel>/updates/` + `depmod`; record `modinfo -F vermagic`. |
| D1-h | minor | `INTR_RESET_ON_ERROR_SENT` returns before the W1C status clear (`exynos-mipi-lli.c:951-955`): with a level IRQ it can re-enter, and each entry fires another soft reset. | Clear the status (W1C) before the soft reset, in addition to KP's rate limit. |
| D1-i | minor | `CONFIG_SUSPEND=y` is built (KP §3.6). A wakeup source does not block an explicit `systemctl suspend` unless `wakeup_count` is used. | `modem_suspend()` returns `-EBUSY` while the state is not OFFLINE (phase 1), and the mission masks `suspend.target`/`sleep.target`. |
| D1-j | minor | Requesting the CP2AP/PHONE_ACTIVE IRQs switches those pins to EINT (KP §2.3). If done at probe with `allow_hw=0`, G2's "CP pins unchanged" check fails on CON. | Request them at the 0→1 transition (D1-a), or accept and document the CON change in G2. |

### D2. LLI power management: agree with changes

Verified in DM (LLI/PM lines only): 25 mounts and 26 `Unmount` lines between 686 s and 942 s;
up-time 0.306-0.969 s (median 0.483 s); 10 remounts from `CP2AP_WAKEUP_HIGH:UNMOUNTED->RESETTING`
and 15 via `CP_HOLD_REQUEST:UNMOUNTED->HOLDING`; **0 of 26** unmounts without
`CP_FREE->UNMOUNTING` right before. The FSM code shows why: the CP starts every release by
lowering CP2AP_WAKEUP (`ACTIVE→AP_FREE`, `K/…/link_device_pm.c:499-512`). The AP drops
AP2CP_WAKEUP only after `CP_HOLD_TIMEOUT` with no pending TX (`:514-543`). The CP lowers
CP2AP_STATUS (unmount) only after that (`:545-…`). So the AP's hold is the second step of a
CP-led handshake. That is stronger support for (c) than S:487 states, though still I.
Pin behaviour up to `PHONE_START`: stock `start_link_pm` asserts both AP lines for
`CP_BOOTING` and `LOCK_ON` alike (`:809-820`); while the FSM is inactive every event releases
AP2CP_WAKEUP (`:388-394`). D2's claim holds (P).

| # | Sev | Finding | Required change |
|---|---|---|---|
| D2-a | **major** | Fallback F1 (S:490) says "call `mipi_lli_reset()` once". The stock remount is a handshake, not a bare reset. `UNMOUNTING→UNMOUNTED` **releases AP2CP_STATUS** (`link_device_pm.c:599`). `RESETTING` re-asserts it only after `LINK_RESET` (`:473-477`), with 500 ms watchdogs. The LLI driver already re-inits itself on `UNMOUNT_DONE` when no `unmount_cb` exists (`exynos-mipi-lli.c:1003-1007`), so a second reset from F1 is redundant at best and races the CP at worst. In locked-on mode AP2CP_STATUS never falls, so whether the CP remounts at all is unknown. | Replace F1 with the replacement text in §5.5. If F1 is ever needed, go to F2. |
| D2-b | **major** | D2 requests the CP2AP edge-both IRQs "after `ss333_on`" but never disables them. The port's `modem_off` drives CP_ON low (D1 ABI), and then gpa2-5/gpa3-1 float (stock pinctrl: no pull, `K/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:81-92`). The gpa banks share the muxed wakeup EINT with BT host-wake and MUIC (KP §5.1). | `stop_pm` disables both IRQs (`disable_irq`) **before** CP_RESET/CP_ON change. Add a storm guard: more than 1000 edges in 1 s → `disable_irq_nosync` + one log line. Counters stay readable in debugfs. |
| D2-c | minor | `stop_pm` lowers AP2CP_WAKEUP/STATUS (S:489). Stock `stop_link_pm` does not touch them (`link_device_pm.c:846-872`), so stock leaves AP2CP_STATUS high across an off. This deviation is harmless (BOOT waits for the line to rise after `BOOT_ON`), but it is not "stock" behaviour. | Note it as a deliberate deviation. |
| D2-d | minor | `pm_mode=lockon` "only value" is fine. G10's evidence counts only `Unmount`. | Also count `HIBERN8_ENTER_DONE`, `PLU_DETECT`, CP2AP_WAKEUP falling edges and `Error sent`. A CP that tries to sleep and is refused would show CP2AP_WAKEUP low with no unmount: that is the signal that F2 is wanted for power. |

### D3. Shared memory: agree with changes

Verified: the stock ION carveouts leave exactly 8 MiB between `common` (0xdda00000 + 0x600000,
ends at 0xde000000) and `mfc_sh` (0xde800000) (`dumps/live_fdt.dts:1911`). Our DT keeps the same
hole (`ML/arch/arm/boot/dts/samsung/exynos5433-gts28ltexx.dts:214-222`), and BL shows
`[0xde000000-0xde7fffff]` as an ordinary memory range today. The remap arithmetic
(`(0xde000000>>23)<<8 | 23 | 0x80 = 0x0001BC97`, `K/…/exynos-mipi-lli.c:68-90`, `.h:245-246`)
is exact: it is arithmetic on proven code, so "P" instead of "I" for the value. The ARM32
`ioremap` guard refuses RAM that is still map memory (`ML/arch/arm/mm/ioremap.c:318-320`),
so `no-map` is required (as D3 says).

| # | Sev | Finding | Required change |
|---|---|---|---|
| D3-a | **blocker** | **The remap is protected once (G3), not per boot.** In 3.10 the remap is written only inside `exynos_lli_setting()`, called from hard IRQ at `SW_RESET_DONE`. Its return value is ignored, and on a remap error it returns after having written the PMU and PA registers (`exynos-mipi-lli.c:296-308,911-914`). The AP slave then answers any `HIBERN8_EXIT_DONE` with `LLI_MOUNT_CTRL` unconditionally (`:926-932`). A mount with remap registers at reset value would send CP accesses to an unknown AP address. This is the "silent AP memory corruption" risk of S:89-91. | Per-boot interlock (exact text in §5.1): `remap_ok` recomputed from a readback at every `SW_RESET_DONE`; `LLI_MOUNT_CTRL` written only if `remap_ok`; `ss333_on` releases CP_RESET only after its own `SW_RESET_DONE` and `remap_ok`. |
| D3-b | **blocker** | **A failed reservation still prints the `OF: reserved mem:` line.** Our own boot log shows `failed to reserve memory for node 'sec-log@25fff000'` (BL:7) and then `OF: reserved mem: … nomap non-reusable sec-log@25fff000` (BL:31). `__reserved_mem_reserve_reg()` returns 0 after its `pr_err` (`ML/drivers/of/of_reserved_mem.c:187-197`), so `of_reserved_mem_lookup()` still succeeds. The D3/G2 checkpoint "`OF: reserved mem: 0xde000000..` line" (S:500, S:614) does not prove the reservation. The LLI driver would program a remap onto memory the page allocator owns. The ARM `ioremap` WARN only protects the modem driver's mapping, not the remap. | Probe check: `region_intersects(base, size, IORESOURCE_SYSTEM_RAM, IORES_DESC_NONE) == REGION_DISJOINT` (exported, `ML/kernel/resource.c:629-640`), else refuse to bind. G2 evidence: no `failed to reserve memory for node 'cp-shmem@de000000'` line, and `/proc/iomem` without System RAM in [0xde000000, 0xde980000). |
| D3-c | **major** | **Exposure beyond 8 MiB is unknown (U2), and the U2 fallback "try another 8 MiB-aligned no-map base" (S:684) makes it worse.** CP MPU region 3 is 256 MiB (RI §2.4). The remap word encodes the size (bit_pos 23), so masking to 8 MiB is plausible but not proven. At 0xde000000, everything above the region is no-map ION (0xde800000-0xde91ffff) except **384 KiB of ordinary RAM 0xde920000-0xde97ffff** (BL "Early memory node ranges"), and DRAM ends at 0xde980000. Any lower base would expose up to 248 MiB of live kernel memory to a non-masking IAL. | Add `cp-guard@de920000 { reg = <0xde920000 0x60000>; no-map; };` so that all DRAM from 0xde000000 to the end of DRAM is no-map. Rule: the region base is 0xde000000; any other base needs owner approval **and** all DRAM in [base, min(base + 256 MiB, DRAM end)) no-map. Canary: fill the guard and the unused upper 4 MiB of the region before B2; check them after G7 and after G8 `--stop-after=nv` (only BOOT runs then; SBD may later use the upper half). |
| D3-d | minor | Rationale (S:499): "strongly-ordered … has the same ordering and alignment rules as Device memory on ARMv7". Alignment: yes. Ordering: no. SO accesses complete in program order and are not buffered. Device ordering is only guaranteed within an implementation-defined peripheral block, so data at +0x3000… and indices at +0x18 are **not** ordered without a barrier. | Reword: "Device keeps the stock alignment semantics and removes write merging; it does not remove the need for barriers, which D3 adds in both modes." |
| D3-e | minor | The vendor code uses plain `memcpy`/`memset` on `__iomem` buffers (`K/…/include/circ_queue.h:254-300`, `link_device_bootdump.c:173`, `link_device_memory_sbd.c:398`). On Device memory, a compiler-inlined unaligned word access faults → oops → `oops=panic` reboot. Stock ran the same code on SO, so the risk is moderate. | Convert ring copies to `memcpy_toio`/`memcpy_fromio` and require `make C=1` with zero new `__iomem` warnings (O1). |
| D3-f | minor | KP §2.1: "`no-map` ⇒ `pfn_valid()` false". Wrong on ARM32 6.12: `pfn_valid()` is true when the pageblock overlaps `memblock.memory`, which keeps NOMAP ranges (`ML/arch/arm/mm/init.c:126-145`); BL lists the hole as an early memory range. No design consequence, since `ioremap` is decided by `memblock_is_map_memory`. | Correct the KP note (C50 below). |

### D4. Loader: agree with changes

| # | Sev | Finding | Required change |
|---|---|---|---|
| D4-a | **major** | **eFuse window.** BOOT's order is mount → sideband (CP2AP_STATUS rises, hypothesis) → I2C → **eFuse compare and program** → magic read (RI §2.3 steps 6-11; §2.8: each program cycle toggles a PMIC rail over I2C). The `spi` and `lli` rungs end with `MODEM_OFF` (S:508) right after `cp_status` = 1, which is inside that window. On this tablet the slots probably already match (RI §2.8, I), but interrupting OTP programming is irreversible. | Rule text in §5.2: no CP power-off or reset between `cp_status` = 1 and either the first `0xA00D` or 3 s, whichever comes first. The rungs honour it (`--settle=3s` default). |
| D4-b | **major** | BOOT bytes: the CRC is checked in preflight (F4), but B7's buffer origin is not stated. NV is snapshotted (no TOCTOU); BOOT is not. | Read BOOT once into memory in preflight; check CRC32 0x5DB1F04C **and** a pinned SHA-256 of the 0x29FC-byte slice (computed offline from the backed-up `radio.img`); B7 writes that buffer. The kernel tripwire (D1-d) is the second line. |
| D4-c | **major** | Retries: "3 per start" + systemd restarts, combined with D1-c, give non-independent attempts and up to 9 CP power cycles per 10 min. | `--attempts=1` during gates G4-G9. Install the unit **disabled** until G11 passes (enabling it before the reboot path is proven lets systemd power-cycle the CP unattended). |
| D4-d | major | NV Mode A provisioning mounts EFS on the tablet (`blockdev --setro` + `ro,noload`, S:509). Safe, but avoidable. `noload` also gives a view without the journal, so it may be stale. | Default: extract `nv_data.bin` (+ `.md5`) **on the Mac** from a **copy** of G0's raw EFS image (e2fsprogs `debugfs -c -R 'dump …'`). If `e2fsck -n` on the copy reports a journal to replay, replay it on a second copy and extract from that. Compare the result with the TWRP EFS backup, then push it to `/var/lib/shannon/nv/` with its SHA-256. The tablet never mounts EFS. Keep `ro,noload` as the fallback. |
| D4-e | minor | Preflight only logs `MIPI-LLI 0`/`0` (LS2 F6, "not enforced"). | Refuse unless `/sys/module/sec_modem_v1/parameters/allow_hw` = `Y`. If `cp_status` = 1 before B2, a CP is alive from an earlier session: log it and run `MODEM_OFF` first. |
| D4-f | minor | Rung discipline for G8 (`toc`, then `main`, `nv`, `fin`, each a full CP boot) adds power cycles without adding information: one full transcript shows every stage reply. | Rungs one by one through G7 (new territory); at G8 run `--stop-after=fin` first and use the rungs only to bisect a failure. |

### D9. Security and privacy: agree with changes

Verified: with `dflags = 0`, `log_ipc_pkt()` returns before any dump for every channel
(`K/drivers/misc/modem_v1/modem_utils.c:286-322`; the final `!DEBUG_FLAG_UNKNOWN` return). The
IPC logger `mif_ipc_log()` has no caller in the tree (grep), so `IOCTL_MIF_LOG_DUMP` exports no
payload. `pr_skb`/`pr_buffer`/`mif_print_dump` have no callers. The only remaining unconditional
print is 4 header bytes in `BAD MSG` (`link_device_memory.c:89-91`), which is acceptable.

| # | Sev | Finding | Required change |
|---|---|---|---|
| D9-a | **major** | Node modes: "other `umts_*` 0660 root:radio" (S:554) includes `umts_dm0` (DIAG/SDM: on Shannon it can read and write NV) and `umts_router` (Samsung factory AT commands can reach NV), both relevant to rule 4, plus `umts_ramdump0` (CP RAM). | `umts_boot0`, `umts_ramdump0`, `umts_dm0`, `umts_router`, `ipc_loopback0`: 0600 root. Only `umts_ipc0`, `umts_rfs0` (and later `umts_csd`) 0660 root:radio. G13 runs as root, on its own. |
| D9-b | major | debugfs `svnet/mem_dump` (kept, D1) dumps the shared region, which holds FMT/RFS ring contents (SMS, numbers, IMSI) after ONLINE. | Treat `mem_dump` and any shmem readout as payload: private directory only, never with a SIM inserted, never pasted into notes. |
| D9-c | major | `dflags ≠ 0` (or any kernel hex dump) lands in the journal on the **persistent root** (journald `Storage=auto` with `/var/log/journal`) and in pstore (`ramoops@26446000`, console 512 KiB), which `systemd-pstore` may archive to disk. "Payload logging … only under `$T715_PRIVATE/`" is then not true. | `dflags ≠ 0` only in a session with `journald Storage=volatile` and `systemd-pstore` masked, then reboot and clear pstore. `shannond --log-payload` writes to tmpfs, which is copied off and deleted. |
| D9-d | major | No rule keeps the SIM out during G4-G12, so IMSI/ICCID can appear in FMT/RFS traffic and in `mem_dump` before any of the privacy machinery has been tested. | SIM absent until G14 (also reduces RF activity during bring-up). |

---

## 2. Factual errors, unsupported claims, inconsistencies

| # | Sev | Location | Statement | Correct statement | Evidence |
|---|---|---|---|---|---|
| E1 | **major** | §2.3 S:152, G11 S:628 vs D1 S:475 | `ss333_off` "**CP_ON stays high**"; G11: "CP_ON left high: note (stock behaviour)" | Stock leaves CP_ON high. The port (D1) drives CP_RESET then CP_ON low unconditionally. G11's expected evidence must be the port behaviour (CP_RESET 0, CP_ON 0, `current_now` back to baseline), not "note". | `K/…/modem_ctrl_ss333.c:211-272`; S:475 |
| E2 | **major** | §2.2 S:143 | Pinctrl caveat covers only "no output function on CP_ON/CP_RESET" | KP §3.4's `cp-ctrl-out-*` groups also set `samsung,pin-pud = <PULL_NONE>` on CP_ON, CP_RESET, PDA_ACTIVE, AP_DUMP_INT. With `allow_hw = 0` these stay **inputs** (ASIS) with the SoC pull removed: if the board has no external resistor, CP_ON and CP_RESET float from G2 on. Stock never set a normal-mode PUD on these pins (only `pin-con-pdn`/`pin-pud-pdn`) and drove them as outputs at probe. G2's own criterion "CP pins unchanged vs G1" contradicts KP's DT. Fix: the default state carries no normal-mode `samsung,pin-pud`/`pin-function` on any AP→CP output; G1/G2 compare CON/DAT/PUD/DRV byte for byte. | `K/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:43-71,96-114`; KP §3.4; `ML/drivers/pinctrl/samsung/pinctrl-samsung.c:287-303` (debugfs prints CON/DAT/PUD/DRV) |
| E3 | minor | §2.1 S:115 | cmdline source `exynos5433-gts28ltexx.dts:114` | sboot replaces DT `bootargs` (dts comment `:106-112`); the effective options come from `CONFIG_CMDLINE` (+`CMDLINE_EXTEND`), which also carries `s3c2410_wdt.tmr_atboot=1`: the watchdog runs from boot and a kernel kthread pings it | CFG `CONFIG_CMDLINE=…`; `docs/hardware/WATCHDOG.md:132-161` |
| E4 | minor | §1 S:93-95 risk 5 | bus hang / IRQ storm "ends in a watchdog reset" | Either a watchdog reset (sboot then boots the RECOVERY rescue) or, if one CPU stalls on the interconnect while the watchdog kthread still runs on another, a frozen-but-pinged system that only a forced restart ends | `docs/DEPLOY.md` §13 "Linux frozen: ping answers…"; KP R-4 has the same over-claim |
| E5 | minor | §2.1 S:117 | base "top of DRAM 0xde980000, below the ION hole"; remap value "I (arithmetic)" | "in the 8 MiB hole between the stock ION carveouts `common` (ends 0xde000000) and `mfc_sh` (0xde800000)"; the remap value is P (arithmetic from proven code); the base stays I | `dumps/live_fdt.dts:1911`; D3 above |
| E6 | minor | §2.16 S:404; C45 | "gap between mounts 0.41-32 s (median 3.0 s)" | Mount-to-mount interval 0.415-32.16 s, median **2.83 s** (24 intervals). Down-time (Unmount → next Mount) 0.036-31.8 s, median 2.46 s. One 36 ms outage shows remounts can be almost immediate. | DM, LLI lines, recomputed |
| E7 | minor | C25 S:443 | "needs hardware" with only code order as evidence | Add evidence: in all 25 stock (MAIN) remounts, `CP2AP_STATUS_HIGH` is logged 1.8-2.0 ms after `HIBERN8_EXIT_DONE`, within 0.1 ms of `Mount intr` (8 before, 17 after). At run time the CP raises CP2AP_STATUS at mount completion, which supports RI's reading for BOOT. Consequence for G5: `cp_status` = 1 most likely **already implies** the LLI mount (and CP access to shmem). | DM timestamps |
| E8 | minor | D3 S:499 | SO "has the same ordering … rules as Device" | see D3-d | ARMv7 memory model |
| E9 | minor | D1 S:478 | overlay argument | see D1-e | — |
| E10 | minor | §5 rule 15 S:580 and D1 S:476 vs G9 S:626 | blocklist "until G9" vs "remove … only after G10" | One rule: blocklisted until **G11** passes (autoload and an enabled loader are only safe once the off/reboot path is proven) | — |
| E11 | minor | §5 rule 2 S:567 | denylist "RADIO, EFS, m9kefs1-3, BOOTLOADER, PARAM (nor CDMA-RADIO)" | DEPLOY's list also has BOTA. There is no BOOTLOADER partition in `by-name` (sboot lives in the eMMC hardware boot partitions). Use an allowlist instead (§5.2 rule 2). | `docs/DEPLOY.md` §2; `dumps/by-name.txt` |
| E12 | minor | KP §2.1 (cited by D3) | `no-map ⇒ pfn_valid() false` | `pfn_valid()` is true for NOMAP ranges on ARM32 6.12 | `ML/arch/arm/mm/init.c:126-145` |
| E13 | minor | §9.1 row "§5.3 l.492-494" | location | l.490-495 is in BR §3.6, not §5.3 (anchor only; the correction itself is right) | BR |

**Contradiction log rows to add**

| # | Topic | A | B | Resolution |
|---|---|---|---|---|
| C46 | Mapping default | KP §0.1/§2.6: `ioremap_wc` | D3: `device` | D3 (with D3-d/e); record it, the synthesis silently overrode KP |
| C47 | Hang outcome | KP R-4: "ends in the AP watchdog" | DEPLOY §13: kernel keeps pinging, system frozen | plan for both (§5.2 rule 22) |
| C48 | CP_ON after off | §2.3/G11: stays high (stock) | D1: driven low | D1; fix G11 |
| C49 | LLI reset electrical state | G3: CP_ON = CP_RESET = 0 | stock `ld->reset` always ran with CP_ON = 1, CP_RESET = 0 (`modem_ctrl_ss333.c:187-198`) | no stock precedent for G3's state; acceptable (AP M-PHY stays in HIBERN8 as slave), but list it; see D1-c for the AFC side effect |
| C50 | `pfn_valid` on no-map | KP §2.1 | ML `init.c:126-145` | ML; no design change |
| C51 | Blocklist duration | rule 15, D1: G9 | G9 row: after G10 | G11 (E10) |

**Checked and correct (no change):** S:105-114, S:116, S:118 (offsets, IRQ indices, doorbell
registers, M-PHY values including `init-gear <2 2 1>` = HS-G2-A, `exynos-mipi-lli-mphy.c:26-49,
190-205`), the 0x6Fnn values, the `shmem_4mb_phys_map` offsets (sum = 0x400000), `MIF_INIT_TIMEOUT`/
`FORCE_CRASH_ACK_TIMEOUT`, C01-C05, C09, C10, C14, C15, C33-C35, C42-C43, the `ss333_on/off`
sequences (`modem_ctrl_ss333.c:159-272`), the PHONE_ACTIVE logic, the cp_status sysfs path
(valid because KP §3.3 places `mif_pdata` at the root; a node under `soc` would be named
`soc@0:mif_pdata`). §9 anchors spot-checked: BR, CBD_RE and LS1 rows are within ±2 lines,
except E13.

**§9.4 additions** (minor): define the `SET_TX_LINK` argument values (`LINKDEV_SPI 3`,
`LINKDEV_LLI 10`); fix the header comment "arm32 kernel / arm32+arm64 userspace", since
`struct modem_firmware` holds a `char *` and only ARM32 userspace exists on this kernel; note
that `IOCTL_MIF_LOG_DUMP` copies an `unsigned long` (4 bytes).

---

## 3. Safety

### 3.1 Findings

| # | Sev | Issue | Where |
|---|---|---|---|
| F1 | **blocker** | Remap protected by a one-time gate, not per boot; a failed reservation looks like a good one | D3-a, D3-b |
| F2 | **blocker** | G3 corrupts the M-PHY AFC state for the rest of that boot (misdiagnosis of the riskiest gates; retries not independent) | D1-c |
| F3 | **major** | eFuse programming window can be interrupted by the `spi` rung; no kernel guard on SPI payload | D4-a, D1-d |
| F4 | **major** | Floating CP_ON/CP_RESET from G2 because of `pin-pud = NONE` on ASIS inputs | E2 |
| F5 | **major** | Rollback assumes a running Linux (`t715-reboot-to`); a hang needs the owner's hands (forced restart, Download-mode keys); pstore is not in the procedure; no owner-presence precondition | §5 rules 20-21; G2-G3 rollback |
| F6 | **major** | Blocklist ordering: the initramfs installs BOOT's whole `lib/modules/<rel>` into the persistent root (`boot/initramfs/init:845-873`), so udev can autoload the LLI and modem modules by OF modalias at the **first** boot of a modem BOOT image, before G1 is re-checked. The blocklist must exist before that boot. | D1, G2 |
| F7 | **major** | After `oops=panic`, a forced restart or a watchdog reset, `.shutdown` does not run: the CP may stay powered with no driver loaded (modules blocklisted). There is no defined "CP kill" procedure. | §5 |
| F8 | **major** | `allow_hw` 0→1 does not drive the lines | D1-a |
| F9 | **major** | BOOT is a shared resource: any BOOT write by the Omarchy session replaces the modem kernel and vice versa (HO: the Omarchy session deploys) | §5 rule 11 |
| F10 | **major** | No battery or thermal thresholds; no current measurement although the gauge exposes `CURRENT_NOW` (`docs/hardware/BATTERY.md:76`) | rule 19 |
| F11 | **major** | DIAG/AT node modes allow NV-writing interfaces to a group | D9-a |
| F12 | minor | IRQ storms: CP2AP IRQs stay enabled across CP power-off (D2-b); `RESET_ON_ERROR_SENT` without W1C (D1-h); G3 success "counter increments" accepts a storm | D2, G3 |
| F13 | minor | Suspend not blocked | D1-i |
| F14 | minor | Too strict / redundant: rule 8 (never write `lli_control`) becomes structural with 0444 (D1-f); rule 6's `ro,noload` mount becomes unnecessary with Mac-side NV extraction (D4-d) | §5 |

### 3.2 Proposed rule text (replaces or extends §5)

- **Rule 1 (A, replace).** "Only the exact BOOT bytes of RADIO p13 (image[0x200..0x2BFC),
  CRC32 0x5DB1F04C, SHA-256 pinned from the backed-up `radio.img`) ever cross SPI. They are
  checked on the in-memory buffer that B7 writes. The kernel SPI link refuses any other payload
  (size ≠ 0x29FC or CRC32 ≠ `boot_crc`) and allows one SPI write per `MODEM_ON`. Never send a
  modified BOOT/MAIN, a Meizu test loader or another RADIO image. Never power off or reset the
  CP between `cp_status` = 1 and the first of: `0xA00D` received, or 3 s elapsed (eFuse
  provisioning window, RI §2.3 step 9). Battery ≥ 50 % before any CP power-on."
- **Rule 2 (A, replace).** "Partitions are read-only except BOOT and RECOVERY, which are written
  only with `device/write-part.sh` (allowlist, sha256, read-back) or heimdall. Never write the
  whole-disk device, never clear `/sys/block/mmcblk0boot*/force_ro`, never open `mmcblk0rpmb`.
  RECOVERY keeps the rescue (kernel 00021, no modem code) for the whole modem mission."
- **Rule 6 (A, replace).** "EFS, m9kefs1-3, RADIO, CDMA-RADIO, PARAM, BOTA0/1: `blockdev --setro`
  at every boot from a udev rule that also sets `UDISKS_IGNORE=1`, verified with
  `blockdev --getro` = 1 before each gate. EFS is never mounted on the tablet; NV is extracted
  on the Mac from a copy of the raw backup (D4-d)."
- **Rule 12 (A, replace).** "Stage discipline and interlocks. No CMU_CPIF/LLI/SYSREG access
  before G1 has recorded the CMU state and the go/no-go of §4 (G1). The modem probe binds only
  if the shared region is base 0xde000000, size 8 MiB, disjoint from System RAM, and all DRAM
  above it is no-map. The LLI driver writes `LLI_MOUNT_CTRL` only when the remap readback
  matches; `ss333_on` releases CP_RESET only after its own `SW_RESET_DONE` and a matching
  readback. Any interlock refusal ends the session (`MODEM_OFF`, logs, no retry in that boot)."
- **Rule 22 (A, new) Recovery path.** "Before any W gate: the owner is at the tablet (keys
  reachable); the tablet is on USB to an unlocked Mac; battery ≥ 50 % and battery temperature
  < 40 °C; the running BOOT image and its sha256 are on the Mac; the modem modules are
  blocklisted in `/etc/modprobe.d/` **and** through the BOOT knob
  `t715.modblacklist=exynos5433_mipi_lli,sec_modem_v1` before the first boot of a modem BOOT
  image. After any unexpected reboot, hang or forced restart: (1) copy `/sys/fs/pstore/` to the
  private directory before anything reboots again; (2) read the CP lines (pinctrl debugfs:
  gpr3-1, gpc0-5, gpa2-3, gpa2-5) and `current_now`; if the CP may be powered and no modem
  module is loaded, drive CP_ON then CP_RESET low with `gpioset`. BOOT rollback, in order:
  SSH up → `write-part.sh BOOT <previous>`; RECOVERY rescue after a watchdog reset → the same
  from the rescue; frozen → the owner holds Power + Volume down about 10 s; boot loop →
  Download mode (Power + Volume down + Home, then Volume up) → `heimdall flash --BOOT
  <previous>`."
- **Rule 23 (A, new) Single owner of BOOT.** "While a modem gate series is open, only the modem
  mission writes BOOT, and its series is rebased on the daily kernel the Omarchy session last
  validated. Hand-over in both directions is recorded in `docs/journal/HANDOVER.md` with the BOOT
  sha256."
- **Rule 24 (S, new) Session limits.** "Abort the gate and run `MODEM_OFF` if the battery
  falls below 30 % or its temperature reaches 42 °C. Log `capacity`, `temp` and `current_now`
  at 1 Hz during every W gate. `MODEM_OFF` counts as done only when `current_now` is back to
  the G1 baseline ±30 mA within 3 s."
- **Rule 25 (A, new) Nodes and SIM.** "`umts_boot0`, `umts_ramdump0`, `umts_dm0`, `umts_router`,
  `ipc_loopback0`: 0600 root; DIAG and AT stay closed except in their named gate. No SIM until
  G14. `dflags ≠ 0` only with a volatile journal and `systemd-pstore` masked."
- **Rule 15 (S, amend).** "… blocklisted until **G11**; the loader unit is installed disabled
  until G11; `allow_hw` defaults to 0, its 0→1 transition drives every AP→CP line low in stock
  order, and 1→0 is refused unless OFFLINE; suspend targets masked during the mission."

---

## 4. Plan gates

### 4.1 Per gate

| Gate | Sev | Problem | Fix |
|---|---|---|---|
| O1 | major | No `__iomem` audit (needed for D3's `device` default); "no `panic(`" is checked by grep only | `make W=1 C=1`: zero new sparse warnings; `objdump -dr` of both `.ko`: no call to `panic`, `__bug`/`BUG`, `machine_restart`, `emergency_restart`; `modinfo -F vermagic` equals BOOT's release |
| O1b (new) | major | No DT validation beyond "DT compiles" | Script over the compiled DTB: reserved ranges disjoint and inside the memory banks; `cp-shmem` aligned; all DRAM ≥ 0xde000000 no-map; every modem GPIO flag cell 0; IRQ cells `<0 184 4>`/`<0 185 4>`; no normal-mode `samsung,pin-pud`/`pin-function` on AP→CP outputs; `dtc` diff against the 00024 DTB shows additions only. Optional: YAML bindings for the two compatibles + `dt_binding_check`/`dtbs_check`. |
| O2 | major | Vectors are fed open-loop | Add a **CP model** written from RI §2.5-§2.7 (busy-polls `raw_tx_head`, round-up-4, replies with copied cfg/ch, len 8, signal 0x83, the 0xA?0F cases). Drive the ported `xmit_udl`/RX demux compiled in userspace against it: CRC frame 12 bytes (not 16), wrap at 0x1FD000, ENOSPC all-or-nothing, single TOC frame. |
| O4 | minor | CUSE backend is a mock state machine | Back the CUSE device with O2's harness: loader → real ring code → CP model, golden transcript end to end (17 497 writes, FIN) |
| O8 (new) | **blocker** for D1-c/D3-a | Kernel logic has no unit test | KUnit under `qemu-system-arm -M virt` (separate config), or a userspace harness with mocked `readl`/`writel`: `exynos_lli_cal_remap(0xde000000, SZ_8M) == 0x0001BC97`; interlock refuses a bad readback; AFC branch over reset → reset → mount → reset; SPI tripwire; `allow_hw` transitions drive lines in stock order; `modem_off` from every state ends with CP_RESET 0 and CP_ON 0; reset rate limiter |
| O9 (new) | minor | — | Build-only debug fragment (`DEBUG_ATOMIC_SLEEP`, `PROVE_LOCKING`, `DEBUG_SPINLOCK`, `DEBUG_OBJECTS_TIMERS`); use it for G2-G7 if it boots: it catches sleeping regmap/gpiod calls in the hard IRQ and timer misuse at the first run |
| O7 | minor | Kernel side not audited | Also grep the port for GPIO writes outside the `allow_hw` checks, for LLI register access outside the clocked paths, and for any CP_RESET release outside the interlock; check that the image ships `gpioset` (libgpiod) and a `devmem`, or use pinctrl/regmap debugfs instead |
| G0 | major | Precondition gaps | Check that EFS/RADIO are not mounted (`findmnt`); `blockdev --getro` = 1; back up **BOOT p9 and RECOVERY p10** too, compared with the known sha256s; NV via D4-d (Mac-side), compared with the TWRP EFS backup; record `/proc/cmdline`, `uname -r` |
| G1 | major | Data recorded but no go/no-go | Add CMU_MIF `DIV_MIF3` (0x105b060c) and `ENABLE_ACLK_MIF3` (0x105b080c). Read pinctrl debugfs CON/DAT/PUD/DRV of all 12 pins, `/proc/iomem`, `current_now` baseline. **Go only if** ENABLE_ACLK_CPIF (0x10fc0800) bits 1-4, 7, 9-11 and ENABLE_PCLK_CPIF (0x10fc0900) bit 1 (`pclk_sysreg_cpif`) are set: the clock patch models only ENABLE_IP_CPIF0/1 (KP §4.3), so these come from reset/sboot; otherwise make them modelled clocks first. PMU 0x720 can be read from regmap debugfs instead of `devmem`. |
| G2 | **blocker** (F6) / major | One gate mixes a new BOOT, the first CMU/LLI touch and the modem probe; evidence misses the reservation-failure case | **G2a**: new BOOT, modules not loaded (blocklist active from rule 22): non-modem regression (`device/final-interactive.sh`); repeat the G1 reads, which must be byte-identical (the clock patch must change no register); reserved-memory checks of D3-b. **G2b**: `modprobe exynos5433-mipi-lli`: `clk_summary` `aclk_cpif_200` = 100 MHz, LLI gates on; IRQ 184/185 counts 0 and steady for 60 s; pins unchanged. **G2c**: `modprobe sec_modem_v1` (`allow_hw = 0`): nodes as listed; pins byte-identical to G1 (E2); `MODEM_ON` → `-EPERM`. Rollback per rule 22. |
| G3 | **blocker** (F2) / minor | AFC side effect; storm accepted as success; electrical state without stock precedent (C49) | Success: exactly one `SW_RESET_DONE`; remap 0x0001BC97 in both registers; PMU 0x720 = 1; SPI 184 delta ≤ 2 and steady for 60 s; SPI 185 delta 0; no `Error sent`/`PA_REASON`; record `IAL_LL/BE_TARG_ADDR_REMAP` (0x1108/0x110C) and `IAL_OVERLAP_ADDR_CTRL_EN` (0x1144) for reference. Negative test with the CP unpowered: an SPI write of a wrong payload is refused by the tripwire. **Reboot before G4** until O8 proves the AFC fix. |
| G4 | major | Proof that the CP is really powered or off | Add the `current_now` step at CP_ON and at reset release; the interlock log line inside `MODEM_ON`; after `MODEM_OFF`: CP_RESET 0, **CP_ON 0**, current at baseline (rule 24) |
| G5 | major | Evidence misread (E7); eFuse window | Expect `MIPI-LLI 1` already at B8 time (record `lli_control` when `cp_status` rises, and the IRQ timestamps). The CP may access shmem from G5 on: run the canary check (D3-c) after G5. The rung honours the 3 s settle (rule 1). |
| G6 | minor | Mostly merged into G5 by C25 | Keep it as the diagnostic rung for "cp_status = 1 but no `MIPI-LLI 1`" |
| G7 | minor | — | Add the canary check after `0xA00D`. G7 success proves the window base (magic read at offset 0, reply in raw_rx), not the size masking (U2). |
| G8 | minor | Rungs | D4-f; canary after `--stop-after=nv` |
| G9 | minor | — | Also record `cp_status` and PHONE_ACTIVE levels, CP2AP edge counts and `current_now` |
| **G9b (new, before G10)** | **major** | G10 soaks 30 min with no FMT client, so the CP gets no SMS_DEVICE_READY S and no IPC_LOOPBACK CFRM (S:343 says the AP must answer both). A CRASH_EXIT in G10 could not be told apart from link-PM trouble. | Within 2 min of ONLINE: `ipc-probe --passive` (header tuples) with the two mandatory replies and the RFS observe server, no SIM. Evidence: the five start-up NOTIs named, both replies acknowledged, no CRASH_EXIT for 10 min. G12 then extends it. |
| G10 | major | Order and configuration | After G9b **and G11**; soak in the G12 configuration (probe + RFS observe), counters of D2-d, 1 Hz battery/temp/current |
| G11 | major | E1; must precede blocklist removal and unit enable | Evidence: `.shutdown` runs, CP_RESET 0 → CP_ON 0, next boot shows the CP lines low and `current_now` at baseline before any module loads; also `systemctl poweroff` with the CP ONLINE (the CP must not stay powered while the tablet is "off") |
| G12 | minor | — | Header-only logging verified by grepping the private log for absence of payload; SIM still absent |

### 4.2 What can be settled offline before touching the tablet

- **Build only:** O1 (sparse, objdump, vermagic), O1b (DTB checks), O9 debug fragment builds.
- **Unit and harness:** O3/O4 (loader), O2 + CP model (ring), O8 (interlocks, AFC, tripwire,
  `allow_hw`, `modem_off`), O5.
- **From existing data, no device:** the RADIO BOOT-slice SHA-256 to pin (from the backed-up
  `radio.img`); NV extraction from a copy of the raw EFS image (D4-d); C25 timing from DM
  (done above); the go/no-go bits for G1 are fixed in advance (above), so G1 decides by
  comparison only.
- **Cheap on-device reads that replace riskier diagnostics:** pinctrl debugfs (CON/DAT/PUD)
  instead of GPIO pokes; regmap debugfs for PMU 0x720; `current_now` as a CP-power indicator;
  `/proc/interrupts` deltas with bounds; pstore after any reboot.

---

## 5. The five changes that matter most (replacement text for SYNTHESIS.md)

### 5.1 D3: replace the "Checkpoints" row and add an "Interlocks" row (blocker)

> | **Interlocks** | Per boot, in the kernel, not only at G3. (1) The LLI probe binds only if `memory-region` is base 0xde000000, size 0x800000 (any other base needs `shmem_unsafe_base=1` and owner approval, and all DRAM in [base, min(base + 256 MiB, DRAM end)) must be no-map), `size == 2^n`, `base % size == 0`, and `region_intersects(base, size, IORESOURCE_SYSTEM_RAM, IORES_DESC_NONE) == REGION_DISJOINT`. (2) DT adds `cp-guard@de920000 { reg = <0xde920000 0x60000>; no-map; }`, so that all DRAM from 0xde000000 to the end of DRAM is no-map. (3) At every `INTR_SW_RESET_DONE` the driver reads back `IAL_LL/BE_INIT_ADDR_REMAP` and PMU 0x720 and sets `remap_ok`; an `exynos_lli_setting()` error clears it. (4) On `HIBERN8_EXIT_DONE` the hard IRQ writes `LLI_MOUNT_CTRL` only if `remap_ok`, else logs `lli: mount refused (remap %08x/%08x)`. (5) `ss333_on` waits ≤ 100 ms for the `SW_RESET_DONE` of its own `ld->reset` and releases CP_RESET only if `remap_ok`; otherwise CP_ON → 0 and `-EIO`. |
> | **Checkpoints** | G2a: no `failed to reserve memory for node 'cp-shmem@de000000'` line (the `OF: reserved mem:` line alone proves nothing: BL:7 vs BL:31 for `sec-log`); no System RAM in [0xde000000, 0xde980000) in `/proc/iomem`. G3: both remap registers 0x0001BC97, `remap_ok = 1`. G5/G7/G8: canary in the guard and in the upper 4 MiB of the region unchanged. |

### 5.2 Rule 1: replace (major; irreversible risk)

> | 1 | **Only the exact BOOT bytes of RADIO p13 cross SPI**: image[0x200..0x2BFC), CRC32 0x5DB1F04C and the pinned SHA-256 of that slice, checked on the in-memory buffer that B7 writes. The kernel SPI link refuses any other payload (length ≠ 0x29FC or CRC32 ≠ `boot_crc`) and allows one SPI write per `MODEM_ON`. Never a modified BOOT/MAIN, a Meizu test loader or another RADIO image. **Never power off or reset the CP between `cp_status` = 1 and the first of `0xA00D` received or 3 s elapsed** (BOOT compares and programs eFuse slots in that window). Battery ≥ 50 % before any CP power-on. | BOOT programs CP eFuse key slots when blank or different; OTP is irreversible | A | RI §2.3, §2.8; KD Q6 |

### 5.3 D1: add an "M-PHY state and allow_hw" row; replace the G3 row (blocker)

> | **M-PHY AFC** | 3.10 runs AFC only in the first `cmn_init` after boot and saves the code only at the first `MOUNT_DONE` (`exynos-mipi-lli-mphy.c:55,79-88`; `exynos-mipi-lli.c:841,853-858`); a second reset before a mount programs AFC override with code 0. The port uses `phy->afc_valid`: AFC branch while it is false, set only at a `MOUNT_DONE` with DL credits. Until O8 and the bench prove it: reboot between G3 and G4, and `--attempts=1`. |
> | **allow_hw** | Bool, default 0, with a `set` callback. At 0 nothing on the modem side drives a line, and the LLI module has done only the documented G2b side effects (assigned clocks, gate enable, INTR register clear). 0→1 (state OFFLINE only) drives CP_ON 0, CP_RESET 0, PDA_ACTIVE 0, AP_DUMP_INT 0, AP2CP_STATUS 0, AP2CP_WAKEUP 0, IPC_INT2CP 0 in this order, requests the CP2AP/PHONE_ACTIVE IRQs (disabled) and logs the pin registers; 1→0 is refused unless OFFLINE. The pinctrl default state sets no normal-mode `pin-function`/`pin-pud` on any AP→CP output. |

> | **G3** LLI alone, CP unpowered (S2) | G2c; G1 go/no-go passed | `allow_hw = 1`; debugfs `ss333/lli_reset` once; SPI tripwire negative test | exactly one `SW_RESET_DONE ++`; remap 0x0001BC97 ×2, `remap_ok = 1`; PMU 0x720 = 1; `PA_SYSTEM_CLK_PERIOD` = 10; mount bit clear; SPI 184 delta ≤ 2 and steady for 60 s; SPI 185 delta 0; no `Error sent`/`PA_REASON`; wrong SPI payload refused | bus hang → rule 22 path, pstore, compare the G1 dump; no `SW_RESET_DONE` → IRQ index/type, INTR_ENABLE; remap mismatch → stop the series | **reboot** (AFC), `allow_hw = 0` | W |

### 5.4 §5: add rule 22 (recovery path) and fix G2 (major)

> Rule 22 as in §3.2, and G2 replaced by G2a/G2b/G2c as in §4.1. Change the G2 rollback to:
> "rule 22 rollback order; the blocklist (`/etc/modprobe.d` + `t715.modblacklist=`) is
> installed and checked on the running daily kernel before `write-part.sh BOOT`".

### 5.5 D2 F1 and the G9→G10 order (major)

> | **Fallback** | F1 (only if G10 counts an `Unmount`): replay the stock remount handshake, not a bare reset. On `INTR_LLI_UNMOUNT_DONE` the LLI driver has already re-armed itself (`exynos-mipi-lli.c:1003-1007`). The PM code lowers AP2CP_STATUS and AP2CP_WAKEUP (stock `UNMOUNTING→UNMOUNTED`, `link_device_pm.c:599`). On pending TX or a CP2AP_WAKEUP rise it raises AP2CP_WAKEUP and waits ≤ 500 ms for CP2AP_WAKEUP high. It then calls `mipi_lli_reload()`, raises AP2CP_STATUS on `SW_RESET_DONE` (`:473-477`) and waits ≤ 500 ms for `LLI_MOUNTED` (`remap_ok` still required). One try per event, at least 1 s apart; on failure CRASH_EXIT and the supervisor's silent reset. If F1 fires more than once per hour, take F2 (verbatim FSM, `pm_enable = 1`). CP2AP IRQs are disabled before any CP_RESET/CP_ON change, with a storm guard (> 1000 edges/s → `disable_irq_nosync`). |

> Insert **G9b** (first FMT within 2 min of ONLINE, passive header log + SMS_DEVICE_READY S +
> IPC_LOOPBACK CFRM + RFS observe, no SIM, no CRASH_EXIT for 10 min) between G9 and G10. Make
> G10 depend on G9b and G11 and run in the G12 configuration. Remove the blocklist and enable
> the loader unit only after G11.

---

## Appendix: verification log (what was re-read)

- `K/drivers/misc/mipi-lli/`: `mipi-lli.c` (store/show `:240-313`, sig IRQ, add_driver
  `:438-485`), `exynos-mipi-lli.c` (remap `:68-90`, reg dump `:141-185`, init/setting
  `:271-385`, signal `:434-500`, gating `:517-565`, IRQs `:834-1022`, probe `:1071-1208`),
  `exynos-mipi-lli-mphy.c:26-152,155-222`, `exynos-mipi-lli.h:18-47,141-151,160-260`.
- `K/drivers/misc/modem_v1/`: `link_device_lli.c:41-42,213-233,589-620`; `link_device_pm.c`
  (FSM `:375-610`, start/stop `:795-872`, GPIO parse `:1026-1092`); `modem_ctrl_ss333.c:45-587`;
  `modem_main.c:294-382`; `modem_utils.c:58-335`; `modem_io_device.c:163-183,1270-1285,1786-1840`;
  `link_device_memory.c:85-95,220-240`; `include/circ_queue.h`; `include/sipc5.h:93-97`.
- `K/arch/arm/boot/dts/exynos5433-modem-ss333.dtsi:20-176`; `dumps/live_fdt.dts:1909-1925,4743-4744`.
- `ML/`: `drivers/of/of_reserved_mem.c:141-197`; `arch/arm/mm/ioremap.c:305-330`;
  `arch/arm/mm/init.c:120-146`; `kernel/resource.c:629-640`; `drivers/base/platform.c:1367`;
  `drivers/base/dd.c:694`; `drivers/soc/samsung/exynos-pmu.c:240-345`;
  `drivers/base/regmap/regmap-mmio.c:398`; `drivers/pinctrl/samsung/pinctrl-samsung.c:281-312,437-470`,
  `pinctrl-exynos-arm64.c:28-80`, `pinctrl-exynos.h:94-113`; `drivers/spi/spi-s3c64xx.c:378-410,793-842`;
  `drivers/clk/samsung/clk-exynos5433.c:839-915`; `include/dt-bindings/clock/exynos5433.h:191-199`;
  board `exynos5433-gts28ltexx.dts:88-230`.
- Project: `docs/journal/HANDOVER.md`, `docs/DEPLOY.md` §2, §10, §11.7, §13,
  `docs/hardware/WATCHDOG.md`, `docs/hardware/BATTERY.md`, `device/README.md`,
  `device/write-part.sh:1-20`, `boot/initramfs/init:44-47,835-891,1309-1323`,
  `kernel/kbuild-mainline.sh`, CFG, BL.
- DM, LLI/PM lines only, recomputed with a script: mount/unmount counts, up and down times,
  remount causes, the CP2AP_STATUS vs `Mount intr` timing, suspend counts (10 "Entering mem
  sleep", 2 "Some devices failed to suspend", i.e. 8 completed suspends, as S states).
