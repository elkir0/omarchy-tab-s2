#!/usr/bin/env bash
# Snapshot the modem bring-up state of the tablet for one gate, read-only.
#
#   device/modem-snap.sh GATE [--ref FILE]
#
# Writes into $T715_PRIVATE/modem-snap/<date>/GATE/<time>/ (never the repo):
#   innocuity.sha256  sha256 of EFS, m9kefs1-3 and RADIO read by partlabel,
#                     compared with --ref (default: the G0 reference); a
#                     mismatch prints MISMATCH and exits 3 (stop all tablet work)
#   dmesg.txt         kernel lines of the modem stack (dflags=0: headers only)
#   state.txt         uname, lsmod, lli_control, cp_status, debugfs status
#                     files, modem GPIO registers (read through /dev/mem)
# Nothing here writes to the tablet except /root/rdreg.py when it is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSSH="$REPO_ROOT/device/tssh"
PRIVATE="${T715_PRIVATE:-$HOME/t715-private}"
GATE="${1:?usage: modem-snap.sh GATE [--ref FILE]}"; shift
REF="$PRIVATE/modem-snap/G0/innocuity-before.sha256"
[[ "${1:-}" == --ref ]] && { REF="$2"; shift 2; }
OUT="$PRIVATE/modem-mission/$(date +%Y%m%d)/$GATE/$(date +%H%M%S)"
mkdir -p "$OUT"

"$TSSH" 'for p in EFS m9kefs1 m9kefs2 m9kefs3 RADIO; do sha256sum /dev/disk/by-partlabel/$p; done' >"$OUT/innocuity.sha256"
status=0
for p in EFS m9kefs1 m9kefs2 m9kefs3 RADIO; do
    now=$(awk -v p="/$p" '$2 ~ p"$" {print $1}' "$OUT/innocuity.sha256")
    ref=$(awk -v p="/$p" '$2 ~ p"$" {print $1}' "$REF")
    if [[ -n "$now" && "$now" == "$ref" ]]; then
        echo "innocuity $p MATCH ${now:0:12}"
    else
        echo "innocuity $p MISMATCH (now ${now:0:12}, ref ${ref:0:12})"; status=3
    fi
done

"$TSSH" "dmesg | grep -iE 'lli|mphy|mif|modem|ss333|sipc|umts|spi|rmnet|cp_|shannon|cpif|reserved mem' || true" >"$OUT/dmesg.txt"

[[ -n "$("$TSSH" 'ls /root/rdreg.py 2>/dev/null')" ]] || "$TSSH" 'cat > /root/rdreg.py' <<'EOF'
import mmap, os, struct, sys
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
for a in sys.argv[1:]:
    addr = int(a, 16); base = addr & ~0xfff
    m = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    print("0x%08x = 0x%08x" % (addr, struct.unpack_from("<I", m, addr - base)[0]))
    m.close()
EOF

# GPIO banks of the modem pins (CON, DAT, PUD): gpa2 gpa3 (alive), gpf1 gpf5
# (alive, second resource), gpr2 gpr3, gpv7 gpc0 gpg2; CMU_CPIF; PMU 0x720.
"$TSSH" 'uname -r; echo; lsmod | grep -iE "lli|modem|spi" || echo "(no modem module)"; echo
for f in /sys/bus/platform/devices/*mipi-lli*/lli_control /sys/bus/platform/drivers/mif_sipc5/*/cp_status/value /sys/kernel/debug/mipi-lli/status /sys/kernel/debug/ss333/status /sys/module/exynos5433_mipi_lli/parameters/* /sys/module/sec_modem_v1/parameters/*; do [ -r "$f" ] && { echo "== $f"; cat "$f"; }; done 2>/dev/null; echo
ls -l /dev/umts_* /dev/ipc_loopback0 /dev/multipdp 2>/dev/null; ip -br link 2>/dev/null | grep rmnet; echo
cat /sys/class/power_supply/*/capacity 2>/dev/null | head -1 | sed "s/^/battery% /"
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr "\n" " " | sed "s/^/thermal /"; echo
python3 /root/rdreg.py 10580040 10580044 10580060 10580064 11090020 11090024 110900a0 110900a4 15690080 15690084 156900a0 156900a4 14cc0000 14cc0004 14cc0040 14cc0044 14cc01e0 14cc01e4 10fc0204 10fc0b00 10fc0b04 105c0720' >"$OUT/state.txt" 2>&1 || true

echo "snapshot: $OUT"
exit $status
