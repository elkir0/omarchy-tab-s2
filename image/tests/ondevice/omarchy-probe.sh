#!/usr/bin/env bash
# omarchy-probe.sh — measurements on the tablet while it runs
# out/rootfs-omarchy.img. Runs as root ON THE TABLET, fed over SSH from the
# Mac:
#
#   ssh root@172.16.42.1 'bash -s' -- report    < tests/ondevice/omarchy-probe.sh
#   ssh root@172.16.42.1 'bash -s' -- sample 60 < tests/ondevice/omarchy-probe.sh
#   ssh root@172.16.42.1 'bash -s' -- overlay on < tests/ondevice/omarchy-probe.sh
#   ssh root@172.16.42.1 'bash -s' -- shot      < tests/ondevice/omarchy-probe.sh
#
#   report      boot path, units, session processes, GL renderer from
#               Hyprland's log, monitors and input devices, memory, pressure,
#               GPU frequency, temperatures, journal errors.
#   sample N    one line per second for N seconds (default 30): CPU % of
#               Hyprland and quickshell, load, free memory, GPU frequency.
#               Run it while someone uses the screen.
#   overlay on|off
#               Hyprland's debug overlay (FPS and frame times, drawn on the
#               screen) through `hyprctl eval` (Lua config).
#   shot        grim screenshot to /tmp/omarchy-shot.png (fetch it with scp).
#   bt          Bluetooth: t715-bt-addr's journal, the kernel's firmware
#               lines, the controller (address masked), a 10 s scan (count
#               of devices only: their names are other people's).
#   p2          touch layer P2 without hands on the tablet: the shell's
#               layers and cost, a cold restart timed to the home page,
#               each sheet opened through the shell's IPC (screenshots
#               /tmp/p2-*.png), and whether squeekboard unfolds for
#               Firefox's address bar.
#   image       the image and kernel at a glance: kernel options, Hyprland's
#               version and clients, whether the dmabuf shim is mapped,
#               t715-keys, squeekboard's unit and layout, bt-agent skipped
#               and the adapter not pairable, the IOMMU groups.
#   wifi        Wi-Fi: t715-wifi-addr's journal, brcmfmac, the interface
#               (address masked), NetworkManager, a scan (counts per band
#               only: the networks are other people's), NTP and the RTC.
#   noshim [off]
#               Hyprland without the dmabuf shim (kernels with the DECON
#               SysMMU): moves the /usr/local/bin/Hyprland wrapper aside,
#               restarts sddm, then checks the shell's layers, foot and
#               Firefox, and the kernel log. "off" puts the wrapper back
#               and restarts sddm again.
#
# Read-only apart from the overlay toggle, p2's shell restart and Firefox,
# noshim's wrapper move and sddm restarts, and /tmp: no package or partition
# is touched. The root is a RAM overlay, so nothing survives
# `systemctl reboot` anyway.
set -uo pipefail
export LC_ALL=C    # the image is fr_FR: keep top's "12.5" parseable

U="${T715_USER:-alarm}"
UID_U="$(id -u "$U")"
RUN="/run/user/$UID_U"

