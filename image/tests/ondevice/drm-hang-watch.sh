#!/bin/sh
# drm-hang-watch.sh — diagnostic for the exynos-drm black screens
# (docs/DEPLOY.md 13., "A black screen"). Runs as root ON THE TABLET from
# early boot (t715-drm-hang-watch.service below), waits for the first
# "flip_done timed out" in the kernel log, then writes two snapshots of
# the display pipeline 20 s apart to /var/lib/t715-drm-hang/BOOTID-N.txt:
# DECON and DSIM registers (read only while their runtime PM status is
# "active": reading a powered-off block hangs the bus), interrupt
# counts, the DRM atomic state, display clocks and the kernel log's tail.
#
# Install (persistent root), from the Mac:
#   tssh 'cat > /usr/local/sbin/drm-hang-watch' < tests/ondevice/drm-hang-watch.sh
#   tssh 'chmod 755 /usr/local/sbin/drm-hang-watch; drm-hang-watch --install'
# "drm-hang-watch --snapshot" prints one snapshot now (check it reads).
set -u
OUT=/var/lib/t715-drm-hang
DECON=/sys/devices/platform/soc@0/13800000.decon
DSI=/sys/devices/platform/soc@0/13900000.dsi
MIC=/sys/devices/platform/soc@0/13930000.mic

if [ "${1:-}" = --install ]; then
    cat >/etc/systemd/system/t715-drm-hang-watch.service <<'EOF'
[Unit]
Description=Snapshot the display pipeline at the first exynos-drm flip_done timeout
DefaultDependencies=no
After=systemd-tmpfiles-setup-dev-early.service
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
ExecStart=/usr/local/sbin/drm-hang-watch

[Install]
WantedBy=sysinit.target
EOF
    systemctl daemon-reload
    systemctl enable t715-drm-hang-watch.service
    exit
fi

# regs BASE_HEX SIZE_HEX OFFSET...: one line per register, read via /dev/mem.
regs() {
    python3 - "$@" <<'PY'
import mmap, os, struct, sys
base, size = int(sys.argv[1], 16), int(sys.argv[2], 16)
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
for o in sys.argv[3:]:
    off = int(o, 16)
    print("  0x%08x +0x%04x = 0x%08x" % (base + off, off, struct.unpack("<I", m[off:off + 4])[0]))
PY
}

snapshot() {
    echo "== snapshot $1 at $(cat /proc/uptime | cut -d' ' -f1) s"
    grep -E "drm_dec|13900000|panfrost" /proc/interrupts
    for d in "$DECON" "$DSI" "$MIC"; do
        echo "${d##*/}: runtime $(cat "$d/power/runtime_status" 2>/dev/null)"
    done
    if [ "$(cat "$DECON/power/runtime_status" 2>/dev/null)" = active ]; then
        echo "DECON (VIDCON0 VIDOUTCON0 WINCON0-4 SHADOWCON VIDINTCON0/1 CMU UPDATE CRFMID UPDATE_SCHEME VIDCON1 TRIGCON), twice 100 ms apart:"
        set -- 0000 0010 0020 0024 0028 002c 0030 00a0 0220 0224 1404 1410 1414 1438 2000 2040
        regs 13800000 3000 "$@"
        sleep 0.1
        regs 13800000 3000 1414 2000 2040 0224
    fi
    if [ "$(cat "$DSI/power/runtime_status" 2>/dev/null)" = active ]; then
        echo "DSIM 0x00-0x7c:"
        regs 13900000 1000 00 04 08 0c 10 14 18 1c 20 24 28 2c 30 34 38 3c 40 44 48 4c 50 54 58 5c 60 64 68 6c 70 74 78 7c
    fi
    echo "-- DRM atomic state"
    cat /sys/kernel/debug/dri/0/state 2>&1 | head -60
    echo "-- clocks"
    grep -iE "decon|dsim|mipi|disp|mic|vclk" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -40
    echo "-- kernel log tail"
    dmesg | grep -vE "^\[[ 0-9.]+\]  " | tail -40
}

if [ "${1:-}" = --snapshot ]; then
    snapshot now
    exit
fi

mkdir -p "$OUT"
dmesg -w | grep -m1 -q "flip_done timed out"
f="$OUT/$(cat /proc/sys/kernel/random/boot_id)-$(date +%s).txt"
{ date; snapshot 1; sleep 20; snapshot 2; } >"$f" 2>&1
sync
