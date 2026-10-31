#!/bin/bash
# install-packages.sh — step 3 of rootfs/Dockerfile: Omarchy's own package
# list (install/omarchy-base.packages of the installed omarchy package, as
# Omarchy's ISO and omarchy-mobile use it) minus packages.omarchy-skip, plus
# packages.extra, in one pacman transaction.
#
# A name of Omarchy's list that pacman cannot resolve on armv7h (missing, or
# with a missing dependency) is left out and recorded as unavailable.
# Records, for finalize.sh and the MANIFEST:
#   /usr/share/t715-omarchy/build/omarchy-base.tsv   name, status, reason
#   /usr/share/t715-omarchy/build/extras.tsv         name, status, reason
set -euo pipefail

BASE_LIST=/usr/share/omarchy/install/omarchy-base.packages
SKIP_LIST=/t715/packages.omarchy-skip
EXTRA_LIST=/t715/packages.extra
B=/usr/share/t715-omarchy/build

# Omarchy's guard hook refuses "pacman -Syu" outside "omarchy update".
export OMARCHY_ALLOW_DIRECT_PACMAN=1

die() { printf 'install-packages: %s\n' "$*" >&2; exit 1; }

[ -f "$BASE_LIST" ] || die "no $BASE_LIST (is omarchy installed?)"
mkdir -p "$B"

# list_entries FILE: "name<TAB>comment" for every non-comment line.
list_entries() {
    sed -n 's/^[[:space:]]*\([^#[:space:]][^#[:space:]]*\)[[:space:]]*\(#[[:space:]]*\(.*\)\)\{0,1\}$/\1\t\3/p' "$1"
}

# why_unavailable NAME: one line explaining why pacman cannot install NAME.
why_unavailable() {
    local out deps
    out="$(pacman -Sp --print-format %n "$1" 2>&1 || true)"
    deps="$(printf '%s\n' "$out" \
        | sed -n "s/^:: unable to satisfy dependency '\([^']*\)' required by \(.*\)$/\1 (needed by \2)/p" \
        | paste -sd, - | sed 's/,/, /g')"
    if printf '%s\n' "$out" | grep -q 'target not found'; then
        echo "not in the armv7h repositories"
    elif [ -n "$deps" ]; then
        echo "unsatisfiable dependencies on armv7h: $deps"
    else
        printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-120
    fi
}

available() { pacman -Sp --print-format %n "$1" >/dev/null 2>&1; }

pacman -Sy --noconfirm

declare -A skip_reason=()
while IFS=$'\t' read -r name reason; do
    skip_reason[$name]="${reason:-listed in packages.omarchy-skip}"
done < <(list_entries "$SKIP_LIST")

want=()
: > "$B/omarchy-base.tsv.tmp"
while IFS=$'\t' read -r name _; do
    if [ -n "${skip_reason[$name]+x}" ]; then
        printf '%s\tskipped\t%s\n' "$name" "${skip_reason[$name]}" >> "$B/omarchy-base.tsv.tmp"
    elif available "$name"; then
        want+=("$name")
        printf '%s\twanted\t\n' "$name" >> "$B/omarchy-base.tsv.tmp"
    else
        printf '%s\tunavailable\t%s\n' "$name" "$(why_unavailable "$name")" >> "$B/omarchy-base.tsv.tmp"
    fi
done < <(list_entries "$BASE_LIST")

mandatory=()
besteffort=()
: > "$B/extras.tsv.tmp"
while IFS=$'\t' read -r name reason; do
    case "$name" in
        \?*) name="${name#\?}"
             if available "$name"; then
                 besteffort+=("$name")
             else
                 printf '%s\tmissing\tbest effort: %s\n' "$name" "$(why_unavailable "$name")" >> "$B/extras.tsv.tmp"
             fi ;;
        *)   available "$name" || die "mandatory extra package $name: $(why_unavailable "$name")"
             mandatory+=("$name") ;;
    esac
done < <(list_entries "$EXTRA_LIST")

echo "install-packages: Omarchy's list: ${#want[@]} to install, ${#skip_reason[@]} in the skip list; extras: ${#mandatory[@]} mandatory, ${#besteffort[@]} best effort"

# One transaction (hooks run once under qemu). If it fails with the
# best-effort packages, retry without them.
if ! pacman -Su --needed --noconfirm "${want[@]}" "${mandatory[@]}" "${besteffort[@]}"; then
    [ "${#besteffort[@]}" -gt 0 ] || die "pacman failed"
    echo "install-packages: retrying without the best-effort packages: ${besteffort[*]}" >&2
    pacman -Su --needed --noconfirm "${want[@]}" "${mandatory[@]}" || die "pacman failed"
fi

# Final statuses, from what pacman now has (pacman -T also accepts names
# provided by another package).
: > "$B/omarchy-base.tsv"
while IFS=$'\t' read -r name status reason; do
    if [ "$status" = wanted ]; then
        if pacman -T "$name" >/dev/null 2>&1; then
            printf '%s\tinstalled\t%s\n' "$name" "$(pacman -Q "$name" 2>/dev/null | cut -d' ' -f2)" >> "$B/omarchy-base.tsv"
        else
            printf '%s\tfailed\tpacman did not install it\n' "$name" >> "$B/omarchy-base.tsv"
        fi
    else
        printf '%s\t%s\t%s\n' "$name" "$status" "$reason" >> "$B/omarchy-base.tsv"
    fi
done < "$B/omarchy-base.tsv.tmp"
rm -f "$B/omarchy-base.tsv.tmp"

for name in "${mandatory[@]}" "${besteffort[@]}"; do
    if pacman -T "$name" >/dev/null 2>&1; then
        printf '%s\tinstalled\t%s\n' "$name" "$(pacman -Q "$name" 2>/dev/null | cut -d' ' -f2)" >> "$B/extras.tsv.tmp"
    else
        printf '%s\tmissing\tbest effort: pacman did not install it\n' "$name" >> "$B/extras.tsv.tmp"
    fi
done
mv "$B/extras.tsv.tmp" "$B/extras.tsv"

# The session cannot work without these: fail the build early.
required="omarchy omarchy-settings hyprland quickshell uwsm sddm mesa squeekboard openssh dnsmasq"
missing=""
for name in $required; do
    pacman -Q "$name" >/dev/null 2>&1 || missing="$missing $name"
done
[ -z "$missing" ] || die "required packages not installed:$missing"

echo "install-packages: $(pacman -Q | wc -l) packages installed"
