#!/bin/bash
# install-mobile.sh — step 3d of rootfs/Dockerfile: touch layer P2's
# packages (packages.mobile: omamobile-omarchy, omamobile-shell, built from
# pkg/ by tools/build-pkg), from the local [t715-omarchy] repository only.
#
# Installing omamobile-omarchy runs its pacman hook, which applies the
# Omarchy patch series (omamobile-omarchy-patches apply --hook). This script
# then runs the applier again (a no-op when the hook succeeded), its status
# and its verify, and stops the build unless the whole series is in place:
# a half-patched Omarchy would be worse than none.
#
# Records, for finalize.sh and the MANIFEST:
#   /usr/share/t715-omarchy/build/mobile.tsv   step, status, detail
set -euo pipefail

LIST=/t715/packages.mobile
B=/usr/share/t715-omarchy/build
OUT="$B/mobile.tsv"
PATCHES=/usr/bin/omamobile-omarchy-patches

# Omarchy's guard hook refuses pacman outside "omarchy update".
export OMARCHY_ALLOW_DIRECT_PACMAN=1

die() { printf 'install-mobile: %s\n' "$*" >&2; exit 1; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; }

mkdir -p "$B"
: > "$OUT"

names=()
while IFS= read -r name; do
    names+=("$name")
done < <(sed -n 's/^[[:space:]]*\([^#[:space:]][^#[:space:]]*\).*/\1/p' "$LIST")
[ "${#names[@]}" -gt 0 ] || die "no package in $LIST"

# The pacman cache is a BuildKit cache mount that every build of this image
# shares: it can hold another build of a local package under the same file
# name (another checkout's build-pkg run), which pacman then rejects as
# corrupted. [t715-omarchy] is the only source of these files: drop their
# cached copies, so that pacman takes them from /repo.
for f in /repo/*.pkg.tar.zst; do
    rm -f "/var/cache/pacman/pkg/${f##*/}" "/var/cache/pacman/pkg/${f##*/}.sig"
done

pacman -Sy --noconfirm
for name in "${names[@]}"; do
    pacman -Sp "$name" >/dev/null 2>&1 \
        || die "$name: not installable ($(pacman -Sp "$name" 2>&1 | tail -n1))"
    # pacman -Si lists the repositories in pacman.conf order: the first one wins.
    repo="$(pacman -Si "$name" | sed -n 's/^Repository *: //p' | head -n1)"
    [ "$repo" = t715-omarchy ] || die "$name comes from [${repo:-?}], not the local [t715-omarchy] (tools/build-pkg $name)"
done

echo "install-mobile: ${names[*]}"
pacman -S --needed --noconfirm "${names[@]}" || die "pacman failed"
for name in "${names[@]}"; do
    record "package: $name" installed "$(pacman -Q "$name" | cut -d' ' -f2) from [t715-omarchy]"
done

# The series, explicitly (the hook ran it already; this must say so).
if out="$("$PATCHES" apply 2>&1)"; then
    record "patches: apply" ok "$(printf '%s\n' "$out" | tail -n1)"
else
    printf '%s\n' "$out" >&2
    die "omamobile-omarchy-patches apply failed (log /var/log/omamobile/omarchy-patches.log)"
fi
"$PATCHES" status > "$B/omarchy-patches.status" 2>&1 || {
    cat "$B/omarchy-patches.status" >&2
    die "omamobile-omarchy-patches status is not ok"
}
if out="$("$PATCHES" verify 2>&1)"; then
    record "patches: verify" ok "$out"
else
    printf '%s\n' "$out" >&2
    die "omamobile-omarchy-patches verify failed"
fi
applied="$(sed -n 's/^applied: //p' "$B/omarchy-patches.status")"
upstream="$(sed -n 's/^already in omarchy: //p' "$B/omarchy-patches.status")"
record "patches: applied" "$(echo $applied | wc -w | tr -d ' ')" "$applied"
record "patches: already in Omarchy" "$(echo $upstream | wc -w | tr -d ' ')" "${upstream:--}"

echo "install-mobile: done"
cat "$OUT"
