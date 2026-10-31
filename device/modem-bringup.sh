#!/usr/bin/env bash
# One modem bring-up after a tablet boot (image mode), through the systemd
# units of modem/systemd:
#
#   device/modem-bringup.sh --apn APN [--no-data] [--tag NAME]
#
# 1. device/modem-push.sh, then installs the loader in /usr/local/bin, shannond
#    in /usr/lib/shannond, the two units, the ModemManager D-Bus policy and
#    the radio group (all in the RAM overlay of image mode);
# 2. loads the LLI, SPI and modem modules, sets allow_hw, fills the guard canary;
# 3. waits for the gauge temperature (< 54.0 degC; the unit's loader refuses at
#    55.0), starts
#    shannon-loader.service (Type=notify: returns at ONLINE) and shannond.service;
# 4. unless --no-data: NetworkManager brings the "t715-mobile" gsm connection
#    up (enable, registration, bearer), pings and fetches 200 kB over rmnet0,
#    and takes it down again;
# 5. device/modem-snap.sh TAG (innocuity hashes).
# Prints timings and states only, never an identifier. Stops at the first
# failed step (exit 1, after the innocuity hashes), or with exit 3 when the
# innocuity hashes differ.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSSH="$REPO_ROOT/device/tssh"
APN="" DATA=1 TAG="bringup"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apn) APN="$2"; shift 2 ;;
        --no-data) DATA=0; shift ;;
        --tag) TAG="$2"; shift 2 ;;
        *) echo "usage: modem-bringup.sh --apn APN [--no-data] [--tag NAME]" >&2; exit 2 ;;
    esac
done
[[ $DATA == 0 || -n "$APN" ]] || { echo "--apn is required unless --no-data" >&2; exit 2; }

"$REPO_ROOT/device/modem-push.sh" >/dev/null
COPYFILE_DISABLE=1 tar --no-xattrs -C "$REPO_ROOT/modem" -cf - systemd shannond/dbus | "$TSSH" 'tar -C /root/modem -xf -'
# the "Voice Call" UCM verb (not in the image yet)
COPYFILE_DISABLE=1 tar --no-xattrs -C "$REPO_ROOT/image/rootfs/overlay/usr/share/alsa/ucm2/conf.d/wm1814" -cf - VoiceCall.conf wm1814.conf |
    "$TSSH" 'tar -C /usr/share/alsa/ucm2/conf.d/wm1814 -xf -'

steps_rc=0
"$TSSH" "APN='$APN' DATA=$DATA bash -s" <<'EOF' || steps_rc=$?
set -euo pipefail
t0=$(date +%s.%N)
el() { awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%6.1f s", b - a }'; }
step() { echo "[$(el)] $*"; }
fail() { echo "[$(el)] FAILED: $*"; exit 1; }

install -m 0755 /root/modem/loader/build/shannon-loader-armv7 /usr/bin/shannon-loader
mkdir -p /usr/lib/shannond && cp -r /root/modem/shannond/shannond /root/modem/shannond/bin /usr/lib/shannond/
install -m 0755 /root/modem/audio/voice-hook.sh /usr/lib/shannond/voice-hook.sh
install -m 0644 /root/modem/systemd/shannon-loader.service /root/modem/systemd/shannond.service /etc/systemd/system/
install -m 0644 /root/modem/shannond/dbus/org.freedesktop.ModemManager1.conf /usr/share/dbus-1/system.d/t715-modem-mm.conf
getent group radio >/dev/null || groupadd -r radio
systemctl daemon-reload
busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig
step "userspace and units installed"

modprobe exynos5433-mipi-lli && modprobe spi-s3c64xx && modprobe sec_modem_v1
for m in exynos5433_mipi_lli sec_modem_v1; do echo 1 > /sys/module/$m/parameters/allow_hw; done
python3 /root/modem/tools/canary.py set >/dev/null
step "modules loaded, allow_hw=1, canary set"

for i in $(seq 1 90); do
    t=$(cat /sys/class/power_supply/sm5703-fuelgauge/temp)
    [ "$t" -lt 540 ] && break
    [ "$i" = 1 ] && step "battery ${t} deci-degC: waiting for < 540"
    sleep 20
done
[ "$t" -lt 540 ] || fail "battery still at $t deci-degC after 30 min"
step "battery gate: $(cat /sys/class/power_supply/sm5703-fuelgauge/capacity) %, $t deci-degC"

systemctl start shannon-loader.service || fail "shannon-loader.service: $(systemctl show -p ExecMainStatus --value shannon-loader.service)"
grep -q 'state=online' /run/shannon/cp-state || fail "cp-state: $(cat /run/shannon/cp-state)"
step "CP ONLINE ($(journalctl -u shannon-loader -b -o cat | grep -o 'CP online after [0-9.]* s' | tail -1))"

systemctl start shannond.service
sleep 2
systemctl is-active -q shannond.service || fail "shannond.service: $(journalctl -u shannond -b -o cat | tail -1)"
mm=/org/freedesktop/ModemManager1/Modem/0
for i in $(seq 1 30); do
    st=$(busctl --system get-property org.freedesktop.ModemManager1 $mm org.freedesktop.ModemManager1.Modem State 2>/dev/null | cut -d' ' -f2) || true
    [ -n "$st" ] && [ "$st" -ge 3 ] && break
    sleep 1
done
[ -n "$st" ] && [ "$st" -ge 3 ] || fail "ModemManager facade state ${st:-absent}"
step "shannond up, facade modem state $st"

if [ "$DATA" = 1 ]; then
    nmcli -t -f NAME connection show | grep -qx t715-mobile ||
        nmcli connection add type gsm ifname '*' con-name t715-mobile gsm.apn "$APN" \
            connection.autoconnect no ipv6.method ignore >/dev/null
    nmcli -w 180 connection up t715-mobile >/dev/null || fail "nmcli connection up"
    step "NetworkManager: $(nmcli -t -f GENERAL.STATE device show umts_ipc0 | cut -d: -f2) on $(nmcli -t -f GENERAL.IP-IFACE device show umts_ipc0 | cut -d: -f2)"
    r0=$(cat /sys/class/net/rmnet0/statistics/rx_bytes)
    ping -I rmnet0 -c 3 -W 5 1.1.1.1 >/dev/null || fail "ping over rmnet0"
    curl -s --interface rmnet0 -o /dev/null "https://speed.cloudflare.com/__down?bytes=200000" || fail "HTTPS over rmnet0"
    step "traffic over rmnet0: +$(( $(cat /sys/class/net/rmnet0/statistics/rx_bytes) - r0 )) bytes received"
    nmcli connection down t715-mobile >/dev/null
fi
env PYTHONPATH=/usr/lib/shannond python3 /usr/lib/shannond/bin/shannonctl status | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["reg"]
print("registration cs=%s ps=%s rat=%s signal=%s%% sim=%s power=%s" % (r["cs"], r["ps"], r["rat"],
      d["signal"]["percent"], d["sim"]["state"], d["power"]))'
python3 /root/modem/tools/canary.py check | tail -1
step "done"
EOF
# innocuity hashes even when a step failed
rc=0
out=$("$REPO_ROOT/device/modem-snap.sh" "$TAG") || rc=$?
grep -E "MISMATCH|snapshot" <<<"$out"
[[ $rc -ne 0 ]] && exit $rc
exit $(( steps_rc ? 1 : 0 ))
