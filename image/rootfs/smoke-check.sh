#!/bin/bash
# smoke-check — "do the binaries load" check of Omarchy's session stack in
# the SM-T715 image (omarchy-tab-s2, rootfs/smoke-check.sh, installed as
# /usr/lib/t715-omarchy/smoke-check).
#
# tools/build-rootfs runs it in the final armv7h image (under qemu, so no
# DRM device and no compositor) before the export; it can be rerun on the
# tablet as root or as alarm. It starts nothing and writes only to a
# temporary directory.
#
# FAIL (exit 1): Hyprland, quickshell, uwsm or sddm cannot report a version;
#                ldd misses a library of Hyprland, quickshell, sddm or
#                squeekboard; the dmabuf-check shim is not wired; the touch
#                layer (t715-keys --check, the on-screen keyboard's gsettings,
#                terminal layouts and session environment) is not in place;
#                the touch shell
#                (P2) is not: omamobile-omarchy's patch series not in place
#                (its status and verify), a QML module its plugins import
#                missing, its QML or helpers not parsing, alarm's profile or
#                plugin links wrong; the Bluetooth patch RAM, t715-bt-addr or
#                PipeWire's BlueZ plugin missing; the Wi-Fi firmware, NVRAM
#                or t715-wifi-addr (or logger) missing, or NetworkManager's merged
#                configuration not driving Wi-Fi through wpa_supplicant with
#                the USB link unmanaged; alarm's Hyprland config does not
#                verify.
# WARN/INFO (never fail): other session binaries, QML modules imported by the
#                Omarchy shell that cannot be found.
set -u

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 0755 "$tmp"
mkdir -p "$tmp/home" "$tmp/run"
chmod 0700 "$tmp/run"

# Hyprland refuses to run as root: run the commands as alarm when started
# as root.
runas=()
if [ "$(id -u)" = 0 ] && id alarm >/dev/null 2>&1; then
    chown alarm:alarm "$tmp/home" "$tmp/run"
    runas=(runuser -u alarm --)
fi
run() {
    timeout 180 "${runas[@]}" env -i PATH=/usr/local/bin:/usr/bin \
        HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/run" LANG=C.UTF-8 \
        QT_QPA_PLATFORM=offscreen "$@"
}
indent() { sed 's/^/        /'; }

echo "== versions =="
# version LABEL CMD...: PASS with the first lines of the output.
version() {
    local label="$1" out rc
    shift
    out="$(run "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        pass "$label: $(printf '%s\n' "$out" | head -n1)"
        printf '%s\n' "$out" | sed -n '2,3p' | indent
    else
        fail "$label (exit $rc): $(printf '%s\n' "$out" | head -n1)"
        printf '%s\n' "$out" | sed -n '2,6p' | indent
    fi
}
version "Hyprland --version" Hyprland --version
version "quickshell --version" quickshell --version
# SDDM has no --version (an unknown option starts the daemon): have it print
# its built-in default configuration instead, which runs the binary.
out="$(run sddm --example-config 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^\[Autologin\]'; then
    pass "sddm --example-config runs (SDDM has no --version; package $(pacman -Q sddm 2>/dev/null | cut -d' ' -f2))"
else
    fail "sddm --example-config (exit $rc): $(printf '%s\n' "$out" | head -n1)"
fi

# uwsm: the first of these that prints a version.
uwsm_done=0
for args in "--version" "version" "-v"; do
    # shellcheck disable=SC2086
    out="$(run uwsm $args 2>&1)" && [ -n "$out" ] \
        && printf '%s\n' "$out" | grep -qiE '[0-9]+\.[0-9]+' && {
        pass "uwsm $args: $(printf '%s\n' "$out" | head -n1)"
        uwsm_done=1
        break
    }
done
if [ "$uwsm_done" = 0 ]; then
    if out="$(run uwsm --help 2>&1)"; then
        pass "uwsm --help runs (no version option; package $(pacman -Q uwsm 2>/dev/null | cut -d' ' -f2))"
    else
        fail "uwsm cannot run: $(printf '%s\n' "$out" | tail -n1)"
    fi
