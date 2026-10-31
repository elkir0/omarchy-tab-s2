# Modem research (Shannon SS333), 2026-10-29/30

Read-only research done before any hardware test: web research, static
analysis of our own dumps and of the stock Samsung blobs, a consolidated
theory, and two adversarial reviews. No file here contains firmware,
blob bytes or personal identifiers. The raw material (stock blobs, decompilations, cloned sources) stays outside the repository.

Where to start, and what overrides what:

| File | Role |
|---|---|
| `SYNTHESIS.md` | **The reference** (v2, reviews integrated): fact sheet, contradiction log, decisions D1-D9, safety rules (§5), staged plan with gates (§6), work breakdown, unknowns, corrections to the older documents (§9), review log (§10) |
| `review/kernel_boot_review.md`, `review/telephony_voice_review.md` | the two adversarial reviews of SYNTHESIS v1; their accepted findings are already in v2 |
| `analysis/` | the static analyses (evidence): `radio_image.md` (BOOT/MAIN of the RADIO image), `loader_spec_v2.md` (the loader, supersedes `../LOADER_SPEC.md`), `ipc41_catalogue.md` (IPC 4.1 messages), `ril_runtime_rfs.md` (libsec-ril, RFS, NV checks), `kernel_port_design.md`, `voice_audio_design.md`. Some of their statements were later corrected: SYNTHESIS §9.5 lists them |
| `research_notes/Modem Shannon SS333 sous Linux/` | the five web research notes (kernel drivers, CP boot and firmware, Samsung IPC and free RILs, Android RIL reuse, Linux phone stack and voice) |
| `reports/Modem Shannon SS333 sous Linux.md` | the French summary of the web research, for the owner |

The older documents one level up (`SS333_LLI_BRINGUP.md`, `CBD_RE.md`,
`LOADER_SPEC.md`, `modem_v1_uapi.h`) were corrected in place on
2026-10-30 following SYNTHESIS §9; `LOADER_SPEC.md` is superseded.
