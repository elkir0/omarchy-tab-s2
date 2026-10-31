#!/usr/bin/env bash
# Phase 1 — extraction SANS ROOT de la vérité terrain du SM-T715 (lecture seule).
#
# - Ne fait AUCUNE écriture sur la tablette (pas de dd, pas de push, pas de setprop).
# - Exige ANDROID_SERIAL : un autre appareil Android peut être connecté en même temps.
# - Copie brute (identifiants inclus) dans $PRIVATE_DIR, HORS du dépôt.
# - Copie caviardée (numéros de série, IMEI, MAC) dans dumps/ pour le travail courant.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRIVATE_DIR="${PRIVATE_DIR:-$HOME/t715-private}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RAW="$PRIVATE_DIR/raw_$STAMP"
OUT="${T715_DUMPS_DIR:-$ROOT/dumps}"

: "${ANDROID_SERIAL:?ANDROID_SERIAL doit désigner la tablette (adb devices -l)}"
export ANDROID_SERIAL

dev="$(adb shell getprop ro.product.device | tr -d '\r')"
model="$(adb shell getprop ro.product.model | tr -d '\r')"
if [ "$dev" != "gts28lte" ] || [ "$model" != "SM-T715" ]; then
  echo "ABANDON : $ANDROID_SERIAL est '$model/$dev', pas SM-T715/gts28lte" >&2
  exit 1
fi

mkdir -p "$RAW"/{dt,vendor_firmware,etc_wifi,lib} "$OUT"
sh_out() { adb shell "$1" 2>&1 | tr -d '\r' > "$RAW/$2" || true; }

echo "[1/5] Propriétés, partitions, logs noyau"
sh_out 'getprop' getprop.txt
sh_out 'cat /proc/partitions' partitions.txt
sh_out 'ls -l /dev/block/platform/15540000.dwmmc0/by-name/' by-name.txt
sh_out 'dmesg' dmesg.txt
sh_out 'cat /proc/last_kmsg' last_kmsg.txt
sh_out 'ls -la /sys/fs/pstore/' pstore_ls.txt
sh_out 'cat /proc/cpuinfo' cpuinfo.txt
sh_out 'cat /proc/meminfo' meminfo.txt
sh_out 'cat /proc/version' version.txt
sh_out 'ls -la /system/lib/ /system/vendor/lib/ /system/bin/ /system/vendor/bin/' system_listing.txt

echo "[2/5] Device tree vivant (/proc/device-tree)"
adb pull /proc/device-tree/. "$RAW/dt/" >/dev/null 2>"$RAW/dt_pull_errors.txt" || true
dtc -q -I fs -O dts -o "$RAW/live_fdt.dts" "$RAW/dt" 2>"$RAW/dtc_errors.txt" || true

echo "[3/5] Blobs lisibles (firmwares, RIL)"
adb pull /system/vendor/firmware/. "$RAW/vendor_firmware/" >/dev/null 2>>"$RAW/pull_errors.txt" || true
adb pull /system/etc/wifi/. "$RAW/etc_wifi/" >/dev/null 2>>"$RAW/pull_errors.txt" || true
for f in /system/lib/libsec-ril.so /system/lib/libsec-ril-dsds.so /system/lib/libreference-ril.so; do
  adb pull "$f" "$RAW/lib/" >/dev/null 2>>"$RAW/pull_errors.txt" || true
done

echo "[4/5] Copie caviardée vers dumps/"
serials="$(grep -E '\[(ro\.serialno|ro\.boot\.serialno|ril\.serialnumber|ro\.boot\.ap_serial|ro\.boot\.em\.did)\]' "$RAW/getprop.txt" \
  | sed -E 's/.*\]: \[(.*)\]/\1/' | grep -v '^$' || true)"
redact() {
  local s="$1" d="$2"
  # perl plutôt que sed : \b et le drapeau /i ne sont pas portables sur le sed BSD de macOS
  REDACT_LIST="$serials $ANDROID_SERIAL" perl -pe '
    BEGIN { @lit = grep { length } split /\s+/, $ENV{REDACT_LIST}; }
    s/\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/XX:XX:XX:XX:XX:XX/g;
    s/\b[0-9]{15}\b/<IMEI-REDACTED>/g;
    s/((?:serialno|serial|ap_serial|em\.did|imei|meid|macaddr|btaddr|wifimac|cordon|connie)\]?[=:]\s*\[?)[^\s\]]+/$1<REDACTED>/gi;
    s/^(Serial\s*:\s*)\S+/$1<SERIAL-REDACTED>/;
    s/(\bserial = )<0x[0-9a-f]+ 0x[0-9a-f]+>;/$1<0x0 0x0>; \/\* <SERIAL-REDACTED> \*\//;
    for my $p (@lit) { s/\Q$p\E/<SERIAL-REDACTED>/g; }
  ' "$s" > "$d"
}
for f in getprop.txt partitions.txt by-name.txt dmesg.txt last_kmsg.txt pstore_ls.txt cpuinfo.txt meminfo.txt version.txt system_listing.txt live_fdt.dts; do
  [ -f "$RAW/$f" ] && redact "$RAW/$f" "$OUT/$f"
done
rsync -a --delete "$RAW/vendor_firmware/" "$OUT/vendor_firmware/"
rsync -a --delete "$RAW/etc_wifi/" "$OUT/etc_wifi/"
rsync -a --delete "$RAW/lib/" "$OUT/lib/"
# Les fichiers nvram/calibration Wi-Fi peuvent embarquer une adresse MAC
grep -rlE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}|macaddr' "$OUT/etc_wifi" 2>/dev/null | while read -r f; do
  redact "$RAW/etc_wifi/${f#"$OUT/etc_wifi/"}" "$f"
done

echo "[5/5] Vérification : aucun identifiant brut dans dumps/"
leak=0
for pat in $serials $ANDROID_SERIAL; do
  if grep -rlF -- "$pat" "$OUT" >/dev/null 2>&1; then echo "FUITE : $pat dans $(grep -rlF -- "$pat" "$OUT" | head -3)"; leak=1; fi
done
[ "$leak" = 0 ] && echo "OK : copie caviardée propre"
echo "Brut  : $RAW"
echo "Caviardé : $OUT"
exit "$leak"