fi

echo "== Hyprland dmabuf-check shim =="
# The wrapper must come first in the session's PATH, the shim must take
# Hyprland's drmPrimeFDToHandle (Arch links with -z now, so LD_DEBUG shows
# the binding at start-up), and Hyprland's children must not inherit it.
shim=/usr/local/lib/t715-dmabuf-check-shim.so
hyprland_cmd="$(run sh -c 'command -v Hyprland')"
if [ "$hyprland_cmd" = /usr/local/bin/Hyprland ]; then
    pass "Hyprland in PATH is the wrapper ($hyprland_cmd)"
else
    fail "Hyprland in PATH is ${hyprland_cmd:-missing}, not /usr/local/bin/Hyprland"
fi
if run env LD_DEBUG=bindings LD_PRELOAD="$shim" /usr/bin/Hyprland --version 2>&1 \
        | grep -q "binding file /usr/bin/Hyprland .* to $shim .*drmPrimeFDToHandle"; then
    pass "Hyprland's drmPrimeFDToHandle binds to the shim"
else
    fail "Hyprland's drmPrimeFDToHandle does not bind to $shim"
fi
if run env LD_PRELOAD="$shim" env | grep -q '^LD_PRELOAD='; then
    fail "the shim leaves LD_PRELOAD to child processes"
else
    pass "the shim drops LD_PRELOAD for child processes"
fi

echo "== shared libraries (ldd) =="
# libs BIN REQUIRED: PASS/FAIL (or WARN when not required).
libs() {
    local bin="$1" required="$2" path out missing n
    path="$(command -v "$bin" 2>/dev/null || true)"
    if [ -z "$path" ]; then
        if [ "$required" = 1 ]; then fail "$bin: not installed"; else warn "$bin: not installed"; fi
        return
    fi
    path="$(readlink -f "$path")"
    if ! out="$(ldd "$path" 2>&1)"; then
        if [ "$required" = 1 ]; then fail "ldd $path: $(printf '%s\n' "$out" | head -n1)"
        else warn "ldd $path: $(printf '%s\n' "$out" | head -n1)"; fi
        return
    fi
    missing="$(printf '%s\n' "$out" | awk '/not found/ {print $1}' | tr '\n' ' ')"
    n="$(printf '%s\n' "$out" | grep -c '=>' || true)"
    if [ -n "$missing" ]; then
        if [ "$required" = 1 ]; then fail "ldd $path: not found: $missing"
        else warn "ldd $path: not found: $missing"; fi
    elif [ "$required" = 1 ]; then
        pass "ldd $path: $n libraries, none missing"
    else
        info "ldd $path: $n libraries, none missing"
    fi
}
# The binary itself: "Hyprland" in PATH is the shim's shell wrapper.
libs /usr/bin/Hyprland 1
libs /usr/local/lib/t715-dmabuf-check-shim.so 1
libs quickshell 1
libs sddm 1
libs squeekboard 1
for b in start-hyprland hyprctl Xwayland sddm-greeter-qt6 foot \
         /usr/lib/firefox/firefox; do
    libs "$b" 0
done
for f in /usr/lib/xdg-desktop-portal-hyprland /usr/lib/dri/panfrost_dri.so \
         /usr/lib/dri/exynos_dri.so /usr/lib/libgallium-*.so; do
    [ -e "$f" ] || continue
    if missing="$(ldd "$f" 2>&1 | awk '/not found/ {print $1}' | tr '\n' ' ')" && [ -z "$missing" ]; then
        info "ldd $f: none missing"
    else
        warn "ldd $f: not found: $missing"
    fi
done
dri="$(ls /usr/lib/dri/ 2>/dev/null | grep -E '^(panfrost|exynos|kmsro|libdril)' | tr '\n' ' ')"
info "Mesa DRI entries for this SoC: ${dri:-none}"

