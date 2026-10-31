#!/bin/bash
# t715-wallpapers.sh — step 3c of rootfs/Dockerfile (root, armv7h, qemu).
# Scales Omarchy's theme backgrounds down so that their short side is 2048 px,
# the panel's long side: sharp in portrait and landscape, but no longer
# decoded at up to 7680x4320. Omarchy's shell loads the background with no
# sourceSize, so a 6016x3384 JPEG became a 78 MiB texture, and a theme switch
# took MemAvailable down to 291 MiB (docs/journal/ONDEVICE-2026-10-28.md).
# Writes /usr/share/t715-omarchy/wallpapers.tsv: file, size before, size after.
set -euo pipefail

SHORT=2048
OUT=/usr/share/t715-omarchy/wallpapers.tsv
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

n=0; scaled=0
while IFS= read -r -d '' f; do
    n=$((n + 1))
    w="$(vipsheader -f width "$f" 2>/dev/null)" || { printf '%s\tunreadable\t-\n' "$f" >> "$OUT"; continue; }
    h="$(vipsheader -f height "$f")"
    s=$(( w < h ? w : h ))
    if [ "$s" -le "$SHORT" ]; then
        printf '%s\t%sx%s\tunchanged\n' "$f" "$w" "$h" >> "$OUT"
        continue
    fi
    case "${f,,}" in
        *.jpg|*.jpeg) fmt='[Q=90,strip]' ;;
        *.png)        fmt='[compression=6,strip]' ;;
        *.webp)       fmt='[Q=90,strip]' ;;
        *)            printf '%s\t%sx%s\tskipped (format)\n' "$f" "$w" "$h" >> "$OUT"; continue ;;
    esac
    tmp="$(dirname "$f")/.t715-$(basename "$f")"
    VIPS_CONCURRENCY=4 vips resize "$f" "$tmp$fmt" "$(awk -v a="$SHORT" -v b="$s" 'BEGIN { printf "%.6f", a / b }')"
    chmod --reference="$f" "$tmp"
    mv -f "$tmp" "$f"
    printf '%s\t%sx%s\t%sx%s\n' "$f" "$w" "$h" "$(vipsheader -f width "$f")" "$(vipsheader -f height "$f")" >> "$OUT"
    scaled=$((scaled + 1))
done < <(find /usr/share/omarchy/themes -path '*/backgrounds/*' -type f \
              \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print0 | sort -z)

[ "$n" -gt 0 ] || { echo "wallpapers: no theme background found" >&2; exit 1; }
echo "wallpapers: $scaled of $n scaled to a ${SHORT}px short side"
