# Repacking Omarchy's packages for armv7h

The SM-T715 runs a 32-bit Arch Linux ARM userland (`armv7h`). Omarchy's
repository (`https://pkgs.omarchy.org/stable/<arch>/`) only publishes `x86_64`
and `aarch64`, but most of its packages contain no compiled code:

- `arch = any` packages (`omarchy-keyring`, `omarchy-themes-intros`,
  `omarchy-nvim`, the fonts, themes and small tools of
  `image/tools/repack.list`) are valid on any architecture: they are copied
  unchanged, with their upstream signatures.
- `omarchy` and `omarchy-settings` are tagged `aarch64` but contain only
  scripts, QML, configs and themes. `image/tools/repack-omarchy` retags them:
  `arch = armv7h`, `pkgrel` gets a `.1` suffix (`4.0.6-1` → `4.0.6-1.1`),
  a local packager line is set, and `.MTREE` is regenerated exactly the way
  makepkg writes it, over the unchanged file set.

Compiled packages (`quickshell`, `hyprland` extras, `neovim` build, …) are
**not** repacked here; rebuilding them for armv7h is a later task. They are
expected from the official ALARM `armv7h` repositories, which already carry
`hyprland`, `quickshell` and the rest of `omarchy`'s dependency tree.

## The ELF check

A package wrongly reused across architectures would put aarch64 machine code
on an armv7h system. Before retagging, the repack extracts the package inside
the `aarch64` dev container and **aborts if any regular file starts with the
ELF magic `\x7fELF`**. Everything is extracted inside Linux containers on
whole archive files; the macOS host never sees extracted contents (it is
case-insensitive and loses ownership).

## Signature model

- Upstream signatures are verified **at repack time**: every downloaded
  package is checked with `gpg --verify` against the keys shipped in the
  downloaded `omarchy-keyring` package, and the signing key must be listed in
  its `omarchy-trusted` file. Any failure aborts the run. Package files are
  additionally SHA-256-checked against the values in `omarchy.db`.
- The keyring vouches for itself, so its keys are **pinned**: every
  fingerprint its `omarchy-trusted` file lists must appear in
  `image/tools/omarchy-trusted.fpr` (today `40DFB630FF42BCFFB047046CF0134EE680CAC571`,
  "Omarchy <pkgs@omarchy.org>"), or the run aborts with `UNPINNED KEY`.
- The retagged packages are **unsigned** (their contents changed), and the
  repository database is unsigned too. On the armv7h system the repository is
  consumed over `file://` with

  ```
  [t715-omarchy]
  SigLevel = Optional TrustAll
  Server = file:///repo
  ```

  declared before the official repositories, so unsigned local packages
  install while the ALARM repositories stay fully signed. The trust therefore
  rests on this repository's build machine plus the repack-time verification
  recorded in `image/out/repo/armv7h/MANIFEST.tsv`.

## Running it

```bash
image/tools/repack-omarchy                 # download, verify, retag, index
image/tools/repack-omarchy --force         # re-download and rebuild everything
image/tools/repack-omarchy --list FILE     # another package list
image/tests/test_repack.sh                 # pacman checks in an armv7h container
column -t -s $'\t' image/out/repo/armv7h/MANIFEST.tsv
```

Downloads land in `image/cache/omarchy-upstream/<channel>/aarch64/`, retagged
packages in `image/cache/repacked/<channel>/`, the repository in
`image/out/repo/armv7h/` (`t715-omarchy.db`, packages, `MANIFEST.tsv`; stale
versions are removed). Packages built from `image/pkg/` by `image/tools/build-pkg`
(listed in `MANIFEST-built.tsv`) are kept and indexed, never removed: see
`docs/image/PACKAGES.md`. The tool is idempotent: without `--force` and without
upstream changes it downloads nothing (`omarchy.db` re-check uses
If-Modified-Since) and leaves the repository byte-identical.

## Refreshing when Omarchy releases

Just run `image/tools/repack-omarchy` again: it re-checks the channel's `omarchy.db`
(304 → nothing to do; 200 → new versions are downloaded, verified, retagged
and re-indexed, and the old package files are dropped from `image/out/repo/armv7h/`).
If a package upstream gains compiled code, the ELF check aborts the run and
that package moves to the rebuild track (`image/pkg/`). When Omarchy rotates its
signing key, the run stops with `UNPINNED KEY`: check the new key's
fingerprint through a second channel (Omarchy's site or repository), then add
it to `image/tools/omarchy-trusted.fpr`.
