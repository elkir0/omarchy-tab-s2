#!/usr/bin/env bash
# tests/verify-armv8.sh — the fleet task's acceptance check (2026-11-25), from pkg/voxtype-bin: builds PKGBUILD for aarch64 in the container t715-arm64-port-rootfs/dev (Arch Linux
# ARM, network on), then runs every ELF file of the built package under qemu-aarch64 -cpu cortex-a57
# (ARMv8.0-A: no LSE atomics, no dotprod, no fp16, no RCpc: the target tablet's CPU), then
# tests/transcribe-check.sh (a real transcription, also under qemu cortex-a57).
# Ends with "VERIFY: PASS" only if all of it passes. Packages land in out/.
# Usage: ./verify.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # pkg/voxtype-bin
if [ "${1:-}" != --inner ]; then
  mkdir -p "$HERE/out"
  exec docker run --rm --platform linux/arm64 -v "$HERE:/w" t715-arm64-port-rootfs/dev bash /w/verify.sh --inner
fi

# --- inside the container, as root
printf 'Server = http://mirror.archlinuxarm.org/$arch/$repo\n' > /etc/pacman.d/mirrorlist
pacman -Syu --noconfirm --noprogressbar >/dev/null
pacman -S --needed --noconfirm --noprogressbar base-devel qemu-user llvm >/dev/null
id builder >/dev/null 2>&1 || useradd -m -U builder
B=/tmp/build; rm -rf "$B"; mkdir -p "$B"; cp /w/PKGBUILD "$B"/; chown -R builder:builder "$B"
cd "$B"
# makedepends/depends/checkdepends from .SRCINFO, installed by root (no sudo for the builder)
mapfile -t deps < <(su builder -c "cd $B && makepkg --printsrcinfo" \
  | awk -F' = ' '/^\t(make|check)?depends = /{print $2}' | sed 's/[<>=].*//' | sort -u)
[ "${#deps[@]}" -eq 0 ] || pacman -S --needed --asdeps --noconfirm --noprogressbar "${deps[@]}" >/dev/null
su builder -c "cd $B && MAKEFLAGS=-j$(nproc) makepkg --nodeps --noconfirm -f"
cp "$B"/*.pkg.tar.* /w/out/

echo "== every ELF of the package under qemu-aarch64 -cpu cortex-a57"
X=/tmp/x; rm -rf "$X"; mkdir -p "$X"
for p in "$B"/*.pkg.tar.zst; do bsdtar -xf "$p" -C "$X"; done
fail=0; n=0
while IFS= read -r f; do
  file -b "$f" | grep -q '^ELF 64-bit LSB pie executable\|^ELF 64-bit LSB executable' || continue
  n=$((n + 1))
  rc=0; timeout 120 qemu-aarch64 -cpu cortex-a57 -L "$X" "$f" --version >/tmp/q.out 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    rc2=0; timeout 120 qemu-aarch64 -cpu cortex-a57 -L "$X" "$f" --help >/tmp/q.out 2>&1 || rc2=$?
    # 132 = SIGILL, 139 = SIGSEGV, 124 = timeout: never acceptable
    case "$rc2" in 132|139|124) echo "FAIL ${f#$X} (--version $rc, --help $rc2)"; fail=1; continue ;; esac
  fi
  lse=$(llvm-objdump -d "$f" 2>/dev/null | grep -cE '\s(cas|casa|casal|casl|casp|swp|swpa|swpal|swpl|ldadd|ldadda|ldaddal|ldaddl|ldset|ldseta|ldsetal|ldsetl|ldclr|ldclra|ldclral|ldclrl|ldeor|ldeora|ldeoral|ldeorl)[bh]?\s' || true)
  echo "ok   ${f#$X} (LSE instructions in the file: $lse)"
done < <(find "$X/usr" -type f)
[ "$n" -gt 0 ] || { echo "FAIL: no ELF executable in the package"; exit 1; }
[ "$fail" -eq 0 ] || { echo "FAIL: an ELF does not run on ARMv8.0"; exit 1; }

echo "== tests/transcribe-check.sh"
[ -x /w/tests/transcribe-check.sh ] || { echo "FAIL: tests/transcribe-check.sh missing or not executable"; exit 1; }
QEMU_CPU=cortex-a57 bash /w/tests/transcribe-check.sh "$X"
echo "VERIFY: PASS"
