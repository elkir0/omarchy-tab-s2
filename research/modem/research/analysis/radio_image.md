# RADIO image (Shannon SS333, SM-T715): static analysis of TOC, BOOT and MAIN

Scope: what the CP's first-stage loader (BOOT) and main firmware (MAIN) expect from the
AP during boot, so that a independent Linux loader can be written. Static and offline
only. No firmware was executed or emulated, and the tablet was not contacted.
EFS, `nv_data` and `m9kefs` were not opened.

Inputs:
- `dumps/radio.img` (RADIO, p13, 0x5800000 bytes).
- `dumps/radio-cdma.img` (4 MiB).
- The TWRP raw backups of the same two partitions.

Tools: python3 (`-I`), capstone 5.0.7 (in a scratch venv) and the existing
`radio_toc.py`.

Marks used throughout:
- **[proven]**: backed by a byte offset, an instruction address, or a kernel source line.
- **[inferred]**: reasoning given; not directly observable in the bytes.

Address convention:
- BOOT is linked and loaded at CP address 0 (TOC load_addr 0). Every BOOT code or data
  address below is a **CP address**, and image offset = CP address + 0x200.
- The link address 0 is proven: absolute literals point into the image. For example, the
  literal 0x27e8 loaded at 0x284 is the date string at BOOT+0x27e8.
- Kernel paths are relative to `src/kernel_universal5433/`.

---

## Key findings (summary)

1. **MAIN is encrypted; BOOT is plaintext ARM.**
   - BOOT is plaintext A32 ARM code with a signed header and trailer.
   - MAIN (34.7 MB) is uniformly encrypted:
     - Entropy is about 8.0 bits/byte everywhere.
     - It uses a chained 16-byte block cipher whose IV restarts every 64 KiB.
   - BOOT decrypts MAIN on the CP with a hardware engine at CP 0x81003000. Neither the
     AP nor cbd plays any part in the decryption.
2. **The download protocol, read from the CP side, matches cbd exactly.** It adds hard
   constraints that cbd never states:
   - The TOC must be sent as one frame.
   - FIN `0x9f00` is mandatory: it is the only way BOOT jumps to MAIN.
   - Never send a CRC step for the TOC or for NV.
   - Every message must be exactly one 4-byte-padded SIPC5 frame.
   - BOOT has **no timeouts**. Any protocol error makes BOOT print `XxX!` on the CP UART
     and spin forever, so recovery means a full CP power cycle.
3. **The CP's view of the shared memory is the kernel's `shmem_4mb_phys_map`, mapped at
   CP 0x30000000.**
   - BOOT reads the magic **once**; it must be `0x424F4F54` "BOOT" or "DUMP".
   - BOOT busy-polls `raw_tx_head` and needs no AP→CP doorbell.
   - It answers on the `raw_rx` ring plus a CP→AP doorbell value `0x83`.
4. **The CP is the MIPI-LLI master and starts the mount.**
   - BOOT writes `MASTER_NOT_SLAVE|LLI_MOUNT_CTRL` and then waits without limit for
     `LLI_MOUNT_DONE`.
   - The AP kernel mounts as slave from its IRQ handler.
   - So a loader never writes `lli_control`, which settles U-7.
5. **In this image the MAIN CRC value sent by the AP is ignored.**
   - The BOOT header carries the `HASH` magic, which sets BOOT's secure flag.
   - With that flag set, BOOT CRCs the *decrypted* MAIN against a CRC stored inside the
     plaintext.
   - A 272-byte MAIN trailer (version word + 256-byte signature) sits after TOC.size in
     the partition and is never sent.

---

## 1. TOC, partition identity, `radio-cdma.img`

**Hashes and identity.**
- `dumps/radio.img` and TWRP `modem.emmc.win` are byte-identical: `cmp` reports no
  difference, and both have SHA-256 `63a02cb6…a8cd`, matching TWRP's `.sha2` file.
  **[proven]**
- `dumps/radio-cdma.img` and TWRP `modem-cdma.emmc.win` are identical, SHA-256
  `bb9f8df6…3af8`. **[proven]**

**`radio-cdma.img`.** All 4,194,304 bytes are 0x00: the most common byte is 0x00 with a
count of 4,194,304, and there are no non-zero 4 KiB blocks. **[proven]**
- It holds no TOC and no second CP image. On this LTE-only SKU the CDMA-RADIO partition
  is unused. **[proven for content; "unused" inferred]**

**TOC** (`radio_toc.py`, CRCs recomputed with zlib): **[proven]**

| slot @img | name | offset | load_addr | size | crc32 | idx | check |
|---|---|---|---|---|---|---|---|
| 0x00 | TOC | 0 | 0 | 0x200 | 0 | 1 | self-record |
| 0x20 | BOOT | 0x200 | 0x00000000 | 0x29fc | 0x5db1f04c | 0 | CRC OK |
| 0x40 | MAIN | 0x2c00 | 0x40000000 | 0x21271a0 | 0x1e71169c | 2 | CRC OK |
| 0x60 | NV | 0 | 0x47ee0000 | 0x100000 | 0 | 3 | no data in image |
| 0x80 | OFFSET | 0x7aa00 | 0 | 0x85600 | 0 | 4 | no stored CRC |
| 0xa0–0x1ff | — | all zero | | | | | |

**Partition map.** **[proven]**

| image range | content |
|---|---|
| 0x0–0x200 | TOC |
| 0x200–0x2bfc | BOOT |
| 0x2bfc–0x2c00 | 4 zero bytes |
| 0x2c00–0x2129da0 | MAIN |
| 0x2129da0–0x2129eb0 | 272-byte MAIN trailer, outside the TOC (§3.3) |
| 0x2129eb0–0x5800000 | zeros |

