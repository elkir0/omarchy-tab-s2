#!/usr/bin/env bash
# Phase 1 — sauvegarde des partitions depuis TWRP (root), en LECTURE SEULE.
#
# - Les images sont lues par `dd if=<partition>` côté tablette et transmises par
#   `adb exec-out` : rien n'est écrit sur la tablette.
# - Chaque image est vérifiée : SHA-256 calculé sur la tablette = SHA-256 sur le Mac.
# - Tout part dans $PRIVATE_DIR (hors dépôt) : EFS et m9kefs contiennent l'IMEI.
# - Seuls les blobs non personnels utiles au portage sont copiés dans dumps/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRIVATE_DIR="${PRIVATE_DIR:-$HOME/t715-private}"
OUT="$PRIVATE_DIR/backups/$(date +%Y%m%d-%H%M%S)"
BYNAME=/dev/block/platform/15540000.dwmmc0/by-name

: "${ANDROID_SERIAL:?ANDROID_SERIAL doit désigner la tablette (adb devices -l)}"
export ANDROID_SERIAL

state="$(adb get-state 2>/dev/null || true)"
dev="$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
uid="$(adb shell id -u 2>/dev/null | tr -d '\r')"
if [ "$state" != "recovery" ] || [ "$uid" != "0" ]; then
  echo "ABANDON : il faut TWRP (état=$state, uid=$uid)" >&2; exit 1
fi
case "$dev" in gts28lte|gts28ltexx) ;; *) echo "ABANDON : appareil '$dev' inattendu" >&2; exit 1 ;; esac

# Partitions sauvegardées. SYSTEM (3 Go) permet de revenir à Android plus tard.
PARTS="EFS m9kefs1 m9kefs2 m9kefs3 PERSISTENT PERSDATA PARAM CARRIER BOTA0 BOTA1 BOOT RADIO CDMA-RADIO DNT SYSTEM"
[ "${SKIP_SYSTEM:-0}" = 1 ] && PARTS="${PARTS% SYSTEM}"

mkdir -p "$OUT"
: > "$OUT/SHA256SUMS"
for p in $PARTS; do
  if ! adb shell "test -b $BYNAME/$p" ; then echo "  $p : absent, ignoré"; continue; fi
  printf "  %-11s " "$p"
  adb exec-out "dd if=$BYNAME/$p bs=1048576 2>/dev/null" > "$OUT/$p.img"
  remote="$(adb shell "sha256sum $BYNAME/$p" | tr -d '\r' | awk '{print $1}')"
  local_sum="$(shasum -a 256 "$OUT/$p.img" | awk '{print $1}')"
  size="$(stat -f %z "$OUT/$p.img")"
  if [ "$remote" != "$local_sum" ]; then
    echo "ÉCHEC sha256 (tablette=$remote mac=$local_sum)"; exit 1
  fi
  echo "$local_sum  $p.img" >> "$OUT/SHA256SUMS"
  echo "OK $size octets"
done

echo "Infos noyau TWRP (pas le noyau d'origine)"
adb shell 'cat /proc/iomem' 2>/dev/null | tr -d '\r' > "$OUT/twrp_iomem.txt" || true
adb shell 'cat /proc/cmdline' 2>/dev/null | tr -d '\r' > "$OUT/twrp_cmdline.txt" || true
adb exec-out 'cat /proc/config.gz' > "$OUT/twrp_config.gz" 2>/dev/null || true
chmod -R go-rwx "$PRIVATE_DIR"

# Blobs non personnels utiles au portage (firmware modem, noyau + ramdisk d'origine)
mkdir -p "${T715_DUMPS_DIR:-$ROOT/dumps}/stock"
cp "$OUT/RADIO.img" "${T715_DUMPS_DIR:-$ROOT/dumps}/radio.img"
cp "$OUT/BOOT.img" "${T715_DUMPS_DIR:-$ROOT/dumps}/stock/boot.img"
grep -E " (RADIO|BOOT)\.img$" "$OUT/SHA256SUMS" > "${T715_DUMPS_DIR:-$ROOT/dumps}/stock/SHA256SUMS"

echo "Sauvegardes : $OUT"