hsig() { ls -t "$RUN/hypr" 2>/dev/null | head -1; }
wdisp() { ls "$RUN" 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1; }
as_user() {
    runuser -u "$U" -- env XDG_RUNTIME_DIR="$RUN" \
        HYPRLAND_INSTANCE_SIGNATURE="$(hsig)" WAYLAND_DISPLAY="$(wdisp)" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$RUN/bus" \
        OMARCHY_PATH=/usr/share/omarchy "$@"
}
sec() { printf '\n== %s\n' "$*"; }
pids() { pgrep -x "$1" | tr '\n' ',' | sed 's/,$//'; }
gpufreq() {
    local d
    for d in /sys/class/devfreq/*; do
        case "$(basename "$d")" in *gpu*) cat "$d/cur_freq" 2>/dev/null; return ;; esac
    done
    echo "?"
}

report() {
    sec "kernel, boot"
    # The boot loader's command line carries the serial number and other
    # identifiers: masked, never logged.
    uname -r; uptime
    sed -E 's/((androidboot\.(serialno|un|ap_serial|sn|hw_id|em\.[a-z_]+|carrierid)|cordon|connie)=)[^ ]*/\1x/g' /proc/cmdline
    findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null
    [ -f /run/t715/initramfs.log ] && tail -n 25 /run/t715/initramfs.log

    sec "systemd"
    systemctl is-system-running
    systemctl --failed --no-legend --no-pager
    systemctl status sddm --no-pager -n 0 2>&1 | head -5

    sec "session processes"
    pgrep -a -x sddm; pgrep -a -f 'uwsm|start-hyprland'; pgrep -a -x Hyprland
    pgrep -a -x quickshell; pgrep -a -x Xwayland
    loginctl list-sessions --no-legend --no-pager

    sec "Hyprland log: GL, errors"
    local log="$RUN/hypr/$(hsig)/hyprland.log"
    if [ -f "$log" ]; then
        grep -m 12 -iE 'gles|egl|renderer|vendor|panfrost|mali|drm device|backend' "$log"
        grep -iE 'error|fail|crash' "$log" | tail -n 15
    else
        echo "no Hyprland log under $RUN/hypr"
    fi
    ls -t "/home/$U/.cache/hyprland/"hyprlandCrashReport* 2>/dev/null | head -3

    sec "hyprctl"
    as_user hyprctl version 2>&1 | head -3
    as_user hyprctl monitors 2>&1
    as_user hyprctl devices 2>&1 | sed -n '1,40p'
    as_user hyprctl clients 2>&1 | grep -E 'class:|title:' | head -20

    sec "quickshell (journal)"
    journalctl -b --no-pager -o cat -t quickshell -t omarchy-shell 2>/dev/null | tail -n 20
    journalctl -b --no-pager -o cat 2>/dev/null | grep -i quickshell | tail -n 10

    sec "memory, pressure"
    free -m
    for p in cpu memory io; do printf '%-7s %s\n' "$p" "$(head -1 /proc/pressure/$p)"; done
    swapon --show 2>/dev/null

    sec "GPU, temperatures"
    for d in /sys/class/devfreq/*; do
        echo "$(basename "$d"): cur $(cat "$d/cur_freq" 2>/dev/null) gov $(cat "$d/governor" 2>/dev/null) avail $(cat "$d/available_frequencies" 2>/dev/null)"
    done
    for z in /sys/class/thermal/thermal_zone*; do
        echo "$(cat "$z/type" 2>/dev/null): $(( $(cat "$z/temp" 2>/dev/null || echo 0) / 1000 )) C"
    done

    sec "top"
    top -b -n 1 -o %CPU | sed -n '1,22p'

    sec "journal errors (this boot)"
    journalctl -b -p err --no-pager -o short-monotonic 2>/dev/null | tail -n 40
}

# Frames sent to the panel: DECON interrupts, summed over CPUs (the panel is
# in DSI command mode, so DECON raises one per frame it pushes out).
decon_irqs() {
    awk '/drm_decon/ { for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i } END { print s + 0 }' /proc/interrupts
}

sample() {
    local n="${1:-30}" h q i f0 f1 t0 t1
    h="$(pids Hyprland)"; q="$(pids quickshell)"
    echo "t  fps  hypr%  qs%  load1  memfree_MiB  gpu_hz"
    f0="$(decon_irqs)"; t0="$(date +%s%N)"
    for ((i = 1; i <= n; i++)); do
        local hc=0 qc=0
        if [ -n "$h$q" ]; then
            read -r hc qc < <(top -b -d 1 -n 2 -p "${h}${h:+${q:+,}}${q}" |
                awk -v h=",$h," -v q=",$q," '
                    /^ *PID/ { blk++; next }
                    blk == 2 && $1 ~ /^[0-9]+$/ {
                        if (index(h, "," $1 ",")) hs += $9
                        if (index(q, "," $1 ",")) qs += $9
                    }
                    END { printf "%.0f %.0f\n", hs, qs }')
        else
            sleep 1
        fi
        f1="$(decon_irqs)"; t1="$(date +%s%N)"
        printf '%-3s %-4s %-6s %-4s %-6s %-12s %s\n' "$i" \
            "$(( (f1 - f0) * 1000000000 / (t1 - t0) ))" "$hc" "$qc" \
            "$(cut -d' ' -f1 /proc/loadavg)" \
            "$(awk '/MemAvailable/ { print int($2 / 1024) }' /proc/meminfo)" \
            "$(gpufreq)"
        f0="$f1"; t0="$t1"
    done
}

overlay() {
    local v=false
    [ "${1:-on}" = on ] && v=true
    as_user hyprctl eval "hl.config({ debug = { overlay = $v } })"
}

shot() {
    as_user grim /tmp/omarchy-shot.png && ls -l /tmp/omarchy-shot.png
}

bt() {
    sec "t715-bt-addr (journal)"
    journalctl -b --no-pager -o short-monotonic -t t715-bt-addr 2>/dev/null | tail -n 10
    systemctl list-units --no-legend --no-pager 't715-bt-addr@*' 2>/dev/null

    sec "kernel"
    lsmod | grep -E '^(hci_uart|btbcm|bluetooth) ' || echo "(no Bluetooth module loaded)"
    dmesg | grep -iE 'bluetooth|hci0|btbcm' | tail -n 15

    sec "controller"
    systemctl is-active bluetooth
    # The generated address stays out of the log: its first octet only (bit
    # 0x02 set = locally administered).
    bluetoothctl show 2>&1 | sed -E 's/^(Controller [0-9A-F]{2}):[0-9A-F:]{14}/\1:xx:xx:xx:xx:xx/' |
        grep -E 'Controller|Powered|Discoverable|Pairable|PowerState|No default'

    sec "scan 10 s"
    bluetoothctl --timeout 10 scan on >/dev/null 2>&1
    echo "devices seen: $(bluetoothctl devices 2>/dev/null | grep -c '^Device ')"
}

layers() {
    as_user hyprctl layers -j 2>/dev/null | python3 -c '
import json, sys
found = set()
def walk(node):
    if isinstance(node, dict):
        if isinstance(node.get("namespace"), str):
            found.add(node["namespace"])
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
walk(json.load(sys.stdin))
print(" ".join(sorted(found)))'
}
qs_pid() { pgrep -n -u "$U" -x quickshell; }
# CPU time of a process in ms (utime + stime) and its RSS in MiB.
cpu_ms() { awk -v hz="$(getconf CLK_TCK)" '{ print int(($14 + $15) * 1000 / hz) }' "/proc/$1/stat" 2>/dev/null || echo 0; }
rss_mib() { awk '/^VmRSS/ { print int($2 / 1024) }' "/proc/$1/status" 2>/dev/null || echo 0; }
osk_visible() {
    as_user busctl --user get-property sm.puri.OSK0 /sm/puri/OSK0 sm.puri.OSK0 Visible 2>/dev/null |
        awk '{ print $2 }'
}

p2() {
    local q l t0 t rc c0 name call close
    sec "shell (as it booted)"
    journalctl -b --no-pager -o short-monotonic -t omarchy-shell 2>/dev/null |
        grep -E 'Launching config|Configuration Loaded' | tail -n 2
    q="$(qs_pid)"
    echo "quickshell $q: cpu $(cpu_ms "$q") ms, rss $(rss_mib "$q") MiB, up $(ps -o etimes= -p "$q" | tr -d ' ') s"
    echo "layers: $(layers)"
    pgrep -a -u "$U" -f 'omamobile-osk-watch|inotifywait|squeekboard' | cut -c1-120
    sec "shell warnings (this boot)"
    journalctl -b --no-pager -o cat -t omarchy-shell 2>/dev/null | grep -cE 'WARN|ERROR'
    journalctl -b --no-pager -o cat -t omarchy-shell 2>/dev/null | grep -E 'WARN|ERROR' | tail -n 15

    sec "cold restart: time to ping, to the dock and to the home page"
    t0="$(date +%s%N)"
    as_user omarchy-restart-shell; rc=$?
    echo "ping after $(( ($(date +%s%N) - t0) / 1000000 )) ms (exit $rc)"
    for ((t = 0; t < 120; t++)); do
        l=" $(layers) "
        [[ $l == *" omamobile-home "* && $l == *" omamobile-dock "* ]] && break
        sleep 0.5
    done
    echo "home and dock after $(( ($(date +%s%N) - t0) / 1000000 )) ms"
    sleep 10
    q="$(qs_pid)"
    echo "quickshell $q 10 s later: cpu $(cpu_ms "$q") ms, rss $(rss_mib "$q") MiB"
    echo "layers: $(layers)"

    sec "sheets through the shell's IPC (cost = quickshell CPU over 3 s)"
    # Each line: name|IPC call|IPC call that closes it. eval keeps '' an
    # empty argument (goHome takes one, as t715-keys passes it).
    while IFS='|' read -r name call close; do
        c0="$(cpu_ms "$q")"
        eval "as_user omarchy-shell $call"
        sleep 3
        echo "$name: cpu +$(( $(cpu_ms "$q") - c0 )) ms; layers: $(layers)"
        as_user grim "/tmp/p2-$name.png"
        [ -n "$close" ] && eval "as_user omarchy-shell $close"
        sleep 1
    done <<'EOF'
home|shell call omamobile.home goHome ''|
launcher|shell toggle omamobile.launcher {}|shell hide omamobile.launcher
quicksettings|shell toggle omamobile.quicksettings {}|shell hide omamobile.quicksettings
switcher|shell toggle omamobile.switcher {}|shell hide omamobile.switcher
EOF
    ls -l /tmp/p2-*.png

    sec "squeekboard for Firefox's address bar"
    echo "before: visible $(osk_visible)"
    as_user hyprctl dispatch 'hl.dsp.exec_cmd("firefox")' >/dev/null
    for ((t = 0; t < 40; t++)); do
        [ "$(osk_visible)" = true ] && break
        sleep 1
    done
    echo "after ${t} s: visible $(osk_visible); layers: $(layers)"
    as_user grim /tmp/p2-firefox-osk.png
    # Closed as the switcher closes windows (the app's own close request).
    # A killed Firefox leaves squeekboard up: Hyprland does not deactivate
    # the input method when its text-input client dies.
    as_user hyprctl dispatch 'hl.dsp.window.close()' >/dev/null
    for ((t = 0; t < 15; t++)); do
        pgrep -u "$U" -x firefox >/dev/null || break
        sleep 1
    done
    pkill -u "$U" -x firefox && echo "Firefox killed after ${t} s"
    sleep 3
    echo "Firefox closed: visible $(osk_visible)"
}

# Kernel options from /proc/config.gz, when the kernel has IKCONFIG_PROC.
kconfig() {
    [ -r /proc/config.gz ] || { echo "(no /proc/config.gz)"; return; }
    zcat /proc/config.gz | grep -E "^CONFIG_($1)=" || echo "(none of $1 set)"
}
# MAC addresses out of the log: first octet kept (bit 0x02 set = locally
# administered).
mask_mac() { sed -E 's/\b([0-9a-fA-F]{2})(:[0-9a-fA-F]{2}){5}\b/\1:xx:xx:xx:xx:xx/g'; }

image() {
    local h
    sec "kernel"
    uname -r
    kconfig 'HZ|HZ_[0-9]+|PREEMPT|PREEMPT_NONE|HIGH_RES_TIMERS|NO_HZ_IDLE|SCHED_MC|LRU_GEN|LRU_GEN_ENABLED|EXYNOS_IOMMU|RTC_SYSTOHC'
    # Without IKCONFIG: the build banner, the timer resolution (1 ns with
    # high-resolution timers) and the scheduler's CPU capacities.
    uname -v
    grep -m 1 -E '^ *\.resolution' /proc/timer_list 2>/dev/null
    echo "cpu capacity: $(cat /sys/devices/system/cpu/cpu*/cpu_capacity 2>/dev/null | tr '\n' ' ')"
    echo "lru_gen: $(cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || echo '?')"

    sec "IOMMU groups"
    for g in /sys/kernel/iommu_groups/*; do
        [ -d "$g" ] || { echo "(none)"; break; }
        echo "$(basename "$g") type $(cat "$g/type" 2>/dev/null): $(ls "$g/devices" | tr '\n' ' ')"
    done
    dmesg | grep -iE 'sysmmu|iommu' | tail -n 10

    sec "Hyprland"
    as_user hyprctl version 2>&1 | head -2
    h="$(pgrep -x Hyprland | head -1)"
    if grep -q t715-dmabuf-check-shim "/proc/$h/maps" 2>/dev/null; then
        echo "dmabuf shim: mapped in Hyprland $h"
    else
        echo "dmabuf shim: not mapped in Hyprland $h"
    fi
    echo "clients: $(as_user hyprctl clients 2>/dev/null | grep -c '^Window ')"
    as_user hyprctl clients 2>&1 | grep -E 'class:' | sort | uniq -c
    echo "layers: $(layers)"
    dmesg | grep -i 'contiguous' | tail -n 5

    sec "t715-keys (user unit)"
    as_user systemctl --user is-active t715-keys.service
    journalctl -b --no-pager -o short-monotonic _SYSTEMD_USER_UNIT=t715-keys.service 2>/dev/null | tail -n 8

    sec "squeekboard"
    as_user systemctl --user is-active t715-squeekboard.service
    as_user systemctl --user status t715-squeekboard.service --no-pager -n 0 2>&1 | sed -n '1,4p'
    echo "input sources: $(as_user gsettings get org.gnome.desktop.input-sources sources 2>&1)"

    sec "bt-agent (skipped), adapter not pairable"
    as_user systemctl --user status bt-agent.service --no-pager -n 0 2>&1 | grep -E 'Loaded|Active|Condition'
    bluetoothctl show 2>&1 | grep -E 'Powered|Pairable|Discoverable'
}

wifi() {
    local ifc
    sec "t715-wifi-addr (journal)"
    journalctl -b --no-pager -o short-monotonic -t t715-wifi-addr 2>/dev/null | tail -n 5

    sec "kernel"
    lsmod | grep -E '^(brcmfmac|brcmutil|cfg80211|pci_exynos) ' || echo "(no Wi-Fi module loaded)"
    dmesg | grep -iE 'brcmf|pci.*exynos|pcie' | mask_mac | tail -n 15
    ls -l /usr/lib/firmware/brcm/brcmfmac4358-pcie.* 2>&1

    sec "interface"
    ifc="$(ls /sys/class/net | grep -E '^wl' | head -1)"
    if [ -n "$ifc" ]; then
        ip -br link show "$ifc" | mask_mac
        echo "locally administered: $(( 0x$(cut -c1-2 "/sys/class/net/$ifc/address") & 2 ? 1 : 0 ))"
    else
        echo "(no wl* interface)"
    fi

    sec "NetworkManager"
    systemctl is-active NetworkManager wpa_supplicant 2>&1 | tr '\n' ' '; echo
    nmcli -t -f DEVICE,TYPE,STATE device status 2>&1
    nmcli -t -f WIFI,WIFI-HW general 2>&1
    # Type and device only: the connection's name is the network's SSID.
    nmcli -t -f TYPE,DEVICE,STATE connection show --active 2>&1 | grep -v '^loopback:'

    sec "scan (count per band)"
    nmcli -t -f FREQ device wifi list --rescan yes 2>/dev/null |
        awk '{ f = $1 + 0; if (f < 3000) a++; else b++ } END { printf "2.4 GHz: %d, 5 GHz: %d\n", a, b }'

    sec "time"
    timedatectl show -p NTPSynchronized -p TimeUSec -p Timezone 2>&1
    timedatectl timesync-status 2>&1 | grep -E 'Server|Poll|Offset' | head -4
    echo "RTC: $(date -u -d "@$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null || echo 0)" '+%F %T UTC'); system: $(date -u '+%F %T UTC')"
}

# Waits for the shell after an sddm restart: Hyprland's instance, then the
# home and dock layers.
wait_shell() {
    local t l
    for ((t = 0; t < 120; t++)); do
        if pgrep -x Hyprland >/dev/null && [ -n "$(hsig)" ]; then
            l=" $(layers) "
            [[ $l == *" omamobile-home "* && $l == *" omamobile-dock "* ]] && break
        fi
        sleep 1
    done
    echo "shell after ${t} s; layers: $(layers)"
}

noshim() {
    local w=/usr/local/bin/Hyprland m0 h c
    if [ "${1:-on}" = off ]; then
        [ -e "$w.t715-shim" ] && mv "$w.t715-shim" "$w"
        systemctl restart sddm
        sleep 5; wait_shell
        h="$(pgrep -x Hyprland | head -1)"
        grep -q t715-dmabuf-check-shim "/proc/$h/maps" && echo "shim mapped again in Hyprland $h"
        return
    fi
    [ -e "$w" ] || { echo "no $w (already moved?)"; return 1; }
    m0="$(dmesg | wc -l)"
    mv "$w" "$w.t715-shim"
    sec "sddm restart without the wrapper"
    systemctl restart sddm
    sleep 5; wait_shell
    h="$(pgrep -x Hyprland | head -1)"
    echo "Hyprland $h: $(readlink "/proc/$h/exe")"
    grep -q t715-dmabuf-check-shim "/proc/$h/maps" 2>/dev/null && echo "shim still mapped" || echo "shim not mapped"

    sec "GPU clients"
    for c in foot firefox; do
        as_user hyprctl dispatch "hl.dsp.exec_cmd(\"$c\")" >/dev/null
    done
    sleep 25
    echo "running: foot $(pids foot) firefox $(pids firefox) quickshell $(pids quickshell)"
    as_user hyprctl clients 2>&1 | grep -E 'class:' | sort | uniq -c
    as_user grim /tmp/noshim.png && ls -l /tmp/noshim.png
    pkill -u "$U" -x firefox; pkill -u "$U" -x foot

    sec "kernel log since the restart"
    dmesg | tail -n "+$((m0 + 1))" | grep -iE 'contiguous|sysmmu|iommu|fault|exynos-drm|panfrost' | tail -n 20
    echo "(end; \"noshim off\" puts the wrapper back)"
}

cmd="${1:-report}"; shift || true
case "$cmd" in
    report|sample|overlay|shot|bt|p2|image|wifi|noshim) "$cmd" "$@" ;;
    *) echo "usage: report | sample [N] | overlay on|off | shot | bt | p2 | image | wifi | noshim [off]" >&2; exit 2 ;;
esac