**What BOOT reads from the TOC.** BOOT uses a TOC entry only through its **slot
position** and only its `load_addr` (+0x10) and `size` (+0x14) fields, plus the name for
printing. The `offset`, `crc32` and `index` fields are never read by BOOT
(§2.5, 0x1758–0x1940). **[proven]**

---

## 2. BOOT (image 0x200, 0x29fc bytes, CP load address 0)

### 2.1 Entropy and container layout

**Entropy.** In 512-byte blocks, entropy is 5.0–5.8 bits/byte from BOOT+0x0 to +0x2400,
the range of ARM code and literals. **[proven]**
- The 1 KiB from BOOT+0x23e0 is the standard reflected CRC-32 table (poly 0xEDB88320):
  entry[1]=0x77073096 is at BOOT+0x23e4. **[proven]**
- The last 512 bytes have high entropy (signature, 7.53 bits/byte measured over
  512 bytes). **[proven]**

**Layout:**

| BOOT offset | content | mark |
|---|---|---|
| +0x00–0x1f | ARM vector table: `b 0x74` (reset); undef/svc/pabt/dabt/irq/fiq = `ldr pc,=0x400000xx` (forwarded into MAIN's vectors at 0x40000004…0x4000001c); +0x14 = `b .` | [proven] |
| +0x20 | 0x000027e4 → pointer to a version word (BOOT+0x27e4, bytes `00 00 00 02`) | [proven value; "version" inferred] |
| +0x24 | 0x000027e8 → pointer to the build date string "Oct 21 2015" (printed at 0x284) | [proven] |
| +0x28 | 0x000029fc = total BOOT size (= TOC size) | [proven] |
| +0x2c | 0x00310000, meaning unknown | [proven value] |
| +0x30 | magic 0x48415348 (bytes "HSAH", i.e. "HASH") | [proven] |
| +0x34–0x73 | 64-byte field (SHA-512-sized) | [proven size] |
| +0x74–0x23df | code + literal pools | [proven] |
| +0x23e0–0x27df | CRC-32 table (used by `crc32()` at 0x133c, literal 0x23e0 at 0x1378) | [proven] |
| +0x27e0 | runtime "secure" flag word (0 in image; written at 0x314/0x320) | [proven] |
| +0x27e4 | version word `00 00 00 02` | [proven] |
| +0x27e8–0x27fb | "Oct 21 2015" + zero padding | [proven] |
| +0x27fc–0x29fb | 512-byte high-entropy block = signature (RSA-4096-sized) | [proven position/size; "signature" inferred] |

**Comparison with the published template.** This matches the Comsecuris template from
the research notes: preamble[8], rev, date, size, unk, hash_magic, sha512[64], code,
signature[512]. In this image, "rev" and "date" are pointers. The trailer is
512 + 28 bytes of metadata, not "512 + 16". **[proven]**

**The 64-byte field is not a plain digest of BOOT.**
- It is not the SHA-512, SHA-384, SHA-256, SHA-1 or MD5 of any contiguous 4-aligned
  BOOT range tested:
  - starts 0…0x7c, any end;
  - any start, ends 0x27e4/0x27e8/0x27fc/0x29fc;
  - header plus code with the field excluded;
  - word-swapped variants.
- It is also not a hash of MAIN.

  **[proven negative over the tested set]**
- BOOT's only use of the field is eFuse provisioning (§2.8). It is most likely the hash of
  the BootROM's verification key, not a code digest. **[inferred]**

### 2.2 CPU and instruction set

- The whole code region decodes as A32 ARM. **[proven]**
  - There are no `blx`, and no `bx` to an odd address.
  - The only `bx` targets are `lr` and `ip`.
  - The jump to MAIN is `bx ip` with ip = 0x40000000 (0x214–0x21c), so MAIN is entered
    in ARM state.
- The code uses ARMv7-R system registers. **[proven]**
  - MPU: c6 RGNR/DRBAR/DRSR/DRACR at 0x22f0–0x2300, with 12 regions reset at 0x718–0x734.
  - TCM region registers c9,c1 at 0x2304.
  - Set/way cache maintenance at 0x7f4 and 0x220c.
- Cortex-R7 specifically is consistent with this but not provable from the code alone.
  **[inferred]**

### 2.3 Reset path and `main` (0x274)

**Reset (0x74).** **[proven]**
- Fills 0x2f10–0x3000 with 1. Enters SVC mode with IRQ and FIQ masked (0x8c).
- Writes a boot marker "!BB!" and snapshots of two CP system registers
  (0x83004404/0x83004408, plausibly the reset cause **[inferred]**) to 0x2f10…
- Clears SCTLR M/C/I.
- Calls:
  - 0x1e00: PLL/clock setup;
  - 0x2130: clocks;
  - 0x1ea0: **DRAM controller init** (DMC 0x82000000, PHY 0x82010000/0x82011000,
    direct-command block 0x8300c000).
- Sets the IRQ stack to 0x2ef0 and the SVC stack to 0x2ed0, then calls `main` (0x164).

So the CP has its own DRAM controller and BOOT trains it. The AP provides no CP RAM.
**[proven code; "own LPDDR" inferred]**

**`main` (0x274) order.** **[proven]** The character in quotes is what BOOT prints on its
UART after each step.
1. UART init at CP 0x84000000 (0x1040). Print `"\nS333 (" + "Oct 21 2015" + ") : "`.
2. Warm-restart check. If `[0x2efc] == 0x424F4F54` (an SRAM marker BOOT writes just
   before jumping to MAIN, at 0x11dc), BOOT flushes its caches including the L2 at CP
   0x80800000 (0x828) and prints `c`. This is the post-crash path, so DRAM is coherent
   before a dump.
3. `0x220c` cache invalidate → `'C'`.
4. `0x710` MPU map (§2.4) → `'M'`.
5. `0x21e8` → `'S'`.
6. `0xe70` **LLI and M-PHY init plus mount** (§2.6) → `'L'`.
7. `0x1a4`: drive CP 0x83007100 bit 3 low→high, print `e`, then wait with no limit for
   CP 0x83007200 bit 1 → `'G'`. See §2.6 for the GPIO hypothesis.
8. `0xd48` I2C master init at CP 0x84003000 → `'i'`.
9. If BOOT+0x30 == "HSAH": set the secure flag `[0x27e0]=1` and run eFuse provisioning
   (§2.8). Otherwise clear the flag. Print `F` (and `0`/`1`/`8`/`9`/`2` for each slot
   programmed).
10. `0xc08` eFuse sense → `'s'`.
11. `0x137c`: **read the shared-memory magic once**, at CP 0x30000000 (load at 0x1394).
    Also snapshot `raw_rx_head` from 0x30000020 into BOOT's TX write pointer (0x27f8).
    Then:
    - `== 0x44554D50` "DUMP" (0x66c): crash-dump upload (§2.9). Print `Done`, then hang.
    - `== 0x424F4F54` "BOOT" (0x68c): print `Boot\n` and run the download (0x162c, §2.5).
      - Result ≤ 0x10000000: print `XxX!\n` (0x708) and hang at `b .` (0x688).
      - Otherwise call 0x1e0, which jumps to MAIN.
    - Anything else: print `Unknown\n` (0x6f4) and hang (0x688).
12. Jump to MAIN (0x1e0):
    1. Store "BOOT" at 0x2efc.
    2. `'R'`.
    3. Clean and invalidate the D-cache (0x7f4).
    4. `'u'`.
    5. MPU off (0x22c0).
    6. `"n\n"`.
    7. `bx 0x40000000`.

    The entry 0x40000000 is a constant returned at 0x1a18, not taken from the TOC.

The value **0xAA** (the kernel's `MEM_IPC_MAGIC`) is never referenced by BOOT. No
compare or literal with 0xaa exists, so the IPC magic belongs to MAIN. **[proven]**

### 2.4 CP memory map (BOOT's view)

MPU regions programmed at 0x710–0x7e8. DRSR encodes size = 2^(N+1). **[proven]**

| region | base | size | DRACR | use |
|---|---|---|---|---|
| 0 | 0x00000000 | 32 KiB | 0x308 normal non-cacheable | BOOT SRAM (code 0–0x29fc, data/stack to 0x3000) |
| 1 | 0x04000000 | 64 KiB | 0x1608 XN | TCM (ATCM base set at 0x2304 on the dump path) |
| 2 | 0x04800000 | 16 KiB | 0x1608 XN | TCM (BTCM) |
| 3 | 0x30000000 | 256 MiB | 0x1300 strongly-ordered XN | **LLI window onto AP shared memory** |
| 4 | 0x40000000 | 128 MiB | 0x321 normal cacheable | **CP DRAM**: MAIN at 0x40000000 |
| 5 | 0x47000000 | 16 MiB | 0x1308 normal NC XN | MAIN staging buffer 0x47000000–0x47f00000; NV at 0x47ee0000 |
| 6 | 0x80000000 | 2 GiB | 0x1310 device XN | peripherals |
| 7/8 | 0xe0000000 / 0xef000000 | 256 / 16 MiB | 0x1300 | dumped region 0xe0000000+0x57000 (§2.9) |

**Peripheral identities:**
- From register usage and log strings **[inferred]**:
  - 0x84000000 UART;
  - 0x84003000 I2C master;
  - 0x8400c000 eFuse/OTP;
  - 0x81003000 crypto (decryption) engine;
  - 0x82000000 DRAM controller;
  - 0x80800000 L2 cache controller (PL310-style 0x7fc/0x730 maintenance registers);
  - 0x89000000 M-PHY attribute window;
  - 0x89004000 LLI (DME/PA/IAL).
- 0x8a004000 is a second LLI register window used for the doorbell (§2.6). Its identity
  is unknown.

**Destination address validator (0x6b8).** It accepts only:
- [0x40000000, 0x48000000);
- [0x04000000, 0x04010000);
- [0x04800000, 0x04804000).

**[proven]**

### 2.5 The download protocol (function 0x162c), CP side

**Primitives.** All on the shared-memory window; see §2.7 for the ring layout.
**[proven]**
- `rx(dst,n)` (0x14e8):
  - Spin until `raw_tx_head` (0x30000018) != `raw_tx_tail` (0x3000001c). There is no
    timeout.
  - Copy **n rounded up to 4** bytes from the ring at 0x30003000+tail, handling the wrap
    at 0x1fd000. The copy is skipped if `dst > 0x48000000 - n`.
  - Advance `raw_tx_tail` by the same amount.
  - BOOT waits only for "not empty" and then reads `n` bytes, so it relies on each frame
    being published whole.
- `skip(n)` (0x15f4) discards n bytes (rounded up to 4).
- `reply(buf,cmd)` (0x14cc):
  - Writes `buf[+4]=cmd` and `u16 buf[+2]=8`, keeping bytes 0–1 of the *received* frame
    (SIPC5 cfg and channel).
  - Sends 8 bytes on the CP→AP ring (0x13b4) and commits (0x139c, §2.7).
- `expect(buf,exp)` (0x15c4):
  - Reads 8 bytes (4-byte SIPC5 header + 4-byte command).
  - If `cmd == exp`, replies `exp + 0x1000`; if not, replies nothing.
  - The caller then checks `buf[+4] == exp+0x1000`.

**Message sizes BOOT consumes:** **[proven]**
- 8 bytes: SIPC5 header + command.
- 20 bytes: SIPC5 header + std_udl header `{cmd, num_frames, curr_frame, len}`, read into
  sp+0x108…+0x11b.
- `len` bytes of payload.
- 4 bytes: the CRC value following a `0x?0C` command.

**Sequence** (stage id `s` in bits 8–11; responses = request + 0x1000):

| step | CP expects (addr) | CP action / reply | on mismatch |
|---|---|---|---|
| 0 | `0x900d` (0x1630–0x1650) | reply `0xa00d`, print `Recv` | silent; return 0x900d → `XxX!` hang |
| 1a | `0x9100` (0x165c) | reply `0xa100` | silent hang |
| 1b | one 20-byte header with cmd `0x9101` (0x1684–0x1694) | if len > 0x100: keep the first 0x100 bytes (8 TOC slots) in a stack buffer and `skip(len-0x100)` (0x16b0–0x16d4); else read len. **One frame only**: `num_frames`/`curr_frame` are not checked | reply `0xa10f` (0x1698–0x16a0), hang |
| 1c | — | send `0xa101` unsolicited (0x16e4) | — |
| 1d | `0x910d` (0x16f0–0x170c) | reply `0xa10d`, print `TOC TBL` | silent hang (a `0x910c` CRC step is **not** accepted) |
| loop | for s = 2…7 (0x171c, 0x19f0–0x19f8) | | |
| s.a | `0x9000\|s<<8` (0x1724–0x173c) **or** `0x9f00` (0x1740) | start: reply `0xa000\|s<<8`. FIN: reply `0xaf00` (0x1748) and **return 0x40000000** (0x1a18) | silent hang |
| s.b | — | print TOC slot s name (0x1764). `la` = slot s `load_addr`: must pass 0x6b8 (0x176c). If s==2: `la ≤ 0x40020000` (0x1794). Else: `la > 0x41000000` (0x1784). The check runs **after** the start was ACKed | silent hang |
| s.c | frames: 20-byte header, `cmd == 0x9001\|s<<8` (0x17b0–0x17cc) | MAIN with secure flag: payload goes to the staging buffer at 0x47000000. Each time 64 KiB accumulates (0x1810–0x182c), decrypt 64 KiB to `la` via engine 0x99c. Compact the staging buffer at 0x47f00000 (0x1834–0x1858). Other stages: payload goes straight to `la+offset` (0x1860–0x1870). Loop until `curr_frame == num_frames` (0x1874–0x1880). Sequence numbers and total size are not checked | reply `0xa00f\|s<<8` (0x17d0–0x17dc), hang |
| s.d | — | decrypt the remainder (0x1894–0x18ac), send `0xa001\|s<<8` unsolicited (0x18b0–0x18bc) | — |
| s.e | `0x900d\|s<<8` (0x18c0–0x18e4) | reply `0xa00d\|s<<8` | → s.f if the word is `0x900c\|s<<8`, else silent hang |
| s.f | `0x900c\|s<<8` + 4-byte CRC (0x18e8–0x1910) | see CRC rule below. Match: print `Ok)` and reply `0xa00c\|s<<8` (0x1958–0x1964), then expect `0x900d\|s<<8` → `0xa00d\|s<<8` (0x1968–0x197c) | reply `0xa00f\|s<<8`, print `Nok)` (0x19c4–0x19d8), hang |
| end | after s=7: `0x9f00` (0x19fc–0x1a14) | reply `0xaf00`, return 0x40000000 | silent hang |

All rows above are **[proven]**.

**CRC rule (0x1914–0x1948).** **[proven]**
- **Secure flag clear:** `crc32(la, slot.size)` (zlib CRC-32, table at 0x23e0) is compared
  with the CRC the AP sent.
- **Secure flag set**, which is this image because BOOT+0x30 == "HSAH" (0x304–0x320):
  - BOOT cleans the caches (0x7f4).
  - It **overwrites the AP's CRC** with `*(u32*)(la + *(u32*)(la+0x34) + 4)` and computes
    `crc32(la, *(u32*)(la+0x34))`.
  - In other words, it uses a size field at +0x34 of the decrypted MAIN and a CRC word in
    the decrypted trailer.
  - The AP's CRC value has no effect.
  - The CRC step itself is **optional** for BOOT: it also accepts `0x920d` straight after
    `0xa201`.

**Decrypt engine (0x99c, base 0x81003000).** **[proven register writes; semantics inferred]**
- Register writes:
  - `+0x68` = source;
  - `+0x6c` = destination;
  - `+0x70` = (len>>4)-1, a count of 16-byte blocks;
  - `+0x60` = 2; `+0x74` = 1; `+0x80` = 0; `+0x84` = 2;
  - `+0x64` = 1 (start);
  - poll `+0x8c` != 0.
- Each 64 KiB call reprograms the engine from scratch.
- BOOT contains no RSA or SHA routine for MAIN. Its only MAIN integrity check is the
  plaintext CRC-32. Authenticity, if any, comes from the cipher key being secret, or is
  checked later by MAIN. **[inferred]**

### 2.6 LLI bring-up as seen by the CP (0xe70)

**Register map.** BOOT writes the same register offsets and values as the AP's
`exynos-mipi-lli` driver, which pins the CP LLI block at CP 0x89004000. **[proven writes;
register identity inferred from matching offsets, values and log strings]**
- `+0x134 PA_DRIVE_TACTIVATE_DURATION = 0xf` (0xeb4–0xeb8).
- `+0x400 PA_SYSTEM_CLK_PERIOD = 10` (0xec0–0xec8).
- `+0x100c DME_LLI_INTR_ENABLE = 0xffffff` (0xecc–0xed0).
- `+0x900 DME_LL_TC_DISABLE = 0` (0xed4–0xedc).
- `+0x41c PA_MPHY_CMN_ENABLE` is set to 1 (0xf08) and back to 0 (0xf24) around the
  M-PHY CMN writes.
- `+0x418 PA_MPHY_OV_TM_ENABLE` is set to 1 (0xf2c) and back to 0 (0xf90) around the
  OVTM writes, mirroring the AP driver's `cmn_init`/`ovtm_init`.

The AP kernel writes 0xf and 10 to the same PA offsets (`exynos-mipi-lli.c:299,302`).

**M-PHY attributes** at CP 0x89000000 + 4×attr. These match the AP kernel's
`exynos_mphy_init` values and DT `init-gear = <2 2 1>`. **[proven values; mapping
inferred]**
- TX_LCC_ENABLE(0x2c) = 0 (0xf94).
- TX_HS_SYNC_LENGTH(0x28) = 0x45 (0xf98–0xf9c).
- TX_MODE(0x21) = RX_MODE(0xa1) = 2, and TX/RX_HSGEAR(0x23/0xa3) = 2 (0xfa4–0xfb0).

**Mount.** **[proven code]**
1. `DME_CSA_SYSTEM_SET (0x8900490c) = 6` = `LLI_MOUNT_CTRL | MASTER_NOT_SLAVE`
   (0xfd0–0xfd8).
2. Poll `DME_LLI_INTR_STATUS (0x89005010)` until bit 0 `INTR_LLI_MOUNT_DONE` is set
   (0xe0c–0xe4c). It prints `cfg` on bit 4 `LINK_UPDATE_CONFIG_DONE` and `MT` on bit 0.
3. Then poll `DL_DBG_TX_CREDITS (0x89005290) != 0` (0xe50–0xe58).

Both loops are unbounded.

**Consequence.** **[inferred, strong]**
- The CP is the LLI master.
- The AP kernel is slave by default (`exynos-mipi-lli.c:1155` `is_master = false`). It
  answers by writing `LLI_MOUNT_CTRL` in its IRQ handler on `INTR_MPHY_HIBERN8_EXIT_DONE`
  (`exynos-mipi-lli.c:926-932`).
- No userspace write to `lli_control` is needed (U-7 in SS333_LLI_BRINGUP.md §8).
- If the AP's LLI/M-PHY is not ready, BOOT blocks forever in this step: before the
  sideband handshake, before it reads the magic, and before any std_udl traffic.

**Sideband (0x1a4).** BOOT pulses CP 0x83007100 bit 3 from 0 to 1, then waits without
limit for CP 0x83007200 bit 1. **[proven]**
- At reset, 0x83007000/0x83007100 bits 3 and 7 are cleared and bit 1 of 0x83007000 is set
  (0x10c–0x144). **[proven]**
- Hypothesis **[inferred, low-medium]**:
  - bit 3 of 0x83007100 is **CP2AP_STATUS**, the line cbd polls as `cp_status/value`
    (gpa2-5, DT `exynos5433-modem-ss333.dtsi:30,37`);
  - bit 1 of 0x83007200 is **AP2CP_STATUS** (gpf1-2), which the AP raises in
    `ss333_boot_on` (`modem_ctrl_ss333.c:391`) before the BOOT transfer.
- If true, CP_STATUS rises only *after* the LLI mount completes. That fits cbd waiting for
  CP_STATUS and then for "MIPI-LLI 1".

### 2.7 Shared-memory layout used by BOOT (CP view at 0x30000000)

Every offset below equals the kernel's `struct shmem_4mb_phys_map`
(`drivers/misc/modem_v1/link_device_memory.h:81-112`). **[proven]**

| shmem offset | kernel field | BOOT use |
|---|---|---|
| +0x00 | `magic` | read once (0x1394): "BOOT"/"DUMP"/other |
| +0x04 | `access` | never touched |
| +0x08…+0x14 | fmt ring indices | never touched |
| +0x18 | `raw_tx_head` (AP write ptr) | read (0x14fc) |
| +0x1c | `raw_tx_tail` | read and written by CP (0x14f8, 0x1574, 0x15ac) |
| +0x20 | `raw_rx_head` | snapshot at 0x1380, written on commit (0x13a8) |
| +0x24 | `raw_rx_tail` (AP read ptr) | read for free space (0x13e0) |
| +0x3000, 0x1fd000 B | `raw_tx_buff` = AP→CP ring | ring base literal 0x30003000 (0x1994), size 0x1fd000 (0x1990) |
| +0x200000, 0x200000 B | `raw_rx_buff` = CP→AP ring | base 0x30200000 (0x198c), wrap at 0x200000 |

**Commit and doorbell (0x139c).**
- Store the TX write pointer to +0x20, then write **0x83** to **CP 0x8a006008** (via 0xffc).
  **[proven]**
- 0x83 = `MASK_INT_VALID | MASK_SEND_FMT | MASK_SEND_RAW`
  (`link_device_memory.h:127-137`). It passes the kernel's `int_valid()`. **[proven
  constants]**
- 0x8a006008 = 0x8a004000 + 0x2008 (`TL_SIGNAL_SET_LSB` offset). The AP reads
  `TL_SIGNAL_STATUS_LSB` as the CP2AP value (`exynos-mipi-lli.c:474-498`).
  **[offset match proven; register identity inferred]**

**No AP→CP doorbell.** BOOT reads no mailbox, signal or interrupt register while it waits
for data. It busy-polls `raw_tx_head` (0x14f8–0x1504). This settles U-6: no doorbell is
needed. **[proven]**

### 2.8 eFuse / key-slot provisioning (HASH field)

When the HASH magic is present (0x2fc–0x64c), BOOT does the following. **[proven code]**
- Reads key slots 0 and 1 through 0xc24 (CP 0x8400c200 + 16·n, unlocked with the word
  0x70615243 at 0x8400c6fc) and compares them with field bytes 0–31.
- XORs field[32:64] with field[0:32] in place (0x42c–0x43c, routine 0x970) and compares
  slots 8 and 9 with the result.
- **Programs** any slot that is blank or different (0xca8 → 0xb20). Around each program
  cycle it makes an I2C write: slave 0x82, register 0x2e, values 0xdd/0xdc/0x1c
  (0xde4/0xd70). This is most likely an eFuse supply rail on a PMIC. **[inferred]**
- If slots 0 and 1 then match, sets bit 0x4000 in slot 2 (0x610–0x64c).

Reading **[inferred]**: BOOT fuses the hash of the signing key and a secure-boot enable
bit on first boot. On this tablet the slots already match from years of stock boots, so
nothing is written.

Rule: only ever send this exact BOOT image. **[inferred]**

### 2.9 DUMP path (magic "DUMP", for later crash handling)

Called at 0x1a98. **[proven]** Message order:
1. AP sends `0x9d00`.
2. CP sends a 20-byte info frame on **channel 0xE1 (225, umts_ramdump0)** with cfg 0xFC:
   `{0xad00, total_size, 5, reason_len}`, then a reason string.
3. For region n = 0…4, the AP sends `0x9d01+n`. The CP then pushes all frames of that
   region, with header `{0xad01+n, num_frames, curr_frame, len ≤ 0x800}`, and no
   per-frame acknowledgement.
4. The AP ends with `0x9d0d` and the CP replies `0xad0d`.

On error the CP sends `0xad0f`.

Regions (table built at 0x1a20 into 0x27fc):
- 0x40000000+128 MiB;
- 0x04000000+64 KiB;
- 0x04800000+16 KiB;
- 0xe0000000+0x57000;
- 0x2f00+0x100.

Total 0x806b100 bytes.

The dump includes the CP DRAM, which holds the **decrypted MAIN** after a successful boot.
This is a possible future way to obtain MAIN plaintext; it was not attempted. **[inferred]**

### 2.10 CP UART trace (debug aid)

Expected cold-boot trace, from the putc/puts order above. **[proven strings; trace order
inferred from control flow]**

`\nS333 (Oct 21 2015) : CMSMTLeGiFsBoot\nRecvTOC TBL\nMAIN (CRC:Ok)>Done\nNV>Done\nRun\n`

`MT` appears when the LLI mount interrupt fires. `cfg` may also appear before it.

Failure markers: `Unknown`, `XxX!`, `Nok)`.

The CP UART is at CP 0x84000000. Whether it can be reached on the T715 (cbd references
`/sys/class/sec/uart_cp/control`) is unknown.

---

## 3. MAIN (image 0x2c00, 0x21271a0 bytes, load 0x40000000)

### 3.1 Encrypted: yes

**Entropy.** All 34 one-MiB blocks are 7.99876–7.99984 bits/byte. No 4 KiB block is below
7.85. Chi² over byte values = 274 (255 degrees of freedom). No "MAIN", "HSAH", "SS333" or
"Shannon" string appears. **[proven]**

**Cipher structure** (from the ciphertext alone). **[proven statistics; cipher identity
inferred]**
- Size 0x21271a0 is a multiple of 16.
- There are 21,437 repeated 16-byte aligned blocks (occurrences beyond the first),
  falling into exactly 4,096 groups (= 65,536 / 16). Random data would show none.
  - **Every** group sits at one offset modulo 0x10000.
  - **No** group shares an offset modulo 0x20000.
  - 4 whole 64 KiB chunks are identical: MAIN+0x1240000/0x1250000/0x12b0000/0x12c0000.
- All 820 matching segments between chunks start at chunk offset 0. None starts in the
  middle of a chunk.
- Conclusion:
  - a 16-byte block cipher in a **chained (CBC-like) mode**, not ECB or CTR;
  - the IV/state **restarts every 64 KiB**;
  - this equals BOOT's 0x10000-byte decrypt calls (0x181c–0x1828).

**Consequence.** MAIN must be streamed byte-for-byte unmodified, from its first byte, in
order. **[inferred]** Because the analysis stops at encryption (as instructed), MAIN's
version and build strings, IPC identifiers, RFS paths, NV item names and SIPC5 constants
**cannot be recovered from this image**.

### 3.2 What is known about the plaintext MAIN (from BOOT only)

- The plaintext has a 32-bit size field at offset +0x34 and a CRC-32 word at +size+4.
  **[proven from 0x1928–0x1938]**
- The plaintext starts with a vector table: BOOT forwards its exception vectors to
  0x40000004…0x4000001c and enters at 0x40000000. **[proven forwarding; "vector table"
  inferred]**
- The IPC magic 0xAA and every SIPC5 IPC behaviour (INIT_START, PHONE_START, RFS) are
  MAIN's. BOOT contains none of them. **[proven absence in BOOT]**

### 3.3 Trailer outside the TOC

**Bytes.** Image 0x2129da0–0x2129eb0 (272 bytes) holds: **[proven]**
1. `02 00 00 00`;
2. 12 zero bytes;
3. 256 high-entropy bytes (RSA-2048-sized);
4. then zeros to the end of the partition.

This matches the Comsecuris "MAIN: data[size], unk1, padding[12], signature[256]"
layout, except that the trailer lies **after** TOC MAIN.size.

**Not sent.** cbd's stage-2 size is TOC MAIN.size (CBD_RE.md §4), so the trailer is never
sent to the CP. **[proven]** Its consumer is probably flash-time or AP-bootloader
verification. **[inferred, low]**

---

## 4. OFFSET and NV entries

**OFFSET** (offset 0x7aa00, size 0x85600, load 0, crc 0, index 4).
- Image range 0x7aa00–0x100000 lies **inside the MAIN ciphertext** (MAIN spans
  0x2c00–0x2129da0). Its entropy is the same as its surroundings, with no step at 0x7aa00
  or 0x100000. **[proven]**
- So the entry does not describe separate data in the image.
- 0x7aa00 + 0x85600 = 0x100000 = NV.size. The same values appear in a 2019 S10 TOC
  (research note `cp_boot_firmware.md` Q1). **[proven arithmetic]**
- Most plausible reading: a split point inside the 1 MiB NV region, not a loadable image.
  **[inferred, low]**
- BOOT would only read slot 4 if the AP sent stage 4 (`0x9400`). It would then reject
  load 0 (0x6b8) *after* ACKing `0xa400` and hang. **[proven path]**

**NV** (load 0x47ee0000, size 0x100000, offset 0).
- The image holds no NV data.
- BOOT copies the stage-3 stream raw to 0x47ee0000+ with no parsing and no CRC.
  **[proven]**
- The range 0x47ee0000–0x47fe0000 lies in MPU region 5 (non-cacheable, XN) and overlaps
  the end of BOOT's MAIN staging buffer (0x47000000–0x47f00000). NV can therefore only be
  loaded after MAIN, which the stage order already forces. **[proven layout; consequence
  inferred]**
- BOOT does not require stage 3: FIN is accepted right after MAIN. Whether MAIN needs NV
  at 0x47ee0000 is unknown. **[proven for BOOT]**

---

## 5. Constraints on the AP-side loader

### 5.1 Before and around the BOOT transfer

| # | constraint | mark |
|---|---|---|
| C1 | Before BOOT reaches 0x1394 (i.e. before the SPI transfer), shmem+0 must hold `0x424F4F54` and all ring indices must be 0 (kernel `IOCTL_MODEM_DL_START`, `link_device_bootdump.c:194-222`). BOOT reads the magic **once**. Other values → `Unknown`; "DUMP" → dump mode. Both mean a silent hang from the AP's view. | [proven] |
| C2 | Do not reset the rings or rewrite the magic after the BOOT transfer: BOOT caches `raw_rx_head` at 0x1380. | [proven cache; consequence inferred] |
| C3 | The AP LLI must accept a mount started by the CP as master (AP slave, mount on HIBERN8_EXIT) and grant DL credits. Otherwise BOOT spins forever at 0xe0c/0xe50. | [proven loops; register identity inferred] |
| C4 | The AP's LLI remap must make CP 0x30000000 = shmem offset 0, with the exact `shmem_4mb_phys_map` layout (§2.7). | [inferred from proven CP offsets] |
| C5 | AP2CP_STATUS high (as in `ss333_boot_on`) before BOOT reaches 0x1cc; expect CP_STATUS to rise only after the LLI mount. | [inferred, low-medium] |
| C6 | Send exactly image[0x200 : 0x200+0x29fc] over SPI, unmodified (signed: HASH field plus 512-byte trailer). 0x29fc is 4-aligned, so no SPI padding leaks. | [proven size/layout; BootROM check inferred] |

### 5.2 Framing (umts_boot0, ch 215)

| # | constraint | mark |
|---|---|---|
| C7 | One logical message = one `write()` = one SIPC5 frame with a **4-byte** header. BOOT ignores the header contents but **copies cfg and channel into its replies**, always with len=8 and a 4-byte header. Never set the EXT/CTL bits; the kernel's `sipc5_build_config` does not for these sizes. | [proven 0x14cc; kernel `modem_io_device.c:1706-1758`] |
| C8 | Pad frames to a **4-byte** multiple. BOOT advances by roundup4 (0x13c4, 0x157c). The kernel pads to `sizeof(size_t)` (`sipc5.h:93-97`): correct on ARM32, **wrong on an arm64 kernel** (the 12-byte CRC frame would become 16). | [proven] |
| C9 | Sizes: command frames carry 4 bytes. The CRC command is a single 8-byte `{0x?0c, crc}` write. Data frames are a single write of the 16-byte header plus payload. Splitting any of these desynchronises the ring. | [proven] |
| C10 | Publish each frame whole (data first, then head). BOOT waits only for head != tail. The kernel's `udl_write` does this. | [proven] |
| C11 | Ring capacities: AP→CP 0x1fd000 bytes; CP→AP 0x200000 bytes. | [proven] |

### 5.3 Sequence

| # | constraint | mark |
|---|---|---|
| C12 | The first message is `0x900d`, with no `0x9000` before it → `0xa00d`. | [proven] |
| C13 | Stage 1 (TOC): `0x9100`→`0xa100`; **exactly one** data frame with cmd `0x9101` carrying the TOC (send all 0x200 bytes; BOOT keeps the first 0x100); wait for the unsolicited `0xa101`; `0x910d`→`0xa10d`. **No CRC step.** | [proven] |
| C14 | Stages in strictly increasing order starting at 2; stage N uses TOC **slot N**. | [proven] |
| C15 | MAIN (stage 2): slot-2 load ≤ 0x40020000 and within CP DRAM; frames with cmd `0x9201`; last frame `curr_frame == num_frames`; stream image[0x2c00 : +0x21271a0] unmodified; wait for the unsolicited `0xa201`. | [proven] |
| C16 | MAIN frame payload ≤ 64 KiB. BOOT decrypts at most one 64 KiB unit per frame, so larger frames break the per-64 KiB IV units. cbd's 0x800 is fine. | [proven code; consequence inferred] |
| C17 | MAIN CRC step is optional for BOOT. If sent: `{0x920c, crc}` → `0xa20c`/`0xa20f`. The value is ignored in this image (secure flag). Send TOC MAIN.crc32 0x1e71169c anyway, for parity with cbd. Then `0x920d`→`0xa20d`. | [proven] |
| C18 | NV (stage 3): slot-3 load must be in (0x41000000, 0x48000000); 0x100000 bytes; cmd `0x9301`; `0xa301`; `0x930d`→`0xa30d`. **Never `0x930c`**: in secure mode BOOT would read a "size" from NV+0x34 and CRC an arbitrary span. | [proven path; consequence inferred] |
| C19 | Never send stage 4 or above (OFFSET slot has load 0, so BOOT hangs after ACK). | [proven] |
| C20 | FIN `0x9f00`→`0xaf00` is **mandatory**: the only path to `bx 0x40000000`. Never send it before MAIN, because FIN at s=2 jumps to an empty DRAM. | [proven] |

### 5.4 Errors and timing

| # | constraint | mark |
|---|---|---|
| C21 | BOOT has **no software timeouts**; every wait is unbounded. AP timeouts are policy (cbd: 30 s `poll` per response; 10×500 ms for CP_STATUS and LLI). | [proven] |
| C22 | Only two errors produce a reply, `0xa?0f`: a wrong frame command, or a CRC mismatch. All others (wrong command word, bad load address after ACK) are **silent**. After any error BOOT spins at 0x688. Recovery = `IOCTL_MODEM_OFF`/`ON` and the full sequence from C1, BOOT over SPI included. | [proven] |
| C23 | No AP→CP doorbell is needed during download. Each CP reply comes with LLI signal value 0x83. | [proven] |
| C24 | Optional AP pre-check: zlib CRC-32 of BOOT = 0x5db1f04c and of MAIN = 0x1e71169c (TOC values, verified). The 272-byte MAIN trailer is not part of either. | [proven] |

### 5.5 Corrections to existing notes

- **LOADER_SPEC.md "Risk notes" (record 4: skip it).** Wrong. FIN is required (C20); this
  is now proven from the CP side.
- **LOADER_SPEC.md step 12.**
  - Add C7–C9 (framing), C13 (single TOC frame), C18 (no NV CRC) and C22 (hang semantics).
  - CRC: the value is irrelevant for this BOOT.
- **SS333_LLI_BRINGUP.md §3.2 step 4 ("userspace must write 2 then 3 to lli_control").**
  Refuted. The CP masters the mount (0xfd8) and the AP mounts as slave from its IRQ
  handler.
- **SS333_LLI_BRINGUP.md §8:**
  - U-6: resolved, no doorbell.
  - U-3: resolved by §2.4.
  - U-1: resolved by §1–§3.
  - U-7: resolved as above.

---

## 6. Unknowns

Each unknown is listed with its status. None blocks a first hardware test.

1. **BootROM.** Its SPI expectations and its BOOT signature check (what the 64-byte HASH
   field and the 512-byte signature cover) are not visible. The ROM is not in the image.
2. **The GPIOs at CP 0x83007100 bit 3 and 0x83007200 bit 1.** The CP2AP/AP2CP_STATUS
   hypothesis (§2.6) is untested. Who raises CP_STATUS (BootROM or BOOT) is unknown.
3. **The CP register window 0x8a004000.** It is a remote or second LLI window used for the
   doorbell. The doorbell register identity is inferred.
4. **The cipher.** Its algorithm, key source (eFuse slots 0/1/8/9?) and exact mode are
   unknown beyond "chained, 16-byte blocks, 64 KiB units".
5. **MAIN plaintext.** Everything about it is unknown: version, IPC, RFS paths, NV
   items, what it expects after `bx 0x40000000`, and whether it needs NV at 0x47ee0000.
   The BOOT DUMP path (§2.9) could later yield a plaintext dump; that step needs the
   hardware.
6. **The meaning of OFFSET** (0x7aa00/0x85600), and whether MAIN reads BOOT's TOC copy at
   all. That copy lives on BOOT's stack in SRAM; no pointer is passed.
7. **The consumer of the 272-byte MAIN trailer.**
8. **A hardware watchdog during BOOT.** If one exists, BOOT's unbounded waits could reset
   the CP instead of hanging.
9. **Throughput.** CP decryption speed against the kernel's 20×50 ms `-ENOSPC` retry
   budget in `xmit_udl` is unknown. A 2 MB ring makes a problem unlikely.
   **[inferred]**
10. **BOOT header word `+0x2c = 0x00310000`.** Its meaning is unknown.