echo "== QML modules imported by the Omarchy shell =="
shell_dir=/usr/share/omarchy/shell
qs_bin="$(readlink -f "$(command -v quickshell 2>/dev/null || echo /usr/bin/quickshell)")"
if [ -d "$shell_dir" ]; then
    found=""; builtin=""; missing=""
    while IFS= read -r m; do
        case "$m" in qs|qs.*) continue ;; esac   # the shell's own modules
        d="/usr/lib/qt6/qml/${m//.//}"
        if [ -f "$d/qmldir" ]; then
            found="$found $m"
        elif [[ $m == Quickshell* ]] && [ -f "$qs_bin" ] && grep -aqF "$m" "$qs_bin"; then
            builtin="$builtin $m"
        else
            missing="$missing $m"
        fi
    done < <(find "$shell_dir" -name '*.qml' -exec \
                 sed -n 's/^[[:space:]]*import[[:space:]]\{1,\}\([A-Za-z][A-Za-z0-9_.]*\).*/\1/p' {} + | sort -u)
    info "in /usr/lib/qt6/qml:${found:- none}"
    info "built into quickshell:${builtin:- none}"
    if [ -n "$missing" ]; then
        warn "not found (the shell may fail to load them):$missing"
    else
        info "every imported module was found"
    fi
else
    warn "no $shell_dir"
fi

echo "== touch layer P1 (docs/image/ROOTFS.md) =="
# t715-keys: its interpreter runs, the event size matches the kernel's, the
# commands it calls exist (no key device in a container: listed as none).
out="$(run /usr/local/bin/t715-keys --check 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass "t715-keys --check: $(printf '%s\n' "$out" | head -n1 | sed 's/^t715-keys: //')"
else
    fail "t715-keys --check (exit $rc): $(printf '%s\n' "$out" | grep -m1 FAIL || printf '%s\n' "$out" | tail -n1)"
fi
# The on-screen keyboard shows itself only with this gsetting on (alarm's
# dconf database, written at build time).
osk="$(run env HOME=/home/alarm gsettings get org.gnome.desktop.a11y.applications screen-keyboard-enabled 2>/dev/null)"
if [ "$osk" = true ]; then
    pass "alarm's gsetting org.gnome.desktop.a11y.applications screen-keyboard-enabled: true"
else
    fail "alarm's gsetting screen-keyboard-enabled: ${osk:-unreadable}, not true"
fi
# Its layout: the first input source, US QWERTY.
want="[('xkb', 'us'), ('xkb', 'fr')]"
src="$(run env HOME=/home/alarm gsettings get org.gnome.desktop.input-sources sources 2>/dev/null)"
if [ "$src" = "$want" ]; then
    pass "alarm's gsetting org.gnome.desktop.input-sources sources: $src"
else
    fail "alarm's gsetting input-sources sources: ${src:-unreadable}, not $want"
fi
# alarm's terminal layouts with Esc load in squeekboard's own layout parser.
for l in us fr; do
    f=/home/alarm/.local/share/squeekboard/keyboards/terminal/$l.yaml
    out="$(run squeekboard-test-layout "$f" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'Test result: OK'; then
        pass "squeekboard-test-layout $f: OK"
    else
        fail "squeekboard-test-layout $f (exit $rc): $(printf '%s\n' "$out" | grep -v '^$' | head -n2 | tr '\n' ' ')"
    fi
done
# The session environment as systemd's user manager builds it: the Wayland
# input method must win over Omarchy's fcitx values.
gen=/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator
if [ -x "$gen" ]; then
    envd="$(run env HOME=/home/alarm "$gen" 2>/dev/null)"
    want="QT_IM_MODULE=wayland GTK_IM_MODULE=wayland INPUT_METHOD=none XMODIFIERS=@im=none SDL_IM_MODULE=none"
    bad=""
    for kv in $want; do
        printf '%s\n' "$envd" | grep -qx -- "$kv" || bad="$bad ${kv%%=*}=$(printf '%s\n' "$envd" | sed -n "s/^${kv%%=*}=//p")"
    done
    if [ -z "$bad" ]; then
        pass "user session environment (environment.d): $want"
    else
        fail "user session environment (environment.d):$bad"
    fi
