#!/bin/bash
# install-base.sh — step 2 of the Dockerfile: the base image's packages
# (packages.base) over ALARM's base, in one transaction, after dropping what
# the tarball carries and this image does not want:
#   netctl, dhcpcd: the tarball's network tools; NetworkManager manages the
#   network here (with its own DHCP client), and two managers on one wlan
#   would race at boot.
# They are marked explicit, so a later `pacman -Qdt` keeps them.
set -euo pipefail

LIST=/t715/packages.base
die() { printf 'install-base: %s\n' "$*" >&2; exit 1; }

[ -f "$LIST" ] || die "no $LIST"
names=()
while IFS= read -r name; do
    names+=("$name")
done < <(sed -n 's/^[[:space:]]*\([^#[:space:]][^#[:space:]]*\).*/\1/p' "$LIST")
[ "${#names[@]}" -gt 0 ] || die "no package in $LIST"

drop=""
for p in netctl dhcpcd; do
    pacman -Qq "$p" >/dev/null 2>&1 && drop="$drop $p"
done
if [ -n "$drop" ]; then
    # shellcheck disable=SC2086
    pacman -R --noconfirm --nosave $drop || die "cannot remove:$drop"
fi

# Omarchy's guard hook refuses "pacman -Syu" outside "omarchy update"; the
# base image has no omarchy yet, the variable costs nothing.
export OMARCHY_ALLOW_DIRECT_PACMAN=1
pacman -Syu --needed --noconfirm "${names[@]}" || die "pacman failed"
pacman -D --asexplicit "${names[@]}" >/dev/null

for name in "${names[@]}"; do
    pacman -Q "$name" >/dev/null 2>&1 || die "$name was not installed"
done
echo "install-base: $(pacman -Q | wc -l) packages installed"
