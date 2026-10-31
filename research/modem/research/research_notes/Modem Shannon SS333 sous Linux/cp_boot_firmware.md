# Shannon CP boot chain, firmware container, NV/RFS and security checks (SS333 over MIPI-LLI vs. integrated Shannon)

Scope note. This pass added public sources on top of what we already had (CBD_RE.md, LOADER_SPEC.md, SS333_LLI_BRINGUP.md). Every claim carries a URL or a local `file:line` and a confidence tag: **[confirmed]** (read in source or primary document), **[likely]** (strong inference from several sources), **[speculative]**. Facts are labelled **SS333/external** (Exynos 5433/7420 + external SS333 over SPI+LLI, 2015-2016: Galaxy S6, Note 4 S-LTE, Tab S2 LTE) or **integrated** (Exynos 7xxx/8xxx/9xxx "ModAP" with the CP on the same die, 2016+). Local paths are relative to `the repository root`; `kernel/` means `src/kernel_universal5433/`.

**Biggest finding.** Samsung's own `cbd` source is public. The C "cpboot v1" tree contains `boot_shannon333.c` (our exact SS333 flow), `std_boot.c` and `std_boot.h`. It sits in the LineageOS-derived repo `samsungexynos7420/android_hardware_samsung_slsi-linaro_exynos`, commit "Import cpboot v1 from linaro", 2025-04-03 ([repo](https://github.com/samsungexynos7420/android_hardware_samsung_slsi-linaro_exynos/tree/lineage-19.1/cpboot)). Samsung's C++ rewrite, "cpboot_v3" (`CBD-V3-20221018R1`, "Copyright (C) 2020 Samsung Electronics", **Apache-2.0**), is in LineageOS's official repo ([ProtocolSipc.cpp](https://github.com/LineageOS/android_hardware_samsung_slsi-linaro_exynos/blob/lineage-24.0/cpboot_v3/ProtocolSipc.cpp)). The v1 source agrees, function by function, with our static RE of the stock binary. It settles most of our open items: see Q2, "Resolution of our open items".

**Licence caveat.**
- The v1 files carry no per-file licence header. `cpboot/Android.bp` marks the `cbd` module `proprietary: true`, while the repo-level NOTICE is AOSP Apache-2.0 ([Android.bp](https://github.com/samsungexynos7420/android_hardware_samsung_slsi-linaro_exynos/blob/lineage-19.1/cpboot/Android.bp), [NOTICE](https://github.com/samsungexynos7420/android_hardware_samsung_slsi-linaro_exynos/blob/lineage-19.1/NOTICE)).
- For a "independent" loader, treat v1 as a specification and cross-check, and do not copy its code.
- cpboot_v3 is explicitly Apache-2.0. Apache-2.0 code can go into GPLv3 or Apache projects, but not into GPLv2-only ones. [confirmed]

---

## Q1. Firmware container (TOC; BOOT/MAIN/VSS/NV/OFFSET; signatures): who verifies what, external vs. integrated

### Takeaway
- **Container.** `modem.bin` / RADIO is a flat file whose 512-byte (or larger) TOC holds 32-byte entries `{name[12], offset, load_addr, size, crc32, id}`. On SS333 the entries are TOC/BOOT/MAIN/NV/OFFSET. VSS arrives on later integrated SoCs, and NV_NORM/NV_PROT on some images.
- **Signatures.** On the Galaxy S6 (SS333) generation, BOOT carries a SHA-512 and a 512-byte signature, MAIN carries a 256-byte signature trailer, and MAIN is encrypted.
- **No AP security step on SS333.** Neither the AP-side `cbd` nor the kernel decrypts, verifies or issues an SMC. Verification and decryption must happen on the CP side: BootROM checks BOOT, then BOOT checks and decrypts MAIN.
- **Integrated parts differ.** On Exynos 7570/7870/8890/9820 and later, the AP's EL3 secure monitor marks CP memory secure and verifies BOOT+MAIN signatures via `IOCTL_SECURITY_REQ` → `exynos_smc(0x82000700, …)`.
- **Consequence for us.** A independent loader for SS333 needs no TrustZone or signing. It must ship Samsung's signed and encrypted blobs unmodified, and it cannot run modified CP firmware.

### Cited Findings

**TOC format (all generations)**
- **Entry layout.** 32-byte entries `name[12], offset/start, load_addr, size, crc (FirmWire: "crc", Comsecuris/Grant: "unk"), id`. The first entry is the TOC itself, and parsing stops at the first empty name. [confirmed] Sources: [FirmWire TOCFile.py](https://github.com/FirmWire/FirmWire/blob/main/firmwire/vendor/shannon/TOCFile.py), [Comsecuris sam.bt (2015/2016)](https://github.com/Comsecuris/shannonRE/blob/master/010/sam.bt), [Grant Hernandez parse_modem.py](https://github.com/grant-h/ShannonBaseband/blob/master/reversing/modem/parse_modem.py), [libsamsung-ipc toc.h (T. Garnock-Jones, 2020)](https://github.com/manoedinata/libsamsung-ipc/blob/shannon-lte-data/samsung-ipc/partitions/toc/toc.h).
- **cbd's own struct.** Six fields: name, file offset, load offset, size, CRC and a reserved word. [confirmed] Source: [cpboot v1 std_boot.h](https://github.com/samsungexynos7420/android_hardware_samsung_slsi-linaro_exynos/blob/lineage-19.1/cpboot/std_boot.h).