else
    warn "no $gen: session environment not checked"
fi

echo "== touch layer P2: the touch shell (docs/image/ROOTFS.md) =="
# omamobile-omarchy's patch series is in place on this Omarchy (the applier's
# own status and verify: every patched file still has the sha256 it wrote).
patches=/usr/bin/omamobile-omarchy-patches
if [ -x "$patches" ]; then
    out="$("$patches" status 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qx 'result: ok'; then
        pass "omamobile-omarchy-patches status: $(printf '%s\n' "$out" | sed -n 's/^message: //p')"
    else
        fail "omamobile-omarchy-patches status (exit $rc): $(printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-160)"
    fi
    out="$("$patches" verify 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "omamobile-omarchy-patches verify: $(printf '%s\n' "$out" | head -n1 | sed 's/^ok *//')"
    else
        fail "omamobile-omarchy-patches verify (exit $rc): $(printf '%s\n' "$out" | grep -m1 FAIL)"
    fi
else
    fail "no $patches (omamobile-omarchy)"
fi
# Every QML module the touch shell's plugins import must be installed: a
# missing one makes the Omarchy shell drop that plugin.
mobile_dir=/usr/share/omamobile/shell/plugins
if [ -d "$mobile_dir" ]; then
    found=""; builtin=""; missing=""
    while IFS= read -r m; do
        case "$m" in qs|qs.*) continue ;; esac   # the Omarchy shell's own modules
        d="/usr/lib/qt6/qml/${m//.//}"
        if [ -f "$d/qmldir" ]; then
            found="$found $m"
        elif [[ $m == Quickshell* ]] && [ -f "$qs_bin" ] && grep -aqF "$m" "$qs_bin"; then
            builtin="$builtin $m"
        else
            missing="$missing $m"
        fi
    done < <(find "$mobile_dir" -name '*.qml' -exec \
                 sed -n 's/^[[:space:]]*import[[:space:]]\{1,\}\([A-Za-z][A-Za-z0-9_.]*\).*/\1/p' {} + | sort -u)
    if [ -z "$missing" ]; then
        pass "QML modules of the omamobile plugins: in /usr/lib/qt6/qml:${found:- none}; built into quickshell:${builtin:- none}"
    else
        fail "QML modules of the omamobile plugins not found:$missing"
    fi
    # The plugin QML parses (qmlformat, Qt's own parser), as upstream's test/all checks it.
    qmlformat=/usr/lib/qt6/bin/qmlformat
    if [ -x "$qmlformat" ]; then
        bad=""; n=0
        while IFS= read -r -d '' q; do
            n=$((n + 1))
            run "$qmlformat" "$q" >/dev/null 2>&1 || bad="$bad ${q#$mobile_dir/}"
        done < <(find "$mobile_dir" -name '*.qml' -print0)
        if [ -z "$bad" ]; then pass "the $n QML files of the omamobile plugins parse (qmlformat)"
        else fail "omamobile QML that does not parse:$bad"; fi
    else
        info "no $qmlformat: the omamobile QML is not parsed here"
    fi
else
    fail "no $mobile_dir (omamobile-shell)"
fi
# Its helpers run on this Python and bash.
bad=""
for b in omamobile-setup-user omamobile-launch omamobile-osk-watch omamobile-bt-agent omamobile-screenrecord omamobile-widget; do
    f="/usr/bin/$b"
    if [ ! -x "$f" ]; then bad="$bad $b(missing)"; continue; fi
    case "$(head -n1 "$f")" in
        *python3*) python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null || bad="$bad $b" ;;
        *)         bash -n "$f" 2>/dev/null || bad="$bad $b" ;;
    esac
done
if [ -z "$bad" ]; then pass "omamobile helpers parse (python3, bash)"; else fail "omamobile helpers:$bad"; fi
if run python3 -c 'import dbus, dbus.mainloop.glib; from gi.repository import GLib' 2>/dev/null; then
    pass "python3 has dbus and GLib (omamobile-osk-watch, omamobile-bt-agent)"
else
    fail "python3 cannot import dbus or gi.repository.GLib (omamobile-osk-watch, omamobile-bt-agent)"
fi
# alarm's shell profile: the touch shell's bar, its plugins linked.
shell_json=/home/alarm/.config/omarchy/shell.json
if python3 -c 'import json, sys; c = json.load(open(sys.argv[1])); assert c["bar"]["id"] == "omamobile.bar"' "$shell_json" 2>/dev/null; then
    pass "alarm's shell.json: bar omamobile.bar, plugins $(python3 -c 'import json, sys; print(" ".join(p["id"] for p in json.load(open(sys.argv[1]))["plugins"]))' "$shell_json")"
else
    fail "alarm's shell.json does not select omamobile.bar"
fi
bad=""
for p in "$mobile_dir"/omamobile.*; do
    [ "$(readlink -f "/home/alarm/.config/omarchy/plugins/${p##*/}")" = "$p" ] || bad="$bad ${p##*/}"
done
if [ -z "$bad" ]; then pass "omamobile plugins linked into alarm's ~/.config/omarchy/plugins"
else fail "omamobile plugins not linked for alarm:$bad"; fi

echo "== Bluetooth (docs/image/ROOTFS.md) =="
fw=/usr/lib/firmware/brcm
if [ -e /usr/share/t715-omarchy/build/public-image ]; then
    if [ ! -e "$fw/BCM4358A3.hcd" ] && [ "$(readlink "$fw/BCM.samsung,gts28ltexx.hcd")" = BCM4358A3.hcd ]; then
        pass "public image: no patch RAM, BCM.samsung,gts28ltexx.hcd ready for the one copied at boot"
    else
        fail "public image: a patch RAM in $fw, or no BCM.samsung,gts28ltexx.hcd link"
    fi
elif [ -f "$fw/BCM4358A3.hcd" ] && [ "$(readlink "$fw/BCM.samsung,gts28ltexx.hcd")" = BCM4358A3.hcd ]; then
    pass "BCM4358 patch RAM: $fw/BCM4358A3.hcd ($(wc -c < "$fw/BCM4358A3.hcd") bytes), BCM.samsung,gts28ltexx.hcd -> BCM4358A3.hcd"
else
    fail "no BCM4358 patch RAM in $fw, or no BCM.samsung,gts28ltexx.hcd link"
fi
if sh -n /usr/local/sbin/t715-bt-addr 2>/dev/null && command -v btmgmt >/dev/null; then
    pass "t715-bt-addr parses; btmgmt present"
else
    fail "t715-bt-addr does not parse, or no btmgmt (bluez-utils)"
fi
libs /usr/lib/bluetooth/bluetoothd 0
# Bluetooth audio: wireplumber needs PipeWire's BlueZ SPA plugin (pipewire-audio).
spa=/usr/lib/spa-0.2/bluez5/libspa-bluez5.so
if [ -f "$spa" ] && missing="$(ldd "$spa" 2>&1 | awk '/not found/ {print $1}' | tr '\n' ' ')" && [ -z "$missing" ]; then
    pass "PipeWire's BlueZ plugin $spa: present, no library missing"
else
    fail "PipeWire's BlueZ plugin $spa: missing, or not found: ${missing:-?}"
fi

echo "== Wi-Fi (docs/image/ROOTFS.md) =="
# The NVRAM holds the tablet's MAC address: only its presence and size here.
if [ -e /usr/share/t715-omarchy/build/public-image ]; then
    if [ -f "$fw/brcmfmac4358-pcie.bin" ] && [ ! -e "$fw/samsung-gts28/nvram_net.txt" ] \
            && [ "$(readlink "$fw/brcmfmac4358-pcie.txt")" = samsung-gts28/nvram_net.txt ]; then
        pass "public image: brcmfmac4358-pcie.bin, no NVRAM, the link ready for the one copied at boot"
    else
        fail "public image: no brcmfmac4358-pcie.bin, an NVRAM, or no brcmfmac4358-pcie.txt link"
    fi
elif [ -f "$fw/brcmfmac4358-pcie.bin" ] && [ -s "$fw/samsung-gts28/nvram_net.txt" ] \
        && [ "$(readlink "$fw/brcmfmac4358-pcie.txt")" = samsung-gts28/nvram_net.txt ]; then
    pass "BCM4358 Wi-Fi: $fw/brcmfmac4358-pcie.bin ($(wc -c < "$fw/brcmfmac4358-pcie.bin") bytes), brcmfmac4358-pcie.txt -> samsung-gts28/nvram_net.txt ($(wc -c < "$fw/samsung-gts28/nvram_net.txt") bytes)"
else
    fail "no brcmfmac4358-pcie.bin in $fw, no NVRAM, or no brcmfmac4358-pcie.txt link"
fi
# t715-wifi-addr runs from udev and logs to the journal with logger.
if sh -n /usr/local/sbin/t715-wifi-addr 2>/dev/null && command -v logger >/dev/null \
        && command -v wpa_supplicant >/dev/null; then
    pass "t715-wifi-addr parses; logger and wpa_supplicant present"
else
    fail "t715-wifi-addr does not parse, or no logger or wpa_supplicant"
fi
# NetworkManager's own merged configuration (it prints it and exits).
nmconf="$(NetworkManager --print-config 2>/dev/null)"
backend="$(printf '%s\n' "$nmconf" | sed -n 's/^#\{0,1\} *wifi\.backend=//p' | tail -n1)"
unmanaged="$(printf '%s\n' "$nmconf" | sed -n 's/^unmanaged-devices=//p' | tail -n1)"
mac="$(printf '%s\n' "$nmconf" | awk '/^\[/ {s = $0} s == "[connection-t715-wifi]" && /^wifi\.cloned-mac-address=/ {print}')"
if [ "$backend" = wpa_supplicant ] && printf '%s\n' "$unmanaged" | grep -q 'interface-name:usb0' \
        && printf '%s\n' "$unmanaged" | grep -q 'interface-name:rndis0' && [ "$mac" = 'wifi.cloned-mac-address=preserve' ]; then
    pass "NetworkManager --print-config: wifi.backend=$backend, unmanaged-devices=$unmanaged, [connection-t715-wifi] $mac"
else
    fail "NetworkManager --print-config: wifi.backend=${backend:-?}, unmanaged-devices=${unmanaged:-none}, t715 Wi-Fi MAC: ${mac:-none}"
fi

echo "== Hyprland config (alarm's) =="
# Required: a config error makes Hyprland draw its error bar, and Hyprland's
# text rendering can deadlock on this device (docs/journal/ONDEVICE-2026-10-28.md).
cfg=/home/alarm/.config/hypr/hyprland.lua
if [ -r "$cfg" ] && run Hyprland --help 2>&1 | grep -q -- '--verify-config'; then
    # Omarchy's bootstrap.lua finds the user's modules through $HOME.
    out="$(run env HOME=/home/alarm OMARCHY_PATH=/usr/share/omarchy \
               Hyprland --verify-config --config "$cfg" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'config ok'; then
        pass "Hyprland --verify-config --config $cfg: config ok"
    else
        fail "Hyprland --verify-config --config $cfg: exit $rc, no \"config ok\""
    fi
    printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -v -e '^[[:space:]]*$' -e '^DEBUG' \
        | tail -n 8 | indent
else
    fail "Hyprland --verify-config not available or $cfg not readable"
fi

echo "-----"
if [ "$fails" -eq 0 ]; then
    echo "SMOKE: PASS"
    exit 0
fi
echo "SMOKE: FAIL ($fails)"
exit 1
